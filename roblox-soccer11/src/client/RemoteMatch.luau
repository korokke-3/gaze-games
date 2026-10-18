--!nonstrict
--[[
	RemoteMatch — オンライン試合の「見た目用の試合」。サーバーの Snapshot を受けて、
	World / Hud が読むフィールド (pl / ball / score / seats ...) を Match と同じ形で用意する。
	位置は InterpDelay 秒だけ遅らせて、前後の Snapshot の間を補間する (カクつき防止)。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Snapshot = require(Shared:WaitForChild("Snapshot"))

local RemoteMatch = {}
RemoteMatch.__index = RemoteMatch

local DELAY = Config.Online.InterpDelay

--[[
	info: OnlineStart の内容 { seats = { { id, team, name } }, formation = { home, away }, length, cup, mode }
	myId: 自分の UserId
]]
function RemoteMatch.new(info, myId)
	local self = setmetatable({}, RemoteMatch)
	self.online = true
	self.mode = "play"
	self.matchTime = info.length
	self.cup = info.cup
	self.roomMode = info.mode
	self.myId = myId
	self.names = {}
	self.teamOf = {}
	for _, s in info.seats do
		self.names[s.id] = s.name
		self.teamOf[s.id] = s.team
	end
	self.myTeam = self.teamOf[myId] or 0
	local forms = {
		[0] = Config.Formations[info.formation.home] or Config.Formation,
		[1] = Config.Formations[info.formation.away] or Config.Formation,
	}
	self.pl = {}
	for t = 0, 1 do
		for i = 0, 10 do
			local f = forms[t][i + 1]
			table.insert(self.pl, {
				team = t,
				i = i,
				role = f.role,
				num = f.num,
				gk = i == 0,
				p = { x = 0, y = 0 },
				v = { x = 0, y = 0 },
				face = { x = t == 0 and 1 or -1, y = 0 },
				stamina = 100,
				exhausted = false,
				out = false,
				stun = 0,
				slide = 0,
				skill = nil,
			})
		end
	end
	self.ball = { p = { x = 0, y = 0 }, v = { x = 0, y = 0 }, z = 0, owner = nil }
	self.score = { [0] = 0, [1] = 0 }
	self.level = { [0] = 0, [1] = 0 }
	self.elapsed = 0
	self.bIndex = 1
	self.period = "regular"
	self.flip = false
	self.paused = false
	self.ended = false
	self.setp = nil
	self.shoot = nil
	self.popups = {}
	self.labels = {}
	self.events = {}
	self.seats = {}
	self.buffer = {} -- { at, snap }
	self.aimProvider = nil
	return self
end

--- サーバーから届いた Snapshot を取り込む。now: 受信時刻 (os.clock)
function RemoteMatch:apply(str, now)
	local ok, snap = pcall(Snapshot.decode, str)
	if not ok then
		return
	end
	table.insert(self.buffer, { at = now, snap = snap })
	while #self.buffer > 6 do
		table.remove(self.buffer, 1)
	end
	-- 一度きりの出来事 (ポップアップ・技名・効果音) はすぐ反映する
	for _, x in snap.popups do
		table.insert(self.popups, { t = snap.elapsed, key = x.key, team = x.team })
	end
	for _, x in snap.labels do
		local p = self.pl[x.index]
		if p ~= nil then
			table.insert(self.labels, { t = snap.elapsed, key = x.key, player = p })
		end
	end
	for _, e in snap.events do
		local who = e.index and self.pl[e.index] or nil
		if e.kind == "sub" and who ~= nil then
			who.num = tonumber(e.tag) or who.num -- 交代で背番号が変わる
		end
		table.insert(self.events, { kind = e.kind, player = who, tag = e.tag })
	end
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

--- 描画時刻に合わせて補間し、フィールドを更新する。
function RemoteMatch:advance(now)
	local buf = self.buffer
	if #buf == 0 then
		return
	end
	local renderAt = now - DELAY
	local a, b = buf[1], buf[#buf]
	for i = 1, #buf - 1 do
		if buf[i].at <= renderAt and buf[i + 1].at >= renderAt then
			a, b = buf[i], buf[i + 1]
			break
		end
	end
	if renderAt > buf[#buf].at then
		a, b = buf[#buf], buf[#buf]
	end
	local t = 0
	if b.at > a.at then
		t = math.clamp((renderAt - a.at) / (b.at - a.at), 0, 1)
	end
	local sa, sb = a.snap, b.snap
	local latest = buf[#buf].snap
	-- 補間するもの
	for i, p in self.pl do
		local pa, pb = sa.pl[i], sb.pl[i]
		local nx, ny = lerp(pa.x, pb.x, t), lerp(pa.y, pb.y, t)
		p.v = { x = (pb.x - pa.x) * 15, y = (pb.y - pa.y) * 15 }
		p.p = { x = nx, y = ny }
		local fx, fy = lerp(pa.fx, pb.fx, t), lerp(pa.fy, pb.fy, t)
		local n = math.sqrt(fx * fx + fy * fy)
		if n > 1e-6 then
			p.face = { x = fx / n, y = fy / n }
		end
		local cur = sb.pl[i]
		p.stamina = cur.stamina
		p.exhausted = cur.exhausted
		p.out = cur.out
		p.gk = cur.gk
		p.stun = cur.stun and 1 or 0
		p.slide = cur.slide and 1 or 0
		p.skill = cur.skill and true or nil
		p.skillAnim = cur.skillName and { name = cur.skillName, u = lerp(pa.skillU or 0, cur.skillU or 0, t) } or nil
	end
	self.ball.p = { x = lerp(sa.ball.x, sb.ball.x, t), y = lerp(sa.ball.y, sb.ball.y, t) }
	self.ball.z = lerp(sa.ball.z, sb.ball.z, t)
	self.ball.v = { x = sb.ball.vx, y = sb.ball.vy }
	self.ball.owner = sb.ball.owner > 0 and self.pl[sb.ball.owner] or nil
	self.elapsed = lerp(sa.elapsed, sb.elapsed, t)
	self.clockInfo = latest.clock
	self.added = latest.clock and latest.clock.added or 0
	-- 最新の値をそのまま使うもの
	self.score = latest.score
	self.level = latest.level
	self.mode = latest.mode
	self.bIndex = latest.bIndex
	self.period = latest.period
	self.flip = latest.flip
	self.paused = latest.paused
	self.ended = latest.ended
	self.shoot = latest.shoot
	if latest.setp then
		self.setp = { kind = latest.setp.kind, team = latest.setp.team, taker = self.pl[latest.setp.takerIndex] }
	else
		self.setp = nil
	end
	self.seats = {}
	for _, s in latest.seats do
		table.insert(self.seats, {
			id = s.id,
			team = self.teamOf[s.id] or 0,
			name = self.names[s.id],
			ctrl = self.pl[s.ctrl],
			kind = s.kind,
			power = s.power,
			preview = s.preview > 0 and self.pl[s.preview] or nil,
			relayTo = (s.relay or 0) > 0 and self.pl[s.relay] or nil,
		})
	end
	local me = self:seat(self.myId)
	self.ctrl = me and me.ctrl
	-- 古いポップアップ等を捨てる
	local keep = {}
	for _, x in self.popups do
		if self.elapsed - x.t < 1.3 and self.elapsed >= x.t - 0.5 then
			table.insert(keep, x)
		end
	end
	self.popups = keep
	keep = {}
	for _, x in self.labels do
		if self.elapsed - x.t < 0.9 then
			table.insert(keep, x)
		end
	end
	self.labels = keep
end

-- ================================================================ Match と同じ問い合わせ
function RemoteMatch:clock()
	local c = self.clockInfo
	if c == nil then
		return 0, 45, 0
	end
	return c.minute, c.endMin, c.added
end

function RemoteMatch:human(team)
	for _, s in self.seats do
		if s.team == team then
			return true
		end
	end
	return false
end

function RemoteMatch:seat(id)
	for _, s in self.seats do
		if s.id == id then
			return s
		end
	end
	return nil
end

function RemoteMatch:chargePower(s)
	if s == nil or s.kind == nil then
		return nil
	end
	return s.power
end

function RemoteMatch:previewReceiver(s)
	return s and s.preview
end

function RemoteMatch:aimOf(s)
	if self.aimProvider then
		local a = self.aimProvider()
		if a then
			return a
		end
	end
	local p = s and s.ctrl
	return p and p.face or { x = 1, y = 0 }
end

--- L1 で切り替わりそうな選手 (表示用の目安)。
function RemoteMatch:nextCursor(s)
	if s == nil then
		return nil
	end
	local taken = {}
	for _, x in self.seats do
		if x.ctrl then
			taken[x.ctrl] = true
		end
	end
	local best, bd = nil, math.huge
	for _, p in self.pl do
		if p.team == s.team and not p.gk and not p.out and not taken[p] then
			local d = math.sqrt((p.p.x - self.ball.p.x) ^ 2 + (p.p.y - self.ball.p.y) ^ 2)
			if d < bd then
				best, bd = p, d
			end
		end
	end
	return best
end

return RemoteMatch
