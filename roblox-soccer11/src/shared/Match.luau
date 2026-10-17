--!nonstrict
--[[
	Match — 11人制サッカーの試合シミュレーション。Roblox の API を一切使わない純粋なロジック。
	(Studio 無しで luau CLI で検証できる。tests/ 参照。サーバーでもクライアントでも同じものが動く)

	座標は x = 攻撃方向 (前半は HOME が +x へ攻める), y = 横方向。単位は m。
	team: HOME = 0, AWAY = 1。

	■ 操作者 (シート)
	人間の操作者はシート (id, team) として参加する。1 チームに複数人 (協力) も、両チームに人 (対戦) もよい。
	各シートは 1 人の選手を操作し、それ以外の選手は AI が動かす。入力の無い操作中の選手も AI が補助する。

	入力 (eFootball の操作体系に合わせた論理ボタン):
	  setMove(id, x, y)     左スティック (アナログ。長さ 1 まで)
	  setAim(id, x, y)      狙いの方向 (マウス等。nil なら左スティックの向き)
	  press / release(id, b) b = "pass" (×) | "through" (△) | "lofted" (○) | "shoot" (□) |
	                         "dash" (R2) | "l1" | "r1" | "l2"
	  flick(id, x, y)       右スティックを弾く (フェイント / 方向指定のカーソル切替 / FK のカーブ)
	  command(id, c)        "pause" | "levelUp" | "levelDown" | "skip"

	攻撃: パス・スルー・浮き球・シュートは長押しでパワーを溜め、離して蹴る。向きは狙い (アナログ 360°)。
	      L1 + パス = ワンツー / L1 + スルー = ループスルー / L1 + シュート = ループシュート /
	      R1 + シュート = コントロールシュート / R1 + パス = パス&ゴー / R2 を押しながら蹴る = 強いキック
	守備: パス長押し = プレッシャー / L2 = マッチアップ / R1 = 2 人目のプレスを呼ぶ / シュート = ショルダーチャージ・クリア /
	      浮き球 = スライディング / スルー長押し = GK 飛び出し / L1 = カーソル切替 / 右スティック = 方向指定の切替

	元は eFootball の操作体系を参考にした視線操作ゲームの一部 (視線に依存する処理は取り除いてある)。
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
local CTRL = Config.Controls

local HOME, AWAY = 0, 1
local KICKS = { pass = true, through = true, lofted = true, shoot = true }

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
local function vrot(a, ang)
	local c, s = math.cos(ang), math.sin(ang)
	return { x = a.x * c - a.y * s, y = a.x * s + a.y * c }
end
local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end
local function lerp(a, b, t)
	return a + (b - a) * t
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
		out = false, -- 退場
		yellow = 0,
		stamina = STAMINA.Max,
		exhausted = false,
		attr = { speed = 1, shoot = 1, pass = 1, tackle = 1, stamina = 1 },
		dive = nil, -- GK のダイブ
		seat = nil, -- 操作しているシート (nil なら AI)
		run = nil, -- パス&ゴー等の走り込み { to, untilT }
	}
end

local function newSeat(id, team)
	return {
		id = id,
		team = team,
		ctrl = nil,
		move = { x = 0, y = 0 },
		aim = nil,
		aimPoint = nil, -- 狙う地点 (マウスが指すピッチ上の点)
		buttons = {}, -- 押している論理ボタン
		charge = nil, -- { btn, t0, mods, firstTime }
		queued = nil, -- ダイレクトで蹴る予約 { btn, power, mods, untilT }
		rsBuf = {}, -- 右スティックの入力列 { t, d }
		lastInputT = -99,
		switchT = -99,
		shieldUntil = -1,
		gkRush = false,
	}
end

--[[
	opts:
	  random: () -> [0, 1)
	  seats: { { id, team }, ... }   人間の操作者。省略時は ctrlKind に従う (互換)
	  ctrlKind: { [0] = "human" | "cpu", [1] = ... }
	  formation: { [0] = "433", [1] = "442" }
	  difficulty: 1..5 (CPU のチームにだけ掛かる)
	  length: 試合時間 [s]
	  cup: true なら同点で延長 → PK 戦
	  tactics: { [0] = { line, press }, [1] = ... } または HOME だけの { line, press } (互換)
	  assist: パスの補助 0 (マニュアル) / 1 (標準) / 2 (フル)
]]
function Match.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Match)
	self.random = opts.random or math.random
	self.assist = opts.assist or CTRL.DefaultAssist
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
	if tac.line ~= nil or tac.press ~= nil then
		tac = { [HOME] = tac }
	end
	self.tactics = {
		[HOME] = { line = (tac[HOME] and tac[HOME].line) or 2, press = (tac[HOME] and tac[HOME].press) or 2 },
		[AWAY] = { line = (tac[AWAY] and tac[AWAY].line) or 2, press = (tac[AWAY] and tac[AWAY].press) or 2 },
	}
	self.level = { [HOME] = 0, [AWAY] = 0 } -- 攻守レベル (-2..2)
	self.pl = {}
	self.teams = { [HOME] = {}, [AWAY] = {} }
	for t = HOME, AWAY do
		for i = 0, 10 do
			local p = newPlayer(t, i, self.forms[t])
			local base = ATTRS[p.role] or ATTRS.CM
			for k, v in base do
				p.attr[k] = v * (1 + (self.random() * 2 - 1) * Config.AttributeSpread)
			end
			table.insert(self.pl, p)
			self.teams[t][i + 1] = p
		end
	end
	self.act = { [HOME] = self.teams[HOME], [AWAY] = self.teams[AWAY] }

	-- 操作者
	self.seats = {}
	self.seatById = {}
	local seats = opts.seats
	if seats == nil then
		seats = {}
		local kinds = opts.ctrlKind or { [HOME] = "human", [AWAY] = "cpu" }
		local id = 1
		for t = HOME, AWAY do
			if kinds[t] == "human" then
				table.insert(seats, { id = id, team = t })
				id += 1
			end
		end
	end
	for _, s in seats do
		self:addSeat(s.id, s.team)
	end

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
		curl = 0, -- 横回転 (FK のカーブ)
		curlUntil = -1,
	}
	self.score = { [HOME] = 0, [AWAY] = 0 }
	self.elapsed = 0
	self.paused = false
	self.ended = false
	self.result = nil
	self.setp = nil -- セットプレー: nil か { kind, team, t0, taker }
	self.seq = 0 -- ポップアップ・技名の通し番号 (オンラインの差分送信用)
	self.popups = {} -- { t, key, team, seq }: 画面中央に出す一言 (team はその出来事で得をしたチーム)
	self.labels = {} -- { t, key, player }: 選手の頭上に出す技名
	self.events = {} -- 効果音用 { kind }
	self.skillStats = { tried = 0, beat = 0 }
	self.presser = { [HOME] = nil, [AWAY] = nil }
	self.chase = {}
	self.flip = false
	self.mode = "play" -- play | halftime | replay | shootout
	self.modeT = 0
	self.boundaries = { self.matchTime / 2, self.matchTime }
	self.bIndex = 1
	self.period = "regular"
	self.poss = { [HOME] = 0, [AWAY] = 0 }
	self.tstats = {}
	for t = HOME, AWAY do
		self.tstats[t] = {
			shots = 0,
			onTarget = 0,
			passes = 0,
			passOk = 0,
			intercepted = 0,
			offside = 0,
			corners = 0,
			fouls = 0,
			yellow = 0,
			red = 0,
			saves = 0,
		}
	end
	self.rec = {}
	self.recT = 0
	self.replay = nil
	self.shoot = nil
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

function Match:oppGoal(team)
	return { x = self:sgn(team) * PL / 2, y = 0 }
end

--- そのチームに人間の操作者がいるか。
function Match:human(team)
	for _, s in self.seats do
		if s.team == team then
			return true
		end
	end
	return false
end

--- CPU 難易度を掛けるチームか (人間がいないチーム)。
function Match:isCpuTeam(team)
	return not self:human(team)
end

function Match:popup(key, team)
	self.seq += 1
	table.insert(self.popups, { t = self.elapsed, key = key, team = team, seq = self.seq })
end

--- 効果音・動作のイベント。player = 動作した選手、tag = 動作の種類 (キックなら pass / shot / ...)
function Match:event(kind, player, tag)
	table.insert(self.events, { kind = kind, player = player, tag = tag })
end

-- ================================================================ 操作者 (シート)
function Match:addSeat(id, team)
	local s = newSeat(id, team)
	table.insert(self.seats, s)
	self.seatById[id] = s
	if self.ball ~= nil then
		self:assign(s, self:freeNearest(team, self.ball.p, nil))
	end
	return s
end

--- 操作者が抜けた (切断など)。その選手は AI に戻る。
function Match:removeSeat(id)
	local s = self.seatById[id]
	if s == nil then
		return
	end
	if s.ctrl ~= nil then
		s.ctrl.seat = nil
	end
	self.seatById[id] = nil
	for i, x in self.seats do
		if x == s then
			table.remove(self.seats, i)
			break
		end
	end
end

function Match:seat(id)
	return self.seatById[id]
end

--- 互換: 最初の操作者が操作している選手。
function Match:primaryCtrl()
	local s = self.seats[1]
	return s and s.ctrl
end

--- シート s に選手 p を割り当てる (p が他のシートのものなら何もしない)。
function Match:assign(s, p)
	if p == nil or (p.seat ~= nil and p.seat ~= s) then
		return
	end
	if s.ctrl ~= nil and s.ctrl ~= p then
		s.ctrl.seat = nil
	end
	s.ctrl = p
	p.seat = s
	s.switchT = self.elapsed
	if s == self.seats[1] then
		self.ctrl = p
	end
end

--- まだ誰も操作していない選手のうち、pos に最も近い者。
function Match:freeNearest(team, pos, exclude)
	local best, bd = nil, math.huge
	for _, p in self:active(team) do
		if p.seat == nil and p ~= exclude and not p.gk then
			local d = vdist(p.p, pos)
			if d < bd then
				best, bd = p, d
			end
		end
	end
	return best
end

--- 操作者に最近の入力があるか (無ければ AI が補助する)。
function Match:seatActive(s)
	if s == nil then
		return false
	end
	if s.charge ~= nil or next(s.buttons) ~= nil then
		return true
	end
	if vlen(s.move) > CTRL.DeadZone then
		return true
	end
	return self.elapsed - s.lastInputT < CTRL.AutopilotDelay
end

--- 狙いの方向 (マウス等の狙い → 左スティック → 選手の向き)。
function Match:aimOf(s)
	if s.aimPoint ~= nil and s.ctrl ~= nil then
		local d = vsub(s.aimPoint, s.ctrl.p)
		if vlen(d) > 0.5 then
			return vnorm(d)
		end
	end
	if s.aim ~= nil and vlen(s.aim) > 0.1 then
		return vnorm(s.aim)
	end
	if vlen(s.move) > CTRL.DeadZone then
		return vnorm(s.move)
	end
	local p = s.ctrl
	return p and { x = p.face.x, y = p.face.y } or { x = 1, y = 0 }
end

--- 溜め中のパワー (0..1)。
function Match:chargePower(s)
	if s == nil or s.charge == nil then
		return nil
	end
	return clamp((self.elapsed - s.charge.t0) / CTRL.GaugeTime, 0, 1)
end

function Match:setMove(id, x, y)
	local s = self.seatById[id]
	if s == nil then
		return
	end
	local v = { x = x or 0, y = y or 0 }
	local n = vlen(v)
	if n > 1 then
		v = vmul(v, 1 / n)
	end
	s.move = v
	if n > CTRL.DeadZone then
		s.lastInputT = self.elapsed
	end
end

--- 狙う地点 (マウス)。nil で解除。パスは指した味方へ、空いたスペースならその地点へ蹴る。
function Match:setAimPoint(id, x, y)
	local s = self.seatById[id]
	if s == nil then
		return
	end
	if x == nil then
		s.aimPoint = nil
	else
		s.aimPoint = { x = clamp(x, -PL / 2 - 5, PL / 2 + 5), y = clamp(y, -PW / 2 - 5, PW / 2 + 5) }
	end
end

function Match:setAim(id, x, y)
	local s = self.seatById[id]
	if s == nil then
		return
	end
	if x == nil then
		s.aim = nil
	else
		s.aim = { x = x, y = y }
	end
end

function Match:command(id, cmd)
	local s = self.seatById[id]
	if cmd == "pause" then
		self.paused = not self.paused
		return
	end
	if s == nil then
		return
	end
	if cmd == "levelUp" or cmd == "levelDown" then
		local t = s.team
		self.level[t] = clamp(self.level[t] + (cmd == "levelUp" and 1 or -1), -2, 2)
		self:popup(cmd == "levelUp" and "popup.levelup" or "popup.leveldown", t)
	elseif cmd == "skip" then
		if self.mode == "replay" then
			self:endReplay()
		end
	end
end

--- 攻撃中か (自分の操作選手がボールを持っている)。
function Match:attacking(s)
	return s.ctrl ~= nil and self.ball.owner == s.ctrl
end

--- ボールが自分の操作選手へ向かっている (ダイレクトで蹴れる)。
function Match:incoming(s)
	local b, p = self.ball, s.ctrl
	if p == nil or b.owner ~= nil then
		return false
	end
	if b.target == p then
		return true
	end
	local d = vdist(b.p, p.p)
	if d > 6 then
		return false
	end
	local spd = vlen(b.v)
	return spd < 1 or vdot(vnorm(b.v), vnorm(vsub(p.p, b.p))) > 0.5
end

function Match:press(id, btn)
	local s = self.seatById[id]
	if s == nil or self.ended then
		return
	end
	s.lastInputT = self.elapsed
	s.buttons[btn] = true
	if self.paused then
		return
	end
	if self.mode == "replay" then
		if KICKS[btn] then
			self:endReplay()
		end
		return
	end
	if self.mode == "halftime" then
		return
	end
	local p = s.ctrl
	if p == nil then
		return
	end
	local b = self.ball
	local sp = self.setp
	-- セットプレー: 蹴る人だけが溜めて蹴る
	if sp ~= nil then
		if sp.team == s.team and sp.taker == p and KICKS[btn] then
			if sp.kind == "pk" then
				if btn == "shoot" then
					self:takeSetpiece(s, "shoot", CTRL.PenaltyPower, {})
				end
			elseif not (btn == "shoot" and sp.kind ~= "fk") then
				s.charge = { btn = btn, t0 = self.elapsed, mods = self:mods(s) }
			end
		end
		return
	end
	-- 攻撃 (自分がボールを持っている)
	if self:attacking(s) then
		if KICKS[btn] then
			s.charge = { btn = btn, t0 = self.elapsed, mods = self:mods(s) }
		end
		return
	end
	-- 空中のボールにヘディング / ボレー
	if KICKS[btn] and (btn == "shoot" or btn == "pass" or btn == "through") and self:tryHeader(s, btn) then
		return
	end
	-- ダイレクト (受ける前に溜め始める)
	if KICKS[btn] and self:incoming(s) and (b.owner == nil) then
		s.charge = { btn = btn, t0 = self.elapsed, mods = self:mods(s), firstTime = true }
		return
	end
	-- 守備
	local opp = b.owner ~= nil and b.owner.team ~= s.team
	if btn == "lofted" then
		if opp or b.owner == nil then
			self:startSlide(p)
		end
	elseif btn == "shoot" then
		self:shoulderOrClear(p)
	elseif btn == "l1" then
		local nxt = s.aimPoint ~= nil and self:nearestFree(s, s.aimPoint) or self:nextCursor(s)
		if nxt ~= nil then
			self:assign(s, nxt)
		end
	elseif btn == "through" then
		s.gkRush = true
	end
end

function Match:release(id, btn)
	local s = self.seatById[id]
	if s == nil then
		return
	end
	s.buttons[btn] = nil
	if btn == "through" then
		s.gkRush = false
	end
	local ch = s.charge
	if ch == nil or ch.btn ~= btn or self.ended then
		return
	end
	s.charge = nil
	if ch.curl == nil and self.setp ~= nil and vlen(s.move) > CTRL.DeadZone then
		-- セットプレーの溜め中に横へ入力していたらカーブ (狙いに対して左右)
		local aim = self:aimOf(s)
		local side = vdot(s.move, { x = -aim.y, y = aim.x })
		if math.abs(side) > 0.4 then
			ch.curl = sgnOf(side)
		end
	end
	ch.mods.curl = ch.curl
	local power = clamp((self.elapsed - ch.t0) / CTRL.GaugeTime, 0, 1)
	local p = s.ctrl
	if self.setp ~= nil then
		if self.setp.taker == p then
			self:takeSetpiece(s, btn, power, ch.mods)
		end
		return
	end
	if p ~= nil and self.ball.owner == p then
		self:doKick(s, btn, power, ch.mods)
	elseif ch.firstTime then
		s.queued = { btn = btn, power = power, mods = ch.mods, untilT = self.elapsed + 1.5 }
	end
end

--- 右スティックを弾いた。
function Match:flick(id, x, y)
	local s = self.seatById[id]
	if s == nil or s.ctrl == nil or self.ended then
		return
	end
	s.lastInputT = self.elapsed
	local d = vnorm({ x = x, y = y })
	if self.mode ~= "play" and self.mode ~= "shootout" then
		return
	end
	if s.charge ~= nil then
		s.charge.curl = sgnOf(vdot(d, { x = -self:aimOf(s).y, y = self:aimOf(s).x })) -- 溜め中: カーブの向き
		return
	end
	if self:attacking(s) then
		local last = s.rsBuf[#s.rsBuf]
		if not (last and vdot(last.d, d) > 0.9 and self.elapsed - last.t < 0.15) then
			table.insert(s.rsBuf, { t = self.elapsed, d = d })
		end
	else
		self:manualCursor(s, d)
	end
end

function Match:mods(s)
	return {
		l1 = s.buttons.l1 == true,
		r1 = s.buttons.r1 == true,
		stun = s.buttons.dash == true,
	}
end

-- ================================================================ 技 (スキルムーブ)
--- 右スティックの入力列を、進行方向に対する相対方向 (F/B/S/X) に直してコマンド表と照合する。
function Match:matchSkill(s)
	local p = s.ctrl
	local f = (vlen(p.v) < 0.5) and p.face or vnorm(p.v)
	local n = { x = -f.y, y = f.x }
	local seq, firstSide = {}, nil
	local start = math.max(1, #s.rsBuf - 2)
	for k = start, #s.rsBuf do
		local d = s.rsBuf[k].d
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
				local lastSide = nil
				for k = #s.rsBuf, 1, -1 do
					local d = s.rsBuf[k].d
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
					lastSide = (opp ~= nil and vdot(vsub(opp.p, p.p), n) > 0) and -1 or 1
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
	if p.seat ~= nil then
		self.skillStats.tried += 1
	end
	self.seq += 1
	table.insert(self.labels, { t = self.elapsed, key = "skill." .. name, player = p, seq = self.seq })
end

--- 技の途中 (u: 0..1) の、ボールの位置 (選手からの相対) と選手の速度。
function Match:skillMotion(p, u)
	local sk = p.skill
	local f, n, name = sk.f, sk.n, sk.name
	local r = P_R + 0.35
	local ball, vel
	if name == "double_touch" then
		local a = 1.3 * math.min(1.0, u / 0.45)
		local c = 0.9 * math.max(0.0, u - 0.45) / 0.55
		ball = { x = f.x * (r + c) + n.x * a, y = f.y * (r + c) + n.y * a }
		if u < 0.45 then
			vel = vmul(n, 3.5)
		else
			vel = vmul(vnorm({ x = f.x * 0.8 + n.x * 0.6, y = f.y * 0.8 + n.y * 0.6 }), DASH * 0.85)
		end
	elseif name == "elastico" then
		local fake = -0.6 * math.sin(math.pi * math.min(1.0, u / 0.35))
		local cut = 1.4 * math.max(0.0, u - 0.35) / 0.65
		ball = { x = f.x * r + n.x * (fake + cut), y = f.y * r + n.y * (fake + cut) }
		if u < 0.35 then
			vel = vmul(n, -1.0)
		else
			vel = vmul(vnorm({ x = f.x * 0.5 + n.x * 0.85, y = f.y * 0.5 + n.y * 0.85 }), DASH * 0.8)
		end
	elseif name == "scissors" then
		local sd = 1.0 * math.max(0.0, u - 0.6) / 0.4
		ball = { x = f.x * r + n.x * sd, y = f.y * r + n.y * sd }
		if u < 0.6 then
			vel = vmul(n, -2.0 * math.sin(math.pi * math.min(1.0, u / 0.6)))
		else
			vel = vmul(vnorm({ x = f.x * 0.6 + n.x * 0.8, y = f.y * 0.6 + n.y * 0.8 }), DASH * 0.8)
		end
	elseif name == "marseille" then
		local ang = 2 * math.pi * u
		local c, sn = math.cos(ang), math.sin(ang)
		ball = { x = (f.x * c + n.x * sn) * r, y = (f.y * c + n.y * sn) * r }
		vel = { x = n.x * 2.5 + f.x * 1.5 * u, y = n.y * 2.5 + f.y * 1.5 * u }
	else -- drag_back
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

--- 技の決め所: 近くの守備者がつられたか。
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
			local rush = vdot(q.v, vnorm(vmul(d, -1)))
			if rush > 3 then
				prob += 0.15
			elseif vlen(q.v) < 1 and vdot(vnorm(d), f) > 0.7 then
				prob -= 0.1
			end
			if q.seat ~= nil and q.seat.buttons.l2 then
				prob -= 0.15 -- マッチアップで構えている人間は引っかかりにくい
			end
			if self:rand() < prob then
				q.stun = math.max(q.stun, 0.7)
				beatAny = true
			else
				read = true
				if self:rand() < 0.5 and self.ball.owner == p then
					p.skill = nil
					self:gainBall(q)
					q.cd = 0.6
					self:popup("popup.steal", q.team)
					return
				end
			end
		end
	end
	if beatAny then
		if p.seat ~= nil then
			self.skillStats.beat += 1
		end
		self:popup("popup.beat", p.team)
	elseif read then
		self:popup("popup.read", 1 - p.team)
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

-- ================================================================ キック (人間)
local PASS_RANGE = {
	pass = { 4, 40 },
	through = { 8, 45 },
	lofted = { 10, 65 },
}

--- 狙い dir とパワーから受け手を選ぶ (補助の強さで角度の許容が変わる)。
function Match:chooseReceiver(p, kind, dir, power)
	local cone = CTRL.AssistCone[self.assist + 1] or 0
	if cone <= 0 then
		return nil
	end
	local range = PASS_RANGE[kind] or PASS_RANGE.pass
	local desired = lerp(range[1], range[2], power)
	local best, bs = nil, math.huge
	for _, m in self:active(p.team) do
		if m ~= p then
			local fut = vadd(m.p, vmul(m.v, 0.5))
			local v = vsub(fut, p.p)
			local dist = vlen(v)
			if dist >= 3 then
				local ang = math.deg(math.acos(clamp(vdot(vnorm(v), dir), -1, 1)))
				if ang <= cone then
					local sc = ang + math.abs(dist - desired) * 0.35 + (m.gk and 25 or 0)
					if sc < bs then
						best, bs = m, sc
					end
				end
			end
		end
	end
	return best
end

--- 指した地点に一番近い、操作されていない味方 (GK 以外)。
function Match:nearestFree(s, pt)
	local best, bd = nil, math.huge
	for _, m in self:active(s.team) do
		if m ~= s.ctrl and m.seat == nil and not m.gk then
			local d = vdist(m.p, pt)
			if d < bd then
				best, bd = m, d
			end
		end
	end
	return best
end

--[[
	パスの受け手と行き先を決める。
	  狙う地点 (マウス) がある: 地点の近くの味方へ。空いたスペースなら地点へ蹴る
	    (スルーなら、一番近い味方がそこへ走り込む受け手になる)
	  無い: 狙いの向き + パワーで受け手を探す (eFootball のスティック操作)
	戻り値: recv (受け手 or nil), dest (地点へ直接蹴る時の行き先 or nil)
]]
function Match:selectTarget(s, btn, power)
	local p = s.ctrl
	local base = btn == "lofted" and "lofted" or btn
	local pt = s.aimPoint
	if pt ~= nil then
		if self.assist > 0 then
			local best, bd = nil, CTRL.PointSnap
			for _, m in self:active(p.team) do
				if m ~= p then
					local d = vdist(vadd(m.p, vmul(m.v, 0.4)), pt)
					if d < bd then
						best, bd = m, d
					end
				end
			end
			if best ~= nil then
				return best, nil
			end
		end
		local runner = nil
		if base == "through" then
			local rd = CTRL.ThroughReach
			for _, m in self:active(p.team) do
				if m ~= p and not m.gk then
					local d = vdist(m.p, pt)
					if d < rd then
						runner, rd = m, d
					end
				end
			end
		end
		return runner, { x = pt.x, y = pt.y }
	end
	return self:chooseReceiver(p, base, self:aimOf(s), power), nil
end

--- パスのプレビュー (溜め中の受け手)。HUD の表示用。
function Match:previewReceiver(s)
	if s == nil or s.charge == nil or s.ctrl == nil then
		return nil
	end
	local kind = s.charge.btn
	if kind == "shoot" then
		return nil
	end
	local recv = self:selectTarget(s, kind, self:chargePower(s) or 0)
	return recv
end

--- 人間のキック。btn: pass / through / lofted / shoot。power 0..1。
function Match:doKick(s, btn, power, mods)
	local p = s.ctrl
	if p == nil then
		return
	end
	local dir = self:aimOf(s)
	mods = mods or {}
	if btn == "shoot" then
		local style = ""
		if mods.l1 then
			style = "loop"
		elseif mods.r1 then
			style = "control"
		elseif mods.stun then
			style = "impact"
		end
		local g = self:oppGoal(p.team)
		local aimY
		if (g.x - p.p.x) * dir.x > 0 and math.abs(dir.x) > 0.15 then
			aimY = p.p.y + dir.y / dir.x * (g.x - p.p.x)
		else
			aimY = dir.y * GOAL_W / 2
		end
		aimY = clamp(aimY, -GOAL_W / 2 - 2.5, GOAL_W / 2 + 2.5)
		self:kick("shot", { c = p, power = power, aimY = aimY, style = style, curl = mods.curl })
		return
	end
	local kind = btn == "lofted" and "lofted" or btn
	if btn == "through" and mods.l1 then
		kind = "lthrough"
	end
	local recv, dest = self:selectTarget(s, btn, power)
	self:kick(kind, {
		c = p,
		dir = dir,
		power = power,
		target = recv,
		dest = dest,
		stun = mods.stun,
		manual = recv == nil,
		curl = mods.curl,
	})
	-- 蹴った瞬間に、操作を受け手へ移す (eFootball と同じ)
	if recv ~= nil and recv.seat == nil then
		self:assign(s, recv)
	end
	-- ワンツー / パス&ゴー: 出し手が前へ走り込む
	if (btn == "pass" and (mods.l1 or mods.r1)) or (btn == "through" and mods.r1) then
		local fwd = { x = self:sgn(p.team), y = 0 }
		local to = vadd(p.p, vadd(vmul(fwd, 14), vmul(dir, 4)))
		to.x = clamp(to.x, -PL / 2 + 2, PL / 2 - 2)
		to.y = clamp(to.y, -PW / 2 + 2, PW / 2 - 2)
		p.run = { to = to, untilT = self.elapsed + 3.0, oneTwo = mods.l1 and btn == "pass" }
	end
end

-- ================================================================ キック (共通)
function Match:secondLastX(team)
	local s = self:sgn(team)
	local xs = {}
	for _, q in self:active(1 - team) do
		table.insert(xs, s * q.p.x)
	end
	table.sort(xs, function(a, b)
		return a > b
	end)
	return xs[2] or 0
end

--- CPU のパスの受け手 (向き d に近い味方)。
function Match:pickReceiver(c, d)
	local best, bs = nil, -1e9
	for _, p in self:active(c.team) do
		if p ~= c then
			local v = vsub(p.p, c.p)
			local dist = vlen(v)
			if dist >= 2 then
				local sc = 2.2 * vdot(vnorm(v), d) - dist / 45.0
				if p.gk then
					sc -= 1.0
				end
				if sc > bs then
					best, bs = p, sc
				end
			end
		end
	end
	return best
end

--[[
	kind: "shot" | "pass" | "lofted" | "through" | "lthrough"
	o: { c, target, power, aimY, style, dir, stun, manual, curl }
	  人間のパスは dir (狙い) と power で飛ばす。target があれば補助の強さに応じてその味方へ合わせる。
	  CPU のパスは target へ (power 省略時は最適な強さ)。
]]
function Match:kick(kind, o)
	o = o or {}
	local b = self.ball
	local c = o.c or b.owner
	if c == nil then
		return
	end
	local power = o.power or 0.7
	b.offside = nil
	b.curl, b.curlUntil = 0, -1
	local s = self:sgn(c.team)
	local pressured = false
	for _, q in self:active(1 - c.team) do
		if vdist(q.p, c.p) < 2.2 then
			pressured = true
		end
	end
	if kind == "shot" then
		local g = self:oppGoal(c.team)
		local aimY = o.aimY or 0
		local base = c.seat ~= nil and 0.6 or 1.0
		local err = (base + 2.4 * math.max(0.0, power - 0.7)) * self:gauss()
		err = err / math.max(c.attr.shoot, 0.5)
		if pressured then
			err *= 1.3
		end
		if self:isCpuTeam(c.team) then
			err *= self.diff.aiShotErr
		end
		if o.style == "header" then
			err *= 1.4
			power = math.min(power, 0.8)
		elseif o.style == "impact" then
			power = math.min(1.0, power + 0.15)
			err *= 1.25
		elseif o.style == "control" then
			err *= 0.45
			power = math.min(power, 0.7)
		end
		local tgt = { x = g.x, y = aimY + err }
		self.tstats[c.team].shots += 1
		if math.abs(tgt.y) < GOAL_W / 2 then
			self.tstats[c.team].onTarget += 1
		end
		local u = vnorm(vsub(tgt, c.p))
		local spd = 15 + 17 * power
		local dist = vdist(tgt, c.p)
		if o.style == "loop" then
			local tf = clamp(dist / 14.0, 0.8, 2.0)
			b.v = vmul(u, (dist / tf) * 0.95)
			b.z, b.vz = 0.1, 0.5 * GRAV * tf * 0.92
		elseif o.style == "header" then
			b.v = vmul(u, spd * 0.7)
			b.vz = 1.0
			b.z = math.max(b.z, 1.2)
		else
			b.v = vmul(u, spd)
			local tf = dist / spd
			local peak = 0.3 + 3.2 * math.max(0.0, power - 0.55) + math.abs(self:gauss() * 0.25)
			b.z, b.vz = 0.1, (peak + 0.5 * GRAV * tf * tf) / math.max(tf, 0.1) * 0.5
		end
		if o.curl and o.curl ~= 0 then
			b.curl, b.curlUntil = o.curl * 5, self.elapsed + 1.2
		end
		b.target = nil
	else
		local lofted = kind == "lofted" or kind == "lthrough"
		local tgt = o.target
		local dest
		if o.dest ~= nil then
			dest = { x = o.dest.x, y = o.dest.y } -- 指した地点へ直接
		elseif tgt ~= nil then
			local lead = ({ pass = 0.4, lofted = 0.9, through = 1.0, lthrough = 1.1 })[kind]
			dest = vadd(tgt.p, vmul(tgt.v, lead))
			if kind == "through" or kind == "lthrough" then
				local runDir = o.dir or { x = s, y = 0 }
				local fwd = vnorm({ x = runDir.x + s * 0.8, y = runDir.y * 0.6 })
				dest = vadd(dest, vmul(fwd, o.power and lerp(4, 14, power) or 7))
			end
		else
			-- マニュアル: 狙いの方向へ、パワーに応じた距離
			local dir = o.dir or c.face
			local range = PASS_RANGE[kind == "lthrough" and "through" or kind] or PASS_RANGE.pass
			dest = vadd(c.p, vmul(vnorm(dir), lerp(range[1], range[2], power)))
		end
		-- 補助の強さ: パワーの影響 (マニュアル寄りほど、パワーで距離が変わる)
		if (tgt ~= nil or o.dest ~= nil) and o.power ~= nil and o.dir ~= nil then
			local wPower = CTRL.AssistPowerWeight[self.assist + 1] or 0.5
			if o.dest ~= nil then
				wPower *= 0.5 -- 地点を指した時は、距離は主に地点で決まる
			end
			local range = PASS_RANGE[kind == "lthrough" and "through" or kind] or PASS_RANGE.pass
			local dPow = lerp(range[1], range[2], power)
			local d0 = vdist(dest, c.p)
			local dd = lerp(d0, dPow, wPower)
			dest = vadd(c.p, vmul(vnorm(vsub(dest, c.p)), dd))
		end
		-- 精度: パスが下手なほど、強く蹴るほど、寄せられているほどずれる
		local spread = math.rad(0.8 + 3.0 * math.max(0, 1.2 - c.attr.pass) + 4.0 * power * power)
		if pressured then
			spread *= 1.5
		end
		if o.stun then
			spread *= 1.3
		end
		local off = vsub(dest, c.p)
		off = vrot(off, self:gauss() * spread)
		dest = vadd(c.p, off)
		dest.x = clamp(dest.x, -PL / 2 - 3, PL / 2 + 3)
		dest.y = clamp(dest.y, -PW / 2 - 3, PW / 2 + 3)
		local dist = vdist(dest, c.p)
		local u = vnorm(vsub(dest, c.p))
		if lofted then
			local T = clamp(dist / 20.0, 0.7, 2.2)
			b.v = vmul(u, dist / T)
			b.z, b.vz = 0.1, 0.5 * GRAV * T
		else
			-- 受け手へは勢いを残して届ける。空いた地点へは、そこで止まる程度に
			local arrive = (tgt == nil and o.dest ~= nil) and 1.0 or 3.5
			local v0 = math.sqrt(2 * FRICTION * dist) + arrive
			b.v = vmul(u, math.min(v0, 28.0))
			b.z, b.vz = 0, 0
		end
		if o.stun then
			b.v = vmul(b.v, 1.25)
		end
		if o.curl and o.curl ~= 0 then
			b.curl, b.curlUntil = o.curl * 4, self.elapsed + 1.2
		end
		b.target = tgt
		if tgt ~= nil then
			local rx = s * tgt.p.x
			if rx > 0 and rx > s * c.p.x and rx > self:secondLastX(c.team) + 0.3 then
				b.offside = tgt
			end
		end
		self.tstats[c.team].passes += 1
	end
	b.kind = kind
	b.owner = nil
	b.kicker, b.last = c, c
	b.kickT = self.elapsed
	b.p = vadd(c.p, vmul(vnorm(b.v), P_R + 0.3))
	c.face = vnorm(b.v)
	-- キックの種類 (見た目の動きに使う)
	local tag = self.kickTag
	self.kickTag = nil
	if tag == nil then
		if kind == "shot" then
			tag = (o.style == "loop" and "loop") or (o.style == "header" and "header") or "shot"
		elseif kind == "lofted" or kind == "lthrough" then
			tag = "lofted"
		elseif kind == "through" then
			tag = "through"
		else
			tag = "pass"
		end
	end
	self:event("kick", c, tag)
	if kind == "shot" then
		self:triggerDive(c)
	end
end

--- p がボールを持つ (所有の切り替えと、操作者の割り当て)。
function Match:gainBall(p)
	local b = self.ball
	b.owner = p
	b.last = p
	b.v = { x = 0, y = 0 }
	b.z, b.vz = 0, 0
	b.target, b.offside = nil, nil
	b.curl, b.curlUntil = 0, -1
	if p.seat == nil then
		-- 人間のチーム: 出し手の操作者 → 一番近い操作者 の順で、受けた選手に切り替える
		local best, bd = nil, math.huge
		for _, s in self.seats do
			if s.team == p.team then
				local d = s.ctrl and vdist(s.ctrl.p, p.p) or 1e6
				if b.kicker ~= nil and b.kicker.seat == s then
					d = -1
				end
				if d < bd then
					best, bd = s, d
				end
			end
		end
		if best ~= nil then
			self:assign(best, p)
		end
	end
	-- ダイレクトの予約があれば蹴る
	local s = p.seat
	if s ~= nil and s.queued ~= nil then
		local q = s.queued
		s.queued = nil
		if self.elapsed <= q.untilT then
			self:doKick(s, q.btn, q.power, q.mods)
		end
	end
end

function Match:startSlide(p)
	if p.cd > 0 or p.slide > 0 then
		return
	end
	p.slide, p.cd = 0.45, 1.4
	p.v = vmul(p.face, 10.0)
end

--- 立ったままの奪取 (プレッシャー / CPU の寄せ)。
function Match:tryTackle(p, rate, dt)
	local b = self.ball
	if b.owner == nil or b.owner.team == p.team or p.cd > 0 or b.owner.skill ~= nil then
		return
	end
	local owner = b.owner
	if owner.seat ~= nil and self.elapsed < owner.seat.shieldUntil then
		rate *= 0.5
	end
	rate *= p.attr.tackle * TACTICS.Press[self.tactics[p.team].press]
	if self:isCpuTeam(p.team) then
		rate *= self.diff.aiTackle
	end
	if vdist(b.p, p.p) < 1.3 and self:rand() < rate * dt then
		p.cd = 0.9
		self:event("steal", p) -- 足を出す
		if self:rand() < 0.55 then
			owner.stun = 0.5
			self:gainBall(p)
			self:popup("popup.steal", p.team)
		elseif self:rand() < 0.12 then
			self:foul(p, owner, 0.4)
		end
	end
end

--- 守備のシュートボタン: 近い相手にショルダーチャージ、こぼれ球ならクリア。
function Match:shoulderOrClear(p)
	local b = self.ball
	if p.cd > 0 then
		return
	end
	p.cd = 0.7
	if b.owner ~= nil and b.owner.team ~= p.team and b.owner.skill == nil then
		if vdist(b.p, p.p) < 1.7 then
			self:event("charge", p)
			if self:rand() < 0.5 * p.attr.tackle then
				b.owner.stun = 0.5
				self:gainBall(p)
				self:popup("popup.steal", p.team)
			end
		end
	elseif b.owner == nil and vdist(b.p, p.p) < 2.2 and b.z < 1.6 then
		local g = self:oppGoal(p.team)
		local d = vnorm({ x = g.x - p.p.x, y = g.y - p.p.y + self:uniform(-15, 15) })
		b.v = vmul(d, 24.0)
		b.z, b.vz = 0.1, 7.0
		b.kicker, b.last = p, p
		b.kickT = self.elapsed
		b.kind, b.target, b.offside = "clear", nil, nil
		self:popup("popup.clear", p.team)
		self:event("kick", p, "lofted")
	end
end

-- ================================================================ カーソル
function Match:defendScore(p)
	local b = self.ball
	local s = self:sgn(p.team)
	local d = vdist(p.p, b.p)
	local goalSide = s * p.p.x < s * b.p.x + 1.0
	return d + (goalSide and 0.0 or 12.0) + 0.1 * math.abs(p.p.y - b.p.y)
end

--- L1 で切り替わる選手 (他の操作者の選手と GK は除く)。
function Match:nextCursor(s)
	s = s or self.seats[1]
	if s == nil then
		return nil
	end
	local b = self.ball
	if b.owner == nil and b.target ~= nil and b.target.team == s.team and b.target.seat == nil then
		return b.target
	end
	local best, bs = nil, math.huge
	for _, p in self:active(s.team) do
		if p ~= s.ctrl and p.seat == nil and not p.gk then
			local sc = self:defendScore(p)
			if sc < bs then
				best, bs = p, sc
			end
		end
	end
	return best
end

function Match:manualCursor(s, d)
	local best, bs = nil, -1e9
	for _, p in self:active(s.team) do
		if p ~= s.ctrl and p.seat == nil and not p.gk then
			local v = vsub(p.p, s.ctrl.p)
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
		self:assign(s, best)
	end
end

--- 操作者ごとの自動切り替え (守備で、より良い位置の選手へ。頻繁には変えない)。
function Match:autoSwitch(s)
	local b = self.ball
	local p = s.ctrl
	if p == nil or p.out then
		self:assign(s, self:freeNearest(s.team, b.p, nil))
		return
	end
	if b.owner == p then
		return
	end
	if b.owner ~= nil and b.owner.team == s.team then
		return -- 味方 (他の操作者 / AI) が持っている
	end
	if p.gk then
		local n = self:nextCursor(s)
		if n ~= nil then
			self:assign(s, n)
		end
		return
	end
	if b.owner == nil and b.target ~= nil and b.target.team == s.team and b.target.seat == nil then
		-- 自分のチームへのパス: 出し手の操作者が受け手へ
		if b.kicker ~= nil and b.kicker.seat == s then
			self:assign(s, b.target)
		end
		return
	end
	if s.charge ~= nil or self.elapsed - s.switchT < 1.0 then
		return
	end
	local best = self:nextCursor(s)
	if best ~= nil and self:defendScore(p) > self:defendScore(best) + 8.0 then
		self:assign(s, best)
	end
end

-- ================================================================ セットプレー
function Match:startSetpiece(kind, team, pos, noteKey)
	local b = self.ball
	b.owner = nil
	b.v = { x = 0, y = 0 }
	b.z, b.vz = 0, 0
	b.p = { x = pos.x, y = pos.y }
	b.target, b.offside = nil, nil
	b.curl, b.curlUntil = 0, -1
	for _, q in self.pl do
		q.dive = nil
		q.run = nil
	end
	for _, s in self.seats do
		s.charge, s.queued = nil, nil
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
		for _, p in self.pl do
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
	-- 人間のチーム: 蹴る選手を、一番近い操作者に渡す
	if taker.seat == nil then
		local best, bd = nil, math.huge
		for _, s in self.seats do
			if s.team == team then
				local d = s.ctrl and vdist(s.ctrl.p, taker.p) or 1e6
				if d < bd then
					best, bd = s, d
				end
			end
		end
		if best ~= nil then
			self:assign(best, taker)
		end
	end
	self:popup(noteKey, team)
end

--- 人間が蹴る (aim と power)。
function Match:takeSetpiece(s, btn, power, mods)
	local sp = self.setp
	if sp == nil then
		return
	end
	local taker = sp.taker
	self.setp = nil
	self.ball.owner = taker
	if sp.kind == "pk" then
		local dir = self:aimOf(s)
		local g = self:oppGoal(taker.team)
		local aimY = clamp(dir.y * 1.6, -1, 1) * (GOAL_W / 2 - 0.4)
		if math.abs(dir.x) > 0.2 and (g.x - taker.p.x) * dir.x > 0 then
			aimY = clamp(taker.p.y + dir.y / dir.x * (g.x - taker.p.x), -GOAL_W / 2 - 1, GOAL_W / 2 + 1)
		end
		self:kick("shot", { c = taker, power = power, aimY = aimY })
	else
		if sp.kind == "throw" then
			self.kickTag = "throw"
		end
		self:doKick(s, btn, power, mods or {})
	end
	if sp.kind == "throw" then
		self.ball.offside = nil
		self.ball.v = vmul(self.ball.v, 0.75) -- 投げるので短め
		self.ball.z, self.ball.vz = 1.5, 1.5
	end
end

--- CPU のセットプレー (人間のチームでも、放置が続いたら代わりに蹴る)。
function Match:cpuSetpiece()
	local sp = self.setp
	if sp == nil then
		return
	end
	local dg = vdist(self.ball.p, self:oppGoal(sp.team))
	-- CPU: 最低限の間を置き、配置がそろったら蹴る (そろわなくても上限で蹴る)
	local minWait = ({ corner = 1.5, fk = dg < 35 and 1.5 or 0.8, throw = 0.8, gk = 1.0, pk = 1.8 })[sp.kind] or 1.0
	local maxWait = ({ corner = 7, fk = dg < 35 and 7 or 3, throw = 3, gk = 4, pk = 1.8 })[sp.kind] or 3
	local waited = self.elapsed - sp.t0
	if self:human(sp.team) then
		if waited < CTRL.SetpieceAutoTake then
			return
		end
	elseif waited < minWait or (waited < maxWait and not sp.ready) then
		return
	end
	local taker = sp.taker
	-- ゴール前の FK: 半分くらいは直接狙う (壁の外側、ファーサイドへ)
	if sp.kind == "fk" and dg < 30 and self:rand() < 0.5 then
		self.ball.owner = taker
		self.setp = nil
		local far = -sgnOf(self.ball.p.y)
		if far == 0 then
			far = self:choice({ -1, 1 })
		end
		self:kick("shot", { c = taker, power = self:uniform(0.75, 0.9), aimY = far * self:uniform(1.8, 3.2), curl = far })
		return
	end
	if sp.kind == "pk" then
		self.ball.owner = taker
		self.setp = nil
		local sign = self:choice({ -1, 1 })
		self:kick("shot", { c = taker, power = 0.8, aimY = sign * self:uniform(1.5, 3.2) })
		return
	end
	local how = (sp.kind == "corner" or sp.kind == "gk" or (sp.kind == "fk" and dg < 35)) and "lofted" or "pass"
	local toBox = sp.kind == "corner" or (sp.kind == "fk" and dg < 35)
	local sA = self:sgn(sp.team)
	local best, bs = nil, -1e9
	for _, m in self:active(sp.team) do
		local inBox = sA * m.p.x > PL / 2 - BOX_L and math.abs(m.p.y) < BOX_W / 2
		if m ~= taker and (not toBox or inBox) then
			local sc = self:laneClear(taker.p, m.p, sp.team) - 0.02 * vdist(m.p, taker.p)
			if sc > bs then
				best, bs = m, sc
			end
		end
	end
	self.ball.owner = taker
	self.setp = nil
	if sp.kind == "throw" then
		self.kickTag = "throw"
	end
	self:kick(how, { c = taker, target = best })
	if sp.kind == "throw" then
		self.ball.offside = nil
	end
end

-- ================================================================ セットプレーの配置
-- ゴール前で入る位置 (攻撃方向の座標: x = 相手ゴールへ向かって +、y = 実際の横位置。cy = コーナー側)
local BOX_SLOTS = {
	{ x = PL / 2 - 5, y = 3.5 }, -- ニアポスト
	{ x = PL / 2 - 6, y = -3.0 }, -- ファーポスト
	{ x = PL / 2 - 10.5, y = 0 }, -- PK スポット
	{ x = PL / 2 - 7.5, y = -0.5 }, -- 中央
	{ x = PL / 2 - 13, y = 6 }, -- 手前
	{ x = PL / 2 - 19, y = 0 }, -- エリアの外 (こぼれ球)
}
-- ゴール前に入れる順番 (前線と CB を優先)
local BOX_PRIORITY = { ST = 0, CF = 0, CB = 1, CAM = 2, CM = 2, DM = 3, LW = 3, RW = 3, LM = 3, RM = 3 }

--- そのチームの、蹴る人と GK 以外の選手。
function Match:fieldPlayers(team, except)
	local out = {}
	for _, p in self:active(team) do
		if p ~= except and not p.gk then
			table.insert(out, p)
		end
	end
	return out
end

--- 位置のリスト slots に、選手を近い順に割り当てる (貪欲法)。戻り値: player -> 位置
local function assignSlots(players, slots)
	local out = {}
	local free = table.clone(players)
	for _, slot in slots do
		local best, bd, bi = nil, math.huge, nil
		for i, p in free do
			local d = vdist(p.p, slot)
			if d < bd then
				best, bd, bi = p, d, i
			end
		end
		if best == nil then
			break
		end
		out[best] = slot
		table.remove(free, bi)
	end
	return out, free
end

--- セットプレーの配置 (蹴るまでの間、全員がこの位置へ動く)。
function Match:setpieceTargets()
	local sp = self.setp
	local b = self.ball
	local A = sp.team
	local D = 1 - A
	local sA = self:sgn(A)
	local goal = { x = sA * PL / 2, y = 0 } -- A が攻めるゴール
	local tg = self:shapeTargets(A)
	local function att(x, y)
		return { x = sA * x, y = y }
	end
	local function keepAway(team, radius)
		for _, p in self:active(team) do
			local t = tg[p] or p.p
			local d = vsub(t, b.p)
			if vlen(d) < radius and not p.gk then
				local dir = vlen(d) > 0.1 and vnorm(d) or vnorm(vsub(vmul(goal, -1), b.p))
				tg[p] = vadd(b.p, vmul(dir, radius))
			end
		end
	end
	--- 攻撃側をゴール前に入れ、守備側にマークさせる
	local function boxPlay(cy, nAttackers)
		local cands = self:fieldPlayers(A, sp.taker)
		table.sort(cands, function(a, c)
			return (BOX_PRIORITY[a.role] or 4) < (BOX_PRIORITY[c.role] or 4)
		end)
		local chosen = {}
		for i = 1, math.min(nAttackers, #cands) do
			table.insert(chosen, cands[i])
		end
		local slots = {}
		for i = 1, #chosen do
			local s0 = BOX_SLOTS[i]
			table.insert(slots, att(s0.x, s0.y * cy))
		end
		local placed = assignSlots(chosen, slots)
		for p, pos in placed do
			tg[p] = pos
		end
		-- 守備側: GK はライン上、1 人ニアポスト、他は攻撃側をゴール側からマーク
		local gk = self:slot(D, 0)
		if gk ~= nil and gk.gk then
			tg[gk] = att(PL / 2 - 0.6, cy * 1.0)
		end
		local defs = self:fieldPlayers(D, nil)
		local nearPost = att(PL / 2 - 1, cy * 3.2)
		local np = assignSlots(defs, { nearPost })
		local rest = {}
		for _, q in defs do
			if np[q] == nil then
				table.insert(rest, q)
			else
				tg[q] = nearPost
			end
		end
		local marks = {}
		for p, pos in placed do
			table.insert(marks, vadd(pos, { x = sA * 1.0, y = 0 }))
		end
		local mk, left = assignSlots(rest, marks)
		for q, pos in mk do
			tg[q] = pos
		end
		-- 残り: 1 人はカウンター用に前へ、他はエリアの手前
		for i, q in left do
			if i == 1 then
				tg[q] = att(PL / 2 - 52, 0)
			else
				tg[q] = att(PL / 2 - 21, (i - 2) * 8 - 8)
			end
		end
	end

	if sp.kind == "corner" then
		boxPlay(sgnOf(b.p.y) ~= 0 and sgnOf(b.p.y) or 1, 6)
		keepAway(D, 9.15)
	elseif sp.kind == "fk" then
		local dg = vdist(b.p, goal)
		if dg < 35 then
			-- ゴール前の FK: 攻撃側はゴール前へ、守備側は壁とマーク
			boxPlay(b.p.y >= 0 and 1 or -1, 4)
			local dir = vnorm(vsub(goal, b.p))
			local perp = { x = -dir.y, y = dir.x }
			local n = dg < 22 and 5 or (dg < 28 and 4 or 3)
			local center = vadd(b.p, vmul(dir, 9.15))
			local wall = {}
			for k = 1, n do
				table.insert(wall, vadd(center, vmul(perp, (k - (n + 1) / 2) * 0.75)))
			end
			local defs = self:fieldPlayers(D, nil)
			local placed = assignSlots(defs, wall)
			for q, pos in placed do
				tg[q] = pos
			end
		else
			keepAway(D, 9.15)
		end
	elseif sp.kind == "throw" then
		-- スローイン: 近くの 2 人が受けに寄る。相手は 2m 離れる
		local inward = { x = 0, y = -sgnOf(b.p.y) }
		local opts = {
			vadd(b.p, vadd(vmul(inward, 3), { x = sA * 9, y = 0 })),
			vadd(b.p, vmul(inward, 10)),
		}
		local placed = assignSlots(self:fieldPlayers(A, sp.taker), opts)
		for p, pos in placed do
			tg[p] = pos
		end
		keepAway(D, 2.5)
	elseif sp.kind == "gk" then
		-- ゴールキック: 相手はペナルティエリアの外へ
		for _, q in self:active(D) do
			if not q.gk then
				local t = tg[q] or q.p
				local ownX = -sA * PL / 2 -- A の自陣ゴール (= ボールのある側)
				if math.abs(t.x - ownX) < BOX_L + 1 and math.abs(t.y) < BOX_W / 2 + 1 then
					tg[q] = { x = ownX + sA * (BOX_L + 2), y = t.y }
				end
			end
		end
	elseif sp.kind == "pk" then
		for _, p in self.pl do
			if not p.gk and p ~= sp.taker then
				tg[p] = { x = clamp(p.p.x, -PL / 2 + BOX_L + 1, PL / 2 - BOX_L - 1), y = p.p.y }
			end
		end
	end
	return tg
end

--- セットプレー中: 蹴る人以外が配置へ動く (ボールは止まったまま)。
function Match:moveForSetpiece(dt)
	local sp = self.setp
	local b = self.ball
	local tg = self:setpieceTargets()
	local placed, total = 0, 0
	for _, p in self.pl do
		if not p.out and p ~= sp.taker and tg[p] ~= nil then
			total += 1
			if vdist(p.p, tg[p]) < 2.5 then
				placed += 1
			end
		end
	end
	sp.ready = total == 0 or placed / total >= 0.8 -- 8 割が配置に着いた
	for _, p in self.pl do
		if p.out then
			continue
		end
		if p == sp.taker then
			p.v = { x = 0, y = 0 }
		else
			local target = tg[p] or p.p
			local v = vsub(target, p.p)
			local dist = vlen(v)
			local top = Match.aiSpeed(dist, dist > 6) * self:speedMult(p)
			Match.steer(p, vmul(vnorm(v), top), ACC_AI, dt)
			p.p.x = clamp(p.p.x + p.v.x * dt, -PL / 2 - 2, PL / 2 + 2)
			p.p.y = clamp(p.p.y + p.v.y * dt, -PW / 2 - 2, PW / 2 + 2)
			-- ボールの方を向いて待つ
			local d = vsub(b.p, p.p)
			if vlen(d) > 0.5 and dist < 1.5 then
				p.face = vnorm(d)
			elseif vlen(p.v) > 0.3 then
				p.face = vnorm(p.v)
			end
		end
		self:updateStamina(p, dt)
	end
end

-- ================================================================ AI
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

--- AI が動かしてよい選手か (操作中でも入力が無ければ AI が補助する)。
function Match:aiDriven(p)
	return p.seat == nil or not self:seatActive(p.seat)
end

--- 人間がスティックを倒して動かしている選手か。
function Match:steering(p)
	local s = p.seat
	return s ~= nil and vlen(s.move) > CTRL.DeadZone and self:seatActive(s)
end

--- チームの陣形と、守備の寄せ役 (操作中の選手以外の AI が必ず 1 人寄せる)。
function Match:shapeTargets(attOverride)
	local b = self.ball
	local att = HOME
	if attOverride ~= nil then
		att = attOverride
	elseif b.owner ~= nil then
		att = b.owner.team
	elseif b.last ~= nil then
		att = b.last.team
	end
	local tg = {}
	for team = HOME, AWAY do
		local s = self:sgn(team)
		local bx = s * b.p.x
		local attacking = att == team
		local gkRush = false
		for _, st in self.seats do
			if st.team == team and st.gkRush and not attacking then
				gkRush = true
			end
		end
		for _, p in self:active(team) do
			local f = self.forms[p.team][p.i + 1]
			if p.gk then
				local gx = -s * (PL / 2 - 1.5)
				local gy = clamp(b.p.y * 0.15, -3, 3)
				tg[p] = { x = gx, y = gy }
				if gkRush then
					tg[p] = { x = b.p.x, y = b.p.y }
				end
			else
				local push = bx * 0.55 + (attacking and 14 or -2) + TACTICS.Line[self.tactics[team].line] + self.level[team] * 4
				local x = clamp(f.x + push, -PL / 2 + 6, PL / 2 - 4)
				if not attacking then
					local front = FWD[f.role] and 12 or 4
					x = math.min(x, bx + front)
				end
				local spread = attacking and 1.15 or 0.8
				local y = f.y * spread + b.p.y * 0.3
				if attacking and FWD[f.role] then
					local lim = self:secondLastX(team) - 0.5
					x = math.min(x + 6, lim)
				end
				tg[p] = { x = s * x, y = clamp(y, -PW / 2 + 2, PW / 2 - 2) }
			end
		end
	end
	-- 守備側の寄せ (間合いを取って構え、時々踏み込む。背後から追い回さない)
	--   寄せ役: ゴール側にいる選手を優先。自陣ゴールに近いほど間合いを詰める
	--   2 人目: 寄せ役の後ろ (ゴール側) でカバー。R1 / 攻守レベル最大なら 2 人目も寄せる
	self.pressInfo = {}
	for team = HOME, AWAY do
		if att ~= team and b.owner ~= nil then
			local owner = b.owner
			local ownGoal = vmul(self:oppGoal(team), -1)
			local toGoal = vnorm(vsub(ownGoal, owner.p))
			local defs = {}
			for _, p in self:active(team) do
				if not p.gk and self:aiDriven(p) then
					table.insert(defs, p)
				end
			end
			table.sort(defs, function(a, c)
				return self:defendScore(a) < self:defendScore(c)
			end)
			local cur = self.presser[team]
			local best = defs[1]
			if cur == nil or table.find(defs, cur) == nil or (best ~= nil and self:defendScore(best) < self:defendScore(cur) - 4.0) then
				cur = best
				if cur ~= nil then
					cur.nextCommit = self.elapsed + self:uniform(0.8, 1.6)
				end
			end
			self.presser[team] = cur
			local press = TACTICS.Press[self.tactics[team].press] + self.level[team] * 0.15
			if cur ~= nil then
				local dg = vdist(owner.p, ownGoal)
				local gap = (dg < 30 and 1.3 or (dg < 60 and 2.2 or 3.4)) / math.max(press, 0.5)
				gap = clamp(gap, 1.0, 4.5)
				if self.elapsed >= (cur.nextCommit or 0) then
					local rate = press * (self:isCpuTeam(team) and self.diff.aiTackle or 1)
					cur.commitUntil = self.elapsed + 0.55
					cur.nextCommit = self.elapsed + 0.55 + self:uniform(1.2, 2.6) / math.max(rate, 0.3)
				end
				if self.elapsed < (cur.commitUntil or -1) and vdist(cur.p, owner.p) < gap + 2.5 then
					tg[cur] = vadd(vadd(owner.p, vmul(toGoal, 1.0)), vmul(owner.v, 0.15)) -- ゴール側からボールへ足を出す
					self.pressInfo[cur] = "commit"
				else
					tg[cur] = vadd(vadd(owner.p, vmul(toGoal, gap)), vmul(owner.v, 0.25)) -- 構える
					self.pressInfo[cur] = "contain"
				end
			end
			local extra = self.level[team] >= 2
			for _, st in self.seats do
				if st.team == team and st.buttons.r1 then
					extra = true
				end
			end
			for _, p in defs do
				if p ~= cur then
					if extra then
						tg[p] = vadd(owner.p, vmul(toGoal, 1.2))
						self.pressInfo[p] = "commit"
					else
						tg[p] = vadd(owner.p, vmul(toGoal, 7))
						self.pressInfo[p] = "cover"
					end
					break
				end
			end
		end
	end
	return tg
end

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

--- 誰も持っていないボールへ: 各チームで一番早く追いつける選手 (受け手を含む) を向かわせる。
--- 受け手が届かない場合でも、届く別の選手が取りに行く。
function Match:planChasers()
	self.chase = {}
	local b = self.ball
	if b.owner ~= nil or self.setp ~= nil then
		return
	end
	local fut = self:ballFuture()
	for team = HOME, AWAY do
		local best = nil
		local targetReach = nil
		for _, p in self:active(team) do
			local skip = false
			if p.gk and not (math.abs(b.p.x) > PL / 2 - BOX_L and sgnOf(b.p.x) == -self:sgn(team)) then
				skip = true
			end
			if self:steering(p) then
				skip = true -- 人間が動かしている選手は任せる
			end
			if not skip then
				for _, f in fut do
					if f.z < 1.9 and vdist(f.p, p.p) <= DASH * 0.9 * f.t + CONTROL_R then
						if best == nil or f.t < best.t then
							best = { t = f.t, p = p, q = f.p }
						end
						if p == b.target then
							targetReach = { t = f.t, q = f.p }
						end
						break
					end
				end
			end
		end
		local tgt = b.target
		if tgt ~= nil and tgt.team == team and not self:steering(tgt) then
			-- パスの受け手: 届く最初の点へ (届かなければ一番近い点へ)
			local q = targetReach and targetReach.q
			if q == nil then
				local bd = math.huge
				for _, f in fut do
					local d = vdist(f.p, tgt.p)
					if d < bd then
						q, bd = f.p, d
					end
				end
			end
			self.chase[tgt] = { p = q, urgent = true }
		end
		if best ~= nil and best.p ~= tgt then
			-- 受け手より早く届く味方 / 受け手が届かない時の代わり
			if targetReach == nil or best.t < targetReach.t - 0.4 then
				self.chase[best.p] = { p = best.q, urgent = true }
			end
		elseif best == nil and #fut > 0 and (tgt == nil or tgt.team ~= team) then
			local last = fut[#fut].p
			local np, nd = nil, math.huge
			for _, p in self:active(team) do
				if not p.gk and self:aiDriven(p) then
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
		top = SPEED * 0.85
	elseif dist > 3 then
		top = SPEED * 0.6
	else
		top = SPEED * 0.4
	end
	return top * math.min(1.0, dist / 2.5)
end

function Match:cpuCarrier(c, dt)
	if c.skill ~= nil then
		return
	end
	if self.elapsed >= c.nextDecide or c.ddir == nil then
		local slow = self:isCpuTeam(c.team) and self.diff.aiDecide or 1
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
	if math.abs(c.p.y) < 20 and ((dg < 16 and self:rand() < 0.6) or (dg < 24 and self:rand() < 0.15)) then
		self:kick("shot", {
			c = c,
			power = self:uniform(0.55, 0.85),
			aimY = self:uniform(-GOAL_W / 2 - 0.3, GOAL_W / 2 + 0.3),
		})
		return true
	end
	if (nd < 3.0 and self:rand() < 0.6) or self:rand() < 0.12 then
		local best, bs = nil, -1e9
		for _, m in self:active(team) do
			if m ~= c and not m.gk then
				local clear = self:laneClear(c.p, m.p, team)
				if clear >= 2.0 then
					local sc = clear * 0.3 + 0.06 * s * (m.p.x - c.p.x) - 0.02 * vdist(m.p, c.p)
					if s * m.p.x > self:secondLastX(team) + 0.3 and s * m.p.x > 0 then
						sc -= 5
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
			self:startSkill(c, self:choice({ "double_touch", "elastico", "scissors", "marseille" }), gdir, side)
			return true
		end
	end
	local best, bs = nil, -1e9
	for _, ang in { -90, -60, -30, 0, 30, 60, 90 } do
		local d = vrot(gdir, math.rad(ang))
		local ahead = { x = c.p.x + d.x * 4.0, y = c.p.y + d.y * 4.0 }
		local space = 6.0
		for _, q in opp do
			local qp = { x = q.p.x + q.v.x * 0.6, y = q.p.y + q.v.y * 0.6 }
			space = math.min(space, vdist(qp, ahead))
		end
		local sc = 1.0 * vdot(d, gdir) + 1.2 * space / 6.0
		if math.abs(ahead.y) > PW / 2 - 2 or math.abs(ahead.x) > PL / 2 - 1 then
			sc -= 2.0
		end
		if c.ddir ~= nil then
			sc += 0.25 * vdot(d, c.ddir)
		end
		if sc > bs then
			best, bs = d, sc
		end
	end
	c.ddir = best
	return false
end

-- ================================================================ 能力・スタミナ
function Match:speedMult(p)
	local f = STAMINA.MinFactor + (1 - STAMINA.MinFactor) * (p.stamina / STAMINA.Max)
	return p.attr.speed * f
end

function Match:teamSpeed(team)
	if self:isCpuTeam(team) then
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
		if self.setp ~= nil then
			self:moveForSetpiece(dt)
		end
		return
	end
	-- 右スティックの技: 最後に弾いてから SkillWindow 秒で確定 (続けて弾けばコンビネーション)
	for _, s in self.seats do
		local lastIn = s.rsBuf[#s.rsBuf]
		if lastIn ~= nil and self.elapsed - lastIn.t > CTRL.SkillWindow then
			if self:attacking(s) and s.ctrl.skill == nil then
				local name, f, side = self:matchSkill(s)
				if name ~= nil then
					self:startSkill(s.ctrl, name, f, side)
				end
			end
			s.rsBuf = {}
		end
		if s.queued ~= nil and self.elapsed > s.queued.untilT then
			s.queued = nil
		end
		self:autoSwitch(s)
	end

	local tg = self:shapeTargets()
	self:planChasers()

	for _, p in self.pl do
		if p.out then
			continue
		end
		local integrate = true
		p.cd = math.max(0.0, p.cd - dt)
		local s = p.seat
		if self.mode == "shootout" and not p.gk then
			p.v = { x = 0, y = 0 }
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
		elseif s ~= nil and self:seatActive(s) and not (vlen(s.move) <= CTRL.DeadZone and self.chase[p] ~= nil) then
			self:humanMove(s, p, dt)
		elseif p == b.owner and p.seat == nil then
			self:cpuCarrier(p, dt)
			if b.owner ~= p then
				integrate = false
			end
		elseif p == b.owner then
			Match.steer(p, { x = 0, y = 0 }, ACC_HUMAN, dt) -- 操作中で入力なし: その場でキープ
		else
			local urgent = false
			local target
			local ch = self.chase[p]
			if ch ~= nil then
				target, urgent = ch.p, ch.urgent
			elseif p.run ~= nil and self.elapsed < p.run.untilT then
				target, urgent = p.run.to, true -- パス&ゴーの走り込み
			else
				p.run = nil
				target = tg[p]
				local mode = self.pressInfo and self.pressInfo[p]
				if mode == "commit" then
					urgent = true
				elseif mode == "contain" and target ~= nil and vdist(target, p.p) > 4 then
					urgent = true -- 間合いまでは急いで戻る / 詰める
				end
			end
			target = target or p.p
			local v = vsub(target, p.p)
			local dist = vlen(v)
			local top = Match.aiSpeed(dist, urgent) * self:speedMult(p) * self:teamSpeed(p.team)
			local mode = self.pressInfo and self.pressInfo[p]
			if mode == "contain" and b.owner ~= nil and dist < 4 then
				-- 構えている間は、保持者の速さに合わせて下がる・寄る (置いていかれない程度)
				top = math.max(top, math.min(vlen(b.owner.v) * 1.05, DASH))
			end
			Match.steer(p, vmul(vnorm(v), top), ACC_AI, dt)
			if b.owner ~= nil and b.owner.team ~= p.team then
				local bd = vdist(p.p, b.p)
				if mode == "commit" and bd < 1.6 then
					self:tryTackle(p, 1.5, dt) -- 踏み込んだ時に奪いに行く
				elseif bd < 1.1 then
					self:tryTackle(p, p.seat == nil and 0.6 or 0.4, dt) -- 目の前に来たボールに足を出す
				end
			end
		end
		self:updateStamina(p, dt)
		if integrate then
			p.p.x = clamp(p.p.x + p.v.x * dt, -PL / 2 - 2, PL / 2 + 2)
			p.p.y = clamp(p.p.y + p.v.y * dt, -PW / 2 - 2, PW / 2 + 2)
			if vlen(p.v) > 0.3 and p.slide <= 0 and p.skill == nil then
				p.face = vnorm(p.v)
			end
			-- 寄せている守備者は、下がりながらでも保持者の方を向く
			local mode = self.pressInfo and self.pressInfo[p]
			if (mode == "contain" or mode == "commit") and b.owner ~= nil and p.slide <= 0 then
				local d = vsub(b.owner.p, p.p)
				if vlen(d) < 8 and vlen(d) > 0.1 then
					p.face = vnorm(d)
				end
			end
		end
	end
	self:updateBall(dt)
	self:pruneOld()
end

--- 人間の操作中の選手の動き (攻撃: ドリブル / 守備: プレッシャー・マッチアップ)。
function Match:humanMove(s, p, dt)
	local b = self.ball
	local d = s.move
	local mag = vlen(d)
	local dashing = s.buttons.dash and not p.exhausted
	local sp = (dashing and DASH or SPEED) * math.min(1, mag)
	if b.owner == p then
		sp *= DRIBBLE * (self.elapsed < s.shieldUntil and 0.8 or 1.0)
		if s.charge ~= nil then
			sp *= 0.7 -- 蹴る構え中は少し遅い
		end
	end
	local opp = b.owner ~= nil and b.owner.team ~= p.team
	if s.buttons.pass and opp and s.charge == nil then
		-- プレッシャー (長押し): ボール保持者へ寄せる
		local to = vnorm(vsub(b.owner.p, p.p))
		d = mag > CTRL.DeadZone and vnorm({ x = to.x + 0.4 * d.x, y = to.y + 0.4 * d.y }) or to
		sp = DASH * 0.95
		mag = 1
		self:tryTackle(p, 1.0, dt)
	elseif s.buttons.pass and b.owner == nil and s.charge == nil then
		-- こぼれ球へ向かう
		d = vnorm(vsub(b.p, p.p))
		sp = DASH * 0.95
		mag = 1
	end
	if s.buttons.l2 and opp then
		-- マッチアップ: 保持者とゴールの間に入り、間合いを詰める
		local goal = vmul(self:oppGoal(p.team), -1)
		local spot = vadd(b.owner.p, vmul(vnorm(vsub(goal, b.owner.p)), 1.2))
		local to = vnorm(vsub(spot, p.p))
		d = mag > CTRL.DeadZone and vnorm({ x = to.x + 0.5 * d.x, y = to.y + 0.5 * d.y }) or to
		sp = SPEED * 0.95
		mag = 1
		self:tryTackle(p, 1.4, dt)
	end
	local dir = mag > 1e-6 and vnorm(d) or { x = 0, y = 0 }
	Match.steer(p, vmul(dir, sp * self:speedMult(p)), ACC_HUMAN, dt)
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
	if vdist(b.p, p.p) < 1.0 then
		b.owner = nil
		b.v = vadd(vmul(p.face, 7), vmul(o.v, 0.3))
		b.last = p
		p.slide = 0
		self:popup("popup.nicetackle", p.team)
	elseif vdist(o.p, p.p) < 1.2 then
		p.slide = 0
		o.stun = 0.8
		self:foul(p, o)
	end
end

--- severity: 1 = 悪質 (スライディング) / 小さいほど軽い接触。カードの出やすさに掛かる。
function Match:foul(fouler, victim, severity)
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
	-- カーブ (FK 等): 進行方向に対して横へ曲がる
	if b.curl ~= 0 and self.elapsed < b.curlUntil then
		local sp = vlen(b.v)
		if sp > 4 then
			local n = { x = -b.v.y / sp, y = b.v.x / sp }
			b.v = vadd(b.v, vmul(n, b.curl * dt))
		end
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
	if self.mode == "shootout" and (math.abs(b.p.x) >= PL / 2 or math.abs(b.p.y) >= PW / 2) then
		local scored = math.abs(b.p.x) >= PL / 2 and math.abs(b.p.y) < GOAL_W / 2 and b.z < GOAL_H
		b.v = { x = 0, y = 0 }
		b.vz = 0
		b.p.x = clamp(b.p.x, -PL / 2, PL / 2)
		b.p.y = clamp(b.p.y, -PW / 2, PW / 2)
		self:shootResult(scored)
		return
	end
	if math.abs(b.p.x) >= PL / 2 then
		local side = b.p.x > 0 and 1 or -1
		local att = (side == self:sgn(HOME)) and HOME or AWAY
		if math.abs(b.p.y) < GOAL_W / 2 and b.z < GOAL_H then
			self.score[att] += 1
			self:popup("popup.goal", att)
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
	local order = {}
	for _, p in self.pl do
		if not p.out then
			table.insert(order, p)
		end
	end
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
			local hmax = 1.9
			if p.gk and math.abs(p.p.x) > PL / 2 - BOX_L then
				reach, hmax = 1.7, 2.6
				if p.dive ~= nil then
					reach = 2.2
				end
			end
			if b.z <= hmax and d < reach and (sp < 24 or not mine or p.gk) then
				if mine and b.offside == p then
					self.tstats[p.team].offside += 1
					self:startSetpiece("fk", 1 - p.team, p.p, "popup.offside")
					return
				end
				-- CPU のヘディング
				if
					mine
					and b.z >= HEADER.MinZ
					and not p.gk
					and (b.kind == "lofted" or b.kind == "lthrough")
					and self:aiDriven(p)
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
				if not mine and b.kicker ~= nil and b.kind ~= "shot" and b.kind ~= "clear" then
					self.tstats[b.kicker.team].intercepted += 1
					self:popup("popup.cut", p.team)
				end
				if p.gk and not mine and b.kind == "shot" and sp > 14 and self:rand() < 0.3 and self.mode ~= "shootout" then
					self.tstats[p.team].saves += 1
					self:popup("popup.save", p.team)
					self:event("save", p)
					local gsign = sgnOf(p.p.x)
					b.v = { x = gsign * 5, y = (self:rand() < 0.5 and -1 or 1) * 8 }
					b.z, b.vz = 0.6, 2
					b.last, b.kicker, b.kickT = p, p, self.elapsed
					b.target, b.offside = nil, nil
					b.kind = "clear"
					p.dive = nil
					return
				end
				if p.gk and not mine and b.kind == "shot" then
					self.tstats[p.team].saves += 1
					self:popup("popup.save", p.team)
					self:event("save", p)
					if self.mode == "shootout" then
						self:shootResult(false)
					end
				end
				p.dive = nil
				if self.mode == "shootout" then
					self:shootResult(false)
				end
				p.run = nil
				if not p.gk then
					self:event("trap", p)
				end
				self:gainBall(p)
				return
			end
		end
	end
end

-- ================================================================ GK のダイブ
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
		return
	end
	local t = (gx - b.p.x) / vx
	if t <= 0 or t > 2.5 then
		return
	end
	local yPred = b.p.y + b.v.y * t
	if math.abs(yPred) > GOAL_W / 2 + 1 then
		return
	end
	local y = yPred
	-- PK で人間がキーパーの側: 左スティックの向きに跳ぶ (eFootball と同じ)
	local isPk = vdist(shooter.p, { x = gx - sgnOf(gx) * PEN_SPOT, y = 0 }) < 1.5
	local humanSeat = nil
	for _, s in self.seats do
		if s.team == team then
			humanSeat = s
			break
		end
	end
	if isPk and humanSeat ~= nil then
		local my = humanSeat.move.y
		if math.abs(my) > 0.3 then
			y = sgnOf(my) * GOAL_W / 2 * 0.8
		else
			y = 0
		end
	else
		local react = self:isCpuTeam(team) and self.diff.gkReact or 0.5
		if self:rand() >= react then
			y = self:uniform(-GOAL_W / 2, GOAL_W / 2)
		end
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

-- ================================================================ ヘディング・ボレー
function Match:tryHeader(s, btn)
	local b = self.ball
	local c = s.ctrl
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
	local dir = self:aimOf(s)
	if btn == "shoot" and vdist(goal, c.p) < HEADER.ShotRange then
		local aimY = 0
		if math.abs(dir.x) > 0.15 and (goal.x - c.p.x) * dir.x > 0 then
			aimY = clamp(c.p.y + dir.y / dir.x * (goal.x - c.p.x), -GOAL_W / 2 - 1, GOAL_W / 2 + 1)
		end
		self:kick("shot", { c = c, power = 0.65, style = "header", aimY = aimY })
	else
		local recv = self:chooseReceiver(c, "pass", dir, 0.4)
		self.kickTag = "header"
		self:kick("pass", { c = c, dir = dir, power = 0.4, target = recv })
	end
	self:popup("popup.header", c.team)
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
	self:popup(kind == "yellow" and "popup.yellow" or "popup.red", 1 - p.team)
	self:event("card")
	if kind == "red" then
		self:sendOff(p)
	end
end

function Match:sendOff(p)
	p.out = true
	p.skill, p.dive, p.run = nil, nil, nil
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
	if p.gk then
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
	local s = p.seat
	if s ~= nil then
		p.seat = nil
		s.ctrl = nil
		self:assign(s, self:freeNearest(p.team, self.ball.p, nil))
	end
end

-- ================================================================ 前後半・延長・PK 戦
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
	self:popup(key, nil)
	self.setp = nil
	for _, s in self.seats do
		s.charge, s.queued = nil, nil
	end
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

function Match:placeFormation()
	for _, p in self.pl do
		local f = self.forms[p.team][p.i + 1]
		local s = self:sgn(p.team)
		p.dive, p.run = nil, nil
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
	b.kicker = nil
	b.curl, b.curlUntil = 0, -1
	self.setp = nil
	for _, s in self.seats do
		s.charge, s.queued, s.rsBuf = nil, nil, {}
	end
	for _, q in self:active(1 - team) do
		q.cd = 1.5 -- キックオフ直後は相手がすぐに奪いに来ない
	end
	-- 操作者の割り当て: キックオフするチームは最初の操作者が ST、他は近い選手
	for _, p in self.pl do
		p.seat = nil
	end
	for t = HOME, AWAY do
		local first = true
		for _, s in self.seats do
			if s.team == t then
				s.ctrl = nil
				if first and t == team then
					self:assign(s, st)
				else
					self:assign(s, self:freeNearest(t, b.p, st))
				end
				first = false
			end
		end
	end
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
		passes = self.tstats[HOME].passes,
		intercepted = self.tstats[HOME].intercepted,
		offside = self.tstats[HOME].offside,
		fouls = self.tstats[HOME].fouls,
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
	self.ball.owner = nil
	self:popup("popup.shootout", nil)
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
			self:shootResult(false)
		end
	end
end

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
		self:popup("popup.goal", team)
		self:event("goal")
	else
		self:popup("popup.miss", 1 - team)
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
	for _, s in self.seats do
		s.charge, s.queued = nil, nil
	end
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

return Match
