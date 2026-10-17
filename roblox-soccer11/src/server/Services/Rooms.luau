--!nonstrict
--[[
	Rooms — オンラインの協力 (Co-op: 最大 3 人 vs CPU) と対戦 (Versus: 1 チーム最大 3 人ずつ)。

	試合はサーバーで動かす (Match は Roblox API 非依存なので、そのまま使える)。
	クライアントは入力を送り、サーバーは 15 回 / 秒で Snapshot を送る。
	報酬はサーバーが試合結果から直接計算する (申告に頼らない)。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Match = require(Shared:WaitForChild("Match"))
local Snapshot = require(Shared:WaitForChild("Snapshot"))
local Rewards = require(Shared:WaitForChild("Rewards"))
local Data = require(script.Parent.Data)
local Store = require(script.Parent.Store)

local Rooms = {}

local ONLINE = Config.Online
local STEP = 1 / ONLINE.TickRate
local SNAP = 1 / ONLINE.SnapshotRate

local rooms = {} -- id -> room
local byPlayer = {} -- Player -> room
local nextId = 1
local inputBudget = {} -- Player -> { t, n } 入力の送りすぎ対策

local function members(room)
	local list = {}
	for _, m in room.members do
		table.insert(list, m)
	end
	table.sort(list, function(a, b)
		return a.joinOrder < b.joinOrder
	end)
	return list
end

local function teamCount(room, team)
	local n = 0
	for _, m in room.members do
		if m.team == team then
			n += 1
		end
	end
	return n
end

local function summary(room)
	local list = {}
	for _, m in members(room) do
		table.insert(list, { name = m.name, team = m.team, userId = m.userId, host = m.userId == room.hostId })
	end
	return {
		id = room.id,
		mode = room.mode,
		state = room.state,
		host = room.hostName,
		count = #list,
		cap = room.mode == "coop" and ONLINE.MaxPerTeam or ONLINE.MaxPerTeam * 2,
		members = list,
		length = room.opts.length,
		difficulty = room.opts.difficulty,
		cup = room.opts.cup,
	}
end

function Rooms.list()
	local out = {}
	for _, room in rooms do
		table.insert(out, summary(room))
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

local function broadcastList()
	local list = Rooms.list()
	for _, p in Players:GetPlayers() do
		Net.event("Rooms"):FireClient(p, list)
	end
end

local function pushRoom(room)
	local s = summary(room)
	for _, m in room.members do
		Net.event("RoomState"):FireClient(m.player, s)
	end
	broadcastList()
end

local function sanitizeOpts(raw)
	local o = typeof(raw) == "table" and raw or {}
	local length = Rewards.isValidLength(o.length) and o.length or Config.MatchTime
	local diff = (typeof(o.difficulty) == "number" and o.difficulty >= 1 and o.difficulty <= #Config.Difficulties)
			and math.floor(o.difficulty)
		or Config.DefaultDifficulty
	local formation = (typeof(o.formation) == "string" and Config.Formations[o.formation] ~= nil) and o.formation or "433"
	local assist = (o.assist == 0 or o.assist == 1 or o.assist == 2) and o.assist or Config.Controls.DefaultAssist
	return { length = length, difficulty = diff, cup = o.cup == true, formation = formation, assist = assist }
end

function Rooms.create(player, mode, rawOpts)
	if mode ~= "coop" and mode ~= "versus" then
		return
	end
	Rooms.leave(player)
	local count = 0
	for _ in rooms do
		count += 1
	end
	if count >= ONLINE.MaxRooms then
		Net.event("Notify"):FireClient(player, "notify.rooms_full")
		return
	end
	local room = {
		id = nextId,
		mode = mode,
		state = "lobby",
		hostId = player.UserId,
		hostName = player.Name,
		opts = sanitizeOpts(rawOpts),
		members = {},
		joinCounter = 0,
		match = nil,
	}
	nextId += 1
	rooms[room.id] = room
	Rooms.join(player, room.id)
end

function Rooms.join(player, id)
	local room = rooms[id]
	if room == nil or room.state ~= "lobby" then
		return
	end
	if byPlayer[player] == room then
		return
	end
	Rooms.leave(player)
	local team = 0
	if room.mode == "versus" then
		team = teamCount(room, 0) <= teamCount(room, 1) and 0 or 1
	end
	if teamCount(room, team) >= ONLINE.MaxPerTeam then
		if room.mode == "versus" and teamCount(room, 1 - team) < ONLINE.MaxPerTeam then
			team = 1 - team
		else
			Net.event("Notify"):FireClient(player, "notify.room_full")
			return
		end
	end
	room.joinCounter += 1
	room.members[player] = {
		player = player,
		userId = player.UserId,
		name = player.Name,
		team = team,
		joinOrder = room.joinCounter,
		prevButtons = {},
	}
	byPlayer[player] = room
	pushRoom(room)
end

function Rooms.leave(player)
	local room = byPlayer[player]
	if room == nil then
		return
	end
	byPlayer[player] = nil
	room.members[player] = nil
	if room.match ~= nil then
		room.match:removeSeat(player.UserId)
	end
	Net.event("RoomState"):FireClient(player, nil)
	local rest = members(room)
	if #rest == 0 then
		rooms[room.id] = nil
		broadcastList()
		return
	end
	if room.hostId == player.UserId then
		room.hostId = rest[1].userId
		room.hostName = rest[1].name
	end
	-- 対戦で片方のチームが空になったら、その試合は終える
	if room.match ~= nil and room.mode == "versus" and (teamCount(room, 0) == 0 or teamCount(room, 1) == 0) then
		Rooms.finish(room, true)
	end
	pushRoom(room)
end

function Rooms.setTeam(player, team)
	local room = byPlayer[player]
	if room == nil or room.state ~= "lobby" or room.mode ~= "versus" or (team ~= 0 and team ~= 1) then
		return
	end
	local m = room.members[player]
	if m.team == team or teamCount(room, team) >= ONLINE.MaxPerTeam then
		return
	end
	m.team = team
	pushRoom(room)
end

function Rooms.setOpts(player, rawOpts)
	local room = byPlayer[player]
	if room == nil or room.state ~= "lobby" or room.hostId ~= player.UserId then
		return
	end
	room.opts = sanitizeOpts(rawOpts)
	pushRoom(room)
end

function Rooms.start(player)
	local room = byPlayer[player]
	if room == nil or room.state ~= "lobby" or room.hostId ~= player.UserId then
		return
	end
	if room.mode == "versus" and (teamCount(room, 0) == 0 or teamCount(room, 1) == 0) then
		Net.event("Notify"):FireClient(player, "notify.need_opponent")
		return
	end
	local seats, roster = {}, {}
	for _, m in members(room) do
		table.insert(seats, { id = m.userId, team = m.team })
		table.insert(roster, { id = m.userId, team = m.team, name = m.name })
		m.prevButtons = {}
	end
	local rng = Random.new()
	local forms = Config.FormationOrder
	local awayForm = room.mode == "coop" and forms[rng:NextInteger(1, #forms)] or room.opts.formation
	room.match = Match.new({
		random = function()
			return rng:NextNumber()
		end,
		seats = seats,
		formation = { [0] = room.opts.formation, [1] = awayForm },
		difficulty = room.opts.difficulty,
		length = room.opts.length,
		cup = room.opts.cup,
		assist = room.opts.assist,
	})
	room.state = "playing"
	room.acc = 0
	room.snapAcc = 0
	room.seq = 0
	room.startClock = os.clock()
	local info = {
		roomId = room.id,
		mode = room.mode,
		seats = roster,
		formation = { home = room.opts.formation, away = awayForm },
		length = room.opts.length,
		cup = room.opts.cup,
	}
	for _, m in room.members do
		Net.event("OnlineStart"):FireClient(m.player, info)
	end
	pushRoom(room)
end

--- 入力 (クライアント → サーバー)。送りすぎは捨てる。
function Rooms.input(player, packet)
	local room = byPlayer[player]
	if room == nil or room.match == nil then
		return
	end
	local now = os.clock()
	local b = inputBudget[player]
	if b == nil or now - b.t > 1 then
		b = { t = now, n = 0 }
		inputBudget[player] = b
	end
	b.n += 1
	if b.n > ONLINE.MaxInputsPerSecond then
		return
	end
	if typeof(packet) == "buffer" then
		if buffer.len(packet) > 64 then
			return
		end
		packet = buffer.tostring(packet)
	end
	local inp = Snapshot.unpackInput(packet)
	local m = room.members[player]
	if inp == nil or m == nil then
		return
	end
	m.prevButtons = Snapshot.applyInput(room.match, player.UserId, inp, m.prevButtons)
end

--- 結果を各メンバーの視点に直して送り、報酬を付ける。
function Rooms.finish(room, aborted)
	local match = room.match
	room.match = nil
	room.state = "lobby"
	if match == nil then
		return
	end
	local r = match.result
	local realElapsed = os.clock() - (room.startClock or os.clock())
	for _, m in room.members do
		local team = m.team
		local reward = nil
		if r ~= nil and not aborted then
			local mine = team == 0 and r.home or r.away
			local theirs = team == 0 and r.away or r.home
			local winner = nil
			if r.winner ~= nil then
				winner = r.winner == team and 0 or 1
			end
			local report = Rewards.sanitize({
				home = mine,
				away = theirs,
				winner = winner,
				shootoutWin = r.shootout ~= nil and r.winner == team,
			})
			local data = Data.get(m.player)
			if data ~= nil and realElapsed >= room.opts.length * Config.Rewards.MinElapsedRatio then
				local session = {
					length = room.opts.length,
					difficulty = room.mode == "coop" and room.opts.difficulty or Config.DefaultDifficulty,
				}
				local coins, parts = Rewards.compute(session, report, Store.hasPass(m.player, "VIP"))
				data.coins += coins
				data.stats.matches += 1
				data.stats.goals += math.min(mine, 30)
				if winner == 0 then
					data.stats.wins += 1
				elseif winner == 1 then
					data.stats.losses += 1
				else
					data.stats.draws += 1
				end
				Data.markDirty(m.player)
				reward = { coins = coins, parts = parts, total = data.coins }
			end
		end
		Net.event("OnlineEnd"):FireClient(m.player, {
			aborted = aborted == true,
			myTeam = team,
			result = r and Rooms.flatResult(r) or nil,
			reward = reward,
		})
		Store.push(m.player)
	end
	pushRoom(room)
end

--- RemoteEvent で送れる形 (数値キーの辞書を避ける) にする。
function Rooms.flatResult(r)
	local function st(t)
		return {
			shots = t.shots,
			onTarget = t.onTarget,
			passes = t.passes,
			passOk = t.passOk,
			corners = t.corners,
			fouls = t.fouls,
			yellow = t.yellow,
			red = t.red,
			saves = t.saves,
		}
	end
	return {
		home = r.home,
		away = r.away,
		winner = r.winner,
		possession = r.possession,
		extra = r.extra,
		cup = r.cup,
		shootoutHome = r.shootout and r.shootout.home or nil,
		shootoutAway = r.shootout and r.shootout.away or nil,
		statsHome = st(r.stats[0]),
		statsAway = st(r.stats[1]),
	}
end

function Rooms.tick(dt)
	for _, room in rooms do
		local match = room.match
		if match ~= nil then
			room.acc = math.min(room.acc + dt, 0.25)
			while room.acc >= STEP do
				room.acc -= STEP
				match:update(STEP)
			end
			room.snapAcc += dt
			if room.snapAcc >= SNAP or match.ended then
				room.snapAcc = 0
				local str, seq = Snapshot.encode(match, room.seq)
				room.seq = seq
				match.events = {}
				local buf = buffer.fromstring(str) -- バイナリは buffer で送る (Roblox 推奨の形)
				for _, m in room.members do
					Net.event("OnlineSnap"):FireClient(m.player, buf)
				end
			end
			if match.ended then
				Rooms.finish(room, false)
			end
		end
	end
end

function Rooms.roomOf(player)
	return byPlayer[player]
end

function Rooms.remove(player)
	Rooms.leave(player)
	inputBudget[player] = nil
end

return Rooms
