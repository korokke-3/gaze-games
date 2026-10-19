--!nonstrict
--[[
	Matchmaking — サーバーをまたいだクイックマッチ (1 対 1) と、フレンド招待での合流。

	クイックマッチ:
	  1. 待つ人を MemoryStore のキューへ入れる (どのサーバーからでも同じキュー)
	  2. 待つ人がいるサーバーは数秒ごとにキューから 2 人まとめて取り出す (取り出せたサーバーが担当)
	  3. 担当サーバーが予約サーバー (ReserveServer) を作り、MessagingService で 2 人のいるサーバーへ知らせる
	  4. 各サーバーが自分の所の 1 人を予約サーバーへテレポートする
	  5. 予約サーバーでは、着いた人で対戦の部屋を作って始める。相手が来なければ CPU と対戦にする
	  一定時間見つからなければ "timeout" を返す (クライアントは CPU 戦を勧める)。

	招待: 招待データ (LaunchData) に サーバー (JobId) と部屋の番号を入れる。
	  同じサーバーならその部屋へ、別のサーバーならそのサーバーへテレポートしてから部屋へ。

	Roblox の外部サービス (MemoryStore / Messaging / Teleport) は Studio や未公開の Place で失敗するので、全て pcall。
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Rooms = require(script.Parent.Rooms)

local Matchmaking = {}

local QUEUE = "soccer11_quick"
local TOPIC = "soccer11_quick"
Matchmaking.READ_EVERY = 2.5 -- キューを見る間隔 [s]
Matchmaking.ITEM_TTL = 60 -- キューに残す長さ [s]
Matchmaking.GIVE_UP = 45 -- これだけ待って見つからなければ timeout [s]
Matchmaking.ARRIVE_WAIT = 20 -- 予約サーバーで相手を待つ長さ [s]

-- 外部サービス (テストでは差し替える)
local svc = {
	memory = function()
		return game:GetService("MemoryStoreService")
	end,
	messaging = function()
		return game:GetService("MessagingService")
	end,
	teleport = function()
		return game:GetService("TeleportService")
	end,
}
function Matchmaking.setServices(t)
	for k, v in t do
		svc[k] = function()
			return v
		end
	end
end

local waiting = {} -- Player -> 待ち始めた時刻 (os.clock)
local pending = {} -- Player -> 着いた時の用事 { room = id } | { quick = { users } }
local arrivals = nil -- 予約サーバー: { users = {userId}, roomId, t0 }
local acc = 0
local subscribed = false
local queueObj = nil

local function state(player, s)
	Net.event("QuickMatchState"):FireClient(player, s)
end

local function queue()
	if queueObj == nil then
		local ok, q = pcall(function()
			return svc.memory():GetQueue(QUEUE)
		end)
		if ok then
			queueObj = q
		end
	end
	return queueObj
end

local function placeId()
	return game.PlaceId
end

-- ================================================================ 担当サーバーの知らせを受ける
local function onMatched(data)
	if typeof(data) ~= "table" or typeof(data.code) ~= "string" or typeof(data.users) ~= "table" then
		return
	end
	for _, uid in data.users do
		local p = Players:GetPlayerByUserId(uid)
		if p ~= nil and waiting[p] ~= nil then
			waiting[p] = nil
			state(p, "found")
			pcall(function()
				svc.teleport():TeleportToPrivateServer(placeId(), data.code, { p }, nil, { quick = data.users })
			end)
		end
	end
end

local function subscribe()
	if subscribed then
		return
	end
	subscribed = true
	task.spawn(function()
		pcall(function()
			svc.messaging():SubscribeAsync(TOPIC, function(msg)
				onMatched(msg.Data)
			end)
		end)
	end)
end

-- ================================================================ クイックマッチ
function Matchmaking.join(player)
	if waiting[player] ~= nil then
		return
	end
	local q = queue()
	if q == nil then
		state(player, "unavailable")
		return
	end
	subscribe()
	Rooms.leave(player)
	local ok = pcall(function()
		q:AddAsync({ u = player.UserId, t = os.time() }, Matchmaking.ITEM_TTL)
	end)
	if not ok then
		state(player, "unavailable")
		return
	end
	waiting[player] = os.clock()
	state(player, "searching")
end

function Matchmaking.cancel(player)
	if waiting[player] ~= nil then
		waiting[player] = nil
		state(player, "cancel")
	end
end

--- キューから 2 人取り出して組む (担当になったら予約サーバーを作って知らせる)。
function Matchmaking.tryPair()
	local q = queue()
	if q == nil then
		return
	end
	local ok, items, id = pcall(function()
		return q:ReadAsync(2, true, 0)
	end)
	if not ok or items == nil or #items < 2 then
		return
	end
	pcall(function()
		q:RemoveAsync(id)
	end)
	-- 同じ人が 2 回入っている・古すぎるものは組まない (新しい方は戻す)
	local now = os.time()
	local a, b = items[1], items[2]
	local fresh = function(x)
		return typeof(x) == "table" and typeof(x.u) == "number" and now - (x.t or 0) < Matchmaking.ITEM_TTL
	end
	if not (fresh(a) and fresh(b)) or a.u == b.u then
		for _, x in { a, b } do
			if fresh(x) then
				pcall(function()
					q:AddAsync(x, Matchmaking.ITEM_TTL)
				end)
				break
			end
		end
		return
	end
	local okR, code = pcall(function()
		return svc.teleport():ReserveServer(placeId())
	end)
	if not okR or typeof(code) ~= "string" then
		return
	end
	local data = { code = code, users = { a.u, b.u } }
	onMatched(data) -- このサーバーにいる人はすぐ送る
	pcall(function()
		svc.messaging():PublishAsync(TOPIC, data)
	end)
end

-- ================================================================ 着いた人の用事 (招待 / クイックマッチ)
--- 入ってきた時: 招待データ・テレポートのデータを読む (処理はクライアントの準備ができてから)。
function Matchmaking.onJoin(player)
	local ok, jd = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or typeof(jd) ~= "table" then
		return
	end
	local td = jd.TeleportData
	if typeof(td) == "table" then
		if typeof(td.quick) == "table" then
			pending[player] = { quick = td.quick }
			return
		end
		if typeof(td.room) == "number" then
			pending[player] = { room = td.room }
			return
		end
	end
	local launch = jd.LaunchData
	if typeof(launch) == "string" and #launch > 0 and #launch < 200 then
		local okJ, inv = pcall(function()
			return HttpService:JSONDecode(launch)
		end)
		if okJ and typeof(inv) == "table" and typeof(inv.j) == "string" and typeof(inv.r) == "number" then
			if inv.j == game.JobId then
				pending[player] = { room = inv.r }
			else
				-- 招待した人のサーバーへ
				pcall(function()
					svc.teleport():TeleportToPlaceInstance(placeId(), inv.j, player, nil, { room = inv.r })
				end)
			end
		end
	end
end

--- クライアントの準備ができた (RequestState の初回)。
function Matchmaking.ready(player)
	local p = pending[player]
	pending[player] = nil
	if p == nil then
		return
	end
	if p.room ~= nil then
		Rooms.join(player, p.room)
		return
	end
	-- クイックマッチの予約サーバー: 最初の人が部屋を作り、次の人は入る
	if arrivals == nil then
		Rooms.create(player, "versus", { length = 300 })
		local room = Rooms.of(player)
		arrivals = { users = p.quick, roomId = room and room.id, t0 = os.clock(), host = player, started = false }
	elseif arrivals.roomId ~= nil then
		Rooms.join(player, arrivals.roomId)
	end
	Matchmaking.checkStart()
end

--- 予約サーバー: 全員そろったら始める。待っても来なければ CPU と対戦。
function Matchmaking.checkStart()
	local a = arrivals
	if a == nil or a.started or a.roomId == nil then
		return
	end
	local room = Rooms.get(a.roomId)
	if room == nil then
		arrivals = nil
		return
	end
	local here = 0
	for _ in room.members do
		here += 1
	end
	local all = here >= #a.users
	local late = os.clock() - a.t0 > Matchmaking.ARRIVE_WAIT
	if not all and not late then
		return
	end
	local host = nil
	for pl, m in room.members do
		if m.userId == room.hostId then
			host = pl
		end
	end
	if host == nil then
		return
	end
	a.started = true
	if not all then
		-- 相手が来なかった: CPU と対戦 (協力の部屋に切り替える)
		Rooms.setMode(a.roomId, "coop")
		Net.event("Notify"):FireClient(host, "notify.qm_alone")
	end
	Rooms.start(host)
end

-- ================================================================ 毎フレーム
function Matchmaking.tick(dt)
	if arrivals ~= nil and not arrivals.started then
		Matchmaking.checkStart()
	end
	if next(waiting) == nil then
		acc = 0
		return
	end
	acc += dt
	if acc < Matchmaking.READ_EVERY then
		return
	end
	acc = 0
	local now = os.clock()
	for p, t in waiting do
		if now - t > Matchmaking.GIVE_UP or p.Parent == nil then
			waiting[p] = nil
			if p.Parent ~= nil then
				state(p, "timeout")
			end
		end
	end
	if next(waiting) ~= nil then
		task.spawn(Matchmaking.tryPair)
	end
end

function Matchmaking.remove(player)
	waiting[player] = nil
	pending[player] = nil
end

return Matchmaking
