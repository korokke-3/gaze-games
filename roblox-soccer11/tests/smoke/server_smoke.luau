--!nocheck
print("== サーバー (stub 上で実行) ==")
ServerMode = true
local Config = Require(Shared.Config)

local ok, err = pcall(Load, "server/init")
Check("起動 (init.server) がエラーなく実行できる", ok, err)
if not ok then
	error("server init failed: " .. tostring(err))
end

local function newPlayer(id)
	local p = { UserId = id, Name = "P" .. id, Parent = true }
	table.insert(Players_.list, p)
	return p
end
local function lastState(player)
	local out = nil
	for _, c in Calls do
		if c.name == "State" and c.player == player then
			out = c.args[1]
		end
	end
	return out
end
local function notifies(player)
	local out = {}
	for _, c in Calls do
		if c.name == "Notify" and c.player == player then
			table.insert(out, c.args[1])
		end
	end
	return out
end
local function join(player)
	Fire("PlayerAdded", player)
end

local p1 = newPlayer(1)
join(p1)
local st = lastState(p1)
Check("参加時に状態が送られる", st ~= nil and st.coins == 0)
Check("既定のキットは所持", st and st.owned.kit.classic == true)
Check("VIP 限定は未所持", st and st.owned.kit.gold == false and st.owned.ball.gold == false)
Check("商品が購入可能として通知される", st and st.available.VIP and st.available.Coins500)
Check("DataStore に保存できる状態 (読み取り専用ではない)", st and st.readOnly == false)

-- コイン不足の購入
NetFire("BuyItem", p1, "kit", "crimson")
Check("コイン不足では購入できない", lastState(p1).owned.kit.crimson == false and notifies(p1)[#notifies(p1)] == "notify.not_enough")

-- 開発者製品 (コインパック) の付与
local pid = Config.Monetization.Products.Coins500.id
local receipt = { PlayerId = 1, ProductId = pid, PurchaseId = "r-1" }
local decision = market_.ProcessReceipt(receipt)
Check("コインパックが付与される", decision == Enum.ProductPurchaseDecision.PurchaseGranted and lastState(p1).coins == 500)
local again = market_.ProcessReceipt(receipt)
Check("同じレシートは二重付与されない", again == Enum.ProductPurchaseDecision.PurchaseGranted and lastState(p1).coins == 500)
local unknown = market_.ProcessReceipt({ PlayerId = 1, ProductId = 12345, PurchaseId = "r-x" })
Check("未知の商品は処理しない", unknown == Enum.ProductPurchaseDecision.NotProcessedYet)
local ghost = market_.ProcessReceipt({ PlayerId = 999, ProductId = pid, PurchaseId = "r-2" })
Check("プレイヤー不在なら後で再試行", ghost == Enum.ProductPurchaseDecision.NotProcessedYet)

-- キットの購入と装備
NetFire("BuyItem", p1, "kit", "crimson")
Check("コインでキットを購入できる", lastState(p1).owned.kit.crimson == true and lastState(p1).coins == 500 - 300, lastState(p1).coins)
NetFire("EquipItem", p1, "kit", "crimson")
Check("購入したキットを装備できる", lastState(p1).equipped.kit == "crimson")
NetFire("EquipItem", p1, "kit", "gold")
Check("未所持 (VIP 限定) は装備できない", lastState(p1).equipped.kit == "crimson")
NetFire("BuyItem", p1, "kit", "gold")
Check("VIP 限定はコインで買えない", lastState(p1).owned.kit.gold == false)
NetFire("BuyItem", p1, "kit", { evil = true })
NetFire("BuyItem", p1, 5, nil)
Check("不正な引数でも落ちない", true)

-- 試合の報酬
FakeClock = 100
NetFire("MatchStarted", p1, { length = 300, difficulty = 3, cup = false })
FakeClock = 110 - 1.5 -- 10 秒しか経っていない (NetFire が 1.5 秒進める)
NetFire("MatchFinished", p1, { home = 9, away = 0, winner = 0 })
Check("短すぎる試合は報酬なし", #CallsOf("MatchReward") == 0 and notifies(p1)[#notifies(p1)] == "notify.too_short")

local coinsBefore = lastState(p1).coins
FakeClock = 200
NetFire("MatchStarted", p1, { length = 300, difficulty = 3, cup = false })
FakeClock = 200 + 290
NetFire("MatchFinished", p1, { home = 2, away = 0, winner = 0 })
local rw = CallsOf("MatchReward")
Check("規定時間後は報酬が付く", #rw == 1 and rw[1].args[1].coins > 0)
local expected = Config.Rewards.Base + Config.Rewards.Win + 2 * Config.Rewards.PerGoal + Config.Rewards.CleanSheet
Check("報酬額はサーバーの計算 (3=標準難易度・5 分)", rw[1] and rw[1].args[1].coins == expected, rw[1] and rw[1].args[1].coins)
Check("コインが加算される", lastState(p1).coins == coinsBefore + expected)
Check("統計が更新される", lastState(p1).stats.matches == 1 and lastState(p1).stats.wins == 1)
NetFire("MatchFinished", p1, { home = 5, away = 0, winner = 0 })
Check("開始していない試合の報告は無視", #CallsOf("MatchReward") == 1)

-- 申告の改ざん
FakeClock = 400
NetFire("MatchStarted", p1, { length = 180, difficulty = 1, cup = false })
FakeClock = 400 + 200
local before = lastState(p1).coins
NetFire("MatchFinished", p1, { home = 99999, away = -1, winner = 0, length = 600, difficulty = 5 })
local gain = lastState(p1).coins - before
Check("申告 (得点・難易度) を改ざんしても上限を超えない", gain > 0 and gain <= Config.Rewards.Max, gain)
Check("難易度・時間は開始時の値で計算される", gain <= Config.Rewards.Max * Config.Rewards.DifficultyBonus[1], gain)

-- VIP パス
Check("VIP でない時は 1 倍", lastState(p1).passes.VIP == false)
local passId = Config.Monetization.Passes.VIP.id
Fire("PromptGamePassPurchaseFinished", p1, passId, true)
Check("パス購入で VIP になる", lastState(p1).passes.VIP == true)
Check("VIP 限定のキットが使える", lastState(p1).owned.kit.gold == true and lastState(p1).owned.ball.gold == true)
FakeClock = 700
NetFire("MatchStarted", p1, { length = 300, difficulty = 3, cup = false })
FakeClock = 700 + 290
local c0 = lastState(p1).coins
NetFire("MatchFinished", p1, { home = 2, away = 0, winner = 0 })
Check("VIP はコイン 2 倍", lastState(p1).coins - c0 == expected * 2, lastState(p1).coins - c0)

-- 購入プロンプト
NetFire("PromptPurchase", p1, "pass", "AllKits")
NetFire("PromptPurchase", p1, "product", "Coins2000")
NetFire("PromptPurchase", p1, "pass", "Hacked")
Check("購入ダイアログの呼び出し (未定義は無視)", #Prompts == 2 and Prompts[1].kind == "pass" and Prompts[2].kind == "product", #Prompts)

-- 全キット解放
Fire("PromptGamePassPurchaseFinished", p1, Config.Monetization.Passes.AllKits.id, true)
local s2 = lastState(p1)
Check("全キット解放で有料キットが使える", s2.owned.kit.emerald == true and s2.owned.ball.fire == true)

-- 設定の保存
NetFire("SaveSettings", p1, { difficulty = 5, length = 600, mode = "cup", formation = "442", evil = "x", camera = "bad" })
FakeClock += 5
NetFire("SaveSettings", p1, { difficulty = 5 })
NetFire("RequestState", p1)
local s3 = lastState(p1)
Check("設定が保存され、許可外のキー・型は捨てられる", s3.settings.difficulty == 5 and s3.settings.evil == nil and s3.settings.camera == nil, s3.settings.evil)

-- 操作の割り当て
Check("状態に既定の割り当てが入る", lastState(p1).bindings ~= nil and lastState(p1).bindings.kb.pass[1] == "MouseButton1")
NetFire("SaveBindings", p1, { preset = "custom", kb = { pass = { "G", "Slash", "G", "H" }, evil = { "X" } }, pad = { pass = { "ButtonB" } } })
NetFire("RequestState", p1)
local bnd = lastState(p1).bindings
Check("割り当てが保存され、禁止キー・重複・不明な操作は捨てられる", bnd.kb.pass[1] == "G" and bnd.kb.pass[2] == "H" and #bnd.kb.pass == 2 and bnd.kb.evil == nil and bnd.pad.pass[1] == "ButtonB")
NetFire("SaveBindings", p1, "garbage")
NetFire("RequestState", p1)
Check("壊れたデータは既定に戻す", lastState(p1).bindings.kb.pass[1] == "MouseButton1")
NetFire("SaveBindings", p1, { kb = { pass = { "G" } } })

-- 退出で保存・ロック解放 → 再参加
local coinsNow = lastState(p1).coins
Fire("PlayerRemoving", p1)
local saved = DataStoreMemory["u_1"]
Check("退出時に保存され、ロックが解放される", saved ~= nil and saved.lock == nil and saved.data.coins == coinsNow)
for i, p in Players_.list do
	if p == p1 then
		table.remove(Players_.list, i)
	end
end
local p1b = newPlayer(1)
join(p1b)
Check("再参加で状態が引き継がれる", lastState(p1b).coins == coinsNow and lastState(p1b).owned.kit.crimson == true)
Check("割り当ても引き継がれる", lastState(p1b).bindings.kb.pass[1] == "G")

-- セッションロック: 別サーバーが保持している間は上書きしない
DataStoreMemory["u_2"] = { lock = { jobId = "other-server", time = os.time() }, data = { coins = 777, kits = { classic = true }, balls = { classic = true }, equipped = { kit = "classic", ball = "classic" }, stats = {}, settings = {}, receipts = {} } }
local p2 = newPlayer(2)
join(p2)
local s4 = lastState(p2)
Check("他サーバーのロック中は読み取り専用になる", s4 ~= nil and s4.readOnly == true)
Fire("PlayerRemoving", p2)
Check("ロック中のデータを上書きしない", DataStoreMemory["u_2"].data.coins == 777 and DataStoreMemory["u_2"].lock.jobId == "other-server")

-- ================================================================ オンライン (協力 / 対戦)
print("-- オンライン --")
local Snapshot = Require(Shared.Snapshot)
local function lastOf(player, name)
	local out = nil
	for _, c in Calls do
		if c.name == name and c.player == player then
			out = c
		end
	end
	return out
end
local function countOf(player, name)
	local n = 0
	for _, c in Calls do
		if c.name == name and c.player == player then
			n += 1
		end
	end
	return n
end
local a = newPlayer(41)
local b = newPlayer(42)
local c3 = newPlayer(43)
join(a)
join(b)
join(c3)
NetFire("RoomCreate", a, "coop", { length = 180, difficulty = 2, cup = false, formation = "442", assist = 2 })
local rs = lastOf(a, "RoomState")
Check("協力の部屋を作れる", rs ~= nil and rs.args[1] ~= nil and rs.args[1].mode == "coop" and rs.args[1].count == 1)
local roomId = rs.args[1].id
NetFire("RoomJoin", b, roomId)
NetFire("RoomJoin", c3, roomId)
local rsb = lastOf(b, "RoomState")
Check("3 人まで参加できる", rsb and rsb.args[1].count == 3)
local d = newPlayer(44)
join(d)
NetFire("RoomJoin", d, roomId)
Check("協力は 4 人目を断る", lastOf(d, "RoomState") == nil)
NetFire("RoomStart", b)
Check("ホスト以外は開始できない", lastOf(a, "OnlineStart") == nil)
NetFire("RoomStart", a)
local st = lastOf(b, "OnlineStart")
Check("ホストが開始すると全員に開始が届く", st ~= nil and lastOf(c3, "OnlineStart") ~= nil and #st.args[1].seats == 3)
Check("協力は全員ホームチーム", st and st.args[1].seats[1].team == 0 and st.args[1].seats[3].team == 0)
-- 試合を進めながら入力を送る
local snaps0 = countOf(a, "OnlineSnap")
local okT, errT = pcall(function()
	for i = 1, 60 do
		FakeClock += 1 / 60
		Fire("Heartbeat", 1 / 60)
		if i == 10 then
			local packet = Snapshot.packInput({ move = { x = 1, y = 0 }, aim = { x = 1, y = 0 }, buttons = { pass = true } })
			NetFire("MatchInput", a, packet)
		end
		if i == 30 then
			local packet = Snapshot.packInput({ move = { x = 1, y = 0 }, aim = { x = 1, y = 0 }, buttons = {} })
			NetFire("MatchInput", a, buffer.fromstring(packet)) -- クライアントは buffer で送る
		end
	end
end)
Check("サーバーで試合が進む (Heartbeat)", okT, errT)
Check("Snapshot が送られる (15 回/秒前後)", countOf(a, "OnlineSnap") - snaps0 >= 10, countOf(a, "OnlineSnap") - snaps0)
local snapRaw = lastOf(a, "OnlineSnap").args[1]
Check("Snapshot は buffer で送る", type(snapRaw) == "buffer")
local snap = Snapshot.decode(buffer.tostring(snapRaw))
Check("Snapshot に 3 人の操作者", #snap.seats == 3)
NetFire("MatchInput", a, "garbage")
NetFire("MatchInput", a, buffer.create(500))
NetFire("MatchInput", a, 12345)
Check("壊れた入力でも落ちない", true)
-- 終了まで (3 分)
local okE, errE = pcall(function()
	for _ = 1, 60 * 400 do
		FakeClock += 1 / 60
		Fire("Heartbeat", 1 / 60)
		if lastOf(a, "OnlineEnd") ~= nil then
			break
		end
	end
end)
local fin = lastOf(a, "OnlineEnd")
Check("試合が終わると結果が届く", okE and fin ~= nil, errE)
Check("結果は数値キーの辞書を含まない (RemoteEvent で送れる形)", fin and fin.args[1].result.statsHome ~= nil and fin.args[1].result[0] == nil)
Check("規定時間を満たせば報酬が付く", fin and fin.args[1].reward ~= nil and fin.args[1].reward.coins > 0)
local rsAfter = lastOf(a, "RoomState")
Check("試合後は部屋の待機に戻る", rsAfter and rsAfter.args[1].state == "lobby")

-- 対戦
NetFire("RoomLeave", b)
NetFire("RoomLeave", c3)
NetFire("RoomCreate", b, "versus", { length = 180 })
local vs = lastOf(b, "RoomState").args[1]
NetFire("RoomStart", b)
Check("対戦は相手がいないと開始できない", lastOf(b, "Notify").args[1] == "notify.need_opponent")
NetFire("RoomJoin", c3, vs.id)
local vs2 = lastOf(c3, "RoomState").args[1]
local teams = {}
for _, m in vs2.members do
	teams[m.name] = m.team
end
Check("対戦の 2 人目は相手チーム", teams["P42"] == 0 and teams["P43"] == 1)
NetFire("RoomTeam", c3, 0)
Check("チームを移動できる", (function()
	for _, m in lastOf(c3, "RoomState").args[1].members do
		if m.name == "P43" then
			return m.team == 0
		end
	end
	return false
end)())
NetFire("RoomTeam", c3, 1)
NetFire("RoomStart", b)
Check("対戦が始まる", lastOf(c3, "OnlineStart") ~= nil and lastOf(c3, "OnlineStart").args[1].mode == "versus")
for _ = 1, 30 do
	FakeClock += 1 / 60
	Fire("Heartbeat", 1 / 60)
end
-- 途中退出: 片方が抜けると試合は終わる
NetFire("RoomLeave", c3)
local abort = lastOf(b, "OnlineEnd")
Check("対戦の相手が抜けたら試合を終える (報酬なし)", abort ~= nil and abort.args[1].aborted == true and abort.args[1].reward == nil)
Fire("PlayerRemoving", b)
Check("退出で部屋が消える", (function()
	NetFire("RoomList", a)
	local list = lastOf(a, "Rooms").args[1]
	for _, r in list do
		if r.id == vs.id then
			return false
		end
	end
	return true
end)())

print(("== 結果: %d 失敗 =="):format(Failures))
if Failures > 0 then
	error("server smoke failed")
end
