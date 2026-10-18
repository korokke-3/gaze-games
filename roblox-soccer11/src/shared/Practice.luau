--!nonstrict
--[[
	Practice — 練習モード。Match をそのまま使い、選手の数と配置・終わり方を練習用に変える。
	Roblox API 非依存 (tests/ で全ドリルを通しで検証できる)。

	種類:
	  free    フリー練習: 味方 11 人 + 相手 GK (守備者 0 / 3 / 11 人を選べる)。時間無制限
	  pass    パス: 光っている味方へパスを 10 本つなぐ (タイム)
	  shoot   シュート: エリア周りの 10 か所から GK と 1 対 1 (ゴール数)
	  skills  足技: 守備者の前で 5 種の技を全部出す (タイム)
	  fk      FK: 壁と GK がいる 5 か所から直接 (ゴール数)
	  defend  守備: 攻めてくる相手から 15 秒以内にボールを奪う × 5 回 (成功数)

	操作者は id = 1 (HOME、+x へ攻める)。練習ではコインは出ない。
]]

local Config = require(script.Parent.Config)
local Match = require(script.Parent.Match)

local PL = Config.Pitch.Length
local PW = Config.Pitch.Width
local GOAL = PL / 2

local Practice = {}
Practice.__index = Practice

Practice.KINDS = { "free", "pass", "shoot", "skills", "fk", "defend" }
-- 記録の種類: time = 短いほど良い / count = 多いほど良い
Practice.RECORD = { pass = "time", shoot = "count", skills = "time", fk = "count", defend = "count" }
Practice.TOTAL = { pass = 10, shoot = 10, skills = 5, fk = 5, defend = 5 }
Practice.SKILLS = { "double_touch", "elastico", "scissors", "marseille", "drag_back" }

local SHOOT_SPOTS = {
	{ x = GOAL - 17, y = 0 },
	{ x = GOAL - 17, y = -9 },
	{ x = GOAL - 17, y = 9 },
	{ x = GOAL - 12, y = -12 },
	{ x = GOAL - 12, y = 12 },
	{ x = GOAL - 22, y = -5 },
	{ x = GOAL - 22, y = 5 },
	{ x = GOAL - 9, y = -4 },
	{ x = GOAL - 9, y = 4 },
	{ x = GOAL - 26, y = 0 },
}
local FK_SPOTS = {
	{ x = GOAL - 21, y = 0 },
	{ x = GOAL - 22, y = -8 },
	{ x = GOAL - 23, y = 9 },
	{ x = GOAL - 26, y = -3 },
	{ x = GOAL - 19, y = 12 },
}
local PASS_SLOTS = {
	{ x = -2, y = -16 },
	{ x = 12, y = -6 },
	{ x = 10, y = 14 },
	{ x = -8, y = 8 },
	{ x = 22, y = 2 },
}

local function copy(v)
	return { x = v.x, y = v.y }
end

local function dist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

--[[
	opts: { random, assist, defenders (free の相手の数: 0 / 3 / 11), difficulty }
]]
function Practice.new(kind, opts)
	opts = opts or {}
	local self = setmetatable({}, Practice)
	self.kind = kind
	self.random = opts.random or math.random
	self.match = Match.new({
		random = self.random,
		seats = { { id = 1, team = 0 } },
		assist = opts.assist,
		difficulty = opts.difficulty or Config.DefaultDifficulty,
		length = 1e9, -- 時間で終わらない
	})
	local m = self.match
	m.boundaries = { 1e9, 1e9 } -- ハーフタイムも無し
	m.practice = self -- HUD が練習の表示に使う
	self.seat = m:seat(1)
	self.total = Practice.TOTAL[kind]
	self.progress = 0
	self.score = 0
	self.round = 0
	self.timer = 0
	self.done = false
	self.highlight = nil
	self.skillsDone = {}
	self.waitT = nil -- 次のラウンドまでの待ち (結果を見せる)
	self.shotT = nil -- シュート (FK) を打ってからの時間
	self.lastResult = nil -- "good" | "bad"
	self.defenders = opts.defenders or 0
	self:setup()
	return self
end

-- ================================================================ 選手の出し入れ
--- keep に入っていない選手をピッチから外す (退場と同じ扱い。GK の代役は立てない)。
function Practice:bench(team, keep)
	local m = self.match
	local list = {}
	for _, p in m.teams[team] do
		if keep[p] then
			p.out = false
			table.insert(list, p)
		else
			p.out = true
			p.p = { x = 0, y = PW / 2 + 8 }
			p.v = { x = 0, y = 0 }
			if p.seat ~= nil then
				p.seat.ctrl = nil
				p.seat = nil
			end
		end
	end
	m.act[team] = list
end

local function set(p, x, y, fx)
	p.p = { x = x, y = y }
	p.v = { x = 0, y = 0 }
	p.face = { x = fx or 1, y = 0 }
	p.stun, p.slide, p.skill, p.dive, p.run = 0, 0, nil, nil, nil
	p.cd = 0
end

--- 操作者の選手にボールを持たせる。
function Practice:giveBall(p)
	local m = self.match
	m:assign(self.seat, p)
	local b = m.ball
	b.owner, b.last, b.kicker, b.target, b.offside = p, p, nil, nil, nil
	b.v = { x = 0, y = 0 }
	b.z, b.vz = 0, 0
	b.p = { x = p.p.x + p.face.x * 0.95, y = p.p.y + p.face.y * 0.95 }
	m.setp = nil
	m.mode = "play"
	m.replay = nil
	self.shotT = nil
end

-- ================================================================ 準備
function Practice:setup()
	local m = self.match
	local H, A = m.teams[0], m.teams[1]
	local kind = self.kind
	local function keepSet(list)
		local k = {}
		for _, p in list do
			k[p] = true
		end
		return k
	end
	if kind == "free" then
		local away = { A[1] }
		local n = self.defenders
		if n >= 11 then
			away = A
		elseif n > 0 then
			for i = 2, 1 + n do
				table.insert(away, A[i])
			end
		end
		self:bench(1, keepSet(away))
		self:bench(0, keepSet(H))
	elseif kind == "pass" then
		self.mates = { H[7], H[8], H[9], H[11], H[6] }
		self.slotOf = {}
		local keep = { H[10] }
		for _, p in self.mates do
			table.insert(keep, p)
		end
		self:bench(0, keepSet(keep))
		self:bench(1, keepSet({ A[1] }))
	elseif kind == "shoot" or kind == "skills" then
		self:bench(0, keepSet({ H[10] }))
		self:bench(1, keepSet(kind == "shoot" and { A[1] } or { A[3] }))
	elseif kind == "fk" then
		self:bench(0, keepSet({ H[10], H[9], H[11], H[3] }))
		self:bench(1, keepSet({ A[1], A[2], A[3], A[4], A[5], A[6] }))
	elseif kind == "defend" then
		self:bench(0, keepSet({ H[1], H[3], H[4] }))
		self:bench(1, keepSet({ A[10], A[9] }))
	end
	self:nextRound(true)
end

--- 次のラウンド (first = 最初)。結果に応じて進め、配置し直す。
function Practice:nextRound(first)
	local m = self.match
	local H, A = m.teams[0], m.teams[1]
	if not first then
		self.round += 1
	end
	if self.total ~= nil and self.round >= self.total and self.kind ~= "pass" and self.kind ~= "skills" then
		self:finish()
		return
	end
	self.waitT = nil
	self.shotT = nil
	self.roundStart = m.elapsed
	local kind = self.kind
	if kind == "free" then
		m:placeFormation()
		for _, p in m.act[1] do
			if p.gk then
				set(p, GOAL - 1.5, 0, -1)
			end
		end
		set(H[10], 0, 0)
		self:giveBall(H[10])
	elseif kind == "pass" then
		set(H[10], 0, 0)
		for i, p in self.mates do
			local slot = PASS_SLOTS[i]
			set(p, slot.x, slot.y)
			p.run = { to = copy(slot), untilT = 1e12 } -- その場で待つ
			self.slotOf[p] = slot
		end
		set(A[1], GOAL - 1.5, 0, -1)
		if first then
			self:giveBall(H[10])
			self:pickTarget()
		end
	elseif kind == "shoot" then
		local spot = SHOOT_SPOTS[self.round + 1]
		set(H[10], spot.x, spot.y)
		H[10].face = { x = 1, y = 0 }
		set(A[1], GOAL - 1.5, 0, -1)
		self:giveBall(H[10])
	elseif kind == "skills" then
		set(H[10], -5, 0)
		set(A[3], 3, 0, -1)
		A[3].cd = 1.5
		self:giveBall(H[10])
	elseif kind == "fk" then
		local spot = FK_SPOTS[self.round + 1]
		for _, p in m.pl do
			if not p.out then
				set(p, spot.x + (p.team == 0 and -6 or 6), spot.y * 0.5, p.team == 0 and 1 or -1)
			end
		end
		set(A[1], GOAL - 0.6, 0, -1)
		m:startSetpiece("fk", 0, spot, "practice.fk")
		-- 配置を待たずに、すぐ並ばせる
		local tg = m:setpieceTargets()
		for p, t in tg do
			if not p.out and p ~= m.setp.taker then
				p.p = copy(t)
				p.v = { x = 0, y = 0 }
			end
		end
		m:assign(self.seat, m.setp.taker)
	elseif kind == "defend" then
		local y = (self.random() * 2 - 1) * 14
		set(A[10], 20, y, -1)
		set(A[9], 24, y > 0 and y - 14 or y + 14, -1)
		set(H[3], 2, y * 0.7)
		set(H[4], 4, -y * 0.5)
		set(H[1], -GOAL + 1.5, 0)
		local b = m.ball
		b.owner, b.last, b.kicker, b.target = A[10], A[10], nil, nil
		b.v = { x = 0, y = 0 }
		b.z, b.vz = 0, 0
		b.p = { x = A[10].p.x - 0.95, y = A[10].p.y }
		m.setp, m.mode = nil, "play"
		m:assign(self.seat, H[3])
		for _, p in A do
			p.cd = 0
		end
	end
	self.lastKicker = nil
end

--- パス: 次に狙う味方 (今ボールを持っている選手以外から)。
function Practice:pickTarget()
	local owner = self.match.ball.owner
	-- 間に味方が立っていない (パスコースが空いている) 相手を選ぶ
	local function blocked(q)
		if owner == nil then
			return false
		end
		local ax, ay = owner.p.x, owner.p.y
		local dx, dy = q.p.x - ax, q.p.y - ay
		local L2 = dx * dx + dy * dy
		for _, o in self.mates do
			if o ~= q and o ~= owner and L2 > 0 then
				local t = ((o.p.x - ax) * dx + (o.p.y - ay) * dy) / L2
				if t > 0.05 and t < 0.95 then
					local cx, cy = ax + dx * t - o.p.x, ay + dy * t - o.p.y
					if cx * cx + cy * cy < 3.5 * 3.5 then
						return true
					end
				end
			end
		end
		return false
	end
	local cands, open = {}, {}
	for _, p in self.mates do
		if p ~= owner and p ~= self.highlight then
			table.insert(cands, p)
			if not blocked(p) then
				table.insert(open, p)
			end
		end
	end
	if #open > 0 then
		cands = open
	end
	self.highlight = cands[math.floor(self.random() * #cands) + 1]
end

--- 1 本ごとの結果 (HUD に「ナイス!」「失敗」を出す)。
function Practice:mark(r)
	self.lastResult = r
	self.match:popup(r == "good" and "practice.good" or "practice.bad", r == "good" and 0 or 1)
end

function Practice:finish()
	self.done = true
	self.highlight = nil
	local rec = Practice.RECORD[self.kind]
	if rec == "time" then
		self.result = math.floor(self.timer * 10 + 0.5) / 10
	elseif rec == "count" then
		self.result = self.score
	end
end

--- 自己ベストより良いか。
function Practice.better(kind, value, best)
	if value == nil then
		return false
	end
	if best == nil then
		return true
	end
	if Practice.RECORD[kind] == "time" then
		return value < best
	end
	return value > best
end

-- ================================================================ 更新
function Practice:update(dt)
	local m = self.match
	if self.done or m.paused then
		return
	end
	-- 結果を見せている間は止める (ゴールに入ったボールを何度も数えない)
	if self.waitT ~= nil then
		self.waitT -= dt
		if self.waitT <= 0 then
			self:nextRound(false)
		end
		return
	end
	local scoreBefore = m.score[0]
	local awayBefore = m.score[1]
	m:update(dt)
	if self.kind ~= "free" and self.kind ~= "fk" then
		-- 練習では止めない: 外に出た・ファウル等のセットプレーはやり直し
		if m.setp ~= nil then
			m.setp = nil
			self:onFail()
			return
		end
	end
	if m.mode == "replay" then
		m.mode = "play"
		m.replay = nil
	end
	local scored = m.score[0] > scoreBefore
	local conceded = m.score[1] > awayBefore
	self.timer += dt
	-- 1 ラウンドが長すぎる (シュートを打たない等) ときは失敗として次へ
	local roundLimit = ({ shoot = 12, fk = 20, defend = 15 })[self.kind]
	if roundLimit ~= nil and m.elapsed - (self.roundStart or 0) > roundLimit and not scored then
		self.progress += 1
		self:mark("bad")
		self.waitT = 1.0
		return
	end
	local b = m.ball
	local kind = self.kind
	if kind == "free" then
		if scored or m.setp ~= nil and m.setp.kind ~= "fk" then
			-- ゴール・外に出たら、ボールを足元に戻す
			if scored or m.setp.kind == "throw" or m.setp.kind == "corner" or m.setp.kind == "gk" then
				m.setp = nil
				self:nextRound(true)
			end
		end
	elseif kind == "pass" then
		-- 受け手以外は自分の位置へ戻って待つ (ボールに寄ってパスコースを塞がない)
		for _, p in self.mates do
			local slot = self.slotOf[p]
			if slot and p ~= b.owner and p ~= b.target and p.seat == nil then
				p.run = { to = copy(slot), untilT = 1e12 }
			end
		end
		if b.owner ~= nil and b.owner.team == 0 and b.owner == self.highlight then
			self.progress += 1
			self:mark("good")
			if self.progress >= self.total then
				self:finish()
			else
				self:pickTarget()
			end
		end
	elseif kind == "shoot" or kind == "fk" then
		if b.kind == "shot" and b.kicker ~= nil and b.kicker.team == 0 and b.owner == nil and self.shotT == nil then
			self.shotT = 0
		end
		if self.shotT ~= nil then
			self.shotT += dt
		end
		if kind == "fk" and m.setp ~= nil then
			m.setp.t0 = m.elapsed -- 人間が蹴るまで待つ (代わりに蹴らない)
		end
		local fail = (self.shotT ~= nil and self.shotT > 4)
			or (b.owner ~= nil and b.owner.team == 1)
			or (kind == "fk" and m.setp ~= nil and m.setp.team == 1)
			or (kind == "fk" and m.setp ~= nil and m.setp.kind ~= "fk")
		if scored then
			self.score += 1
			self.progress += 1
			self:mark("good")
			self.waitT = 1.2
		elseif fail then
			self.progress += 1
			self:mark("bad")
			self.waitT = 1.2
		elseif kind == "fk" and self.shotT ~= nil and m.setp ~= nil then
			-- 蹴った後にセットプレーになった (外れた) = 失敗
			self.progress += 1
			self:mark("bad")
			self.waitT = 1.2
		end
	elseif kind == "skills" then
		local p = self.seat.ctrl
		if p ~= nil and type(p.skill) == "table" and not self.skillsDone[p.skill.name] then
			self.skillsDone[p.skill.name] = true
			self.progress += 1
			self:mark("good")
			if self.progress >= self.total then
				self:finish()
			end
		end
		if b.owner ~= nil and b.owner.team == 1 then
			-- 奪われた: 足元に戻してやり直し
			self:nextRound(true)
		end
	elseif kind == "defend" then
		local won = b.owner ~= nil and b.owner.team == 0
		local lost = conceded or (b.kind == "shot" and b.kicker ~= nil and b.kicker.team == 1)
		if won then
			self.score += 1
			self.progress += 1
			self:mark("good")
			self.waitT = 1.0
		elseif lost then
			self.progress += 1
			self:mark("bad")
			self.waitT = 1.0
		end
	end
end

--- 外に出た等でやり直し (ドリルごとの扱い)。
function Practice:onFail()
	local kind = self.kind
	if kind == "pass" then
		-- 持っていた味方 (無ければ自分) にボールを戻して続ける
		local m = self.match
		local back = m.ball.last
		if back == nil or back.team ~= 0 or back.out then
			back = m.teams[0][10]
		end
		self:giveBall(back)
		self:mark("bad")
	elseif kind == "shoot" then
		self.progress += 1
		self:mark("bad")
		self.waitT = 1.0
	elseif kind == "defend" then
		-- 相手が出した = 奪ったのと同じ / 自分が出した = 失敗
		local last = self.match.ball.last
		local good = last ~= nil and last.team == 1
		if good then
			self.score += 1
		end
		self.progress += 1
		self.lastResult = good and "good" or "bad"
		self.waitT = 1.0
	else
		self:nextRound(true)
	end
end

--- 今のラウンドをやり直す (メニューの「やり直す」)。
function Practice:restart()
	self.progress = 0
	self.score = 0
	self.round = 0
	self.timer = 0
	self.done = false
	self.skillsDone = {}
	self.result = nil
	self:nextRound(true)
	if self.kind == "pass" then
		self:pickTarget()
	end
end

--- HUD に出す 1 行 (進み具合)。戻り値: Locale のキー, 引数...
function Practice:status()
	local kind = self.kind
	if kind == "free" then
		return "practice.status.free"
	elseif kind == "pass" or kind == "skills" then
		return "practice.status.time", self.progress, self.total, self.timer
	end
	return "practice.status.count", self.progress, self.total, self.score
end

return Practice
