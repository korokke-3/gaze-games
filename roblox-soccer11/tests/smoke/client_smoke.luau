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
end)
Check("キー入力を処理できる", okP, errP)
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
Check("結果画面に「もう一度」", FindButton("Play again") ~= nil)
local back = FindButton("Back to menu")
Check("メニューへ戻れる", back ~= nil and pcall(back.fn))

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
	for i = 1, 30 * 70 do
		server:update(1 / 30)
		if i % 2 == 0 then
			local str
			str, seq = Snapshot.encode(server, seq)
			server.events = {}
			NetFire("OnlineSnap", str)
		end
		-- クライアントから届いた入力をサーバーの試合へ
		for _, c in Calls do
			if c.name == "MatchInput" and not c.done then
				c.done = true
				local inp = Snapshot.unpackInput(c.args[1])
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

print(("== 結果: %d 失敗 =="):format(Failures))
if Failures > 0 then
	error("client smoke failed")
end
