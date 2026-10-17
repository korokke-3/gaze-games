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

	-- コントロールシュート (R1) はぶれにくい
	local function spread(r1)
		local sum = 0
		for k = 1, 30 do
			local mm = Match.new({ random = lcg(100 + k) })
			clearOpponents(mm)
			local ss = mm:seat(1)
			giveBall(mm, ss, { x = 30, y = 0 })
			mm:setAim(1, 1, 0)
			if r1 then
				mm:press(1, "r1")
			end
			hold(mm, 1, "shoot", 0.5)
			sum += math.abs(mm.ball.v.y / mm.ball.v.x * 22.5)
		end
		return sum / 30
	end
	check("コントロールシュートはぶれが小さい", spread(true) < spread(false), spread(true) .. " / " .. spread(false))
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
	m.ball.p = { x = 10, y = 33.9 }
	m.ball.v = { x = 0, y = 6 }
	m:update(1 / 30)
	check("タッチラインを出たらスローイン", m.setp ~= nil and m.setp.kind == "throw")
	check("人間のチームのスローは操作者が蹴る", m.setp.team == 0 and s.ctrl == m.setp.taker)
	m:setAim(1, 0, -1)
	hold(m, 1, "pass", 0.3)
	check("スローインを投げられる", m.setp == nil and m.ball.owner == nil)

	local m2 = Match.new({ random = lcg(82) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[1][8]
	m2.ball.p = { x = 52.4, y = 20 }
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
	m.ball.p = { x = 52.4, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	m:update(1 / 30)
	check("ゴールで HOME に 1 点", m.score[0] == 1)
	check("得点後は AWAY のキックオフ", m.ball.owner ~= nil and m.ball.owner.team == 1)
	check("GOAL の表示 (得したチームつき)", #m.popups >= 1 and m.popups[1].key == "popup.goal" and m.popups[1].team == 0)
	local m2 = Match.new({ random = lcg(92) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[0][10]
	m2.ball.p = { x = 52.4, y = 0 }
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
	g.ball.p = { x = -52.4, y = 0 }
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
	m.ball.p = { x = 52.4, y = 0 }
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
	m.ball.p = { x = 10, y = 33.9 }
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

print(("%d checks, %d failures"):format(checks, failures))
if failures > 0 then
	error("spec failed")
end
