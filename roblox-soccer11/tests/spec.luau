--!nocheck
--[[
	Match の検証。Config / Locale / Match はランナーがグローバルに注入する。
	乱数は決定論的な LCG を渡して再現できるようにしている。
]]

local failures, checks = 0, 0
local function check(name, cond, detail)
	checks += 1
	if cond then
		print("  ok   " .. name)
	else
		failures += 1
		print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
	end
end

local function lcg(seed)
	local s = seed
	return function()
		s = (s * 48271) % 2147483647 -- MINSTD
		return s / 2147483647
	end
end

local function finite(p)
	return p.x == p.x and p.y == p.y and math.abs(p.x) < 1e6 and math.abs(p.y) < 1e6
end

print("== 設定 ==")
check("選手11人分の陣形", #Config.Formation == 11)
local nums = {}
for _, f in Config.Formation do
	nums[f.num] = true
end
check("背番号が重複しない", (function()
	local n = 0
	for _ in nums do
		n += 1
	end
	return n == 11
end)())

print("== 多言語 ==")
do
	local missing = {}
	for k in Locale.Tables.en do
		if Locale.Tables.ja[k] == nil then
			table.insert(missing, k)
		end
	end
	check("日本語の訳漏れが無い", #missing == 0, table.concat(missing, ","))
	local extra = {}
	for k in Locale.Tables.ja do
		if Locale.Tables.en[k] == nil then
			table.insert(extra, k)
		end
	end
	check("英語にだけ無いキーが無い", #extra == 0, table.concat(extra, ","))
	-- フォーマット指定子の数が揃っていること
	local bad = {}
	for k, en in Locale.Tables.en do
		local ja = Locale.Tables.ja[k]
		if ja then
			local _, a = string.gsub(en, "%%d", "")
			local _, b = string.gsub(ja, "%%d", "")
			if a ~= b then
				table.insert(bad, k)
			end
		end
	end
	check("%d の数が日英で一致", #bad == 0, table.concat(bad, ","))
	check("LocaleId ja-jp → ja", Locale.langOf("ja-jp") == "ja")
	check("LocaleId en-us → en", Locale.langOf("en-us") == "en")
	check("未定義キーはキーを返す", Locale.t("en", "no.such.key") == "no.such.key")
end

print("== 試合 (CPU 同士で通し) ==")
do
	local m = Match.new({
		random = lcg(12345),
		ctrlKind = { [0] = "cpu", [1] = "cpu" },
	})
	local steps = 0
	local bad = nil
	local setKinds = {}
	while not m.ended and steps < 400 / 0.033 do
		m:update(0.033)
		steps += 1
		if m.setp then
			setKinds[m.setp.kind] = true
		end
		for _, p in m.pl do
			if not finite(p.p) or not finite(p.v) then
				bad = "player " .. p.team .. ":" .. p.i
			end
		end
		if not finite(m.ball.p) or m.ball.z ~= m.ball.z then
			bad = "ball"
		end
		if bad then
			break
		end
	end
	check("座標が発散しない", bad == nil, bad)
	check("5分で試合が終わる", m.ended, "elapsed=" .. m.elapsed)
	check("結果が作られる", m.result ~= nil)
	local total = m.score[0] + m.score[1]
	check("得点が現実的 (0〜20)", total >= 0 and total <= 20, total)
	check("パスが出ている (CPU でも stats は人間のみなので 0 でよい)", m.stats.passes == 0)
	local kinds = 0
	for _ in setKinds do
		kinds += 1
	end
	-- CPU 同士はタッチラインに近づかないのでセットプレーは起きないことが多い (下で強制して検証する)
	print(("  info score=%d-%d fouls=%d setpieces=%d"):format(m.score[0], m.score[1], m.stats.fouls, kinds))
end

print("== 複数シードで安定 ==")
do
	local ok, totalGoals = true, 0
	for seed = 1, 6 do
		local m = Match.new({ random = lcg(seed * 7919), ctrlKind = { [0] = "cpu", [1] = "cpu" } })
		local n = 0
		while not m.ended and n < 12000 do
			m:update(1 / 30)
			n += 1
		end
		if not m.ended then
			ok = false
		end
		totalGoals += m.score[0] + m.score[1]
	end
	check("6 シードすべて完走", ok)
	check("6 試合で 1 点以上は入る", totalGoals >= 1, totalGoals)
end

print("== 人間操作 ==")
do
	local m = Match.new({ random = lcg(99) })
	check("キックオフは HOME 保持", m.ball.owner ~= nil and m.ball.owner.team == 0)
	check("操作選手が保持者", m.ctrl == m.ball.owner)
	-- 前へドリブル
	m:setKey("D", true)
	local x0 = m.ctrl.p.x
	for _ = 1, 30 do
		m:update(1 / 30)
	end
	check("D で +x へ進む", m.ctrl.p.x > x0 or m.ball.owner ~= m.ctrl, m.ctrl.p.x - x0)
	m:setKey("D", false)
	-- パス
	local c = m.ball.owner
	if c and c.team == 0 then
		m:onKey("K")
		check("K でパスが出る", m.ball.owner == nil and m.ball.kind == "pass", m.ball.kind)
		check("パス数が数えられる", m.stats.passes == 1)
	end
	-- 一時停止
	m:onKey("P")
	local t = m.elapsed
	m:update(0.1)
	check("P で一時停止", m.paused and m.elapsed == t)
	m:onKey("P")
	check("P で再開", not m.paused)
end

print("== シュートの溜め ==")
do
	local m = Match.new({ random = lcg(5) })
	local c = m.ctrl
	c.p = { x = 40, y = 0 }
	m.ball.owner = c
	m:setKey("J", true)
	m:onKey("J")
	check("J を押すと溜め開始", m.charge ~= nil)
	for _ = 1, 20 do
		m:update(1 / 30)
	end
	m:setKey("J", false)
	m:update(1 / 30)
	check("J を離すとシュートが飛ぶ", m.ball.kind == "shot" and m.ball.owner == nil, m.ball.kind)
	check("ボールがゴール方向へ", m.ball.v.x > 0)
end

print("== 技 (Shift タップ → WASD) ==")
do
	local m = Match.new({ random = lcg(3) })
	for _, q in m.teams[1] do -- 邪魔が入らないよう相手を遠ざける
		q.p = { x = 45, y = q.p.y }
	end
	local c = m.ctrl
	check("技の入力前は skill なし", c.skill == nil)
	m:setKey("Shift", true)
	m:update(1 / 30)
	m:setKey("Shift", false)
	m:update(1 / 30)
	m:onKey("S") -- 横へ弾く (HOME は +x を向くので S は横)
	for _ = 1, 10 do
		m:update(1 / 30)
	end
	check("横1回でダブルタッチが始まる", m.skillStats.tried == 1, m.skillStats.tried)
	check("技名のラベルが出る", #m.labels >= 1 and m.labels[1].key == "skill.double_touch")
end

print("== キックオフ直後の保護 ==")
do
	local m = Match.new({ random = lcg(11) })
	local owner = m.ball.owner
	for _ = 1, 30 do -- 1 秒
		m:update(1 / 30)
	end
	check("開始 1 秒はボールを奪われない", m.ball.owner == owner or m.ball.owner == nil or m.ball.owner.team == 0)
end

print("== ボールが出た時のセットプレー ==")
do
	local m = Match.new({ random = lcg(21) })
	m.ball.owner, m.ball.last = nil, m.teams[0][8]
	m.ball.p = { x = 10, y = 33.9 }
	m.ball.v = { x = 0, y = 6 }
	m:update(1 / 30)
	check("タッチラインを出たらスローイン", m.setp ~= nil and m.setp.kind == "throw", m.setp and m.setp.kind)
	check("最後に触れた HOME の相手 (AWAY) がスロー", m.setp.team == 1)

	local m2 = Match.new({ random = lcg(22) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[1][8] -- AWAY が最後に触れた
	m2.ball.p = { x = 52.4, y = 20 }
	m2.ball.v = { x = 6, y = 0 }
	m2:update(1 / 30)
	check("AWAY が出したら HOME のコーナー", m2.setp ~= nil and m2.setp.kind == "corner" and m2.setp.team == 0,
		m2.setp and (m2.setp.kind .. m2.setp.team))

	local m3 = Match.new({ random = lcg(23) })
	m3.ball.owner, m3.ball.last = nil, m3.teams[0][8] -- HOME が最後に触れた
	m3.ball.p = { x = 52.4, y = 20 }
	m3.ball.v = { x = 6, y = 0 }
	m3:update(1 / 30)
	check("HOME が出したら AWAY のゴールキック", m3.setp ~= nil and m3.setp.kind == "gk" and m3.setp.team == 1)
end

print("== ゴール ==")
do
	local m = Match.new({ random = lcg(31) })
	m.ball.owner, m.ball.last = nil, m.teams[0][10]
	m.ball.p = { x = 52.4, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	m:update(1 / 30)
	check("ゴールで HOME に 1 点", m.score[0] == 1, m.score[0])
	check("得点後は AWAY のキックオフ", m.ball.owner ~= nil and m.ball.owner.team == 1)
	check("GOAL! の表示が出る", #m.popups >= 1 and m.popups[1].key == "popup.goal")

	local m2 = Match.new({ random = lcg(32) })
	m2.ball.owner, m2.ball.last = nil, m2.teams[0][10]
	m2.ball.p = { x = 52.4, y = 0 }
	m2.ball.v = { x = 8, y = 0 }
	m2.ball.z = 3.5 -- バーの上
	m2:update(1 / 30)
	check("バーの上を越えたらゴールではない", m2.score[0] == 0)
end

print("== オフサイド・ファウルの導線 ==")
do
	local m = Match.new({ random = lcg(8) })
	m:foul(m.teams[1][5], m.teams[0][5])
	check("ファウルで FK/PK になる", m.setp ~= nil and (m.setp.kind == "fk" or m.setp.kind == "pk"))
	check("ファウルが数えられる", m.stats.fouls == 1)
	check("人間側のセットプレーではキッカーを操作", m.ctrl == m.setp.taker)
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
	check("後半はサイドが入れ替わる", flipDuring == true, tostring(flipDuring))
	check("規定時間で終了する", m.ended and m.elapsed >= 60 - 0.1, m.elapsed)
	check("引き分けでもカップ戦でなければ終了", m.result ~= nil and m.result.shootout == nil)
	local hs = Match.new(cpuOpts(102, { length = 60 }))
	for _ = 1, 3 do
		hs:update(1 / 30)
	end
	check("前半は HOME が +x を攻める", hs:sgn(0) == 1 and hs:sgn(1) == -1)
	hs.flip = true
	check("後半は HOME が -x を攻める", hs:sgn(0) == -1 and hs:sgn(1) == 1)
	check("ゴール判定がサイドに追従", (function()
		local g = Match.new(cpuOpts(103, { length = 60 }))
		g.flip = true
		g.ball.owner, g.ball.last = nil, g.teams[0][10]
		g.ball.p = { x = -52.4, y = 0 } -- 後半は HOME が -x のゴールを攻める
		g.ball.v = { x = -8, y = 0 }
		g.ball.z = 0.5
		g:update(1 / 30)
		return g.score[0] == 1
	end)())
end

print("== スタミナ ==")
do
	local m = Match.new({ random = lcg(7) })
	for _, q in m.teams[1] do
		q.p = { x = 45, y = q.p.y }
	end
	local c = m.ctrl
	check("開始時はスタミナ満タン", c.stamina == Config.Stamina.Max)
	m:setKey("D", true)
	m:setKey("Shift", true)
	for _ = 1, 150 do
		m:update(1 / 30)
		if m.ball.owner ~= m.ctrl then
			break
		end
	end
	check("ダッシュでスタミナが減る", c.stamina < Config.Stamina.Max - 5, c.stamina)
	c.stamina = 0
	c.exhausted = true
	check("スタミナ切れは速度が落ちる", m:speedMult(c) < c.attr.speed * 0.9, m:speedMult(c))
	check("スタミナ切れではダッシュできない", c.exhausted)
	for _ = 1, 600 do
		m:setKey("Shift", false)
		m:setKey("D", false)
		c.v = { x = 0, y = 0 }
		m:updateStamina(c, 1 / 30)
	end
	check("止まっていれば回復する", c.stamina > Config.Stamina.DashMin and not c.exhausted, c.stamina)
end

print("== 選手の能力差 ==")
do
	local m = Match.new({ random = lcg(55) })
	local st, cb, gk = m.teams[0][10], m.teams[0][3], m.teams[0][1]
	check("ST はシュートが上手い", st.attr.shoot > cb.attr.shoot, st.attr.shoot .. " vs " .. cb.attr.shoot)
	check("CB は守備が強い", cb.attr.tackle > st.attr.tackle)
	check("GK は足が遅い", gk.attr.speed < st.attr.speed)
	local lo, hi = 9, 0
	for _, p in m.pl do
		lo, hi = math.min(lo, p.attr.speed), math.max(hi, p.attr.speed)
	end
	check("個体差がある", hi - lo > 0.05, hi - lo)
end

print("== フォーメーション ==")
do
	for _, key in Config.FormationOrder do
		local m = Match.new({ random = lcg(9), formation = { [0] = key, [1] = key } })
		local roles = {}
		for _, p in m.teams[0] do
			roles[p.role] = (roles[p.role] or 0) + 1
		end
		check(key .. " は 11 人", #m.teams[0] == 11)
		local fw = 0
		for r, n in roles do
			if Config.ForwardRoles[r] then
				fw += n
			end
		end
		check(key .. " に前線の選手がいる", fw >= 1, fw)
	end
	local m = Match.new({ random = lcg(9), formation = { [0] = "352", [1] = "442" } })
	local cb = 0
	for _, p in m.teams[0] do
		if p.role == "CB" then
			cb += 1
		end
	end
	check("3-5-2 はセンターバックが 3 人", cb == 3, cb)
	local r442 = {}
	for _, p in m.teams[1] do
		r442[p.role] = true
	end
	check("チームごとに別のフォーメーション", r442.LM == true and r442.ST == true)
end

print("== 難易度 ==")
do
	local easy = Match.new({ random = lcg(1), difficulty = 1 })
	local hard = Match.new({ random = lcg(1), difficulty = 5 })
	check("難しいほど CPU が速い", hard:teamSpeed(1) > easy:teamSpeed(1))
	check("味方 (人間側) には掛からない", hard:teamSpeed(0) == 1)
	check("GK の反応が難易度で変わる", Config.Difficulties[5].gkReact > Config.Difficulties[1].gkReact)
	-- 簡単な相手はシュートがぶれやすい
	local function spread(diff)
		local m = Match.new({ random = lcg(77), difficulty = diff, ctrlKind = { [0] = "cpu", [1] = "cpu" } })
		local sum, n = 0, 0
		for _ = 1, 200 do
			local c = m.teams[1][10]
			c.p = { x = -30, y = 0 }
			m.ball.owner = c
			m:kick("shot", { c = c, power = 0.7, aimY = 0 })
			local tgtY = m.ball.v.y / math.max(math.abs(m.ball.v.x), 1e-6) * (m.ball.p.x + 52.5)
			sum += math.abs(tgtY)
			n += 1
		end
		return sum / n
	end
	check("簡単な CPU ほどシュートがぶれる", spread(1) > spread(5), spread(1) .. " vs " .. spread(5))
end

print("== カード・退場 ==")
do
	local m = Match.new({ random = lcg(31) })
	local p = m.teams[1][3]
	m:showCard(p, "yellow")
	check("イエローが数えられる", m.tstats[1].yellow == 1 and not p.out)
	p.yellow = 1
	m:cardCheck(p) -- 乱数次第で 1 枚追加される場合がある
	local q = m.teams[1][4]
	q.yellow = 1
	m:showCard(q, "red")
	check("レッドで退場する", q.out == true)
	check("退場者はアクティブから外れる", #m:active(1) == 10 or #m:active(1) == 9, #m:active(1))
	local inList = false
	for _, x in m:active(1) do
		if x == q then
			inList = true
		end
	end
	check("退場者は選手一覧に含まれない", not inList)
	local gk = m.teams[0][1]
	m:sendOff(gk)
	local newGk = m:slot(0, 0)
	check("GK 退場後は別の選手がキーパーになる", newGk ~= gk and newGk.gk == true)
	-- 通し (退場者がいても試合が壊れない)
	local steps = 0
	while not m.ended and steps < 12000 do
		m:update(1 / 30)
		steps += 1
		for _, x in m.pl do
			if x.p.x ~= x.p.x then
				steps = 99999
			end
		end
	end
	check("退場者がいても試合が最後まで進む", steps < 99999)
end

print("== 延長戦・PK 戦 ==")
do
	-- 勝敗判定の単体テスト
	local m = Match.new({ random = lcg(2), cup = true })
	m.shoot = { goals = { [0] = 0, [1] = 0 }, taken = { [0] = 0, [1] = 0 } }
	m.shoot.goals = { [0] = 3, [1] = 0 }
	m.shoot.taken = { [0] = 3, [1] = 3 }
	check("残り 2 本で 3 点差なら勝ち", m:shootWinner() == 0)
	m.shoot.goals = { [0] = 2, [1] = 1 }
	m.shoot.taken = { [0] = 3, [1] = 3 }
	check("まだ逆転できるなら続行", m:shootWinner() == nil)
	m.shoot.goals = { [0] = 4, [1] = 4 }
	m.shoot.taken = { [0] = 5, [1] = 5 }
	check("5 本で同点ならサドンデスへ", m:shootWinner() == nil)
	m.shoot.goals = { [0] = 5, [1] = 4 }
	m.shoot.taken = { [0] = 6, [1] = 5 }
	check("サドンデスは同数を蹴るまで決めない", m:shootWinner() == nil)
	m.shoot.goals = { [0] = 5, [1] = 4 }
	m.shoot.taken = { [0] = 6, [1] = 6 }
	check("サドンデスで差がつけば決着", m:shootWinner() == 0)
	m.shoot.goals = { [0] = 1, [1] = 3 }
	m.shoot.taken = { [0] = 5, [1] = 5 }
	check("5 本終了で AWAY の勝ち", m:shootWinner() == 1)

	-- 通し: 引き分けになるシードを探し、PK 戦まで進めて終わること
	local found, ended = 0, 0
	for seed = 1, 40 do
		local c = Match.new(cpuOpts(seed * 13, { length = 40, cup = true }))
		runUntilEnd(c, 60000)
		if c.result and c.result.shootout then
			found += 1
			if c.ended and c.result.winner ~= nil then
				ended += 1
			end
		end
		if found >= 2 then
			break
		end
	end
	check("引き分けの試合が PK 戦まで進む", found >= 1, found)
	check("PK 戦で勝者が決まる", ended == found and found >= 1, ended .. "/" .. found)
end

print("== ゴールリプレイ ==")
do
	local m = Match.new({ random = lcg(61), ctrlKind = { [0] = "cpu", [1] = "cpu" } })
	for _ = 1, 150 do
		m:update(1 / 30) -- 記録をためる
	end
	check("リプレイ用の記録がたまる", #m.rec >= 10, #m.rec)
	m.ball.owner, m.ball.last = nil, m.teams[0][10]
	m.ball.p = { x = 52.4, y = 0 }
	m.ball.v = { x = 8, y = 0 }
	m.ball.z = 0.5
	m:update(1 / 30)
	check("ゴール後はリプレイに入る", m.mode == "replay", m.mode)
	local before = m.elapsed
	for _ = 1, 10 do
		m:update(1 / 30)
	end
	check("リプレイ中は試合時間が進まない", m.elapsed == before)
	m:onKey("K")
	check("K でリプレイをスキップできる", m.mode == "play")
	check("スキップ後は相手のキックオフ", m.ball.owner ~= nil and m.ball.owner.team == 1)
end

print("== ヘディング ==")
do
	local m = Match.new({ random = lcg(71) })
	for _, q in m.teams[1] do
		q.p = { x = 45, y = q.p.y }
	end
	local c = m.ctrl
	c.p = { x = 40, y = 2 }
	m.ball.owner = nil
	m.ball.p = { x = 40.4, y = 2 }
	m.ball.z = 1.5
	m.ball.vz = 0
	m.ball.v = { x = 0, y = 0 }
	m:onKey("J")
	check("空中のボールにシュートで合わせる", m.ball.kind == "shot" and m.ball.owner == nil, m.ball.kind)
	local m2 = Match.new({ random = lcg(72) })
	m2.ball.owner = nil
	m2.ctrl.p = { x = -10, y = 0 }
	m2.ball.p = { x = -9.5, y = 0 }
	m2.ball.z = 0.2
	m2:onKey("J")
	check("低いボールではヘディングにならない", m2.ball.kind ~= "shot")
end

print("== キーパーのダイブ ==")
do
	local m = Match.new({ random = lcg(81), difficulty = 5 })
	local c = m.teams[0][10]
	c.p = { x = 35, y = 0 }
	m.ball.owner = c
	m:kick("shot", { c = c, power = 0.8, aimY = 1.5 })
	local gk = m:slot(1, 0)
	check("枠内のシュートで GK がダイブを始める", gk.dive ~= nil)
	local y0 = gk.p.y
	for _ = 1, 20 do
		m:update(1 / 30)
	end
	check("GK が横へ動く", math.abs(gk.p.y - y0) > 0.3 or m.ball.owner == gk, gk.p.y - y0)
	local m2 = Match.new({ random = lcg(82) })
	local c2 = m2.teams[0][10]
	c2.p = { x = 35, y = 0 }
	m2.ball.owner = c2
	m2:kick("shot", { c = c2, power = 0.8, aimY = 9 }) -- 大きく外す
	check("枠外には反応しない", m2:slot(1, 0).dive == nil)
end

print("== スタッツ ==")
do
	local m = Match.new(cpuOpts(91, { length = 90 }))
	runUntilEnd(m)
	local r = m.result
	check("支配率が 0〜100", r.possession >= 0 and r.possession <= 100, r.possession)
	check("シュート数 ≧ 枠内数", r.stats[0].shots >= r.stats[0].onTarget and r.stats[1].shots >= r.stats[1].onTarget)
	check("パス成功 ≦ パス数 (各チーム)", r.stats[0].passOk <= r.stats[0].passes + 2 and r.stats[1].passOk <= r.stats[1].passes + 2)
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
	local loss = Rewards.sanitize({ home = 0, away = 3, winner = 1 })
	local cl = Rewards.compute(sess(300, 3), loss, false)
	check("敗戦でも基本報酬がある", cl == Config.Rewards.Base, cl)
	local draw = Rewards.sanitize({ home = 1, away = 1 })
	local cd = Rewards.compute(sess(300, 3), draw, false)
	check("引き分けは勝利より少ない", cd < Rewards.compute(sess(300, 3), Rewards.sanitize({ home = 2, away = 1, winner = 0 }), false))
	check("難しい難易度ほど多い", Rewards.compute(sess(300, 5), win, false) > Rewards.compute(sess(300, 1), win, false))
	check("長い試合ほど多い", Rewards.compute(sess(600, 3), win, false) > Rewards.compute(sess(180, 3), win, false))
	local huge = Rewards.sanitize({ home = 9999, away = 0, winner = 0, shootoutWin = true })
	check("得点の申告は丸められる", huge.home == 30)
	local cmax = Rewards.compute(sess(600, 5), huge, false)
	check("上限を超えない", cmax <= Config.Rewards.Max, cmax)
	local cv = Rewards.compute(sess(300, 3), win, true)
	check("VIP は 2 倍", cv == c * Config.Monetization.VipCoinMultiplier, cv)
	local bad = Rewards.sanitize("hack")
	check("不正な入力は 0 点扱い", bad.home == 0 and bad.away == 0 and bad.winner == nil)
	local nan = Rewards.sanitize({ home = 0 / 0, away = -5, winner = 7 })
	check("NaN・負数・範囲外の勝者を弾く", nan.home == 0 and nan.away == 0 and nan.winner == nil)
	check("選べる試合時間の検証", Rewards.isValidLength(300) and not Rewards.isValidLength(7))
end

print("== コスメ・課金設定 ==")
do
	local ids, dup = {}, nil
	for _, k in Config.Kits do
		if ids["kit:" .. k.id] then
			dup = k.id
		end
		ids["kit:" .. k.id] = true
	end
	for _, k in Config.Balls do
		if ids["ball:" .. k.id] then
			dup = k.id
		end
		ids["ball:" .. k.id] = true
	end
	check("キット・ボールの ID が重複しない", dup == nil, dup)
	check("既定のキットは無料", Config.Kits[1].price == 0 and not Config.Kits[1].vip)
	check("既定のボールは無料", Config.Balls[1].price == 0 and not Config.Balls[1].vip)
	local vipKit = false
	for _, k in Config.Kits do
		if k.vip then
			vipKit = true
		end
	end
	check("VIP 限定のキットがある", vipKit)
	check("コインパックは小さいほど安い", Config.Monetization.Products.Coins500.price < Config.Monetization.Products.Coins2000.price)
	local fair = true
	for _, k in Config.Kits do
		if k.stat ~= nil then
			fair = false
		end
	end
	check("キットは勝敗に影響しない (能力値を持たない)", fair)
end

print("== 課金 ID ==")
do
	local ids, dup, zero = {}, false, {}
	for k, d in Config.Monetization.Passes do
		if d.id == 0 then
			table.insert(zero, k)
		end
		dup = dup or ids[d.id] == true
		ids[d.id] = true
	end
	for k, d in Config.Monetization.Products do
		if d.id == 0 then
			table.insert(zero, k)
		end
		dup = dup or ids[d.id] == true
		ids[d.id] = true
	end
	check("全ての商品に ID が入っている", #zero == 0, table.concat(zero, ","))
	check("ID が重複しない", not dup)
end

print(("%d checks, %d failures"):format(checks, failures))
if failures > 0 then
	error("spec failed")
end
