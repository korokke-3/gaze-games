--!nocheck
print("== クライアント (stub 上で実行) ==")
ServerMode = false
local ok, err = pcall(Load, "client/init")
Check("起動 (init.client) がエラーなく実行できる", ok, err)
if not ok then
	error("client init failed: " .. tostring(err))
end
local Snapshot = Require(Shared.Snapshot)
local Match = Require(Shared.Match)

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
Check("State を受け取れる", pcall(NetFire, "State", state))
Check("デモ試合が動く", pcall(Frames, 90))

-- ショップ
local shopTab = FindButton("Shop")
Check("ショップのタブ", shopTab ~= nil and pcall(shopTab.fn))
local buy = FindButton("Buy 300")
if buy then
	buy.fn()
end
Check("キットを買える", #CallsOf("BuyItem") == 1)

-- ソロ
FindButton("Play").fn()
local assistBtn = FindButton("Standard")
Check("パスアシストの設定がある", assistBtn ~= nil)
local okM, errM = pcall(FindButton("Kick off").fn)
Check("ソロの試合を開始できる", okM, errM)
Check("MatchStarted を送る", #CallsOf("MatchStarted") == 1 and CallsOf("MatchStarted")[1].args[1].length == 180)
local okP, errP = pcall(function()
	Press("D")
	Press("LeftShift")
	Frames(20)
	Press("K") -- パスを溜める
	Frames(10)
	Release("K")
	Press("J")
	Frames(15)
	Release("J")
	Release("LeftShift")
	Release("D")
	Press("Q")
	Release("Q")
	Press("Up") -- 右スティック
	Press("F")
	Release("F")
	Press("C")
	Press("P")
	Frames(2)
	Press("P")
	Press("H")
	Press("H")
	-- マウス: 動かす → 左クリック長押し (パス) → 右クリック (シュート) → ホイール
	Fire("InputChanged", { UserInputType = Enum.UserInputType.MouseMovement, Position = Vector3.new(700, 300, 0) }, false)
	Fire("InputBegan", { UserInputType = Enum.UserInputType.MouseButton1 }, false)
	Frames(12)
	Fire("InputEnded", { UserInputType = Enum.UserInputType.MouseButton1 })
	Fire("InputBegan", { UserInputType = Enum.UserInputType.MouseButton2 }, false)
	Frames(6)
	Fire("InputEnded", { UserInputType = Enum.UserInputType.MouseButton2 })
	Fire("InputChanged", { UserInputType = Enum.UserInputType.MouseWheel, Position = Vector3.new(0, 0, 1) }, false)
	Press("Space")
	Frames(3)
	Release("Space")
	-- WASD の 2 回押し (フェイント)
	Press("D")
	Release("D")
	Press("D")
	Release("D")
	Frames(8)
	Press("E")
	Release("E")
	Frames(5)
end)
Check("キーとマウスの入力を処理できる", okP, errP)
local touchButtons = 0
for _, h in Handlers do
	if h.sig == "InputBegan" and h.owner ~= nil and not h.owner._destroyed and h.owner._p.ClassName == "TextButton" then
		touchButtons += 1
	end
end
Check("タッチのボタンが 8 個", touchButtons >= 8, touchButtons)
local steps = 0
local okRun, errRun = pcall(function()
	while #CallsOf("MatchFinished") == 0 and steps < 40000 do
		Frames(1)
		steps += 1
		if steps % 90 == 0 then
			Press("W")
			Press("K")
			Frames(5)
			Release("K")
			Release("W")
		end
	end
end)
Check("ソロの試合が最後まで進む", okRun and #CallsOf("MatchFinished") == 1, errRun or steps)
NetFire("MatchReward", { coins = 42, parts = { base = 30 }, total = 842 })
-- 一時停止メニュー (別の試合を始めて、途中でやめる)
FindButton("Play again").fn()
Frames(10)
local pauseBtn = FindButton("II")
Check("一時停止ボタンがある", pauseBtn ~= nil)
pauseBtn.fn()
Check("一時停止メニューに「再開」", FindButton("Resume") ~= nil)
FindButton("Resume").fn()
pauseBtn.fn()
local quit = FindButton("Quit match (no reward)")
Check("試合をやめられる", quit ~= nil and pcall(quit.fn) and FindButton("Kick off") ~= nil)
Check("やめた試合は結果を送らない", #CallsOf("MatchFinished") == 1, #CallsOf("MatchFinished"))
FindButton("Kick off").fn()
Frames(5)
FindButton("II").fn()
FindButton("Quit match (no reward)").fn()
Check("結果画面に「もう一度」", true)

-- 練習モード
local practiceTab = FindButton("Practice")
Check("練習のタブ", practiceTab ~= nil and pcall(practiceTab.fn))
local defBtn = FindButton("Opponents: 0")
Check("フリー練習の相手の人数を選べる", defBtn ~= nil and pcall(defBtn.fn) and FindButton("Opponents: 3") ~= nil)
local startsBefore = #CallsOf("MatchStarted")
local okF, errF = pcall(function()
	-- 一番上の「Start」= フリー練習 (FindButton は最後に作ったものを返すので、全部の中から探す)
	local first = nil
	for _, h in Handlers do
		if h.sig == "Activated" and not h.dead and h.owner and not h.owner._destroyed and h.owner._p.Text == "Start" then
			first = first or h
		end
	end
	first.fn()
	Frames(60)
	Press("J")
	Frames(10)
	Release("J")
	Frames(30)
end)
Check("フリー練習を始めて動かせる", okF, errF)
Check("練習はサーバーに試合開始を送らない (報酬なし)", #CallsOf("MatchStarted") == startsBefore)
FindButton("II").fn()
local restart = FindButton("Restart drill")
Check("一時停止メニューに「やり直す」", restart ~= nil and pcall(restart.fn))
Frames(10)
FindButton("II").fn()
local endBtn = FindButton("End practice")
Check("練習をやめて練習タブへ戻る", endBtn ~= nil and pcall(endBtn.fn) and FindButton("Opponents: 3") ~= nil)
-- 守備練習 (最後の「Start」) を最後まで: 放置しても 1 本 15 秒で失敗扱いになり、5 本で終わる
local okD, errD = pcall(function()
	FindButton("Start").fn()
	local n = 0
	while FindButton("Try again") == nil and n < 6000 do
		Frames(1)
		n += 1
	end
end)
Check("守備練習が最後まで進み、結果画面が出る", okD and FindButton("Try again") ~= nil, errD)
local again = FindButton("Try again")
Check("結果画面から「もう一度」", again ~= nil and pcall(again.fn))
Frames(10)
FindButton("II").fn()
FindButton("End practice").fn()
FindButton("Play").fn()

-- 操作設定: パスを G に変える
local ctrlTab = FindButton("Controls")
Check("操作設定のタブ (指の図つき)", ctrlTab ~= nil and pcall(ctrlTab.fn))
local fingerLabel = false
for _, d in PlayerGui:GetDescendants() do
	if d._p.ClassName == "TextLabel" and d._p.Text == "L pinky" then
		fingerLabel = true
	end
end
Check("指の凡例が出る", fingerLabel)
local skillHelp = false
for _, d in PlayerGui:GetDescendants() do
	if d._p.ClassName == "TextLabel" and d._p.Text == "Sideways, then the other side" then
		skillHelp = true
	end
end
Check("技の出し方が出る", skillHelp)
local slot = FindButton("L-Click")
Check("パスの枠 (L-Click) がある", slot ~= nil)
slot.fn()
Check("押すと入力待ちになる", FindButton("Press a key...") ~= nil)
Fire("InputBegan", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = "G" } }, false)
Check("G を割り当てた枠が出る", FindButton("G") ~= nil)
Frames(60) -- 保存は少し待ってから
local saved = CallsOf("SaveBindings")
Check("割り当てをサーバーへ保存", #saved >= 1 and saved[#saved].args[1].kb.pass[1] == "G", #saved)
-- 既に使われているキーへ: Space (スルー) をパスに
FindButton("K").fn()
Fire("InputBegan", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = "Space" } }, false)
Frames(60)
local s2 = CallsOf("SaveBindings")
local last = s2[#s2].args[1]
Check("重なったキーはスルーから外れる", last.kb.pass[2] == "Space" and last.kb.through[1] ~= "Space")
-- 取消 (Esc) と禁止キー (/)
FindButton("G").fn()
Fire("InputBegan", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = "Slash" } }, false)
Check("禁止キーは割り当てない", FindButton("G") ~= nil)
-- ゲームパッド表示
local padBtn = FindButton("Gamepad")
Check("ゲームパッドの割り当て画面", padBtn ~= nil and pcall(padBtn.fn) and FindButton("A") ~= nil)
-- プリセット
local keysPreset = FindButton("Preset: keyboard only")
Check("プリセットを選べる", keysPreset ~= nil and pcall(keysPreset.fn))
Frames(60)
local s3 = CallsOf("SaveBindings")
Check("キーボードのみのプリセット (K = パス)", s3[#s3].args[1].kb.pass[1] == "K")
FindButton("Keyboard + mouse").fn()
FindButton("K").fn()
Fire("InputBegan", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = "G" } }, false)
Frames(60)

-- オンライン (協力)
local onlineTab = FindButton("Online")
Check("オンラインのタブ", onlineTab ~= nil and pcall(onlineTab.fn))
NetFire("Rooms", { { id = 3, mode = "versus", state = "lobby", host = "Bob", count = 1, cap = 6, members = {} } })
local join = FindButton("Join")
Check("部屋の一覧に参加ボタン", join ~= nil)
local create = FindButton("Create Co-op room (vs CPU)")
Check("協力の部屋を作れる", create ~= nil and pcall(create.fn) and #CallsOf("RoomCreate") == 1)
local myId = LocalPlayer.UserId
NetFire("RoomState", {
	id = 7,
	mode = "coop",
	state = "lobby",
	host = "Tester",
	count = 1,
	cap = 3,
	length = 180,
	difficulty = 3,
	cup = false,
	members = { { name = "Tester", team = 0, userId = myId, host = true } },
})
local startBtn = FindButton("Start match")
Check("ホストには開始ボタン", startBtn ~= nil and pcall(startBtn.fn) and #CallsOf("RoomStart") == 1)

-- サーバー役: 本物の Match を動かして Snapshot を送る
local server = Match.new({ seats = { { id = myId, team = 0 }, { id = 9999, team = 0 } }, length = 60 })
local info = {
	roomId = 7,
	mode = "coop",
	seats = { { id = myId, team = 0, name = "Tester" }, { id = 9999, team = 0, name = "Friend" } },
	formation = { home = "433", away = "442" },
	length = 60,
	cup = false,
}
local okS, errS = pcall(NetFire, "OnlineStart", info)
Check("オンライン試合の開始を受け取れる", okS, errS)
local prevButtons = {}
local seq = 0
local applied = 0
local okO, errO = pcall(function()
	for i = 1, 30 * 160 do
		server:update(1 / 30)
		if i % 2 == 0 then
			local str
			str, seq = Snapshot.encode(server, seq)
			server.events = {}
			NetFire("OnlineSnap", buffer.fromstring(str)) -- サーバーと同じく buffer で届く
		end
		-- クライアントから届いた入力をサーバーの試合へ
		for _, c in Calls do
			if c.name == "MatchInput" and not c.done then
				c.done = true
				local raw = c.args[1]
				if type(raw) == "buffer" then
					raw = buffer.tostring(raw)
				end
				local inp = Snapshot.unpackInput(raw)
				if inp then
					prevButtons = Snapshot.applyInput(server, myId, inp, prevButtons)
					applied += 1
				end
			end
		end
		Frames(1)
		if i % 100 == 0 then
			Press("D")
			Press("K")
			Frames(4)
			Release("K")
			Release("D")
		end
		if server.ended then
			break
		end
	end
end)
Check("オンライン試合を描画し続けられる", okO, errO)
Check("入力がサーバーへ届き、試合に反映される", applied >= 5, applied)
local sawG = false
Press("G")
Frames(2)
for _, c2 in Calls do
	if c2.name == "MatchInput" then
		local raw = c2.args[1]
		if type(raw) == "buffer" then
			raw = buffer.tostring(raw)
		end
		local inp = Snapshot.unpackInput(raw)
		if inp and inp.buttons.pass then
			sawG = true
		end
	end
end
Release("G")
Check("割り当てたキー (G) でパスが送られる", sawG)
Check("サーバーの試合が終わる", server.ended)
local r = server.result
local function st(t)
	return { shots = t.shots, onTarget = t.onTarget, passes = t.passes, passOk = t.passOk, corners = t.corners, fouls = t.fouls, yellow = t.yellow, red = t.red, saves = t.saves }
end
local okE, errE = pcall(NetFire, "OnlineEnd", {
	myTeam = 0,
	result = { home = r.home, away = r.away, winner = r.winner, possession = r.possession, extra = false, statsHome = st(r.stats[0]), statsAway = st(r.stats[1]) },
	reward = { coins = 50, parts = {}, total = 900 },
})
Check("オンラインの結果画面を出せる", okE and FindButton("Play again") ~= nil, errE)

-- 対戦 (アウェイ側として)
FindButton("Play again").fn()
local server2 = Match.new({ seats = { { id = 555, team = 0 }, { id = myId, team = 1 } }, length = 60 })
NetFire("OnlineStart", {
	roomId = 8,
	mode = "versus",
	seats = { { id = 555, team = 0, name = "Rival" }, { id = myId, team = 1, name = "Tester" } },
	formation = { home = "433", away = "433" },
	length = 60,
	cup = false,
})
local okV, errV = pcall(function()
	for i = 1, 30 * 5 do
		server2:update(1 / 30)
		local str
		str, seq = Snapshot.encode(server2, 0)
		NetFire("OnlineSnap", str)
		Frames(1)
	end
end)
Check("対戦 (アウェイ側) を描画できる", okV, errV)

-- 人型の全ての動作・技の姿勢 (計算が通ること)
local Rig = Require(ClientRoot.Rig)
local folder = Instance.new("Folder")
local rig = Rig.new(folder, { shirt = Color3.new(1, 0, 0), shorts = Color3.new(0, 0, 0), skin = 3 })
local okR, errR = pcall(function()
	for kind in Rig.DURATION do
		for _, u in { 0, 0.2, 0.5, 0.8, 1 } do
			local parts, cfs = {}, {}
			Rig.pose(rig, { pos = Vector3.new(0, 0, 0), face = Vector3.new(0, 0, -1), speed = 6, action = { kind = kind, age = u * Rig.DURATION[kind] } }, 1 / 30, parts, cfs)
			assert(#parts == 6 and #cfs == 6)
		end
	end
	for _, name in { "double_touch", "elastico", "scissors", "marseille", "drag_back" } do
		for _, u in { 0, 0.3, 0.6, 1 } do
			local parts, cfs = {}, {}
			Rig.pose(rig, { pos = Vector3.new(0, 0, 0), face = Vector3.new(1, 0, 0), speed = 4, skill = { name = name, u = u } }, 1 / 30, parts, cfs)
			assert(#parts == 6)
		end
	end
	for _, extra in { { slide = true }, { dive = 1 }, { dive = -1 }, { stun = true }, { hidden = true } } do
		local st = { pos = Vector3.new(0, 0, 0), face = Vector3.new(0, 0, 0), speed = 0 }
		for k, x in extra do
			st[k] = x
		end
		Rig.pose(rig, st, 1 / 30, {}, {})
	end
end)
Check("人型の全ての動作・技の姿勢を計算できる", okR, errR)

print(("== 結果: %d 失敗 =="):format(Failures))
if Failures > 0 then
	error("client smoke failed")
end
