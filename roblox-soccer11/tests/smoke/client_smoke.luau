--!nocheck
print("== クライアント (stub 上で実行) ==")
ServerMode = false
local ok, err = pcall(Load, "client/init")
Check("起動 (init.client) がエラーなく実行できる", ok, err)
if not ok then
	error("client init failed: " .. tostring(err))
end

Check("RequestState をサーバーへ送る", #CallsOf("RequestState") >= 1)

local state = {
	coins = 800,
	owned = {
		kit = { classic = true, crimson = false, emerald = false, midnight = false, sunset = false, gold = false },
		ball = { classic = true, fire = false, ice = false, gold = false },
	},
	equipped = { kit = "classic", ball = "classic" },
	passes = { VIP = false, AllKits = false },
	stats = { matches = 0, wins = 0, draws = 0, losses = 0, goals = 0 },
	settings = { difficulty = 4, length = 180 },
	readOnly = false,
	available = { VIP = true, AllKits = true, Coins500 = true, Coins2000 = true, Coins10000 = true },
}
local ok2, err2 = pcall(NetFire, "State", state)
Check("State を受け取ってメニューが更新できる", ok2, err2)

local okf, errf = pcall(Frames, 90) -- タイトル背景のデモ試合
Check("デモ試合が 3 秒間エラーなく動く", okf, errf)

-- ショップ画面
local shopTab = FindButton("Shop")
Check("ショップのタブがある", shopTab ~= nil)
local okS, errS = pcall(shopTab.fn)
Check("ショップ画面を描画できる", okS, errS)
local buy = FindButton("Buy 300")
Check("キットの購入ボタンがある", buy ~= nil)
if buy then
	buy.fn()
	local bc = CallsOf("BuyItem")
	Check("購入ボタンで BuyItem を送る", #bc == 1 and bc[1].args[1] == "kit" and bc[1].args[2] == "crimson")
end
local vip = FindButton("R$ 399")
Check("VIP の購入ボタンがある", vip ~= nil)
if vip then
	vip.fn()
	local pc = CallsOf("PromptPurchase")
	Check("VIP ボタンで PromptPurchase を送る", #pc == 1 and pc[1].args[1] == "pass" and pc[1].args[2] == "VIP")
end
local packBtn = FindButton("R$ 49")
Check("コインパックの購入ボタンがある", packBtn ~= nil)

-- 装備
state.owned.kit.crimson = true
NetFire("State", state)
local equip = FindButton("Equip")
Check("所持済みのキットに装備ボタンが出る", equip ~= nil)
if equip then
	equip.fn()
	Check("装備で EquipItem を送る", #CallsOf("EquipItem") == 1)
end

-- 試合設定 (カップ戦・3 分)
local playTab = FindButton("Play")
Check("試合タブがある", playTab ~= nil)
playTab.fn()
local modeBtn = FindButton("Quick match")
Check("モードの選択ボタンがある", modeBtn ~= nil)
if modeBtn then
	modeBtn.fn()
end

-- 試合開始
local start = FindButton("Kick off")
Check("キックオフのボタンがある", start ~= nil)
local okM, errM = pcall(start.fn)
Check("試合を開始できる", okM, errM)
Check("MatchStarted をサーバーへ送る", #CallsOf("MatchStarted") == 1)
local started = CallsOf("MatchStarted")[1]
Check("保存された設定 (難易度 4 / 3 分) が反映される", started.args[1].difficulty == 4 and started.args[1].length == 180, started and started.args[1].length)

-- 操作しながら進める
local okP = pcall(function()
	Press("D")
	Press("LeftShift")
	Frames(30)
	Press("K")
	Release("K")
	Press("J")
	Frames(10)
	Release("J")
	Release("LeftShift")
	Release("D")
	Press("U")
	Press("L")
	Press("P")
	Frames(3)
	Press("P")
	Press("H")
end)
Check("キー入力を処理できる", okP)

-- タッチ UI
local touchButtons = 0
for _, h in Handlers do
	if h.sig == "InputBegan" and h.owner ~= nil and not h.owner._destroyed and h.owner._p.ClassName == "TextButton" then
		touchButtons += 1
		pcall(h.fn, { UserInputType = Enum.UserInputType.Touch })
	end
end
Check("タッチ用のボタンが作られる", touchButtons >= 6, touchButtons)

-- 最後まで流す
local steps = 0
local okRun, errRun = pcall(function()
	while #CallsOf("MatchFinished") == 0 and steps < 40000 do
		Frames(1)
		steps += 1
		if steps % 60 == 0 then
			Press("D")
			Press("K")
			Release("K")
			Release("D")
		end
	end
end)
Check("試合が最後までエラーなく進む", okRun, errRun)
local fin = CallsOf("MatchFinished")
Check("終了時に MatchFinished を送る", #fin == 1, steps)
if #fin == 1 then
	local r = fin[1].args[1]
	Check("結果の形が正しい", type(r.home) == "number" and type(r.away) == "number")
end

-- 結果画面
NetFire("MatchReward", { coins = 42, parts = { base = 30 }, total = 842 })
local again = FindButton("Play again")
Check("結果画面に「もう一度」がある", again ~= nil)
if again then
	local okA, errA = pcall(again.fn)
	Check("もう一度で次の試合が始まる", okA and #CallsOf("MatchStarted") == 2, errA)
	Frames(60)
end

-- 通知
local okN = pcall(NetFire, "Notify", "notify.bought")
Check("通知を表示できる", okN)

-- 日本語
LocalPlayer.LocaleId = "ja-jp"

print(("== 結果: %d 失敗 =="):format(Failures))
if Failures > 0 then
	error("client smoke failed")
end
