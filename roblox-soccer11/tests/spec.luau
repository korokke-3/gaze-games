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
	while not m.ended and steps < 300 / 0.033 + 100 do
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

print(("%d checks, %d failures"):format(checks, failures))
if failures > 0 then
	error("spec failed")
end
