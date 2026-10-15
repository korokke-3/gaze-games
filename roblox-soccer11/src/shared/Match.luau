--!nonstrict
--[[
	Match — 11人制サッカーの試合シミュレーション。Roblox の API を一切使わない純粋なロジック。
	(だから Studio 無しで luau CLI で検証できる。tests/ 参照)

	座標は x = 攻撃方向 (HOME は +x へ攻める), y = 横方向。単位は m。
	team: HOME = 0 (人間), AWAY = 1 (CPU)。
	入力は文字列キー名で受ける: "W" "A" "S" "D" (移動), "K" "I" "J" "L" "U" "Q" (ボタン),
	"Up" "Down" "Left" "Right" (フリック), "Shift" (ダッシュ), "P" (一時停止)。

	元は eFootball の操作体系を参考にした視線操作ゲームの一部。視線に依存する処理
	(ノールックパス・パスコースを読む CPU・PK でキーパーが視線を読む) は取り除いてある。
]]

local Config = require(script.Parent.Config)

local PL = Config.Pitch.Length
local PW = Config.Pitch.Width
local GOAL_W = Config.Pitch.GoalWidth
local GOAL_H = Config.Pitch.GoalHeight
local BOX_L = Config.Pitch.BoxLength
local BOX_W = Config.Pitch.BoxWidth
local SIX_L = Config.Pitch.SixLength
local PEN_SPOT = Config.Pitch.PenaltySpot
local P_R = Config.Player.Radius
local CONTROL_R = Config.Player.ControlRadius
local SPEED = Config.Player.Speed
local DASH = Config.Player.Dash
local DRIBBLE = Config.Player.Dribble
local ACC_AI = Config.Player.AccAI
local ACC_HUMAN = Config.Player.AccHuman
local DECIDE_EVERY = Config.Player.DecideEvery
local FRICTION = Config.Physics.Friction
local GRAV = Config.Physics.Gravity
local KEYS = Config.Keys
local FORM = Config.Formation
local FWD = Config.ForwardRoles
local STAMINA = Config.Stamina
local CARDS = Config.Cards
local KEEPER = Config.Keeper
local HEADER = Config.Header
local REPLAY = Config.Replay
local TACTICS = Config.Tactics
local DIFFS = Config.Difficulties
local ATTRS = Config.Attributes
local HALF_BREAK = Config.HalfTimeBreak
local EXTRA = Config.ExtraTime

local HOME, AWAY = 0, 1

local ARROWS = { Up = true, Down = true, Left = true, Right = true }
local FLICK_LATCH = 0.28 -- 矢印キーは、押した直後 (離しても) この時間はフリックとして扱う
local WASD = {
	W = { x = 0, y = -1 },
	S = { x = 0, y = 1 },
	A = { x = -1, y = 0 },
	D = { x = 1, y = 0 },
}

-- ================================================================ ベクトル (x, y のテーブル)
local function vlen(a)
	return math.sqrt(a.x * a.x + a.y * a.y)
end
local function vsub(a, b)
	return { x = a.x - b.x, y = a.y - b.y }
end
local function vadd(a, b)
	return { x = a.x + b.x, y = a.y + b.y }
end
local function vmul(a, k)
	return { x = a.x * k, y = a.y * k }
end
local function vdot(a, b)
	return a.x * b.x + a.y * b.y
end
local function vdist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end
local function vnorm(a)
	local n = vlen(a)
	if n > 1e-9 then
		return { x = a.x / n, y = a.y / n }
	end
	return { x = 0, y = 0 }
end
local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end
local function sgnOf(x)
	if x > 0 then
		return 1
	elseif x < 0 then
		return -1
	end
	return 0
end

local Match = {}
Match.__index = Match
Match.HOME = HOME
Match.AWAY = AWAY

-- ================================================================ 生成
local function newPlayer(team, i, form)
	return {
		team = team,
		i = i,
		role = form[i + 1].role,
		num = form[i + 1].num,
		gk = i == 0,
		out = false, -- 退場
		yellow = 0,
		stamina = STAMINA.Max,
		exhausted = false,
		attr = { speed = 1, shoot = 1, pass = 1, tackle = 1, stamina = 1 },
		dive = nil, -- GK のダイブ { t0, y, until }
		p = { x = 0, y = 0 },
		v = { x = 0, y = 0 },
		face = { x = team == HOME and 1 or -1, y = 0 },
		stun = 0,
		cd = 0, -- タックル等のクールダウン
		slide = 0, -- スライディング中の残り時間
		nextDecide = 0, -- CPU のボール保持者: 次に判断する時刻
		ddir = nil, -- CPU のボール保持者: いまのドリブル方向
		skill = nil, -- 実行中の技
		skillLog = {}, -- 技を使った時刻 (連発すると読まれる)
	}
end

--[[
	opts.random: () -> [0, 1) の乱数 (省略時 math.random)
	opts.ctrlKind: { [0] = "human", [1] = "cpu" }
]]
function Match.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Match)
	self.random = opts.random or math.random
	self.ctrlKind = opts.ctrlKind or { [HOME] = "human", [AWAY] = "cpu" }
	-- 試合の設定
	local formation = opts.formation or {}
	self.formKeys = { [HOME] = formation[HOME] or "433", [AWAY] = formation[AWAY] or "433" }
	self.forms = {
		[HOME] = Config.Formations[self.formKeys[HOME]] or FORM,
		[AWAY] = Config.Formations[self.formKeys[AWAY]] or FORM,
	}
	self.diffIndex = opts.difficulty or Config.DefaultDifficulty
	self.diff = DIFFS[self.diffIndex] or DIFFS[Config.DefaultDifficulty]
	self.matchTime = opts.length or Config.MatchTime
	self.cup = opts.cup == true
	local tac = opts.tactics or {}
	self.tactics = {
		[HOME] = { line = tac.line or 2, press = tac.press or 2 },
		[AWAY] = { line = 2, press = 2 },
	}
	self.pl = {}
	self.teams = { [HOME] = {}, [AWAY] = {} }
	for t = HOME, AWAY do
		for i = 0, 10 do
			local p = newPlayer(t, i, self.forms[t])
			local base = ATTRS[p.role] or ATTRS.CM
			local spread = Config.AttributeSpread
			for k, v in base do
				p.attr[k] = v * (1 + (self.random() * 2 - 1) * spread)
			end
			table.insert(self.pl, p)
			self.teams[t][i + 1] = p
		end
	end
	self.act = { [HOME] = self.teams[HOME], [AWAY] = self.teams[AWAY] } -- 退場者を除いたリスト
	-- 時間の管理: 前半 / 後半 (カップ戦なら延長 2 本) の区切り
	self.flip = false -- true の間はサイドが入れ替わっている
	self.mode = "play" -- play | halftime | replay | shootout
	self.modeT = 0
	self.boundaries = { self.matchTime / 2, self.matchTime }
	self.bIndex = 1
	self.period = "regular" -- regular | extra
	self.kickoffTeam = HOME
	self.poss = { [HOME] = 0, [AWAY] = 0 }
	self.tstats = {}
	for t = HOME, AWAY do
		self.tstats[t] = { shots = 0, onTarget = 0, passes = 0, passOk = 0, corners = 0, fouls = 0, yellow = 0, red = 0, saves = 0 }
	end
	self.rec = {} -- リプレイ用の記録
	self.recT = 0
	self.replay = nil
	self.shoot = nil -- PK 戦の状態
	self.events = {} -- 効果音用 { kind }
	self.ball = {
		p = { x = 0, y = 0 },
		v = { x = 0, y = 0 },
		z = 0,
		vz = 0,
		owner = nil,
		last = nil, -- 最後に触った選手
		kicker = nil,
		kickT = -9,
		kind = "",
		target = nil,
		offside = nil, -- キックの瞬間にオフサイド位置だった受け手
	}
	self.score = { [HOME] = 0, [AWAY] = 0 }
	self.elapsed = 0
	self.paused = false
	self.ended = false
	self.result = nil
	self.ctrl = self:slot(HOME, 9) -- ST (kickoff で改めて決まる)
	self.setp = nil -- セットプレー: nil か { kind, team, t0, taker }
	self.popups = {} -- { t, key, tag, name? }: 画面中央に出す一言
	self.labels = {} -- { t, key, player }: 選手の頭上に出す技名
	self.stats = { passes = 0, intercepted = 0, offside = 0, fouls = 0 }
	self.skillStats = { tried = 0, beat = 0 }
	-- 入力
	self.down = {}
	self.evt = {}
	self.charge = nil -- シュートの溜めを始めた時刻
	self.chargeFlick = nil
	self.rsBuf = {} -- 技の入力列 { t, d }
	self.skillArmUntil = -1
	self.shiftT = nil
	self.qT = -9
	self.shieldUntil = -1
	self.teamPressUntil = -1
	self.gkRushUntil = -1
	self.switchT = -9
	self.presser = { [HOME] = nil, [AWAY] = nil } -- ボールに寄せる役 (すぐには入れ替えない)
	self.chase = {} -- こぼれ球・パスに向かう選手 -> 目標
	self:kickoff(HOME)
	return self
end

-- ================================================================ 基本
function Match:rand()
	return self.random()
end

function Match:uniform(a, b)
	return a + (b - a) * self:rand()
end

function Match:gauss()
	local u1 = math.max(self:rand(), 1e-9)
	local u2 = self:rand()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function Match:choice(list)
	return list[math.floor(self:rand() * #list) + 1]
end

function Match:team(t)
	return self.teams[t]
end

--- 攻撃方向 (+x / -x)。後半と延長後半はサイドが入れ替わる。
function Match:sgn(team)
	local s = team == HOME and 1 or -1
	if self.flip then
		return -s
	end
	return s
end

--- 退場者を除いた、そのチームの選手一覧。
function Match:active(team)
	return self.act[team]
end

--- フォーメーションの位置 index の選手。退場・キーパー交代時は代わりの選手を返す。
function Match:slot(team, i)
	if i == 0 then
		for _, q in self.act[team] do
			if q.gk then
				return q
			end
		end
	end
	local p = self.teams[team][i + 1]
	if p ~= nil and not p.out then
		return p
	end
	for _, q in self.act[team] do
		if not q.gk then
			return q
		end
	end
	return self.act[team][1]
end

function Match:event(kind)
	table.insert(self.events, { kind = kind })
end

function Match:oppGoal(team)
	return { x = self:sgn(team) * PL / 2, y = 0 }
end

function Match:human(team)
	return self.ctrlKind[team] == "human"
end

function Match:popup(key, tag)
	table.insert(self.popups, { t = self.elapsed, key = key, tag = tag or "info" })
end

function Match:placeFormation()
	for _, p in self.pl do
		local f = self.forms[p.team][p.i + 1]
		local s = self:sgn(p.team)
		p.dive = nil
		if p.out then
			-- 退場者は動かさない
		elseif p.gk then
			p.p = { x = -s * (PL / 2 - 1.5), y = 0 }
		else
			p.p = { x = s * f.x * 0.55, y = s * f.y }
		end
		p.v = { x = 0, y = 0 }
		p.stun, p.slide = 0, 0
		p.skill = nil
	end
end

function Match:kickoff(team)
	self:placeFormation()
	local st = self:slot(team, 9)
	st.p = { x = -self:sgn(team) * 0.8, y = 0 }
	local b = self.ball
	b.p = { x = 0, y = 0 }
	b.v = { x = 0, y = 0 }
	b.z, b.vz = 0, 0
	b.owner, b.last, b.target, b.offside = st, st, nil, nil
	self.setp = nil
	self.charge = nil
	for _, q in self:active(1 - team) do
		q.cd = 1.5 -- キックオフ直後は相手がすぐに奪いに来ない (元の版では開始 0.1 秒で奪われた)
	end
	if self:human(team) then
		self.ctrl = st
	end
end

-- ================================================================ 入力
--- キーの押下状態 (押している間 true)。矢印は離した直後も FLICK_LATCH 秒だけ true。
function Match:setKey(name, isDown)
	self.down[name] = isDown and true or nil
	if isDown and ARROWS[name] then
		self.evt[name] = self.elapsed
	end
end

function Match:held(...)
	for i = 1, select("#", ...) do
		local n = select(i, ...)
		if self.down[n] then
			return true
		end
		if ARROWS[n] and self.elapsed - (self.evt[n] or -9) < FLICK_LATCH then
			return true
		end
	end
	return false
end

function Match:moveDir()
	local dx = (self:held("D") and 1 or 0) - (self:held("A") and 1 or 0)
	local dy = (self:held("S") and 1 or 0) - (self:held("W") and 1 or 0)
	return vnorm({ x = dx, y = dy })
end

--- いま押している (または直前に押した) 矢印キー = ボタンをフリックした向き。
function Match:flick()
	for _, name in { "Up", "Down", "Left", "Right" } do
		if self:held(name) then
			return string.lower(name)
		end
	end
	return nil
end

--- キーが押された瞬間のイベント。移動の継続入力は setKey で渡す。
function Match:onKey(ch)
	if ARROWS[ch] then
		self.evt[ch] = self.elapsed
		return
	end
	-- 技の入力受付中は WASD を「弾いた方向」として数える
	local wd = WASD[ch]
	if wd and self.elapsed < self.skillArmUntil and self.ball.owner == self.ctrl and self.ctrl.skill == nil then
		local last = self.rsBuf[#self.rsBuf]
		local repeated = last and last.d.x == wd.x and last.d.y == wd.y and self.elapsed - last.t < 0.15
		if not repeated then
			table.insert(self.rsBuf, { t = self.elapsed, d = wd }) -- キーリピートは1回として数える
		end
		self.skillArmUntil = math.max(self.skillArmUntil, self.elapsed + 0.3)
		return
	end
	if ch == "P" then
		self.paused = not self.paused
		return
	end
	if self.paused or self.ended then
		return
	end
	if self.mode == "replay" then
		if ch == KEYS.pass or ch == KEYS.through or ch == KEYS.shoot then
			self:endReplay() -- リプレイをスキップ
		end
		return
	end
	if self.mode == "halftime" then
		return
	end
	local b = self.ball
	local mine = b.owner == self.ctrl
	local fl = self:flick()
	if self.setp ~= nil and self.setp.team == HOME and self:human(HOME) then
		if ch == KEYS.pass then
			self:takeSetpiece((fl == "up" or fl == "down") and "lofted" or "pass")
		elseif ch == KEYS.through then
			self:takeSetpiece((fl == "up" or fl == "down") and "lthrough" or "through")
		elseif ch == KEYS.shoot and (self.setp.kind == "fk" or self.setp.kind == "pk") then
			self.charge = self.elapsed
			self.chargeFlick = fl
		end
		return
	end
	if ch == KEYS.left_tap then
		self:leftTap()
		return
	end
	if mine then
		if ch == KEYS.pass then
			local wide = math.abs(self.ctrl.p.y) > 20 and self:sgn(HOME) * self.ctrl.p.x > PL / 2 - 30 -- クロスエリア
			if fl == "up" or fl == "down" then
				self:kick("lofted", { cross = wide })
			elseif fl == "left" then
				self:kick("pass", { impact = true, cross = wide })
			elseif fl == "right" then
				self:kick("lofted", { impact = true, cross = wide })
			else
				self:kick("pass", { cross = wide })
			end
		elseif ch == KEYS.through then
			if fl == "up" or fl == "down" then
				self:kick("lthrough")
			elseif fl == "left" then
				self:kick("through", { impact = true })
			elseif fl == "right" then
				self:kick("lthrough", { impact = true })
			else
				self:kick("through")
			end
		elseif ch == KEYS.shoot and self.charge == nil then
			self.charge = self.elapsed
			self.chargeFlick = fl
		end
		return
	end
	-- 空中のボール: ヘディング / ボレー
	if (ch == KEYS.shoot or ch == KEYS.pass or ch == KEYS.through) and self:tryHeader(ch) then
		return
	end
	-- 守備
	if ch == KEYS.slide and b.owner ~= nil and b.owner.team ~= HOME then
		self:startSlide(self.ctrl)
	elseif ch == KEYS.shoot then
		self:standTackle(self.ctrl)
	elseif ch == KEYS.pass and fl == "up" then
		self.teamPressUntil = self.elapsed + 4.0 -- マッチアップを上へ: チームプレス
		self:popup("popup.teampress", "info")
	elseif ch == KEYS.through and fl == "down" and self:sgn(HOME) * b.p.x < 0 then
		self.gkRushUntil = self.elapsed + 1.5 -- プレスを下へ (自陣): GK 飛び出し
	elseif ch == KEYS.cursor then
		if fl ~= nil then
			local dirs = { up = { x = 0, y = -1 }, down = { x = 0, y = 1 }, left = { x = -1, y = 0 }, right = { x = 1, y = 0 } }
			self:manualCursor(dirs[fl])
		else
			local nxt = self:nextCursor()
			if nxt ~= nil then
				self:setCtrl(nxt)
			end
		end
	end
end

--- 左側 (Q) の2回タップ: 攻撃ではドリブル停止 / ダッシュ中はボディコンタクト, 守備ではショルダーチャージ。
function Match:leftTap()
	local prev = self.qT
	self.qT = self.elapsed
	if self.elapsed - prev > 0.35 then
		return
	end
	local p, b = self.ctrl, self.ball
	if b.owner == p then
		if self:held("Shift") then
			self.shieldUntil = self.elapsed + 1.5
			self:popup("popup.body", "info")
		else
			p.v = { x = 0, y = 0 } -- その場で止める
		end
	elseif b.owner ~= nil and b.owner.team ~= p.team and vdist(b.owner.p, p.p) < 1.6 then
		p.cd = 0
		self:tryTackle(p, 30.0, 1.0) -- ショルダーチャージ (体を当てて奪う)
	end
end

-- ================================================================ 技 (スキルムーブ)
--- 入力列を、進行方向に対する相対方向 (F/B/S/X) に直してコマンド表と照合する。
function Match:matchSkill(p)
	local f = (vlen(p.v) < 0.5) and p.face or vnorm(p.v)
	local n = { x = -f.y, y = f.x }
	local seq, firstSide = {}, nil
	local start = math.max(1, #self.rsBuf - 2)
	for k = start, #self.rsBuf do
		local d = self.rsBuf[k].d
		local a, bb = vdot(d, f), vdot(d, n)
		local tok
		if math.abs(a) >= math.abs(bb) then
			tok = a > 0 and "F" or "B"
		else
			local side = bb > 0 and 1 or -1
			if firstSide == nil then
				firstSide = side
			end
			tok = (side == firstSide) and "S" or "X"
		end
		if #seq == 0 or seq[#seq] ~= tok then
			table.insert(seq, tok)
		end
	end
	for _, c in Config.SkillCommands do
		local cmd = c.seq
		if #seq >= #cmd then
			local ok = true
			for k = 1, #cmd do
				if seq[#seq - #cmd + k] ~= cmd[k] then
					ok = false
					break
				end
			end
			if ok then
				-- 抜ける側: 最後に弾いた横方向 (無ければ、近い相手と逆側)
				local lastSide = nil
				for k = #self.rsBuf, 1, -1 do
					local d = self.rsBuf[k].d
					if math.abs(vdot(d, n)) > math.abs(vdot(d, f)) then
						lastSide = vdot(d, n) > 0 and 1 or -1
						break
					end
				end
				if lastSide == nil then
					local opp, od = nil, math.huge
					for _, q in self:active(1 - p.team) do
						local d = vdist(q.p, p.p)
						if d < od then
							opp, od = q, d
						end
					end
					lastSide = vdot(vsub(opp.p, p.p), n) > 0 and -1 or 1
				end
				return c.name, f, vmul(n, lastSide)
			end
		end
	end
	return nil
end

function Match:startSkill(p, name, f, side)
	p.skill = { name = name, t0 = self.elapsed, f = f, n = side, judged = false, dur = Config.SkillDuration[name] }
	local log = {}
	for _, t in p.skillLog do
		if self.elapsed - t < 4.0 then
			table.insert(log, t)
		end
	end
	table.insert(log, self.elapsed)
	p.skillLog = log
	if p.team == HOME then
		self.skillStats.tried += 1
	end
	table.insert(self.labels, { t = self.elapsed, key = "skill." .. name, player = p })
end

--- 技の途中 (u: 0..1) の、ボールの位置 (選手からの相対) と選手の速度。
function Match:skillMotion(p, u)
	local sk = p.skill
	local f, n, name = sk.f, sk.n, sk.name
	local r = P_R + 0.35
	local ball, vel
	if name == "double_touch" then -- 横へ1タッチ -> 斜め前へもう1タッチ
		local a = 1.3 * math.min(1.0, u / 0.45)
		local c = 0.9 * math.max(0.0, u - 0.45) / 0.55
		ball = { x = f.x * (r + c) + n.x * a, y = f.y * (r + c) + n.y * a }
		if u < 0.45 then
			vel = vmul(n, 3.5)
		else
			vel = vmul(vnorm({ x = f.x * 0.8 + n.x * 0.6, y = f.y * 0.8 + n.y * 0.6 }), DASH * 0.85)
		end
	elseif name == "elastico" then -- 外に見せて (逆側へ少し), 内へ大きく切り返す
		local fake = -0.6 * math.sin(math.pi * math.min(1.0, u / 0.35))
		local cut = 1.4 * math.max(0.0, u - 0.35) / 0.65
		ball = { x = f.x * r + n.x * (fake + cut), y = f.y * r + n.y * (fake + cut) }
		if u < 0.35 then
			vel = vmul(n, -1.0)
		else
			vel = vmul(vnorm({ x = f.x * 0.5 + n.x * 0.85, y = f.y * 0.5 + n.y * 0.85 }), DASH * 0.8)
		end
	elseif name == "scissors" then -- 体を逆へ振って (ボールは動かさない), 横へ持ち出す
		local s = 1.0 * math.max(0.0, u - 0.6) / 0.4
		ball = { x = f.x * r + n.x * s, y = f.y * r + n.y * s }
		if u < 0.6 then
			vel = vmul(n, -2.0 * math.sin(math.pi * math.min(1.0, u / 0.6)))
		else
			vel = vmul(vnorm({ x = f.x * 0.6 + n.x * 0.8, y = f.y * 0.6 + n.y * 0.8 }), DASH * 0.8)
		end
	elseif name == "marseille" then -- ボールの周りを回転して、体を入れ替える
		local ang = 2 * math.pi * u
		local c, s = math.cos(ang), math.sin(ang)
		ball = { x = (f.x * c + n.x * s) * r, y = (f.y * c + n.y * s) * r }
		vel = { x = n.x * 2.5 + f.x * 1.5 * u, y = n.y * 2.5 + f.y * 1.5 * u }
	else -- drag_back: ボールを引いて向きを変える
		local k = r * (1 - 2 * u)
		ball = { x = f.x * k + n.x * 0.3 * u, y = f.y * k + n.y * 0.3 * u }
		if u < 0.6 then
			vel = vmul(f, -1.5)
		else
			vel = vmul(vnorm({ x = -f.x * 0.3 + n.x, y = -f.y * 0.3 + n.y }), SPEED * 0.8)
		end
	end
	return ball, vel
end

--- 技の決め所: 近くの守備者がつられたか。技の種類・相手の体勢・連発で確率が変わる。
function Match:judgeSkill(p)
	local sk = p.skill
	local f = sk.f
	local beatAny, read = false, false
	local recent = 0
	for _, t in p.skillLog do
		if self.elapsed - t < 3.0 then
			recent += 1
		end
	end
	local spam = 0.2 * math.max(0, recent - 1)
	for _, q in self:active(1 - p.team) do
		local d = vsub(q.p, p.p)
		if vlen(d) <= 1.8 and not q.gk then
			local prob = Config.SkillBase[sk.name] - spam
			local rush = vdot(q.v, vnorm(vmul(d, -1))) -- 勢いよく寄せてきている
			if rush > 3 then
				prob += 0.15
			elseif vlen(q.v) < 1 and vdot(vnorm(d), f) > 0.7 then
				prob -= 0.1
			end
			if self:human(q.team) and q == self.ctrl and self:held(KEYS.pass) then
				prob -= 0.15 -- マッチアップで構えている人間は引っかかりにくい
			end
			if self:rand() < prob then
				q.stun = math.max(q.stun, 0.7)
				beatAny = true
			else
				read = true
				if self:rand() < 0.5 and self.ball.owner == p then
					p.skill = nil
					self.ball.owner = q
					self.ball.last = q
					q.cd = 0.6
					if self:human(q.team) then
						self.ctrl = q
					end
					self:popup(p.team == HOME and "popup.stopped" or "popup.steal", p.team == HOME and "bad" or "good")
					return
				end
			end
		end
	end
	if beatAny then
		if p.team == HOME then
			self.skillStats.beat += 1
			self:popup("popup.beat", "skill")
		else
			self:popup("popup.beaten", "bad")
		end
	elseif read and p.team == HOME then
		self:popup("popup.read", "bad")
	end
end

function Match:runSkill(p, dt)
	local sk = p.skill
	local u = (self.elapsed - sk.t0) / sk.dur
	if not sk.judged and u >= 0.4 then
		sk.judged = true
		self:judgeSkill(p)
		if p.skill == nil then
			return
		end
	end
	if u >= 1.0 or self.ball.owner ~= p then
		p.skill = nil
		return
	end
	local _, vel = self:skillMotion(p, u)
	p.v = vel
end

-- ================================================================ キック
function Match:pickReceiver(c, d)
	local best, bs = nil, -1e9
	for _, p in self:active(c.team) do
		if p ~= c then
			local v = vsub(p.p, c.p)
			local dist = vlen(v)
			if dist >= 2 then
				local s = 2.2 * vdot(vnorm(v), d) - dist / 45.0
				if p.gk then
					s -= 1.0
				end
				if s > bs then
					best, bs = p, s
				end
			end
		end
	end
	return best
end

--- team から見た相手の、後ろから2人目の x (攻撃方向の座標)。
function Match:secondLastX(team)
	local s = self:sgn(team)
	local xs = {}
	for _, q in self:active(1 - team) do
		table.insert(xs, s * q.p.x)
	end
	table.sort(xs, function(a, b)
		return a > b
	end)
	return xs[2]
end

--[[
	kind: "shot" | "pass" | "lofted" | "through" | "lthrough"
	o: { c, target, power, aimY, style, impact, cross }
]]
function Match:kick(kind, o)
	o = o or {}
	local b = self.ball
	local c = o.c or b.owner
	if c == nil then
		return
	end
	local power = o.power or 0.7
	local human = self:human(c.team) and c == self.ctrl
	local d = human and self:moveDir() or { x = 0, y = 0 }
	if d.x == 0 and d.y == 0 then
		d = { x = c.face.x, y = c.face.y }
	end
	b.offside = nil
	local s = self:sgn(c.team)
	if kind == "shot" then
		local g = self:oppGoal(c.team)
		local aimY = o.aimY
		if aimY == nil then
			aimY = clamp(d.y, -1, 1) * (GOAL_W / 2 - 0.5)
		end
		local err = (1.7 + 2.2 * math.max(0.0, power - 0.75)) * self:gauss() -- 強すぎるとぶれる
		err = err / math.max(c.attr.shoot, 0.5) -- シュートが上手い選手ほどぶれない
		if c.team == AWAY and not self:human(AWAY) then
			err *= self.diff.aiShotErr
		end
		if o.style == "header" then -- ヘディング: 足より不正確
			err *= 1.4
			power = math.min(power, 0.8)
		end
		if o.style == "impact" then -- インパクトシュート: 強烈
			power = math.min(1.0, power + 0.15)
		end
		if o.style == "control" then -- コントロールシュート: 正確だが遅い
			err *= 0.4
			power = math.min(power, 0.7)
		end
		local tgt = { x = g.x, y = aimY + err }
		self.tstats[c.team].shots += 1
		if math.abs(tgt.y) < GOAL_W / 2 then
			self.tstats[c.team].onTarget += 1
		end
		local u = vnorm(vsub(tgt, c.p))
		local spd = 18 + 14 * power
		local dist = vdist(tgt, c.p)
		if o.style == "loop" then -- ループシュート: キーパーの頭上を越す
			local tf = clamp(dist / 14.0, 0.8, 2.0)
			b.v = vmul(u, (dist / tf) * 0.95)
			b.z, b.vz = 0.1, 0.5 * GRAV * tf * 0.92
		else
			b.v = vmul(u, spd)
			local tf = dist / spd
			local peak = 0.3 + 3.2 * math.max(0.0, power - 0.55) + math.abs(self:gauss() * 0.25) -- 強いほど浮く
			b.z, b.vz = 0.1, (peak + 0.5 * GRAV * tf * tf) / math.max(tf, 0.1) * 0.5
		end
		b.target = nil
	else
		local tgt = o.target
		if tgt == nil and o.cross then -- クロス: ゴール前にいる味方へ
			local bestM, bestY = nil, math.huge
			for _, m in self:active(c.team) do
				if m ~= c and math.abs(m.p.y) < BOX_W / 2 and s * m.p.x > PL / 2 - BOX_L - 2 then
					if math.abs(m.p.y) < bestY then
						bestM, bestY = m, math.abs(m.p.y)
					end
				end
			end
			tgt = bestM
		end
		tgt = tgt or self:pickReceiver(c, d)
		if tgt == nil then
			return
		end
		local lead = ({ pass = 0.4, lofted = 0.9, through = 1.0, lthrough = 1.1 })[kind]
		local dest = vadd(tgt.p, vmul(tgt.v, lead))
		if kind == "through" or kind == "lthrough" then
			dest = vadd(dest, { x = s * 7.0, y = 0 })
		end
		local rough = 0.12 * math.max(0, 1.3 - c.attr.pass) * vdist(dest, c.p) / 5 -- 距離が長いほど・パスが下手なほどずれる
		dest.x += self:gauss() * rough
		dest.y += self:gauss() * rough
		dest.x = clamp(dest.x, -PL / 2 + 1, PL / 2 - 1)
		dest.y = clamp(dest.y, -PW / 2 + 1, PW / 2 - 1)
		local dist = vdist(dest, c.p)
		local u = vnorm(vsub(dest, c.p))
		if kind == "lofted" or kind == "lthrough" then
			local T = clamp(dist / 20.0, 0.7, 2.2)
			b.v = vmul(u, dist / T)
			b.z, b.vz = 0.1, 0.5 * GRAV * T
		else
			local v0 = math.sqrt(2 * FRICTION * dist) + 3.5
			b.v = vmul(u, math.min(v0, 26.0))
			b.z, b.vz = 0, 0
		end
		if o.impact then -- インパクトパス: 速く鋭い (カットされにくい)
			b.v = vmul(b.v, 1.3)
		end
		b.target = tgt
		-- オフサイド: 受け手が相手陣内で、ボールと後ろから2人目の相手より前にいる
		local rx = s * tgt.p.x
		if rx > 0 and rx > s * c.p.x and rx > self:secondLastX(c.team) + 0.3 then
			b.offside = tgt
		end
		if c.team == HOME and self:human(HOME) then
			self.stats.passes += 1
		end
		self.tstats[c.team].passes += 1
	end
	b.kind = kind
	b.owner = nil
	b.kicker, b.last = c, c
	b.kickT = self.elapsed
	b.p = vadd(c.p, vmul(vnorm(b.v), P_R + 0.3))
	self.charge = nil
	self:event("kick")
	if kind == "shot" then
		self:triggerDive(c)
	end
end

function Match:startSlide(p)
	if p.cd > 0 or p.slide > 0 then
		return
	end
	p.slide, p.cd = 0.45, 1.4
	p.v = vmul(p.face, 10.0)
end

--- 立ったままの奪取 (マッチアップ / CPU の寄せ)。
function Match:tryTackle(p, rate, dt)
	local b = self.ball
	if b.owner == nil or b.owner.team == p.team or p.cd > 0 or b.owner.skill ~= nil then
		return
	end
	if self:human(b.owner.team) and b.owner == self.ctrl and self.elapsed < self.shieldUntil then
		rate *= 0.5 -- ボディコンタクトでボールを守る
	end
	rate *= p.attr.tackle * TACTICS.Press[self.tactics[p.team].press]
	if p.team == AWAY and not self:human(AWAY) then
		rate *= self.diff.aiTackle
	end
	if vdist(b.p, p.p) < 1.3 and self:rand() < rate * dt then
		p.cd = 0.9
		if self:rand() < 0.55 then
			local lost = b.owner
			lost.stun = 0.5
			b.owner = p
			b.last = p
			if self:human(p.team) then
				self.ctrl = p
				self:popup("popup.steal", "good")
			elseif self:human(lost.team) then
				self:popup("popup.lost", "bad")
			end
		elseif self:rand() < 0.2 then
			self:foul(p, b.owner, 0.4) -- 奪えず体を倒してしまった (軽いファウル)
		end
	end
end

--- 守備のタックル: 相手がドリブル中なら奪取、こぼれ球が近ければクリア。
function Match:standTackle(p)
	local b = self.ball
	if p.cd > 0 then
		return
	end
	p.cd = 0.7
	if b.owner ~= nil and b.owner.team ~= p.team and b.owner.skill == nil then
		if vdist(b.p, p.p) < 1.6 then
			if self:rand() < 0.55 then
				b.owner.stun = 0.5
				b.owner = p
				b.last = p
				self:popup("popup.steal", "good")
			end
		end
	elseif b.owner == nil and vdist(b.p, p.p) < 2.0 and b.z < 1.5 then
		local g = self:oppGoal(p.team)
		local d = vnorm({ x = g.x - p.p.x, y = g.y - p.p.y + self:uniform(-15, 15) })
		b.v = vmul(d, 24.0)
		b.z, b.vz = 0.1, 7.0
		b.kicker, b.last = p, p
		b.kickT = self.elapsed
		b.kind, b.target, b.offside = "clear", nil, nil
		self:popup("popup.clear", "info")
	end
end

--- 守備でカーソルを渡す選手の良さ (小さいほど良い): ボールに近く、ボールより自陣ゴール側にいる選手。
function Match:defendScore(p)
	local b = self.ball
	local s = self:sgn(p.team)
	local d = vdist(p.p, b.p)
	local goalSide = s * p.p.x < s * b.p.x + 1.0
	return d + (goalSide and 0.0 or 12.0) + 0.1 * math.abs(p.p.y - b.p.y)
end

--- カーソル (U) を押したときに切り替わる選手。
function Match:nextCursor()
	local b = self.ball
	if b.owner == nil and b.target ~= nil and b.target.team == HOME and b.target ~= self.ctrl then
		return b.target
	end
	local best, bs = nil, math.huge
	for _, p in self:active(HOME) do
		if p ~= self.ctrl and not p.gk then
			local s = self:defendScore(p)
			if s < bs then
				best, bs = p, s
			end
		end
	end
	return best
end

--- カーソル + 矢印 (守備): 今の選手から見て、その方向にいる味方へ。
function Match:manualCursor(d)
	local best, bs = nil, -1e9
	for _, p in self:active(HOME) do
		if p ~= self.ctrl and not p.gk then
			local v = vsub(p.p, self.ctrl.p)
			local dist = vlen(v)
			local cosv = vdot(vnorm(v), d)
			if cosv >= 0.5 then
				local sc = cosv - dist / 40.0
				if sc > bs then
					best, bs = p, sc
				end
			end
		end
	end
	if best ~= nil then
		self:setCtrl(best)
	end
end

function Match:setCtrl(p)
	self.ctrl = p
	self.switchT = self.elapsed
end

-- ================================================================ セットプレー
function Match:startSetpiece(kind, team, pos, noteKey)
	local b = self.ball
	b.owner = nil
	b.v = { x = 0, y = 0 }
	b.z, b.vz = 0, 0
	b.p = { x = pos.x, y = pos.y }
	b.target, b.offside = nil, nil
	for _, q in self.pl do
		q.dive = nil
	end
	if kind == "corner" then
		self.tstats[team].corners += 1
	end
	self:event("whistle")
	local others = {}
	for _, p in self:active(team) do
		if not p.gk or kind == "gk" or kind == "fk" then
			table.insert(others, p)
		end
	end
	table.sort(others, function(a, c)
		return vdist(a.p, b.p) < vdist(c.p, b.p)
	end)
	local taker = others[1]
	if kind == "gk" then
		taker = self:slot(team, 0)
	end
	if kind == "pk" then
		taker = self:slot(team, 9)
		for _, p in self.pl do -- PK: 他の選手はエリア外へ
			if p ~= taker and not p.gk then
				p.p.x = clamp(p.p.x, -PL / 2 + BOX_L + 1, PL / 2 - BOX_L - 1)
			end
		end
		local gk = self:slot(1 - team, 0)
		gk.p = { x = self:sgn(team) * (PL / 2 - 0.5), y = 0 }
	end
	local back
	if kind ~= "throw" then
		back = vnorm(vsub(b.p, self:oppGoal(team)))
	else
		back = { x = 0, y = sgnOf(b.p.y) }
	end
	taker.p = vadd(b.p, vmul(back, P_R + 0.4))
	taker.v = { x = 0, y = 0 }
	taker.face = vmul(back, -1)
	taker.skill = nil
	self.setp = { kind = kind, team = team, t0 = self.elapsed, taker = taker }
	self.charge = nil
	if self:human(team) then
		self.ctrl = taker
	end
	self:popup(noteKey, "info")
end

function Match:takeSetpiece(how, power)
	local sp = self.setp
	if sp == nil then
		return
	end
	power = power or 0.75
	local taker = sp.taker
	self.ball.owner = taker
	self.setp = nil
	if sp.kind == "pk" or (sp.kind == "fk" and how == "shot") then
		self:kick("shot", { c = taker, power = power })
	elseif sp.kind == "corner" and how == "pass" then
		self:kick("lofted", { c = taker })
	else
		self:kick(how, { c = taker })
	end
	if sp.kind == "throw" then
		self.ball.offside = nil -- スローインにオフサイドはない
	end
end

function Match:cpuSetpiece()
	local sp = self.setp
	if sp == nil or self:human(sp.team) or self.elapsed - sp.t0 < 1.3 then
		return
	end
	local taker = sp.taker
	if sp.kind == "pk" then
		self.ball.owner = taker
		self.setp = nil
		local sign = self:choice({ -1, 1 })
		self:kick("shot", { c = taker, power = 0.8, aimY = sign * self:uniform(1.5, 3.2) })
		return
	end
	local how = (sp.kind == "corner" or sp.kind == "gk") and "lofted" or "pass"
	local best, bs = nil, -1e9
	for _, m in self:active(sp.team) do
		if m ~= taker then
			local sc = self:laneClear(taker.p, m.p, sp.team) - 0.02 * vdist(m.p, taker.p)
			if sc > bs then
				best, bs = m, sc
			end
		end
	end
	self.ball.owner = taker
	self.setp = nil
	self:kick(how, { c = taker, target = best })
end

-- ================================================================ AI
--- a -> b のパスコースに最も近い相手までの距離。大きいほど空いている。
function Match:laneClear(a, b, team)
	local ab = vsub(b, a)
	local L2 = vdot(ab, ab) + 1e-9
	local best = 99.0
	for _, p in self:active(1 - team) do
		local tt = clamp(vdot(vsub(p.p, a), ab) / L2, 0, 1)
		local q = vadd(a, vmul(ab, tt))
		best = math.min(best, vdist(q, p.p))
	end
	return best
end

--- チームの陣形: ボール位置に応じて全体が押し上げ/後退/横スライドする。
function Match:shapeTargets()
	local b = self.ball
	local att = HOME
	if b.owner ~= nil then
		att = b.owner.team
	elseif b.last ~= nil then
		att = b.last.team
	end
	local tg = {}
	for team = HOME, AWAY do
		local s = self:sgn(team)
		local bx = s * b.p.x -- 自チームの攻撃方向で見たボールの x
		local attacking = att == team
		for _, p in self:active(team) do
			local f = self.forms[p.team][p.i + 1]
			if p.gk then
				local gx = -s * (PL / 2 - 1.5)
				local gy = clamp(b.p.y * 0.15, -3, 3)
				tg[p] = { x = gx, y = gy }
				if team == HOME and self.elapsed < self.gkRushUntil then
					tg[p] = { x = b.p.x, y = b.p.y } -- GK 飛び出し
				end
			else
				local push = bx * 0.55 + (attacking and 14 or -2) + TACTICS.Line[self.tactics[team].line]
				if not attacking and team == HOME and self.elapsed < self.teamPressUntil then
					push += 8 -- チームプレス: 全体を押し上げる
				end
				local x = clamp(f.x + push, -PL / 2 + 6, PL / 2 - 4)
				if not attacking then
					local front = FWD[f.role] and 12 or 4
					x = math.min(x, bx + front)
				end
				local spread = attacking and 1.15 or 0.8
				local y = f.y * spread + b.p.y * 0.3
				if attacking and FWD[f.role] then
					local lim = self:secondLastX(team) - 0.5 -- 前線はオフサイドラインの手前で待つ
					x = math.min(x + 6, lim)
				end
				tg[p] = { x = s * x, y = clamp(y, -PW / 2 + 2, PW / 2 - 2) }
			end
		end
	end
	-- 守備側: 最も近い選手が寄せる
	for team = HOME, AWAY do
		if att ~= team and b.owner ~= nil then
			local defs = {}
			for _, p in self:active(team) do
				if not p.gk then
					table.insert(defs, p)
				end
			end
			local near, nd = nil, math.huge
			for _, p in defs do
				local d = vdist(p.p, b.p)
				if d < nd then
					near, nd = p, d
				end
			end
			local cur = self.presser[team]
			if cur == nil or table.find(defs, cur) == nil or nd < vdist(cur.p, b.p) - 3.0 then
				cur = near -- 3m 以上近い選手が出るまで、寄せる役は入れ替えない
			end
			self.presser[team] = cur
			tg[cur] = vadd(b.p, vmul(b.owner.v, 0.3))
			if team == HOME and self.elapsed < self.teamPressUntil then
				local second, sd = nil, math.huge
				for _, p in defs do
					if p ~= cur then
						local d = vdist(p.p, b.p)
						if d < sd then
							second, sd = p, d
						end
					end
				end
				if second ~= nil then
					tg[second] = { x = b.p.x, y = b.p.y } -- チームプレス: 2人目も寄せる
				end
			end
		end
	end
	return tg
end

--- 今の速度から、ボールが今後どこを通るか { t, p, z } を予測する (updateBall と同じ物理)。
function Match:ballFuture(horizon, step)
	horizon = horizon or 3.0
	step = step or 0.1
	local b = self.ball
	local px, py = b.p.x, b.p.y
	local vx, vy = b.v.x, b.v.y
	local z, vz = b.z, b.vz
	local out = {}
	local t = 0.0
	while t < horizon do
		t += step
		if z > 0 or vz > 0 then
			vz -= GRAV * step
			z += vz * step
			if z <= 0 then
				z = 0
				vz = math.abs(vz) > 2.5 and -vz * 0.35 or 0.0
				vx, vy = vx * 0.75, vy * 0.75
			end
		else
			local sp = math.sqrt(vx * vx + vy * vy)
			if sp > 0 then
				local k = math.max(0.0, sp - FRICTION * step) / sp
				vx, vy = vx * k, vy * k
			end
		end
		px += vx * step
		py += vy * step
		table.insert(out, { t = t, p = { x = px, y = py }, z = z })
	end
	return out
end

--- ボールが誰のものでもない時: 各チームで一番早く追いつける選手を、その地点へ向かわせる。
function Match:planChasers()
	self.chase = {}
	local b = self.ball
	if b.owner ~= nil or self.setp ~= nil then
		return
	end
	local fut = self:ballFuture()
	for team = HOME, AWAY do
		local best = nil -- { t, p, q }
		for _, p in self:active(team) do
			local skip = false
			if p.gk and not (math.abs(b.p.x) > PL / 2 - BOX_L and sgnOf(b.p.x) == -self:sgn(team)) then
				skip = true
			end
			if p == self.ctrl and self:human(team) then
				skip = true
			end
			if not skip then
				for _, f in fut do
					if f.z < 1.9 and vdist(f.p, p.p) <= DASH * 0.9 * f.t + CONTROL_R then
						if best == nil or f.t < best.t then
							best = { t = f.t, p = p, q = f.p }
						end
						break
					end
				end
			end
		end
		if b.target ~= nil and b.target.team == team and not (b.target == self.ctrl and self:human(team)) then
			-- パスの受け手: 到着点 (受け手に一番近い軌道上の点) へ
			local bq, bd = nil, math.huge
			for _, f in fut do
				local d = vdist(f.p, b.target.p)
				if d < bd then
					bq, bd = f.p, d
				end
			end
			self.chase[b.target] = { p = bq, urgent = true }
		elseif best ~= nil then
			self.chase[best.p] = { p = best.q, urgent = true }
		elseif #fut > 0 then
			local last = fut[#fut].p
			local np, nd = nil, math.huge
			for _, p in self:active(team) do
				if not p.gk then
					local d = vdist(p.p, last)
					if d < nd then
						np, nd = p, d
					end
				end
			end
			if np ~= nil then
				self.chase[np] = { p = last, urgent = true }
			end
		end
	end
end

function Match.steer(p, desired, acc, dt)
	local dvx, dvy = desired.x - p.v.x, desired.y - p.v.y
	local n = math.sqrt(dvx * dvx + dvy * dvy)
	local lim = acc * dt
	if n <= lim then
		p.v = { x = p.v.x + dvx, y = p.v.y + dvy }
	else
		p.v = { x = p.v.x + dvx / n * lim, y = p.v.y + dvy / n * lim }
	end
end

function Match.aiSpeed(dist, urgent)
	if dist < 0.6 then
		return 0.0
	end
	local top
	if urgent then
		top = DASH * 0.92
	elseif dist > 12 then
		top = SPEED * 0.85 -- ジョグ
	elseif dist > 3 then
		top = SPEED * 0.6
	else
		top = SPEED * 0.4 -- 歩いて位置を微調整
	end
	return top * math.min(1.0, dist / 2.5)
end

--- CPU のボール保持者。DECIDE_EVERY 秒ごとに、シュート / パス / ドリブル方向を決める。
function Match:cpuCarrier(c, dt)
	if c.skill ~= nil then
		return
	end
	if self.elapsed >= c.nextDecide or c.ddir == nil then
		local slow = (c.team == AWAY and not self:human(AWAY)) and self.diff.aiDecide or 1
		c.nextDecide = self.elapsed + DECIDE_EVERY * slow * self:uniform(0.8, 1.2)
		if self:cpuDecide(c) then
			return
		end
	end
	Match.steer(c, vmul(c.ddir, SPEED * DRIBBLE * self:speedMult(c) * self:teamSpeed(c.team)), ACC_AI, dt)
end

function Match:cpuDecide(c)
	local team = c.team
	local goal = self:oppGoal(team)
	local s = self:sgn(team)
	local opp = self:active(1 - team)
	local nd = math.huge
	for _, q in opp do
		nd = math.min(nd, vdist(q.p, c.p))
	end
	local dg = vdist(goal, c.p)
	-- シュート: ゴールに近く、角度があるとき
	if math.abs(c.p.y) < 20 and ((dg < 16 and self:rand() < 0.6) or (dg < 24 and self:rand() < 0.15)) then
		self:kick("shot", {
			c = c,
			power = self:uniform(0.55, 0.85),
			aimY = self:uniform(-GOAL_W / 2 - 0.3, GOAL_W / 2 + 0.3),
		})
		return true
	end
	-- パス: 寄せられている時は高い確率で、そうでなくても時々。コースの空いた味方へ
	if (nd < 3.0 and self:rand() < 0.6) or self:rand() < 0.12 then
		local best, bs = nil, -1e9
		for _, m in self:active(team) do
			if m ~= c and not m.gk then
				local clear = self:laneClear(c.p, m.p, team)
				if clear >= 2.0 then
					local sc = clear * 0.3 + 0.06 * s * (m.p.x - c.p.x) - 0.02 * vdist(m.p, c.p)
					if s * m.p.x > self:secondLastX(team) + 0.3 and s * m.p.x > 0 then
						sc -= 5 -- オフサイド位置は避ける
					end
					if sc > bs then
						best, bs = m, sc
					end
				end
			end
		end
		if best ~= nil then
			local far = vdist(best.p, c.p) > 28
			local wide = math.abs(c.p.y) > 22 and s * c.p.x > PL / 2 - 25
			self:kick((far or wide) and "lofted" or "pass", { c = c, target = best })
			return true
		end
	end
	-- 目の前に相手がいたら、ときどき技で抜きにかかる
	local gdir = vnorm(vsub(goal, c.p))
	local front = nil
	for _, q in opp do
		local d = vsub(q.p, c.p)
		if vlen(d) < 2.2 and vdot(vnorm(d), gdir) > 0.4 then
			front = front or q
		end
	end
	if front ~= nil and self:rand() < 0.3 then
		local recent = false
		for _, t in c.skillLog do
			if self.elapsed - t < 2.5 then
				recent = true
			end
		end
		if not recent then
			local n = { x = -gdir.y, y = gdir.x }
			local side = vdot(vsub(front.p, c.p), n) < 0 and n or vmul(n, -1)
			local name = self:choice({ "double_touch", "elastico", "scissors", "marseille" })
			self:startSkill(c, name, gdir, side)
			return true
		end
	end
	-- ドリブル: ゴール方向を中心に7方向を、前進量と空いている空間で評価して選ぶ
	local best, bs = nil, -1e9
	for _, ang in { -90, -60, -30, 0, 30, 60, 90 } do
		local a = math.rad(ang)
		local d = {
			x = gdir.x * math.cos(a) - gdir.y * math.sin(a),
			y = gdir.x * math.sin(a) + gdir.y * math.cos(a),
		}
		local ahead = { x = c.p.x + d.x * 4.0, y = c.p.y + d.y * 4.0 }
		local space = 6.0
		for _, q in opp do
			local qp = { x = q.p.x + q.v.x * 0.6, y = q.p.y + q.v.y * 0.6 }
			space = math.min(space, vdist(qp, ahead))
		end
		local sc = 1.0 * vdot(d, gdir) + 1.2 * space / 6.0
		if math.abs(ahead.y) > PW / 2 - 2 or math.abs(ahead.x) > PL / 2 - 1 then
			sc -= 2.0 -- タッチラインに向かわない
		end
		if c.ddir ~= nil then
			sc += 0.25 * vdot(d, c.ddir) -- 急に向きを変えすぎない
		end
		if sc > bs then
			best, bs = d, sc
		end
	end
	c.ddir = best
	return false
end

-- ================================================================ 更新
function Match:update(dtRaw)
	local dt = math.min(0.05, dtRaw)
	if self.paused or self.ended or dt <= 0 then
		return
	end
	if self.mode == "halftime" then
		self.modeT -= dt
		if self.modeT <= 0 then
			self:endBreak()
		end
		return
	end
	if self.mode == "replay" then
		self:updateReplay(dt)
		return
	end
	self.elapsed += dt
	if self.mode == "play" and self.elapsed >= self.boundaries[self.bIndex] then
		self:onBoundary()
		return
	end
	if self.mode == "shootout" then
		self:updateShootout()
		if self.ended then
			return
		end
	end
	local b = self.ball
	if self.mode == "play" then
		self:record(dt)
		local holder = b.owner or b.last
		if holder ~= nil then
			self.poss[holder.team] += dt
		end
	end
	if self.setp ~= nil then
		self:cpuSetpiece()
		-- シュートの溜め (FK / PK)
		if self.charge ~= nil and not self:held(KEYS.shoot) then
			local pw = math.min(1.0, (self.elapsed - self.charge) / 1.0)
			self:takeSetpiece("shot", math.max(0.3, pw))
		end
		return
	end
	-- シュートの溜め: ボタンを離した瞬間に打つ。フリックの向き: ↑ ループ / ↓ コントロール / ←→ インパクト
	if self.charge ~= nil and b.owner == self.ctrl and not self:held(KEYS.shoot) then
		local pw = math.max(0.3, math.min(1.0, (self.elapsed - self.charge) / 1.0))
		local fl = self.chargeFlick or self:flick()
		local style = ({ up = "loop", down = "control", left = "impact", right = "impact" })[fl] or ""
		self:kick("shot", { c = self.ctrl, power = pw, style = style })
	end
	if self.charge ~= nil and b.owner ~= self.ctrl then
		self.charge = nil
	end
	-- ダッシュ (Shift) の短押しを検出 -> 技の入力受付を開始 (押しっぱなしはダッシュ)
	local sh = self.down.Shift == true
	if sh and self.shiftT == nil then
		self.shiftT = self.elapsed
	elseif not sh and self.shiftT ~= nil then
		if self.elapsed - self.shiftT < 0.25 and b.owner == self.ctrl then
			self.skillArmUntil = self.elapsed + 0.6
			self.rsBuf = {}
		end
		self.shiftT = nil
	end
	-- 技の入力: 最後に弾いてから 0.18 秒で確定して照合 (2〜3回の連続入力を待つ)
	local lastIn = self.rsBuf[#self.rsBuf]
	if lastIn ~= nil and self.elapsed - lastIn.t > 0.18 then
		if b.owner == self.ctrl and self.ctrl.skill == nil then
			local name, f, side = self:matchSkill(self.ctrl)
			if name ~= nil then
				self:startSkill(self.ctrl, name, f, side)
			end
		end
		self.rsBuf = {}
	end
	local keep = {}
	for _, x in self.rsBuf do
		if self.elapsed - x.t < 0.6 then
			table.insert(keep, x)
		end
	end
	self.rsBuf = keep

	local tg = self:shapeTargets()
	self:planChasers()
	-- 操作選手の自動切り替え (守備では「ボールに近く、自陣ゴール側にいる」選手へ。頻繁には変えない)
	if b.owner ~= nil and b.owner.team == HOME then
		self.ctrl = b.owner
	elseif self.ctrl.gk and not self.ctrl.out then
		self:setCtrl(self:nextCursor() or self.ctrl)
	elseif b.owner == nil and b.target ~= nil and b.target.team == HOME then
		self.ctrl = b.target
	elseif self.elapsed - self.switchT > 1.0 then
		local best = self:nextCursor()
		if best ~= nil and self:defendScore(self.ctrl) > self:defendScore(best) + 8.0 then
			self:setCtrl(best)
		end
	end

	for _, p in self.pl do
		if p.out then
			continue
		end
		local integrate = true
		p.cd = math.max(0.0, p.cd - dt)
		if self.mode == "shootout" and not p.gk then
			p.v = { x = 0, y = 0 } -- PK 戦: キッカー以外は動かない
		elseif p.slide > 0 then
			p.slide -= dt
			self:slideContact(p)
			p.v = vmul(p.v, 0.93)
		elseif p.stun > 0 then
			p.stun -= dt
			p.v = vmul(p.v, 0.85)
		elseif p.skill ~= nil then
			self:runSkill(p, dt)
		elseif p.dive ~= nil then
			self:runDive(p, dt)
		elseif p == self.ctrl and self:human(HOME) then
			local d = self:moveDir()
			local dashing = self:held("Shift") and not p.exhausted
			local sp = dashing and DASH or SPEED
			if b.owner == p then
				sp *= DRIBBLE * (self.elapsed < self.shieldUntil and 0.8 or 1.0)
			end
			if self:held(KEYS.through) and b.owner ~= nil and b.owner.team == AWAY then
				d = vnorm(vsub(b.owner.p, p.p)) -- プレス (長押し): ボールに寄せる
				sp = DASH * 0.95
				self:tryTackle(p, 1.0, dt)
			end
			if self:held(KEYS.pass) and b.owner ~= nil and b.owner.team == AWAY then
				-- マッチアップ: ボール保持者とゴールの間に入り、間合いを詰める
				local goal = vmul(self:oppGoal(HOME), -1)
				local spot = vadd(b.owner.p, vmul(vnorm(vsub(goal, b.owner.p)), 1.2))
				local to = vnorm(vsub(spot, p.p))
				if d.x == 0 and d.y == 0 then
					d = to
				else
					d = vnorm({ x = to.x + 0.5 * d.x, y = to.y + 0.5 * d.y })
				end
				sp = SPEED * 0.95
				self:tryTackle(p, 1.4, dt)
			end
			Match.steer(p, vmul(d, sp * self:speedMult(p)), ACC_HUMAN, dt)
		elseif p == b.owner and not self:human(p.team) then
			self:cpuCarrier(p, dt)
			if b.owner ~= p then
				integrate = false
			end
		elseif p == b.owner then
			Match.steer(p, { x = 0, y = 0 }, ACC_HUMAN, dt)
		else
			local urgent = false
			local target
			local ch = self.chase[p]
			if ch ~= nil then
				target, urgent = ch.p, ch.urgent
			else
				target = tg[p]
				if p == self.presser[p.team] then
					urgent = true
				end
			end
			local v = vsub(target, p.p)
			local dist = vlen(v)
			local top = Match.aiSpeed(dist, urgent) * self:speedMult(p) * self:teamSpeed(p.team)
			Match.steer(p, vmul(vnorm(v), top), ACC_AI, dt)
			if b.owner ~= nil and b.owner.team ~= p.team and dist < 1.6 then
				self:tryTackle(p, (not self:human(p.team)) and 1.0 or 0.6, dt)
			end
		end
		self:updateStamina(p, dt)
		if integrate then
			p.p.x = clamp(p.p.x + p.v.x * dt, -PL / 2 - 2, PL / 2 + 2)
			p.p.y = clamp(p.p.y + p.v.y * dt, -PW / 2 - 2, PW / 2 + 2)
			if vlen(p.v) > 0.3 and p.slide <= 0 and p.skill == nil then
				p.face = vnorm(p.v)
			end
		end
	end
	self:updateBall(dt)
	self:pruneOld()
end

-- ================================================================ 能力・スタミナ
--- 足の速さ (個体差 × スタミナ残量による低下)。
function Match:speedMult(p)
	local f = STAMINA.MinFactor + (1 - STAMINA.MinFactor) * (p.stamina / STAMINA.Max)
	return p.attr.speed * f
end

--- CPU 難易度の速さの倍率 (対戦相手の CPU にだけ掛かる)。
function Match:teamSpeed(team)
	if team == AWAY and not self:human(AWAY) then
		return self.diff.aiSpeed
	end
	return 1
end

function Match:updateStamina(p, dt)
	local spd = vlen(p.v)
	local rate
	if spd > SPEED * 1.05 then
		rate = -STAMINA.DashDrain / p.attr.stamina
	elseif spd > 1.5 then
		rate = -STAMINA.RunDrain / p.attr.stamina
	else
		rate = STAMINA.Regen
	end
	p.stamina = clamp(p.stamina + rate * dt, 0, STAMINA.Max)
	if p.stamina <= 1 then
		p.exhausted = true
	elseif p.stamina >= STAMINA.DashMin then
		p.exhausted = false
	end
end

-- ================================================================ GK のダイブ
--- シュートがゴール枠に向かっていたら、守るキーパーを反応させる。
function Match:triggerDive(shooter)
	local b = self.ball
	local team = 1 - shooter.team
	local gk = self:slot(team, 0)
	if gk == nil or not gk.gk or gk.out then
		return
	end
	local gx = self:oppGoal(shooter.team).x
	local vx = b.v.x
	if math.abs(vx) < 1e-6 or (gx - b.p.x) * vx <= 0 then
		return -- ゴールへ向かっていない
	end
	local t = (gx - b.p.x) / vx
	if t <= 0 or t > 2.5 then
		return
	end
	local yPred = b.p.y + b.v.y * t
	if math.abs(yPred) > GOAL_W / 2 + 1 then
		return -- 枠外には反応しない
	end
	local react = (team == AWAY and not self:human(AWAY)) and self.diff.gkReact or 0.5
	local y = yPred
	if self:rand() >= react then
		y = self:uniform(-GOAL_W / 2, GOAL_W / 2) -- 読み違えて別の側へ跳ぶ
	end
	gk.dive = {
		t0 = self.elapsed + KEEPER.Reaction,
		y = clamp(y, -GOAL_W / 2 - 0.5, GOAL_W / 2 + 0.5),
		x = gx - sgnOf(gx) * 0.8,
		untilT = self.elapsed + t + 0.8,
	}
end

function Match:runDive(p, dt)
	local d = p.dive
	if self.elapsed > d.untilT or self.ball.owner == p then
		p.dive = nil
		return
	end
	if self.elapsed < d.t0 then
		Match.steer(p, { x = 0, y = 0 }, 40, dt)
		return
	end
	local v = vsub({ x = d.x, y = d.y }, p.p)
	local dist = vlen(v)
	Match.steer(p, vmul(vnorm(v), math.min(KEEPER.DiveSpeed, dist / math.max(dt, 1e-3))), 60, dt)
end

-- ================================================================ ヘディング
--- 空中のボールに合わせる (ボタン: シュート = ゴールへ / パス・スルー = 落とす)。
function Match:tryHeader(ch)
	local b = self.ball
	local c = self.ctrl
	if b.owner ~= nil or c == nil or c.out or c.stun > 0 or c.slide > 0 or c.skill ~= nil then
		return false
	end
	if b.z < HEADER.MinZ or b.z > HEADER.MaxZ then
		return false
	end
	if vdist(c.p, b.p) > HEADER.Reach + 0.6 then
		return false
	end
	local goal = self:oppGoal(c.team)
	if ch == KEYS.shoot and vdist(goal, c.p) < HEADER.ShotRange then
		self:kick("shot", { c = c, power = 0.65, style = "header" })
	else
		self:kick("pass", { c = c })
	end
	self:popup("popup.header", "skill")
	return true
end

-- ================================================================ カード・退場
function Match:cardCheck(p, severity)
	severity = severity or 1
	local r = self:rand()
	if r < CARDS.RedChance * severity then
		self:showCard(p, "red")
	elseif r < (CARDS.RedChance + CARDS.YellowChance) * severity then
		p.yellow += 1
		self:showCard(p, p.yellow >= 2 and "red" or "yellow")
	end
end

function Match:showCard(p, kind)
	self.tstats[p.team][kind] += 1
	self:popup(kind == "yellow" and "popup.yellow" or "popup.red", kind == "yellow" and "info" or "bad")
	self:event("card")
	if kind == "red" then
		self:sendOff(p)
	end
end

function Match:sendOff(p)
	p.out = true
	p.skill, p.dive = nil, nil
	p.p = { x = 0, y = PW / 2 + 6 }
	p.v = { x = 0, y = 0 }
	local list = {}
	for _, q in self.teams[p.team] do
		if not q.out then
			table.insert(list, q)
		end
	end
	self.act[p.team] = list
	if self.ball.owner == p then
		self.ball.owner = nil
	end
	if p.gk then -- キーパーが退場: 最終ラインの選手がグローブをつける
		local repl = nil
		for _, q in list do
			if q.role == "CB" then
				repl = q
				break
			end
		end
		repl = repl or list[#list]
		if repl ~= nil then
			repl.gk = true
		end
	end
	if self.ctrl == p then
		self.ctrl = self:nextCursor() or list[#list]
	end
end

-- ================================================================ 前後半・延長・PK 戦
--- 区切り (前半終了 / 試合終了 / 延長前半終了 / 延長後半終了) に達した時。
function Match:onBoundary()
	local idx = self.bIndex
	self:event("whistle")
	if idx == 1 then
		self.bIndex = 2
		self:startBreak("popup.halftime", AWAY, true)
	elseif idx == 2 then
		if self.cup and self.score[HOME] == self.score[AWAY] then
			self.period = "extra"
			table.insert(self.boundaries, self.matchTime + EXTRA)
			table.insert(self.boundaries, self.matchTime + 2 * EXTRA)
			self.bIndex = 3
			self:startBreak("popup.extratime", HOME, false)
		else
			self:finish()
		end
	elseif idx == 3 then
		self.bIndex = 4
		self:startBreak("popup.halftime", AWAY, true)
	else
		if self.cup and self.score[HOME] == self.score[AWAY] then
			self:startShootout()
		else
			self:finish()
		end
	end
end

function Match:startBreak(key, kickTeam, flip)
	self.mode = "halftime"
	self.modeT = HALF_BREAK
	self.pending = { kick = kickTeam, flip = flip }
	self:popup(key, "info")
	self.setp = nil
	self.charge = nil
	if flip then
		for _, p in self.pl do
			p.stamina = math.min(STAMINA.Max, p.stamina + STAMINA.HalfTimeRecover)
			p.exhausted = false
		end
	end
end

function Match:endBreak()
	local pend = self.pending or { kick = HOME, flip = false }
	if pend.flip then
		self.flip = not self.flip
	end
	self.mode = "play"
	self.rec = {}
	self:kickoff(pend.kick)
	self:event("whistle")
end

function Match:finish()
	self.ended = true
	local total = math.max(self.poss[HOME] + self.poss[AWAY], 1e-6)
	local sh = self.shoot
	local winner = nil
	if self.score[HOME] > self.score[AWAY] then
		winner = HOME
	elseif self.score[AWAY] > self.score[HOME] then
		winner = AWAY
	elseif sh ~= nil then
		winner = sh.winner
	end
	self.result = {
		home = self.score[HOME],
		away = self.score[AWAY],
		winner = winner,
		passes = self.stats.passes,
		intercepted = self.stats.intercepted,
		offside = self.stats.offside,
		fouls = self.stats.fouls,
		skillBeat = self.skillStats.beat,
		skillTried = self.skillStats.tried,
		possession = math.floor(self.poss[HOME] / total * 100 + 0.5),
		stats = self.tstats,
		cup = self.cup,
		extra = self.period == "extra",
		shootout = sh ~= nil and { home = sh.goals[HOME], away = sh.goals[AWAY] } or nil,
		elapsed = self.elapsed,
		length = self.matchTime,
		difficulty = self.diffIndex,
		formation = self.formKeys[HOME],
	}
end

function Match:startShootout()
	self.mode = "shootout"
	self.flip = false
	self.shoot = {
		goals = { [HOME] = 0, [AWAY] = 0 },
		taken = { [HOME] = 0, [AWAY] = 0 },
		turn = HOME,
		awaiting = false,
		nextAt = self.elapsed + 1.5,
		kickT = nil,
		winner = nil,
	}
	self.setp = nil
	self.charge = nil
	self.ball.owner = nil
	self:popup("popup.shootout", "info")
end

function Match:shootNext()
	local sh = self.shoot
	local team = sh.turn
	local spot = { x = self:sgn(team) * (PL / 2 - PEN_SPOT), y = 0 }
	sh.awaiting = true
	sh.nextAt = nil
	sh.kickT = nil
	self:startSetpiece("pk", team, spot, "setp.pk")
end

function Match:updateShootout()
	local sh = self.shoot
	if sh == nil or self.ended then
		return
	end
	if sh.nextAt ~= nil and self.elapsed >= sh.nextAt then
		self:shootNext()
	end
	if sh.awaiting and self.setp == nil then
		sh.kickT = sh.kickT or self.elapsed
		if self.elapsed - sh.kickT > 5 then
			self:shootResult(false) -- 結果が出ない (止まった) は失敗扱い
		end
	end
end

--- 勝者が決まっていれば HOME / AWAY、まだなら nil。
function Match:shootWinner()
	local sh = self.shoot
	local g, t = sh.goals, sh.taken
	local R = Config.ShootoutRounds
	if t[HOME] < R or t[AWAY] < R then
		local remH, remA = R - t[HOME], R - t[AWAY]
		if g[HOME] > g[AWAY] + remA then
			return HOME
		elseif g[AWAY] > g[HOME] + remH then
			return AWAY
		end
		return nil
	end
	if t[HOME] == t[AWAY] and g[HOME] ~= g[AWAY] then
		return g[HOME] > g[AWAY] and HOME or AWAY
	end
	return nil
end

function Match:shootResult(scored)
	local sh = self.shoot
	if sh == nil or not sh.awaiting then
		return
	end
	sh.awaiting = false
	local team = sh.turn
	sh.taken[team] += 1
	if scored then
		sh.goals[team] += 1
		self:popup(self:human(team) and "popup.goal" or "popup.concede", self:human(team) and "good" or "bad")
		self:event("goal")
	else
		self:popup("popup.miss", "info")
	end
	sh.turn = 1 - team
	local winner = self:shootWinner()
	if winner ~= nil then
		sh.winner = winner
		self:finish()
		return
	end
	sh.nextAt = self.elapsed + 1.8
end

-- ================================================================ ゴールリプレイ
function Match:record(dt)
	self.recT += dt
	if self.recT < REPLAY.Step then
		return
	end
	self.recT -= REPLAY.Step
	local b = self.ball
	local f = { pl = {}, bx = b.p.x, by = b.p.y, bz = b.z }
	for i, p in self.pl do
		f.pl[i] = { p.p.x, p.p.y, p.face.x, p.face.y }
	end
	table.insert(self.rec, f)
	if #self.rec > REPLAY.Seconds / REPLAY.Step then
		table.remove(self.rec, 1)
	end
end

function Match:startReplay(kickTeam)
	if #self.rec < 10 then
		self:kickoff(kickTeam)
		return
	end
	self.mode = "replay"
	self.replay = { frames = self.rec, pos = 1, kick = kickTeam }
	self.rec = {}
	self.setp = nil
	self.charge = nil
end

function Match:updateReplay(dt)
	local r = self.replay
	if r == nil then
		self:endReplay()
		return
	end
	r.pos += dt * REPLAY.Speed / REPLAY.Step
	local i = math.floor(r.pos)
	if i >= #r.frames then
		self:endReplay()
		return
	end
	local f = r.frames[i]
	for k, p in self.pl do
		local d = f.pl[k]
		p.p = { x = d[1], y = d[2] }
		p.face = { x = d[3], y = d[4] }
	end
	local b = self.ball
	b.p = { x = f.bx, y = f.by }
	b.z = f.bz
	b.owner = nil
end

function Match:endReplay()
	local r = self.replay
	self.mode = "play"
	self.replay = nil
	self:kickoff(r and r.kick or HOME)
	self:event("whistle")
end

function Match:pruneOld()
	local keep = {}
	for _, x in self.popups do
		if self.elapsed - x.t < 1.3 then
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

function Match:slideContact(p)
	local b = self.ball
	if b.owner == nil or b.owner.team == p.team then
		if b.owner == nil and vdist(b.p, p.p) < 1.2 and b.z < 0.5 then
			b.v = vmul(p.face, 6)
			b.last = p
		end
		return
	end
	local o = b.owner
	if vdist(b.p, p.p) < 1.0 then -- 先にボールに触れた: クリーン
		b.owner = nil
		b.v = vadd(vmul(p.face, 7), vmul(o.v, 0.3))
		b.last = p
		p.slide = 0
		if self:human(p.team) then
			self:popup("popup.nicetackle", "good")
		end
	elseif vdist(o.p, p.p) < 1.2 then -- 先に足に当たった: ファウル
		p.slide = 0
		o.stun = 0.8
		self:foul(p, o)
	end
end

--- severity: 1 = 悪質 (スライディング) / 小さいほど軽い接触。カードの出やすさに掛かる。
function Match:foul(fouler, victim, severity)
	self.stats.fouls += 1
	self.tstats[fouler.team].fouls += 1
	self:event("whistle")
	self:cardCheck(fouler, severity or 1)
	local team = victim.team
	local s = self:sgn(team)
	local inBox = s * victim.p.x > PL / 2 - BOX_L and math.abs(victim.p.y) < BOX_W / 2
	if inBox then
		self:startSetpiece("pk", team, { x = s * (PL / 2 - PEN_SPOT), y = 0 }, "popup.foul_pk")
	else
		self:startSetpiece("fk", team, victim.p, "popup.foul_fk")
	end
end

function Match:updateBall(dt)
	local b = self.ball
	if b.owner ~= nil then
		local o = b.owner
		if o.skill ~= nil then
			local u = math.min(1.0, (self.elapsed - o.skill.t0) / o.skill.dur)
			local rel = self:skillMotion(o, u)
			b.p = vadd(o.p, rel)
		else
			b.p = vadd(o.p, vmul(o.face, P_R + 0.35))
		end
		b.v = { x = o.v.x, y = o.v.y }
		b.z = 0
		return
	end
	if b.z > 0 or b.vz > 0 then
		b.vz -= GRAV * dt
		b.z += b.vz * dt
		if b.z <= 0 then
			b.z = 0
			b.vz = math.abs(b.vz) > 2.5 and -b.vz * 0.35 or 0
			b.v = vmul(b.v, 0.75)
		end
	else
		local sp = vlen(b.v)
		if sp > 0 then
			b.v = vmul(b.v, math.max(0.0, sp - FRICTION * dt) / sp)
		end
	end
	b.p = vadd(b.p, vmul(b.v, dt))
	-- PK 戦: ゴールかどうかだけ判定して止める (通常のセットプレーには移らない)
	if self.mode == "shootout" and (math.abs(b.p.x) >= PL / 2 or math.abs(b.p.y) >= PW / 2) then
		local scored = math.abs(b.p.x) >= PL / 2 and math.abs(b.p.y) < GOAL_W / 2 and b.z < GOAL_H
		b.v = { x = 0, y = 0 }
		b.vz = 0
		b.p.x = clamp(b.p.x, -PL / 2, PL / 2)
		b.p.y = clamp(b.p.y, -PW / 2, PW / 2)
		self:shootResult(scored)
		return
	end
	-- ゴール・ゴールライン
	if math.abs(b.p.x) >= PL / 2 then
		local side = b.p.x > 0 and 1 or -1
		local att = (side == self:sgn(HOME)) and HOME or AWAY -- そのゴールを攻めているチーム
		if math.abs(b.p.y) < GOAL_W / 2 and b.z < GOAL_H then
			self.score[att] += 1
			if self:human(att) then
				self:popup("popup.goal", "good")
			else
				self:popup("popup.concede", "bad")
			end
			self:event("goal")
			self:startReplay(1 - att)
			return
		end
		local lastTeam = b.last ~= nil and b.last.team or att
		if lastTeam == att then
			self:startSetpiece("gk", 1 - att, { x = side * (PL / 2 - SIX_L), y = self:choice({ -1, 1 }) * 4 }, "setp.gk")
		else
			self:startSetpiece(
				"corner",
				att,
				{ x = side * (PL / 2 - 0.5), y = sgnOf(b.p.y) * (PW / 2 - 0.5) },
				"setp.corner"
			)
		end
		return
	end
	if math.abs(b.p.y) >= PW / 2 then
		local lastTeam = b.last ~= nil and b.last.team or HOME
		self:startSetpiece(
			"throw",
			1 - lastTeam,
			{ x = clamp(b.p.x, -PL / 2 + 1, PL / 2 - 1), y = sgnOf(b.p.y) * (PW / 2 - 0.3) },
			"setp.throw"
		)
		return
	end
	self:tryReceive()
end

function Match:tryReceive()
	local b = self.ball
	local sp = vlen(b.v)
	local order = table.clone(self.pl)
	table.sort(order, function(a, c)
		return vdist(a.p, b.p) < vdist(c.p, b.p)
	end)
	for _, p in order do
		local d = vdist(p.p, b.p)
		if d > 3 then
			break
		end
		local skip = (p == b.kicker and self.elapsed - b.kickT < 0.3) or p.stun > 0 or p.slide > 0
		if not skip then
			local mine = b.kicker ~= nil and p.team == b.kicker.team
			local reach = CONTROL_R
			local hmax = 1.9 -- 頭で触れる高さ
			if p.gk and math.abs(p.p.x) > PL / 2 - BOX_L then
				reach, hmax = 1.7, 2.6
				if p.dive ~= nil then
					reach = 2.2 -- ダイブ中は届く範囲が広い
				end
			end
			if b.z <= hmax and d < reach and (sp < 24 or not mine or p.gk) then
				-- オフサイド: キックの瞬間にオフサイド位置だった味方が受けた
				if mine and b.offside == p then
					if p.team == HOME then
						self.stats.offside += 1
					end
					self:startSetpiece("fk", 1 - p.team, p.p, "popup.offside")
					return
				end
				-- CPU のヘディング: 空中のボールを頭で合わせる
				if
					mine
					and b.z >= HEADER.MinZ
					and not p.gk
					and (b.kind == "lofted" or b.kind == "lthrough")
					and not (self:human(p.team) and p == self.ctrl)
					and vdist(self:oppGoal(p.team), p.p) < HEADER.ShotRange
					and self:rand() < HEADER.CpuChance
				then
					self:kick("shot", {
						c = p,
						power = 0.6,
						style = "header",
						aimY = self:uniform(-GOAL_W / 2 + 0.6, GOAL_W / 2 - 0.6),
					})
					return
				end
				if mine and b.kicker ~= nil and b.kicker ~= p and b.kind ~= "shot" and b.kind ~= "clear" then
					self.tstats[p.team].passOk += 1
				end
				if not mine and b.kicker ~= nil and b.kicker.team == HOME and b.kind ~= "shot" then
					self.stats.intercepted += 1
					self:popup("popup.cut", "bad")
				end
				if p.gk and not mine and b.kind == "shot" and sp > 14 and self:rand() < 0.3 and self.mode ~= "shootout" then
					-- 強いシュートは弾く (こぼれ球・コーナーになる)
					self.tstats[p.team].saves += 1
					self:popup(p.team == AWAY and "popup.save" or "popup.nicesave", "info")
					self:event("save")
					local gsign = sgnOf(p.p.x)
					b.v = { x = gsign * 5, y = (self:rand() < 0.5 and -1 or 1) * 8 } -- ゴールライン側へ弾く (コーナーになりやすい)
					b.z, b.vz = 0.6, 2
					b.last, b.kicker, b.kickT = p, p, self.elapsed
					b.target, b.offside = nil, nil
					b.kind = "clear"
					p.dive = nil
					return
				end
				if p.gk and not mine and b.kind == "shot" then
					self.tstats[p.team].saves += 1
					self:popup(p.team == AWAY and "popup.save" or "popup.nicesave", "info")
					self:event("save")
					if self.mode == "shootout" then
						self:shootResult(false)
					end
				end
				p.dive = nil
				b.owner = p
				b.last = p
				b.v = { x = 0, y = 0 }
				b.z, b.vz = 0, 0
				b.target, b.offside = nil, nil
				if self.mode == "shootout" then
					self:shootResult(false)
				end
				if self:human(p.team) then
					self.ctrl = p
				end
				return
			end
		end
	end
end

return Match
