--!nocheck
--[[
	Match / Rewards / Locale / Config の検証。モジュールはランナーがグローバルに注入する。
	乱数は決定論的な LCG を渡して再現できるようにしている。
]]

local failures, checks = 0, 0
local function check(name, cond, detail)
	checks += 1
	if cond then
		print("  ok   " .. name)
	else
		failures += 1
		print("  FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
	end
end

local function lcg(seed)
	local s = seed
	return function()
		s = (s * 48271) % 2147483647
		return s / 2147483647
	end
end

local function finite(p)
	return p.x == p.x and p.y == p.y and math.abs(p.x) < 1e6 and math.abs(p.y) < 1e6
end

local function step(m, n, dt)
	for _ = 1, n do
		m:update(dt or 1 / 30)
	end
end

local function runUntilEnd(m, maxSteps)
	local n = 0
	while not m.ended and n < (maxSteps or 40000) do
		m:update(1 / 30)
		n += 1
	end
	return n
end

local function cpuOpts(seed, extra)
	local o = { random = lcg(seed), ctrlKind = { [0] = "cpu", [1] = "cpu" } }
	for k, v in extra or {} do
		o[k] = v
	end
	return o
end

--- 相手を遠ざけて、邪魔の入らない状況を作る。
local function clearOpponents(m, team)
	for _, q in m.teams[team or 1] do
		q.p = { x = (m:sgn(team or 1) > 0) and -45 or 45, y = q.p.y }
		q.v = { x = 0, y = 0 }
	end
end

--- ボールを持たせる (操作者 s の選手に)。
local function giveBall(m, s, pos)
	local p = s.ctrl
	if pos then
		p.p = { x = pos.x, y = pos.y }
	end
	m:gainBall(p)
	if m.ball.owner ~= p then
		m:assign(s, p)
		m:gainBall(p)
	end
	return p
end

--- ボタンを t 秒押して離す (その間も試合を進める)。
local function hold(m, id, btn, seconds)
	m:press(id, btn)
	step(m, math.max(0, math.floor(seconds * 30 + 0.5)))
	m:release(id, btn)
end

local function angleOf(v)
	return math.deg(math.atan2(v.y, v.x))
end

local function angDiff(a, b)
	local d = (a - b + 180) % 360 - 180
	return math.abs(d)
end

print("== 設定 ==")
check("選手11人分の陣形", #Config.Formation == 11)
do
	local nums, n = {}, 0
	for _, f in Config.Formation do
		if not nums[f.num] then
			n += 1
		end
		nums[f.num] = true
	end
	check("背番号が重複しない", n == 11)
end

print("== 多言語 ==")
do
	local missing, extra, bad = {}, {}, {}
	for k in Locale.Tables.en do
		if Locale.Tables.ja[k] == nil then
			table.insert(missing, k)
		end
	end
	for k in Locale.Tables.ja do
		if Locale.Tables.en[k] == nil then
			table.insert(extra, k)
		end
	end
	for k, en in Locale.Tables.en do
		local ja = Locale.Tables.ja[k]
		if ja then
			local _, a = string.gsub(en, "%%[ds]", "")
			local _, b = string.gsub(ja, "%%[ds]", "")
			if a ~= b then
				table.insert(bad, k)
			end
		end
	end
	check("日本語の訳漏れが無い", #missing == 0, table.concat(missing, ","))
	check("英語にだけ無いキーが無い", #extra == 0, table.concat(extra, ","))
	check("書式指定子の数が日英で一致", #bad == 0, table.concat(bad, ","))
	check("LocaleId ja-jp → ja", Locale.langOf("ja-jp") == "ja")
	check("未定義キーはキーを返す", Locale.t("en", "no.such.key") == "no.such.key")
end

print("== 試合 (CPU 同士で通し) ==")
do
	local m = Match.new(cpuOpts(12345))
	local bad = nil
	local n = 0
	while not m.ended and n < 20000 do
		m:update(1 / 30)
		n += 1
		for _, p in m.pl do
			if not finite(p.p) or not finite(p.v) then
				bad = "player " .. p.team .. ":" .. p.i
			end
		end
		if not finite(m.ball.p) then
			bad = "ball"
		end
		if bad then
			break
		end
	end
	check("座標が発散しない", bad == nil, bad)
	check("試合が終わる", m.ended, m.elapsed)
	check("結果が作られる", m.result ~= nil)
	local total = m.score[0] + m.score[1]
	check("得点が現実的 (0〜20)", total >= 0 and total <= 20, total)
	local okAll, goals = true, 0
	for seed = 1, 6 do
		local c = Match.new(cpuOpts(seed * 7919))
		runUntilEnd(c, 20000)
		okAll = okAll and c.ended
		goals += c.score[0] + c.score[1]
	end
	check("6 シードすべて完走", okAll)
	check("6 試合で 1 点以上は入る", goals >= 1, goals)
end

print("== 操作者 (シート) ==")
do
	local m = Match.new({ random = lcg(99) })
	check("既定は HOME に操作者 1 人", #m.seats == 1 and m.seats[1].team == 0)
	local s = m:seat(1)
	check("キックオフは操作者の選手がボールを持つ", m.ball.owner == s.ctrl and s.ctrl.seat == s)
	check("互換: m.ctrl は操作中の選手", m.ctrl == s.ctrl)
	clearOpponents(m)
	m:setMove(1, 1, 0)
	local x0 = s.ctrl.p.x
	step(m, 30)
	check("アナログ入力で +x へ進む", s.ctrl.p.x > x0 + 2, s.ctrl.p.x - x0)
	m:setMove(1, 0.3, 0)
	local p = s.ctrl
	local v0 = 0
	step(m, 30)
	v0 = math.sqrt(p.v.x ^ 2 + p.v.y ^ 2)
	m:setMove(1, 1, 0)
	step(m, 30)
	local v1 = math.sqrt(p.v.x ^ 2 + p.v.y ^ 2)
	check("スティックの倒し具合で速さが変わる", v1 > v0 * 1.5, v0 .. " → " .. v1)
	m:setMove(1, 0, 0)
	m:command(1, "pause")
	local t = m.elapsed
	m:update(0.1)
	check("一時停止", m.paused and m.elapsed == t)
	m:command(1, "pause")
	check("再開", not m.paused)
end

print("== パス: どの方向にも出せる・アナログの狙い・強さ ==")
do
	-- 走っている向きと逆 (後ろ) の味方へパスできる
	local m = Match.new({ random = lcg(5), assist = 1 })
	clearOpponents(m)
	local s = m:seat(1)
	local p = giveBall(m, s, { x = 10, y = 0 })
	local mate = nil
	for _, q in m:active(0) do
		if q ~= p and not q.gk then
			q.p = { x = 100, y = 100 } -- 他は遠くへ
		end
	end
	mate = m.teams[0][6]
	mate.p = { x = -5, y = 6 } -- 後ろ斜め
	m:setMove(1, 1, 0) -- 前へ走りながら
	step(m, 5)
	m:setAim(1, -15, 6) -- 後ろの味方を狙う
	hold(m, 1, "pass", 0.3)
	check("後ろの味方へのパスになる (走る向きと関係ない)", m.ball.target == mate, m.ball.target and m.ball.target.role)
	check("ボールが後ろへ飛ぶ", m.ball.v.x < 0, m.ball.v.x)

	-- マニュアル: 狙った角度 (8 方向でない 37°) にそのまま飛ぶ
	local m2 = Match.new({ random = lcg(6), assist = 0 })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	giveBall(m2, s2, { x = 0, y = 0 })
	local ang = math.rad(37)
	m2:setAim(1, math.cos(ang), math.sin(ang))
	hold(m2, 1, "pass", 0.5)
	local fly = angleOf(m2.ball.v)
	check("マニュアルは狙った角度に飛ぶ (37°)", angDiff(fly, 37) < 6, fly)
	check("マニュアルは受け手を決めない", m2.ball.target == nil)

	-- 強さ: 長く溜めるほど強い
	local function speedAfter(holdT)
		local mm = Match.new({ random = lcg(7), assist = 0 })
		clearOpponents(mm)
		local ss = mm:seat(1)
		giveBall(mm, ss, { x = -20, y = 0 })
		mm:setAim(1, 1, 0)
		hold(mm, 1, "pass", holdT)
		return math.sqrt(mm.ball.v.x ^ 2 + mm.ball.v.y ^ 2)
	end
	local weak, strong = speedAfter(0.1), speedAfter(0.9)
	check("長く溜めるほど強いパス", strong > weak * 1.4, weak .. " / " .. strong)

	-- パワーゲージ
	local m3 = Match.new({ random = lcg(8) })
	local s3 = m3:seat(1)
	clearOpponents(m3)
	giveBall(m3, s3)
	local tgt3 = m3.teams[0][7]
	m3:setAim(1, tgt3.p.x - s3.ctrl.p.x, tgt3.p.y - s3.ctrl.p.y)
	m3:press(1, "pass")
	step(m3, 15)
	local pw = m3:chargePower(s3)
	check("溜め中のパワーが読める (0.5 秒 ≒ 0.5)", pw ~= nil and math.abs(pw - 0.5) < 0.1, pw)
	check("溜め中は受け手のプレビューがある", m3:previewReceiver(s3) ~= nil)
	m3:release(1, "pass")
	check("離すと蹴る", m3.ball.owner == nil and m3.ball.kind == "pass")

	-- 補助: 狙いが少しずれていても、近い角度の味方に合わせる
	local m4 = Match.new({ random = lcg(9), assist = 1 })
	clearOpponents(m4)
	local s4 = m4:seat(1)
	local p4 = giveBall(m4, s4, { x = 0, y = 0 })
	for _, q in m4:active(0) do
		if q ~= p4 and not q.gk then
			q.p = { x = 100, y = 100 }
		end
	end
	local t4 = m4.teams[0][7]
	t4.p = { x = 15, y = 15 } -- 45°
	m4:setAim(1, math.cos(math.rad(30)), math.sin(math.rad(30))) -- 30° を狙う
	hold(m4, 1, "pass", 0.5)
	check("標準の補助は 15° ずれた味方に合わせる", m4.ball.target == t4)
end

print("== スルー・浮き球・シュートの狙い ==")
do
	local m = Match.new({ random = lcg(21) })
	clearOpponents(m)
	local s = m:seat(1)
	giveBall(m, s, { x = 0, y = 0 })
	m:setAim(1, 1, 0)
	hold(m, 1, "lofted", 0.6)
	check("浮き球は空中へ", m.ball.kind == "lofted" and m.ball.vz > 0)

	local m2 = Match.new({ random = lcg(22) })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	giveBall(m2, s2, { x = 0, y = 0 })
	m2:setAim(1, 1, 0)
	m2:press(1, "l1")
	hold(m2, 1, "through", 0.5)
	m2:release(1, "l1")
	check("L1 + スルー = ループスルー", m2.ball.kind == "lthrough")

	-- シュートを右上 / 左上に打ち分け
	local function shotY(aimY)
		local mm = Match.new({ random = lcg(23) })
		clearOpponents(mm)
		local ss = mm:seat(1)
		local p = giveBall(mm, ss, { x = 35, y = 0 })
		mm:setAim(1, 52.5 - 35, aimY)
		hold(mm, 1, "shoot", 0.4)
		return mm.ball.v.y
	end
	check("狙った側にシュートが飛ぶ", shotY(3) > 0 and shotY(-3) < 0)

	-- コントロールシュート (R1) はぶれにくく、ファーへ巻く
	local function awayAll(mm)
		for _, q in mm.teams[1] do
			q.p = { x = -45, y = 30 }
			q.v = { x = 0, y = 0 }
		end
	end
	-- ゴールラインを越えた時の y と、途中で一番外へ膨らんだ y
	-- 返り値: ゴールライン上の y、始点と終点を結ぶ直線から一番離れた距離
	local function flight(mm)
		local pts = { { x = mm.ball.p.x, y = mm.ball.p.y } }
		for _ = 1, 120 do
			step(mm, 1)
			table.insert(pts, { x = mm.ball.p.x, y = mm.ball.p.y })
			if mm.ball.p.x >= 52.5 then
				break
			end
		end
		local a, b = pts[1], pts[#pts]
		local dx, dy = b.x - a.x, b.y - a.y
		local L = math.max(math.sqrt(dx * dx + dy * dy), 1e-6)
		local bend = 0
		for _, q in pts do
			bend = math.max(bend, math.abs((q.x - a.x) * dy - (q.y - a.y) * dx) / L)
		end
		return b.y, bend
	end
	local function spread(r1)
		local sum = 0
		for k = 1, 30 do
			local mm = Match.new({ random = lcg(100 + k) })
			awayAll(mm)
			local ss = mm:seat(1)
			giveBall(mm, ss, { x = 30, y = 0 })
			mm:setAim(1, 1, 0)
			if r1 then
				mm:press(1, "r1")
			end
			hold(mm, 1, "shoot", 0.5)
			sum += math.abs((flight(mm)))
		end
		return sum / 30
	end
	check("コントロールシュートはぶれが小さい", spread(true) < spread(false), spread(true) .. " / " .. spread(false))
	do
		-- 左寄り (y = -10) からファー (y = +2.5) を狙う: 外へ膨らんで (直線から 0.5 m 以上曲がって) 枠へ入る
		local inGoal, bent = 0, 0
		for k = 1, 10 do
			local mm = Match.new({ random = lcg(300 + k) })
			awayAll(mm)
			local ss = mm:seat(1)
			giveBall(mm, ss, { x = 33, y = -10 })
			mm:setAimPoint(1, 52.5, 2.5)
			mm:press(1, "r1")
			hold(mm, 1, "shoot", 0.4)
			mm:release(1, "r1")
			local y, bend = flight(mm)
			if math.abs(y) < 3.66 then
				inGoal += 1
			end
			if bend > 0.5 then
				bent += 1
			end
		end
		check("コントロールシュートはファーへ巻いて枠に入る", inGoal >= 7 and bent >= 7, inGoal .. " in / " .. bent .. " bent")
	end
end

print("== ダイレクト・ヘディング ==")
do
	local m = Match.new({ random = lcg(31), assist = 1 })
	clearOpponents(m)
	local s = m:seat(1)
	local p = giveBall(m, s, { x = 0, y = 0 })
	local mate = m.teams[0][7]
	mate.p = { x = 12, y = 0 }
	m:setAim(1, 1, 0)
	hold(m, 1, "pass", 0.3)
	check("パスの受け手に操作が移る", s.ctrl == mate, s.ctrl and s.ctrl.role)
	-- 受ける前にシュートを溜めて離す → 受けた瞬間に蹴る
	m:setAim(1, 1, 0)
	m:press(1, "shoot")
	step(m, 6)
	m:release(1, "shoot")
	local shot = false
	for _ = 1, 60 do
		m:update(1 / 30)
		if m.ball.kind == "shot" then
			shot = true
			break
		end
	end
	check("受ける前に入力するとダイレクトで蹴る", shot)

	local m2 = Match.new({ random = lcg(32) })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	local c = s2.ctrl
	c.p = { x = 40, y = 2 }
	m2.ball.owner = nil
	m2.ball.p = { x = 40.4, y = 2 }
	m2.ball.z, m2.ball.vz = 1.5, 0
	m2.ball.v = { x = 0, y = 0 }
	m2:press(1, "shoot")
	check("空中のボールにシュートで合わせる (ヘディング)", m2.ball.kind == "shot" and m2.ball.owner == nil)
end

print("== ボールを取りに行く (AI の補助) ==")
do
	-- 誰もいない方向へのパス: 放置しても誰かが拾う
	local m = Match.new({ random = lcg(41), assist = 0 })
	local s = m:seat(1)
	giveBall(m, s, { x = -10, y = 0 })
	m:setAim(1, 0, 1)
	hold(m, 1, "pass", 0.7)
	local owned = false
	for _ = 1, 30 * 8 do
		m:update(1 / 30)
		if m.ball.owner ~= nil or m.setp ~= nil then
			owned = true
			break
		end
	end
	check("こぼれ球を放置せず、誰かが取りに行く", owned)

	-- パスの受け手 (操作が移って入力なし) が自動で受けに行く
	local m2 = Match.new({ random = lcg(42), assist = 2 })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	giveBall(m2, s2, { x = 0, y = 0 })
	local mate = m2.teams[0][7]
	mate.p = { x = 18, y = 6 }
	m2:setAim(1, 18, 6)
	hold(m2, 1, "pass", 0.1) -- 弱すぎる
	m2:setMove(1, 0, 0)
	local got = false
	for _ = 1, 30 * 6 do
		m2:update(1 / 30)
		if m2.ball.owner ~= nil then
			got = m2.ball.owner.team == 0
			break
		end
	end
	check("弱いパスでも受け手が寄って受ける", got)

	-- 守備: 操作中の選手が一番近くても、AI の味方が寄せに行く
	local m3 = Match.new({ random = lcg(43) })
	local s3 = m3:seat(1)
	local carrier = m3.teams[1][8]
	m3:gainBall(carrier)
	carrier.p = { x = 0, y = 0 }
	s3.ctrl.p = { x = -1.5, y = 0 }
	m3:setMove(1, 0, 1) -- 人間は別の方向へ動いている (入力あり)
	step(m3, 2)
	local presser = m3.presser[0]
	check("寄せ役は人間が操作していない選手", presser ~= nil and presser ~= s3.ctrl)

	-- 守備: 人間が放置しても、そのうち奪い返す (CPU 同士と同様にボールが動く)
	local m4 = Match.new({ random = lcg(44) })
	local changes, last = 0, m4.ball.owner
	for _ = 1, 30 * 60 do
		m4:update(1 / 30)
		if m4.ball.owner ~= nil and m4.ball.owner ~= last then
			if last ~= nil and m4.ball.owner.team ~= last.team then
				changes += 1
			end
			last = m4.ball.owner
		end
	end
	check("人間が放置しても攻守が入れ替わる (60 秒)", changes >= 2, changes)
end

print("== 守備の操作 ==")
do
	local m = Match.new({ random = lcg(51) })
	local s = m:seat(1)
	local carrier = m.teams[1][8]
	m:gainBall(carrier)
	carrier.p = { x = 0, y = 0 }
	carrier.cd, s.ctrl.cd = 0, 0
	s.ctrl.p = { x = -8, y = 0 }
	m:press(1, "pass") -- プレッシャー
	local d0 = math.abs(s.ctrl.p.x - carrier.p.x)
	step(m, 15)
	check("パス長押し = プレッシャーで寄せる", math.abs(s.ctrl.p.x - carrier.p.x) < d0 - 2)
	m:release(1, "pass")
	local before = s.ctrl
	m:press(1, "l1")
	m:release(1, "l1")
	check("L1 でカーソルが切り替わる", s.ctrl ~= before)
	local m2 = Match.new({ random = lcg(52) })
	local s2 = m2:seat(1)
	local c2 = m2.teams[1][8]
	m2:gainBall(c2)
	m2:press(1, "lofted")
	check("守備で浮き球ボタン = スライディング", s2.ctrl.slide > 0)
	m2:command(1, "levelUp")
	m2:command(1, "levelUp")
	check("攻守レベルを上げられる", m2.level[0] == 2)
	m2:command(1, "levelDown")
	check("攻守レベルを下げられる", m2.level[0] == 1)
end

print("== 協力 (同じチームに複数人) ==")
do
	local m = Match.new({ random = lcg(61), seats = { { id = 11, team = 0 }, { id = 12, team = 0 }, { id = 13, team = 0 } } })
	local a, b, c = m:seat(11), m:seat(12), m:seat(13)
	check("3 人とも選手を持つ", a.ctrl and b.ctrl and c.ctrl and true or false)
	check("操作する選手が重ならない", a.ctrl ~= b.ctrl and b.ctrl ~= c.ctrl and a.ctrl ~= c.ctrl)
	check("相手は CPU", m:isCpuTeam(1) and not m:isCpuTeam(0))
	clearOpponents(m)
	giveBall(m, a, { x = 0, y = 0 })
	b.ctrl.p = { x = 15, y = 0 }
	m:setAim(11, 1, 0)
	hold(m, 11, "pass", 0.4)
	check("味方の操作者へのパス", m.ball.target == b.ctrl)
	local bc = b.ctrl
	for _ = 1, 60 do
		m:update(1 / 30)
		if m.ball.owner ~= nil then
			break
		end
	end
	check("受けた操作者の操作のまま", m.ball.owner == bc and bc.seat == b)
	check("出し手の操作者は奪わない", a.ctrl ~= bc)
	local unique = {}
	local dup = false
	for _ = 1, 30 * 20 do
		m:update(1 / 30)
		unique = {}
		for _, s in m.seats do
			if s.ctrl ~= nil then
				if unique[s.ctrl] then
					dup = true
				end
				unique[s.ctrl] = true
			end
		end
	end
	check("20 秒間、操作する選手が重ならない", not dup)
	m:removeSeat(12)
	check("抜けた操作者の選手は AI に戻る", bc.seat == nil and #m.seats == 2)
end

print("== 対戦 (両チームに人) ==")
do
	local m = Match.new({ random = lcg(71), seats = { { id = 1, team = 0 }, { id = 2, team = 1 } } })
	check("両チームとも人間 (CPU 難易度は掛からない)", not m:isCpuTeam(0) and not m:isCpuTeam(1))
	local s2 = m:seat(2)
	check("AWAY の操作者も選手を持つ", s2.ctrl ~= nil and s2.ctrl.team == 1)
	local away = s2.ctrl
	m:gainBall(away)
	away.p = { x = 10, y = 0 }
	for _, q in m.teams[0] do
		q.p = { x = 45, y = q.p.y }
	end
	m:setAim(2, -1, 0)
	m:setMove(2, -1, 0)
	step(m, 20)
	check("AWAY は -x へ攻められる", away.p.x < 10 - 2, away.p.x)
	hold(m, 2, "shoot", 0.5)
	check("AWAY のシュートは -x のゴールへ", m.ball.kind == "shot" and m.ball.v.x < 0)
	local r = Match.new({ random = lcg(72), length = 60, seats = { { id = 1, team = 0 }, { id = 2, team = 1 } } })
	runUntilEnd(r, 20000)
	check("対戦でも放置で最後まで進む", r.ended)
end

print("== セットプレー ==")
do
	local m = Match.new({ random = lcg(81) })
	local s = m:seat(1)
	m.ball.owner, m.ball.last = nil, m.teams[1][8]
	m.ball.p = { x = 10, y = 34.0 }
	m.ball.v = { x = 0, y = 6 }
	m:update(1 / 30)
	check("タッチラインを出たらスローイン", m.setp ~= nil and m.setp.kind == "throw")
	check("人間のチームのスローは操作者が蹴る", m.setp.team == 0 and s.ctrl == m.setp.taker)
	m:setAim(1, 0, -1)
	hold(m, 1, "pass", 0.3)
	check("スローインを投げられる", m.setp == nil and m.ball.owner == nil)

	local m2 = Match.new({ random = lcg(82) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[1][8]
	m2.ball.p = { x = 52.5, y = 20 }
	m2.ball.v = { x = 6, y = 0 }
	m2:update(1 / 30)
	check("相手が出したらコーナー", m2.setp ~= nil and m2.setp.kind == "corner" and m2.setp.team == 0)
	m2:setAim(1, -1, -0.6)
	m2:press(1, "lofted")
	step(m2, 10)
	m2:flick(1, 1, 0) -- カーブ
	m2:release(1, "lofted")
	check("コーナーを浮き球で蹴る", m2.ball.kind == "lofted")

	-- PK: 人間のキーパーは左スティックの向きに跳ぶ
	local m3 = Match.new({ random = lcg(83) })
	local s3 = m3:seat(1)
	m3:startSetpiece("pk", 1, { x = -(52.5 - 11), y = 0 }, "setp.pk")
	m3:setMove(1, 0, -1)
	local gk = m3:slot(0, 0)
	for _ = 1, 60 do
		m3:update(1 / 30)
		if gk.dive ~= nil then
			break
		end
	end
	check("相手の PK で GK が入力した側へ跳ぶ", gk.dive ~= nil and gk.dive.y < 0, gk.dive and gk.dive.y)

	-- 放置したセットプレーは代わりに蹴る
	local m4 = Match.new({ random = lcg(84) })
	m4:startSetpiece("fk", 0, { x = 0, y = 0 }, "popup.foul_fk")
	step(m4, 30 * (Config.Controls.SetpieceAutoTake + 1))
	check("放置したセットプレーは自動で蹴る", m4.setp == nil)
end

print("== ゴール ==")
do
	local m = Match.new({ random = lcg(91) })
	m.ball.owner, m.ball.last = nil, m.teams[0][10]
	m.ball.p = { x = 52.5, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	m:update(1 / 30)
	check("ゴールで HOME に 1 点", m.score[0] == 1)
	check("得点後は AWAY のキックオフ", m.ball.owner ~= nil and m.ball.owner.team == 1)
	check("GOAL の表示 (得したチームつき)", #m.popups >= 1 and m.popups[1].key == "popup.goal" and m.popups[1].team == 0)
	local m2 = Match.new({ random = lcg(92) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[0][10]
	m2.ball.p = { x = 52.5, y = 0 }
	m2.ball.v = { x = 8, y = 0 }
	m2.ball.z = 3.5
	m2:update(1 / 30)
	check("バーの上を越えたらゴールではない", m2.score[0] == 0)
end

print("== 前後半・ハーフタイム ==")
do
	local m = Match.new(cpuOpts(101, { length = 60 }))
	local sawHalftime, flipDuring = false, nil
	local n = 0
	while not m.ended and n < 20000 do
		m:update(1 / 30)
		n += 1
		if m.mode == "halftime" then
			sawHalftime = true
		end
		if m.elapsed > 45 and flipDuring == nil and m.mode == "play" then
			flipDuring = m.flip
		end
	end
	check("ハーフタイムが入る", sawHalftime)
	check("後半はサイドが入れ替わる", flipDuring == true)
	check("規定時間で終了する", m.ended and m.elapsed >= 60 - 0.1)
	local g = Match.new(cpuOpts(103, { length = 60 }))
	g.flip = true
	g.ball.owner, g.ball.last = nil, g.teams[0][10]
	g.ball.p = { x = -52.5, y = 0 }
	g.ball.v = { x = -8, y = 0 }
	g.ball.z = 0.5
	g:update(1 / 30)
	check("ゴール判定がサイドに追従", g.score[0] == 1)
end

print("== スタミナ・能力・フォーメーション・難易度 ==")
do
	local m = Match.new({ random = lcg(7) })
	clearOpponents(m)
	local s = m:seat(1)
	local c = s.ctrl
	m:setMove(1, 1, 0)
	m:press(1, "dash")
	step(m, 90)
	check("ダッシュでスタミナが減る", c.stamina < Config.Stamina.Max - 5, c.stamina)
	c.stamina, c.exhausted = 0, true
	check("スタミナ切れは速度が落ちる", m:speedMult(c) < c.attr.speed * 0.9)
	m:release(1, "dash")

	local a = Match.new({ random = lcg(55) })
	check("ST はシュートが上手い", a.teams[0][10].attr.shoot > a.teams[0][3].attr.shoot)
	for _, key in Config.FormationOrder do
		local f = Match.new({ random = lcg(9), formation = { [0] = key, [1] = key } })
		check(key .. " は 11 人", #f.teams[0] == 11)
	end
	local easy = Match.new({ random = lcg(1), difficulty = 1 })
	local hard = Match.new({ random = lcg(1), difficulty = 5 })
	check("難しいほど CPU が速い", hard:teamSpeed(1) > easy:teamSpeed(1))
	check("人間のチームには掛からない", hard:teamSpeed(0) == 1)
end

print("== カード・退場 ==")
do
	local m = Match.new({ random = lcg(31) })
	local p = m.teams[1][3]
	m:showCard(p, "yellow")
	check("イエローが数えられる", m.tstats[1].yellow == 1 and not p.out)
	local q = m.teams[1][4]
	m:showCard(q, "red")
	check("レッドで退場する", q.out == true and #m:active(1) == 10)
	local s = m:seat(1)
	local mine = s.ctrl
	m:sendOff(mine)
	check("操作中の選手が退場したら別の選手に移る", s.ctrl ~= nil and s.ctrl ~= mine and not s.ctrl.out)
	local gk = m.teams[0][1]
	m:sendOff(gk)
	check("GK 退場後は別の選手がキーパー", m:slot(0, 0) ~= gk and m:slot(0, 0).gk)
	runUntilEnd(m, 12000)
	check("退場者がいても試合が進む", m.ended)
end

print("== 延長戦・PK 戦 ==")
do
	local m = Match.new({ random = lcg(2), cup = true })
	m.shoot = { goals = { [0] = 3, [1] = 0 }, taken = { [0] = 3, [1] = 3 } }
	check("残り 2 本で 3 点差なら勝ち", m:shootWinner() == 0)
	m.shoot = { goals = { [0] = 4, [1] = 4 }, taken = { [0] = 5, [1] = 5 } }
	check("5 本で同点ならサドンデス", m:shootWinner() == nil)
	m.shoot = { goals = { [0] = 5, [1] = 4 }, taken = { [0] = 6, [1] = 5 } }
	check("サドンデスは同数を蹴るまで決めない", m:shootWinner() == nil)
	m.shoot = { goals = { [0] = 5, [1] = 4 }, taken = { [0] = 6, [1] = 6 } }
	check("サドンデスで差がつけば決着", m:shootWinner() == 0)
	local found, ended = 0, 0
	for seed = 1, 40 do
		local c = Match.new(cpuOpts(seed * 13, { length = 40, cup = true }))
		runUntilEnd(c, 60000)
		if c.result and c.result.shootout then
			found += 1
			if c.result.winner ~= nil then
				ended += 1
			end
		end
		if found >= 2 then
			break
		end
	end
	check("引き分けの試合が PK 戦まで進む", found >= 1, found)
	check("PK 戦で勝者が決まる", ended == found and found >= 1)
end

print("== ゴールリプレイ ==")
do
	local m = Match.new({ random = lcg(61) })
	step(m, 150)
	check("リプレイ用の記録がたまる", #m.rec >= 10)
	m.setp = nil -- 途中でセットプレーになっていても、ゴールの判定を試せるように
	m.ball.owner, m.ball.last = nil, m.teams[0][10]
	m.ball.p = { x = 52.5, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	m:update(1 / 30)
	check("ゴール後はリプレイ", m.mode == "replay")
	local before = m.elapsed
	step(m, 10)
	check("リプレイ中は時間が進まない", m.elapsed == before)
	m:press(1, "pass")
	m:release(1, "pass")
	check("キックボタンでスキップ", m.mode == "play")
end

print("== キーパー ==")
do
	local m = Match.new({ random = lcg(81), difficulty = 5 })
	local c = m.teams[0][10]
	c.p = { x = 35, y = 0 }
	m.ball.owner = c
	m:kick("shot", { c = c, power = 0.8, aimY = 1.5 })
	check("枠内のシュートで GK がダイブ", m:slot(1, 0).dive ~= nil)
	local m2 = Match.new({ random = lcg(82) })
	local c2 = m2.teams[0][10]
	c2.p = { x = 35, y = 0 }
	m2.ball.owner = c2
	m2:kick("shot", { c = c2, power = 0.8, aimY = 9 })
	check("枠外には反応しない", m2:slot(1, 0).dive == nil)
end

print("== スタッツ ==")
do
	local m = Match.new(cpuOpts(91, { length = 90 }))
	runUntilEnd(m)
	local r = m.result
	check("支配率が 0〜100", r.possession >= 0 and r.possession <= 100)
	check("シュート数 ≧ 枠内数", r.stats[0].shots >= r.stats[0].onTarget)
	check("結果に設定が入る", r.difficulty == 3 and r.formation == "433" and r.length == 90)
end

print("== 報酬 ==")
do
	local function sess(len, diff)
		return { length = len, difficulty = diff, cup = false }
	end
	local win = Rewards.sanitize({ home = 2, away = 0, winner = 0 })
	local c, parts = Rewards.compute(sess(300, 3), win, false)
	check("勝利 + 2 点 + 無失点", c == Config.Rewards.Base + Config.Rewards.Win + 2 * Config.Rewards.PerGoal + Config.Rewards.CleanSheet, c)
	check("内訳に無失点が入る", parts.cleanSheet == Config.Rewards.CleanSheet)
	check("敗戦でも基本報酬", Rewards.compute(sess(300, 3), Rewards.sanitize({ home = 0, away = 3, winner = 1 }), false) == Config.Rewards.Base)
	check("難しいほど多い", Rewards.compute(sess(300, 5), win, false) > Rewards.compute(sess(300, 1), win, false))
	local huge = Rewards.sanitize({ home = 9999, away = 0, winner = 0 })
	check("申告は丸められる", huge.home == 30)
	check("上限を超えない", Rewards.compute(sess(600, 5), huge, false) <= Config.Rewards.Max)
	check("VIP は 2 倍", Rewards.compute(sess(300, 3), win, true) == c * Config.Monetization.VipCoinMultiplier)
	local nan = Rewards.sanitize({ home = 0 / 0, away = -5, winner = 7 })
	check("NaN・負数・範囲外を弾く", nan.home == 0 and nan.away == 0 and nan.winner == nil)
	check("選べる試合時間の検証", Rewards.isValidLength(300) and not Rewards.isValidLength(7))
end

print("== 課金設定 ==")
do
	local zero = {}
	for k, d in Config.Monetization.Passes do
		if d.id == 0 then
			table.insert(zero, k)
		end
	end
	for k, d in Config.Monetization.Products do
		if d.id == 0 then
			table.insert(zero, k)
		end
	end
	check("全ての商品に ID が入っている", #zero == 0, table.concat(zero, ","))
	check("既定のキットは無料", Config.Kits[1].price == 0 and not Config.Kits[1].vip)
end

print("== オンライン同期 (Snapshot) ==")
do
	local m = Match.new({ random = lcg(201), seats = { { id = 1001, team = 0 }, { id = 2002, team = 1 } } })
	step(m, 60)
	m:press(1001, "pass")
	step(m, 5)
	local str = Snapshot.encode(m, 0)
	check("1 回の送信が 400 バイト未満", #str < 400, #str)
	local d = Snapshot.decode(str)
	local maxErr = 0
	for i, p in m.pl do
		maxErr = math.max(maxErr, math.abs(d.pl[i].x - p.p.x), math.abs(d.pl[i].y - p.p.y))
	end
	check("選手の位置が 2cm 以内で復元できる", maxErr < 0.02, maxErr)
	check("ボールの位置", math.abs(d.ball.x - m.ball.p.x) < 0.02 and math.abs(d.ball.y - m.ball.p.y) < 0.02)
	check("スコア・時間", d.score[0] == m.score[0] and math.abs(d.elapsed - m.elapsed) < 0.01)
	check("操作者 (UserId) と操作中の選手", #d.seats == 2 and d.seats[1].id == 1001 and m.pl[d.seats[1].ctrl] == m:seat(1001).ctrl)
	check("溜め中の種類とパワー", d.seats[1].kind == "pass" and d.seats[1].power > 0.1)
	check("向きの復元", math.abs(d.pl[10].fx - m.pl[10].face.x) < 0.05)
	local _, seq = Snapshot.encode(m, 0)
	m:popup("popup.goal", 0)
	local d2 = Snapshot.decode((Snapshot.encode(m, seq)))
	check("新しいポップアップだけを送る", #d2.popups == 1 and d2.popups[1].key == "popup.goal" and d2.popups[1].team == 0)

	-- 入力
	local packed = Snapshot.packInput({ move = { x = 0.5, y = -1 }, aim = { x = 0.6, y = 0.8 }, buttons = { pass = true, l1 = true }, flick = nil, cmd = "levelUp" })
	local inp = Snapshot.unpackInput(packed)
	check("入力の往復 (移動・狙い・ボタン・コマンド)", inp and math.abs(inp.move.x - 0.5) < 0.01 and inp.aim and math.abs(inp.aim.y - 0.8) < 0.01 and inp.buttons.pass and inp.buttons.l1 and not inp.buttons.shoot and inp.cmd == "levelUp")
	check("壊れた入力は捨てる", Snapshot.unpackInput("x") == nil and Snapshot.unpackInput(nil) == nil)
	-- サーバー側の適用: 押す → 離す でパスが出る
	local mm = Match.new({ random = lcg(202), seats = { { id = 7, team = 0 } } })
	clearOpponents(mm)
	local prev = {}
	prev = Snapshot.applyInput(mm, 7, { move = { x = 0, y = 0 }, aim = { x = 1, y = 0 }, buttons = { pass = true } }, prev)
	step(mm, 10)
	prev = Snapshot.applyInput(mm, 7, { move = { x = 0, y = 0 }, aim = { x = 1, y = 0 }, buttons = {} }, prev)
	check("サーバーで適用した入力でパスが出る", mm.ball.owner == nil and mm.ball.kind == "pass")
end

print("== マウスで地点を指す ==")
do
	-- 横 (100°) にいる味方を指すと、その味方へ (スティックの補助の角度外でも)
	local m = Match.new({ random = lcg(301), assist = 1 })
	clearOpponents(m)
	local s = m:seat(1)
	local p = giveBall(m, s, { x = 0, y = 0 })
	for _, q in m:active(0) do
		if q ~= p and not q.gk then
			q.p = { x = 100, y = 100 }
		end
	end
	local mate = m.teams[0][7]
	mate.p = { x = -3, y = 15 }
	m:setMove(1, 1, 0)
	m:setAimPoint(1, -3, 15)
	m:press(1, "pass")
	step(m, 6)
	check("指した味方がプレビューに出る", m:previewReceiver(s) == mate)
	m:release(1, "pass")
	check("指した味方へパス (走る向きと関係ない)", m.ball.target == mate)
	check("ボールが指した方向へ", m.ball.v.y > 0 and math.abs(m.ball.v.x) < m.ball.v.y)

	-- 空いたスペースを指してスルー: そこへ出し、一番近い味方が走り込む
	local m2 = Match.new({ random = lcg(302), assist = 1 })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	giveBall(m2, s2, { x = 0, y = 0 })
	local runner = m2.teams[0][9] -- LW
	runner.p = { x = 10, y = -15 }
	m2:setAimPoint(1, 25, -18)
	hold(m2, 1, "through", 0.4)
	local dir = math.deg(math.atan2(m2.ball.v.y, m2.ball.v.x))
	local want = math.deg(math.atan2(-18, 25))
	check("スペースへのスルーは指した地点の方向へ", angDiff(dir, want) < 8, dir .. " vs " .. want)
	check("近い味方が受け手 (走り込む)", m2.ball.target == runner)
	local reached = false
	for _ = 1, 30 * 4 do
		m2:update(1 / 30)
		if m2.ball.owner == runner then
			reached = true
			break
		end
	end
	check("走り込んだ味方が受ける", reached)

	-- 何もない所へのパスは、指した距離の近くまで転がる
	local m3 = Match.new({ random = lcg(303), assist = 1 })
	clearOpponents(m3)
	local s3 = m3:seat(1)
	for _, q in m3:active(0) do
		if q ~= s3.ctrl then
			q.p = { x = -40, y = q.p.y }
		end
	end
	giveBall(m3, s3, { x = 0, y = 0 })
	m3:setAimPoint(1, 0, 20)
	hold(m3, 1, "pass", 0.45)
	local v = math.sqrt(m3.ball.v.x ^ 2 + m3.ball.v.y ^ 2)
	local rollDist = v * v / (2 * Config.Physics.Friction)
	check("指した距離 (20m) の近くまで転がる", rollDist > 13 and rollDist < 32, rollDist)

	-- シュートはゴールの指した位置へ
	local function shotY(py)
		local mm = Match.new({ random = lcg(304) })
		clearOpponents(mm)
		local ss = mm:seat(1)
		giveBall(mm, ss, { x = 35, y = 0 })
		mm:setAimPoint(1, 52.5, py)
		hold(mm, 1, "shoot", 0.3)
		return mm.ball.v.y / mm.ball.v.x * 17.5
	end
	local up, down = 0, 0
	for _ = 1, 5 do
		up += shotY(3)
		down += shotY(-3)
	end
	check("指した側の隅にシュート", up / 5 > 1.5 and down / 5 < -1.5, up / 5 .. " / " .. down / 5)

	-- 守備の Q: マウスに一番近い味方へ切り替え
	local m4 = Match.new({ random = lcg(305) })
	local s4 = m4:seat(1)
	m4:gainBall(m4.teams[1][8])
	local far = m4.teams[0][5] -- RB
	far.p = { x = -30, y = 25 }
	m4:setAimPoint(1, -30, 24)
	m4:press(1, "l1")
	check("Q でマウスに近い味方へ切替", s4.ctrl == far, s4.ctrl and s4.ctrl.role)

	-- 同期: 地点も送れる
	local packed = Snapshot.packInput({ move = { x = 0, y = 0 }, point = { x = -31.4, y = 12.6 }, buttons = { through = true } })
	local inp = Snapshot.unpackInput(packed)
	check("地点の往復 (10cm 単位)", inp and inp.point and math.abs(inp.point.x + 31.4) < 0.06 and math.abs(inp.point.y - 12.6) < 0.06 and inp.buttons.through)
end

print("== 操作の割り当て ==")
do
	local d = Bindings.default()
	check("既定はマウス中心", d.preset == "mouse" and d.kb.pass[1] == "MouseButton1" and d.kb.shoot[1] == "MouseButton2")
	check("全ての操作に既定のキーがある", (function()
		for _, a in Bindings.ACTIONS do
			if #d.kb[a.id] == 0 then
				return false
			end
		end
		return true
	end)())
	-- 各プリセットでキーが重ならない
	for name in Bindings.PRESETS do
		local b = Bindings.fromPreset(name)
		local seen, dup = {}, nil
		for a, list in b.kb do
			for _, k in list do
				if seen[k] then
					dup = k .. " (" .. seen[k] .. " / " .. a .. ")"
				end
				seen[k] = a
			end
		end
		check(name .. " プリセットでキーが重ならない", dup == nil, dup)
	end
	local k = Bindings.fromPreset("keys")
	check("キーボードのみ: K=パス I=スルー L=浮き球 J=シュート", k.kb.pass[1] == "K" and k.kb.through[1] == "I" and k.kb.lofted[1] == "L" and k.kb.shoot[1] == "J")
	-- 変更: 他の操作に使われていたキーは、そちらから外す
	local b2, removed = Bindings.assign(d, "kb", "pass", 1, "Space")
	check("割り当てを変えられる", b2.kb.pass[1] == "Space")
	check("重なったキーは元の操作から外す", removed == "through" and b2.kb.through[1] ~= "Space", removed)
	check("変えたらカスタム扱い", b2.preset == "custom")
	local b3 = Bindings.assign(b2, "kb", "pass", 2, nil)
	check("キーを外せる", #b3.kb.pass == 1)
	local b4 = Bindings.assign(b3, "kb", "pass", 1, "Slash")
	check("チャットの / は割り当てられない", b4.kb.pass[1] == "Space")
	local b5 = Bindings.assign(d, "pad", "shoot", 1, "ButtonR1")
	check("ゲームパッドも変えられる (重なりは外す)", b5.pad.shoot[1] == "ButtonR1" and #b5.pad.r1 == 0)
	-- 検証: 壊れた / 悪意のあるデータ
	local v = Bindings.validate({ kb = { pass = { "K", "K", "Escape", "J", "X" }, evil = { "A" } }, pad = { pass = { "ButtonA", "ButtonB" } } })
	check("重複・禁止キー・数の超過を捨てる", #v.kb.pass == 2 and v.kb.pass[1] == "K" and v.kb.pass[2] == "J" and v.kb.evil == nil and #v.pad.pass == 1, #v.kb.pass)
	check("壊れた値は既定値", Bindings.validate("x").preset == "mouse" and Bindings.validate(nil).kb.pass[1] == "MouseButton1")
	local L = Bindings.lookup(d)
	check("引き当て: キー → 操作", L.kb.MouseButton1 == "pass" and L.kb.W == "moveUp" and L.pad.ButtonA == "pass")
	check("表記", Bindings.label(d, "kb", "pass") == "L-Click / K" and Bindings.display("DPadUp") == "D-Pad ↑")
	local labels = 0
	for _, a in Bindings.ACTIONS do
		if Locale.Tables.ja["action." .. a.id] and Locale.Tables.en["action." .. a.id] then
			labels += 1
		end
	end
	check("全ての操作に日英の名前", labels == #Bindings.ACTIONS, labels)
end

print("== 守備のプレス (CPU) ==")
do
	-- AWAY の人間がボールを持って止まっている。HOME の CPU が寄せる
	local m = Match.new({ random = lcg(401), seats = { { id = 2, team = 1 } } })
	local s = m:seat(2)
	local carrier = s.ctrl
	m:gainBall(carrier)
	carrier.p = { x = 10, y = 0 }
	carrier.cd = 0
	for _, q in m.teams[0] do
		q.cd = 0
	end
	m:setMove(2, 0, 0)
	m.lastInputT = nil
	s.lastInputT = m.elapsed -- 人間が持っている (AI に任せない)
	local goalSide, close, overlap, frames = 0, 0, 0, 0
	local stolen = false
	for i = 1, 30 * 12 do
		s.lastInputT = m.elapsed
		m:update(1 / 30)
		if m.ball.owner ~= carrier then
			stolen = true
			break
		end
		carrier.p = { x = 10, y = 0 }
		carrier.v = { x = 0, y = 0 }
		local pr = m.presser[0]
		if i > 45 and pr ~= nil then
			frames += 1
			-- HOME は -x のゴールを守る: 寄せ役が保持者よりゴール側 (x が小さい) にいるか
			if pr.p.x < carrier.p.x + 0.3 then
				goalSide += 1
			end
			local d = math.sqrt((pr.p.x - carrier.p.x) ^ 2 + (pr.p.y - carrier.p.y) ^ 2)
			if d < 5 then
				close += 1
			end
			if d < 0.5 then
				overlap += 1
			end
		end
	end
	check("寄せ役はゴール側から構える", frames == 0 or goalSide / frames > 0.8, goalSide .. "/" .. frames)
	check("間合いを保って近くにいる", frames == 0 or close / frames > 0.7, close .. "/" .. frames)
	check("相手の上に重ならない", overlap <= frames * 0.1, overlap .. "/" .. frames)
	check("止まって持っていると、そのうち踏み込んで奪う (12 秒)", stolen)
	local pr = m.presser[0]
	check("寄せ役は保持者の方を向く", stolen or (pr ~= nil and (carrier.p.x - pr.p.x) * pr.face.x + (carrier.p.y - pr.p.y) * pr.face.y > 0))

	-- 背後から追わない: 保持者より前 (相手ゴール側) にいる選手は寄せ役にしない
	local m2 = Match.new({ random = lcg(402), ctrlKind = { [0] = "cpu", [1] = "cpu" } })
	local c2 = m2.teams[1][10]
	m2:gainBall(c2)
	c2.p = { x = 0, y = 0 }
	local behind = m2.teams[0][10] -- HOME の ST を保持者のすぐ背後 (+x 側) に
	behind.p = { x = 1.5, y = 0 }
	local front = m2.teams[0][6] -- HOME の DM を保持者のゴール側 4m に
	front.p = { x = -4, y = 0 }
	m2:update(1 / 30)
	check("背後の選手より、ゴール側の選手が寄せる", m2.presser[0] == front, m2.presser[0] and m2.presser[0].role)
end

print("== 指の割り当て (マウス中心の配置) ==")
do
	local b = Bindings.fromPreset("mouse")
	-- 試合中に使う操作は、全部「左手 (WASD に置いたまま届くキー)」か「マウス」で押せる
	local inPlay = { "moveUp", "moveDown", "moveLeft", "moveRight", "dash", "pass", "shoot", "through", "lofted", "l1", "r1", "l2", "levelUp", "levelDown" }
	local bad = {}
	for _, a in inPlay do
		local k = b.kb[a][1]
		if Bindings.fingerOf(k) == nil then
			table.insert(bad, a .. "=" .. tostring(k))
		end
	end
	check("試合中の操作は全部、左手かマウスで押せる (右手をマウスから離さない)", #bad == 0, table.concat(bad, ","))
	check("パス = 右人差し指 / シュート = 右中指", Bindings.fingerOf(b.kb.pass[1]) == "rindex" and Bindings.fingerOf(b.kb.shoot[1]) == "rmiddle")
	check("ダッシュ = 左小指 / スルー = 左親指", Bindings.fingerOf(b.kb.dash[1]) == "pinky" and Bindings.fingerOf(b.kb.through[1]) == "thumb")
	-- 移動しながら押すので、移動キー (WASD) と同じ指に、よく使う操作を重ねない
	local moveFingers = {}
	for _, a in { "moveUp", "moveDown", "moveLeft" } do
		moveFingers[Bindings.fingerOf(b.kb[a][1])] = true
	end
	local clash = {}
	for _, a in { "dash", "pass", "shoot", "through" } do
		if moveFingers[Bindings.fingerOf(b.kb[a][1])] then
			table.insert(clash, a)
		end
	end
	check("よく使う操作は移動の指 (薬指・中指) と重ならない", #clash == 0, table.concat(clash, ","))
	for _, f in Bindings.FINGER_ORDER do
		check("指の名前 (日英): " .. f, Locale.Tables.ja["finger." .. f] ~= nil and Locale.Tables.en["finger." .. f] ~= nil)
	end
end

print("== 効果音イベントに蹴った選手 ==")
do
	local m = Match.new({ random = lcg(501) })
	local s = m:seat(1)
	clearOpponents(m)
	local p = giveBall(m, s, { x = 0, y = 0 })
	m.events = {}
	m:setAim(1, 1, 0)
	hold(m, 1, "pass", 0.3)
	local found = nil
	for _, e in m.events do
		if e.kind == "kick" then
			found = e.player
		end
	end
	check("kick イベントに蹴った選手が入る", found == p)
	local str = Snapshot.encode(m, 0)
	local d = Snapshot.decode(str)
	local idx = nil
	for _, e in d.events do
		if e.kind == "kick" then
			idx = e.index
		end
	end
	check("オンラインでも蹴った選手が分かる", idx ~= nil and m.pl[idx] == p, idx)
end

print("== 動作のイベント (アニメーション用) ==")
do
	local function kickTag(setup)
		local m = Match.new({ random = lcg(601) })
		clearOpponents(m)
		local s = m:seat(1)
		giveBall(m, s, { x = 30, y = 0 })
		m.events = {}
		setup(m)
		for _, e in m.events do
			if e.kind == "kick" then
				return e.tag
			end
		end
		return nil
	end
	check("パス = pass", kickTag(function(m)
		m:setAim(1, 1, 0)
		hold(m, 1, "pass", 0.2)
	end) == "pass")
	check("スルー = through", kickTag(function(m)
		m:setAim(1, 1, 0)
		hold(m, 1, "through", 0.2)
	end) == "through")
	check("浮き球 = lofted", kickTag(function(m)
		m:setAim(1, 1, 0)
		hold(m, 1, "lofted", 0.2)
	end) == "lofted")
	check("シュート = shot", kickTag(function(m)
		m:setAim(1, 1, 0)
		hold(m, 1, "shoot", 0.2)
	end) == "shot")
	check("L1 + シュート = loop", kickTag(function(m)
		m:setAim(1, 1, 0)
		m:press(1, "l1")
		hold(m, 1, "shoot", 0.2)
	end) == "loop")
	-- スローイン
	local m = Match.new({ random = lcg(602) })
	m.ball.owner, m.ball.last = nil, m.teams[1][8]
	m.ball.p = { x = 10, y = 34.0 }
	m.ball.v = { x = 0, y = 6 }
	m:update(1 / 30)
	m.events = {}
	m:setAim(1, 0, -1)
	hold(m, 1, "pass", 0.3)
	local throwTag = nil
	for _, e in m.events do
		if e.kind == "kick" then
			throwTag = e.tag
		end
	end
	check("スローイン = throw", throwTag == "throw", throwTag)
	-- トラップ
	local m2 = Match.new({ random = lcg(603), assist = 2 })
	clearOpponents(m2)
	local s2 = m2:seat(1)
	giveBall(m2, s2, { x = 0, y = 0 })
	m2.teams[0][7].p = { x = 10, y = 0 }
	m2:setAim(1, 1, 0)
	hold(m2, 1, "pass", 0.3)
	local trapped = false
	for _ = 1, 60 do
		m2.events = {}
		m2:update(1 / 30)
		for _, e in m2.events do
			if e.kind == "trap" and e.player ~= nil then
				trapped = true
			end
		end
		if trapped then
			break
		end
	end
	check("受けた選手のトラップ", trapped)
	-- 技の進み具合を同期
	local m3 = Match.new({ random = lcg(604) })
	clearOpponents(m3)
	local s3 = m3:seat(1)
	local p3 = giveBall(m3, s3)
	m3:startSkill(p3, "marseille", { x = 1, y = 0 }, { x = 0, y = 1 })
	step(m3, 6)
	local d = Snapshot.decode((Snapshot.encode(m3, 0)))
	local idx
	for i, p in m3.pl do
		if p == p3 then
			idx = i
		end
	end
	local want = (m3.elapsed - p3.skill.t0) / p3.skill.dur
	check("技の種類と進み具合を同期", d.pl[idx].skillName == "marseille" and math.abs(d.pl[idx].skillU - want) < 0.02, d.pl[idx].skillU)
	check("1 回の送信が 400 バイト未満 (技の情報を足しても)", #Snapshot.encode(m3, 0) < 400, #Snapshot.encode(m3, 0))
end

print("== セットプレーの配置 ==")
do
	local function inBox(p, goalSign)
		return goalSign * p.p.x > 52.5 - 16.5 and math.abs(p.p.y) < 40.3 / 2
	end
	--- セットプレーが蹴られる直前まで進め、その時の状態を f で調べる
	local function untilKick(m, maxSec, f)
		local last = nil
		for _ = 1, math.floor(maxSec * 30) do
			if m.setp == nil then
				break
			end
			last = f(m)
			m:update(1 / 30)
		end
		return last
	end
	-- コーナー: HOME の攻撃 (+x のゴール)。キックオフの配置から (遠い所から集まる)
	local m = Match.new(cpuOpts(701))
	m:startSetpiece("corner", 0, { x = 52, y = 33.5 }, "setp.corner")
	step(m, 30 * 1)
	check("コーナーはすぐには蹴らない (配置を待つ)", m.setp ~= nil)
	local res = untilKick(m, 9, function(mm)
		local att, def, near = 0, 0, math.huge
		for _, p in mm:active(0) do
			if not p.gk and p ~= mm.setp.taker and inBox(p, 1) then
				att += 1
			end
		end
		for _, p in mm:active(1) do
			if not p.gk and inBox(p, 1) then
				def += 1
			end
			near = math.min(near, math.sqrt((p.p.x - 52) ^ 2 + (p.p.y - 33.5) ^ 2))
		end
		return { att = att, def = def, near = near, gk = mm:slot(1, 0).p.x, t = mm.elapsed }
	end)
	check("コーナーで攻撃側がゴール前に 4 人以上", res.att >= 4, res.att)
	check("守備側もゴール前でマーク (4 人以上)", res.def >= 4, res.def)
	check("相手 GK はゴールライン上", res.gk > 50, res.gk)
	check("守備側はボールから 9.15m 離れる", res.near > 8.5, res.near)
	check("配置がそろったら蹴る (上限 7 秒以内)", m.setp == nil and res.t < 8, res.t)

	-- ゴール前の FK: 壁
	local m2 = Match.new(cpuOpts(702))
	for _, p in m2.pl do
		if not p.gk then
			p.p = { x = 52.5 - 30, y = p.p.y * 0.4 } -- ゴール前で起きたファウル
		end
	end
	m2:startSetpiece("fk", 0, { x = 52.5 - 22, y = 4 }, "popup.foul_fk")
	local wall = untilKick(m2, 8, function(mm)
		local w = 0
		for _, p in mm:active(1) do
			local d = math.sqrt((p.p.x - (52.5 - 22)) ^ 2 + (p.p.y - 4) ^ 2)
			if not p.gk and d > 8 and d < 10.5 and p.p.x > 52.5 - 22 then
				w += 1
			end
		end
		return w
	end)
	check("ゴール前の FK で 3 人以上の壁 (ボールから 9.15m、ゴール側)", wall >= 3, wall)

	-- スローイン: 近くに受け手
	local m3 = Match.new(cpuOpts(703))
	m3:startSetpiece("throw", 0, { x = 0, y = 33.7 }, "setp.throw")
	local helpers = untilKick(m3, 4, function(mm)
		local h = 0
		for _, p in mm:active(0) do
			if p ~= mm.setp.taker and math.sqrt(p.p.x ^ 2 + (p.p.y - 33.7) ^ 2) < 14 then
				h += 1
			end
		end
		return h
	end)
	check("スローインで受け手が寄る", helpers >= 1, helpers)

	-- ゴールキック: 相手はエリアの外
	local m4 = Match.new(cpuOpts(704))
	for _, p in m4.teams[1] do
		p.p = { x = -45, y = p.p.y * 0.3 }
	end
	m4:startSetpiece("gk", 0, { x = -52.5 + 5.5, y = 4 }, "setp.gk")
	local inside = untilKick(m4, 5, function(mm)
		local n = 0
		for _, p in mm:active(1) do
			if not p.gk and p.p.x < -52.5 + 16.5 and math.abs(p.p.y) < 40.3 / 2 then
				n += 1
			end
		end
		return n
	end)
	check("ゴールキックで相手はエリアの外へ出る", inside <= 1, inside)

	-- 人間のチームは配置を待たずに蹴ってもよい (クイックリスタート)
	local m5 = Match.new({ random = lcg(705) })
	m5:startSetpiece("fk", 0, { x = 0, y = 0 }, "popup.foul_fk")
	m5:setAim(1, 1, 0)
	hold(m5, 1, "pass", 0.2)
	check("人間はすぐに蹴れる", m5.setp == nil)
end

print("== 足技のコンビネーション (PC の 2 回押しの間隔) ==")
do
	local function skillAfter(flicks, gap)
		local m = Match.new({ random = lcg(801) })
		clearOpponents(m)
		local s = m:seat(1)
		local p = giveBall(m, s, { x = 0, y = 0 })
		p.face = { x = 1, y = 0 }
		p.v = { x = 0, y = 0 }
		local got = nil
		for i, f in flicks do
			m:flick(1, f[1], f[2])
			if i < #flicks then
				step(m, math.floor(gap * 30))
			end
		end
		for _ = 1, 20 do
			m:update(1 / 30)
			if p.skill ~= nil then
				got = p.skill.name
				break
			end
		end
		return got
	end
	-- 右向きでドリブル中: 横 = 上下、前 = 右、後ろ = 左
	check("横 1 回 = ダブルタッチ", skillAfter({ { 0, -1 } }, 0) == "double_touch")
	check("後ろ 1 回 = ドラッグバック", skillAfter({ { -1, 0 } }, 0) == "drag_back")
	check("横 → 反対の横 (0.25 秒間隔) = エラシコ", skillAfter({ { 0, -1 }, { 0, 1 } }, 0.25) == "elastico", skillAfter({ { 0, -1 }, { 0, 1 } }, 0.25))
	check("前 → 横 (0.25 秒間隔) = シザーズ", skillAfter({ { 1, 0 }, { 0, 1 } }, 0.25) == "scissors")
	check("前 → 後ろ → 横 (0.25 秒間隔) = マルセイユ", skillAfter({ { 1, 0 }, { -1, 0 }, { 0, 1 } }, 0.25) == "marseille")
end

print("== 練習モード ==")
do
	--- 練習を進める (結果待ちの間も含めて)。cond が真になるか maxSec で止める
	local function run(pr, maxSec, cond)
		for _ = 1, math.floor(maxSec * 30) do
			if cond and cond() then
				return true
			end
			pr:update(1 / 30)
		end
		return cond and cond() or false
	end
	local function ready(pr)
		return function()
			return pr.waitT == nil and pr.match.ball.owner ~= nil and pr.match.ball.owner == pr.seat.ctrl
		end
	end
	local function holdP(pr, btn, sec)
		pr.match:press(1, btn)
		run(pr, sec)
		pr.match:release(1, btn)
	end

	-- パス
	local pr = Practice.new("pass", { random = lcg(901), assist = 1 })
	check("パス練習: 味方 5 人と自分だけ", #pr.match:active(0) == 6 and #pr.match:active(1) == 1)
	check("最初の目標がある", pr.highlight ~= nil)
	for _ = 1, 12 do
		if pr.done then
			break
		end
		run(pr, 3, ready(pr))
		local me, tg = pr.seat.ctrl, pr.highlight
		pr.match:setAimPoint(1, tg.p.x, tg.p.y)
		holdP(pr, "pass", 0.25)
		run(pr, 4, function()
			return pr.match.ball.owner ~= nil
		end)
	end
	check("パス 10 本で完了", pr.done and pr.progress == 10, pr.progress)
	check("記録はタイム", pr.result ~= nil and pr.result > 0, pr.result)

	-- シュート
	local ps = Practice.new("shoot", { random = lcg(902) })
	check("シュート練習: 自分と GK だけ", #ps.match:active(0) == 1 and #ps.match:active(1) == 1)
	for i = 1, 10 do
		run(ps, 3, ready(ps))
		ps.match:setAimPoint(1, 52.5, (i % 2 == 0) and 3.2 or -3.2)
		holdP(ps, "shoot", 0.7)
		run(ps, 7, function()
			return ps.waitT ~= nil or ps.done
		end)
		run(ps, 2, function()
			return ps.waitT == nil
		end)
	end
	check("シュート 10 本で完了", ps.done and ps.progress == 10, ps.progress)
	check("隅を狙えば入る (10 本中 2 本以上)", ps.score >= 2, ps.score)

	-- 足技
	local pk = Practice.new("skills", { random = lcg(903) })
	local seqs = {
		{ { 0, -1 } },
		{ { 0, -1 }, { 0, 1 } },
		{ { 1, 0 }, { 0, 1 } },
		{ { 1, 0 }, { -1, 0 }, { 0, 1 } },
		{ { -1, 0 } },
	}
	for _, seq in seqs do
		run(pk, 3, ready(pk))
		local p = pk.seat.ctrl
		p.face = { x = 1, y = 0 }
		p.v = { x = 0, y = 0 }
		for i, f in seq do
			pk.match:flick(1, f[1], f[2])
			if i < #seq then
				run(pk, 0.25)
			end
		end
		run(pk, 1.5)
	end
	check("足技 5 種で完了", pk.done and pk.progress == 5, pk.progress)

	-- FK
	local pf = Practice.new("fk", { random = lcg(904) })
	check("FK 練習: 壁がいる", #pf.match:active(1) >= 5 and pf.match.setp ~= nil and pf.match.setp.kind == "fk")
	for i = 1, 5 do
		run(pf, 3, function()
			return pf.waitT == nil and pf.match.setp ~= nil
		end)
		pf.match:setAimPoint(1, 52.5, (i % 2 == 0) and 3 or -3)
		holdP(pf, "shoot", 0.6)
		run(pf, 8, function()
			return pf.waitT ~= nil or pf.done
		end)
		run(pf, 2, function()
			return pf.waitT == nil
		end)
	end
	check("FK 5 本で完了", pf.done and pf.progress == 5, pf.progress)

	-- 守備 (操作なし: AI の補助だけでも最後まで進む)
	local pd = Practice.new("defend", { random = lcg(905) })
	check("守備練習: 相手 2 人がボールを持って始まる", pd.match.ball.owner ~= nil and pd.match.ball.owner.team == 1)
	run(pd, 5 * 17, function()
		return pd.done
	end)
	check("守備 5 回で完了", pd.done and pd.progress == 5, pd.progress)

	-- フリー練習
	local pfree = Practice.new("free", { random = lcg(906), defenders = 3 })
	check("フリー練習: 味方 11 人 + 相手 4 人 (GK + 3)", #pfree.match:active(0) == 11 and #pfree.match:active(1) == 4)
	check("時間で終わらない", (function()
		run(pfree, 30)
		return not pfree.match.ended and pfree.match.mode == "play"
	end)())
	local m = pfree.match
	m.setp = nil
	m.ball.owner, m.ball.last = nil, m.teams[0][10]
	m.ball.p = { x = 52.5, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	pfree:update(1 / 30)
	check("ゴール後はボールが足元に戻る", m.ball.owner == pfree.seat.ctrl and m.ball.owner.team == 0)

	-- 自己ベスト
	check("自己ベストの比較 (タイムは短い方)", Practice.better("pass", 20, 25) and not Practice.better("pass", 30, 25))
	check("自己ベストの比較 (数は多い方)", Practice.better("shoot", 7, 5) and not Practice.better("shoot", 3, 5))
	check("初回は自己ベスト", Practice.better("fk", 1, nil))
end

print("== パスを出した選手は自分のパスを追わない ==")
do
	local m = Match.new(cpuOpts(951))
	clearOpponents(m)
	local c = m.teams[0][10]
	local r = m.teams[0][7]
	c.p = { x = 0, y = 0 }
	r.p = { x = 14, y = 10 }
	m:gainBall(c)
	m:kick("pass", { c = c, target = r })
	local chased = false
	for _ = 1, 30 do
		m:update(1 / 30)
		if m.chase[c] ~= nil then
			chased = true
		end
		if m.ball.owner ~= nil then
			break
		end
	end
	check("出し手は追わない", not chased)
	check("受け手が受ける", m.ball.owner == r, m.ball.owner and m.ball.owner.role)
end

print("== 本物のサッカーのルール ==")
do
	-- アディショナルタイムと上がっていく時計
	local m = Match.new(cpuOpts(4242, { length = 180 }))
	local m0 = m:clock()
	check("時計は 0 分から", m0 < 0.1, m0)
	local sawAdded, maxFirst = false, 0
	while m.bIndex == 1 and not m.ended do
		m:update(1 / 30)
		if m.added > 0 then
			sawAdded = true
		end
		if m.bIndex == 1 then
			maxFirst = math.max(maxFirst, (m:clock()))
		end
	end
	check("前半にアディショナルタイムが付く", sawAdded)
	check("前半は 45 分を過ぎてから終わる", maxFirst > 45, maxFirst)
	step(m, 30 * 6)
	local c2 = m:clock()
	check("後半は 45 分から", c2 >= 45 and c2 < 50, c2)

	-- 自動交代
	local subs = Match.new(cpuOpts(77, { length = 300 }))
	for _, p in subs:active(0) do
		if not p.gk then
			p.stamina = 20
		end
	end
	subs.elapsed = subs.nextSubCheck - 0.01
	subs:update(1 / 30)
	check("疲れた選手が交代する (1 回 2 人まで)", subs.subsUsed[0] == 2, subs.subsUsed[0])
	local fresh, nums = 0, {}
	for _, p in subs:active(0) do
		if not p.gk and p.stamina >= 99 then
			fresh += 1
			nums[p.num] = true
		end
	end
	check("交代した選手はスタミナ満タン・新しい背番号", fresh == 2 and nums[12] and nums[13])
	for _ = 1, 10 do
		subs:autoSubs(false)
	end
	check("交代は 5 人まで", subs.subsUsed[0] == 5, subs.subsUsed[0])

	-- キックオフ: 相手はセンターサークルの外
	local k = Match.new({ random = lcg(5) })
	k:kickoff(0)
	local inside = 0
	for _, q in k:active(1) do
		if math.sqrt(q.p.x ^ 2 + q.p.y ^ 2) < 9.15 then
			inside += 1
		end
	end
	check("キックオフ時、相手はセンターサークルの外", inside == 0, inside)

	-- CK からはオフサイドにならない
	local c = Match.new({ random = lcg(6) })
	local s = c:seat(1)
	c:startSetpiece("corner", 0, { x = 52, y = 33.5 }, "setp.corner")
	step(c, 30)
	local tgt = c.teams[0][10]
	for _, q in c.teams[1] do
		if not q.gk then
			q.p = { x = 20, y = q.p.y }
		end
	end
	tgt.p = { x = 50, y = 0 }
	c:setAimPoint(1, 50, 0)
	c:press(1, "lofted")
	step(c, 6)
	c:release(1, "lofted")
	check("CK のボールにオフサイドは付かない", c.ball.offside == nil)

	-- バックパスは GK が手で扱えない (手の届く距離が普通の選手と同じ)
	local g = Match.new({ random = lcg(8) })
	clearOpponents(g)
	local gk = g.teams[0][1]
	local mate = g.teams[0][3]
	gk.p = { x = -50, y = 0 }
	mate.p = { x = -40, y = 1.5 }
	g:gainBall(mate)
	g:kick("pass", { c = mate, target = gk })
	g.ball.p = { x = -48.5, y = 1.5 }
	g.ball.v = { x = -8, y = 0 }
	g.ball.z, g.ball.vz = 0, 0
	g:update(1 / 30)
	check("バックパスはキャッチできない距離 (1.5 m) では取れない", g.ball.owner ~= gk)

	-- アドバンテージ: 相手陣で倒されても味方がすぐ拾えるなら流す
	local a = Match.new({ random = lcg(9) })
	local victim, helper, fouler = a.teams[0][10], a.teams[0][9], a.teams[1][4]
	for _, p in a.pl do
		p.p = { x = -40, y = (p.team * 2 - 1) * 30 }
	end
	victim.p = { x = 20, y = 0 }
	victim.stun = 0.8
	helper.p = { x = 21.5, y = 0.5 }
	fouler.p = { x = 19, y = -1.5 }
	fouler.stun = 0.5
	a.ball.owner = nil
	a.ball.p = { x = 21, y = 0 }
	a:foul(fouler, victim, 0)
	check("アドバンテージなら試合を止めない", a.setp == nil)
	victim.p = { x = -20, y = 0 }
	a.ball.p = { x = -19, y = 0 }
	helper.p = { x = -18.5, y = 0.5 }
	a:foul(fouler, victim, 0)
	check("自陣のファウルは FK", a.setp ~= nil and a.setp.kind == "fk")

	-- ボール全体がラインを越えるまではインプレー
	local o = Match.new({ random = lcg(10) })
	o.ball.owner, o.ball.last = nil, o.teams[1][8]
	o.ball.p = { x = 10, y = 33.95 }
	o.ball.v = { x = 0, y = 0.3 }
	o:update(1 / 30)
	check("ボールの中心がラインを越えただけではアウトにならない", o.setp == nil)
end

print(("%d checks, %d failures"):format(checks, failures))
if failures > 0 then
	error("spec failed")
end
