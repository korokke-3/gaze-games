--!nonstrict
--[[
	クライアントのエントリポイント。
	- ソロ: 試合をこのクライアントで動かす (入力の遅延が無い)。報酬はサーバーが結果を丸めて付ける。
	- オンライン (協力 / 対戦): 試合はサーバーが動かす。入力を送り、Snapshot を受けて描画する。
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))
local Match = require(Shared:WaitForChild("Match"))
local Net = require(Shared:WaitForChild("Net"))
local Bindings = require(Shared:WaitForChild("Bindings"))
local Practice = require(Shared:WaitForChild("Practice"))

local World = require(script:WaitForChild("World"))
local Hud = require(script:WaitForChild("Hud"))
local Input = require(script:WaitForChild("Input"))
local Menu = require(script:WaitForChild("Menu"))
local Sfx = require(script:WaitForChild("Sfx"))
local RemoteMatch = require(script:WaitForChild("RemoteMatch"))

local player = Players.LocalPlayer
local lang = Locale.langOf(player.LocaleId)
local rng = Random.new()
local SOLO_SEAT = 1

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)
task.spawn(function()
	local scripts = player:WaitForChild("PlayerScripts")
	local module = scripts:WaitForChild("PlayerModule", 10)
	if module then
		pcall(function()
			require(module):GetControls():Disable()
		end)
	end
end)

local function randomFn()
	return rng:NextNumber()
end

-- ================================================================ 状態
local profile = nil
local current = nil -- { match, world, input, conn, finished, view, online }
local demo = nil
local device = "keyboard"
local bindings = Bindings.default()

local hud = Hud.new(lang)
hud.gui.Enabled = false

local menuGui = Instance.new("ScreenGui")
menuGui.Name = "SoccerMenu"
menuGui.ResetOnSpawn = false
menuGui.IgnoreGuiInset = true
menuGui.DisplayOrder = 10
menuGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
menuGui.Parent = player:WaitForChild("PlayerGui")

local function applyTime(night)
	local cfg = night and Config.View.Night or Config.View.Day
	Lighting.ClockTime = cfg.ClockTime
	Lighting.Brightness = cfg.Brightness
end

local function findById(list, id)
	for _, item in list do
		if item.id == id then
			return item
		end
	end
	return list[1]
end

local function currentStyle(opts)
	local equipped = profile and profile.equipped or { kit = "classic", ball = "classic" }
	local kit = findById(Config.Kits, equipped.kit)
	local ball = findById(Config.Balls, equipped.ball)
	return {
		kit = { color = kit.color, keeper = kit.keeper },
		ball = { color = ball.color, trail = ball.trail },
		camera = opts.camera,
	}
end

-- ================================================================ 試合の共通処理
local menu

local function stopMatch()
	if current == nil then
		return
	end
	current.conn:Disconnect()
	current.input:destroy()
	current.world:destroy()
	current = nil
end

local function stopDemo()
	if demo == nil then
		return
	end
	demo.conn:Disconnect()
	demo.world:destroy()
	demo = nil
end

local function startDemo()
	stopDemo()
	local match = Match.new({ random = randomFn, ctrlKind = { [0] = "cpu", [1] = "cpu" }, length = 600 })
	local world = World.new(match, lang, currentStyle({ camera = 1 }))
	local conn = RunService.RenderStepped:Connect(function(dt)
		match:update(dt)
		match.events = {}
		world:step(dt, { seatId = -1, myTeam = 0 })
		world:updateCamera(dt)
	end)
	demo = { match = match, world = world, conn = conn }
end

local function backToMenu(page)
	stopMatch()
	hud.gui.Enabled = false
	applyTime(false)
	startDemo()
	menu:show(page or "play")
end

--- 試合を画面に出して、毎フレーム動かす。
--- step(dt): 試合を進める (ソロは Match:update、オンラインは補間)
local function runMatch(match, view, sink, opts, step, onEnd)
	stopMatch()
	stopDemo()
	menu:hide()
	applyTime(opts.night)
	local world = World.new(match, lang, currentStyle(opts))
	local input
	input = Input.new({
		gui = hud.gui,
		lang = lang,
		sink = sink,
		allowPause = not view.online,
		ctrlPos = function()
			local s = match:seat(view.seatId)
			return s and s.ctrl and s.ctrl.p
		end,
		onToggleHelp = function()
			hud:toggleHelp()
		end,
		onDevice = function(d)
			device = d
		end,
		onZoom = function(delta)
			world:zoom(delta)
		end,
		mouseAim = opts.mouseAim ~= false,
		bindings = bindings,
	})
	hud:setBindings(bindings, opts.mouseAim ~= false)
	device = input.device
	-- スマホは操作ガイドが左スティックと重なるので、最初は隠す (一時停止メニューから出せる)
	hud.helpVisible = device ~= "touch"
	hud.guide.Visible = hud.helpVisible
	-- 初めての人向けの操作ヒント (全部やったら二度と出さない)
	if not menu.opts.tipsDone then
		local g = function(spec)
			return hud:_glyph(spec, device)
		end
		local used = input.used
		hud:setTips({
			{ text = Locale.t(lang, "tip.pass", g("aim"), g({ "pass" })), done = function()
				return used.pass == true
			end },
			{ text = Locale.t(lang, "tip.shoot", g({ "shoot" })), done = function()
				return used.shoot == true
			end },
			{ text = Locale.t(lang, "tip.dash", g({ "dash" })), done = function()
				return used.dash == true
			end },
			{ text = Locale.t(lang, "tip.switch", g({ "l1" })), done = function()
				return used.l1 == true
			end },
		}, function()
			menu.opts.tipsDone = true
			Net.event("SaveSettings"):FireServer(menu.opts)
		end)
	elseif not menu.opts.tipSpin and device == "keyboard" and opts.mouseAim ~= false then
		-- 操作ヒントを終えた PC の人へ: スワイプの回転 (PC だけの技) を 1 回だけ案内する
		local used = input.used
		hud:setTips({
			{ text = Locale.t(lang, "tip.spin", hud:_glyph({ "pass" }, device)), done = function()
				return used.spin == true
			end },
		}, function()
			menu.opts.tipSpin = true
			Net.event("SaveSettings"):FireServer(menu.opts)
		end)
	else
		hud:setTips(nil)
	end
	hud.gui.Enabled = true
	local c = { match = match, world = world, input = input, finished = false, view = view }
	c.conn = RunService.RenderStepped:Connect(function(dt)
		input:update(dt)
		step(dt)
		view.aim = input:currentAim()
		view.point = input:currentPoint()
		view.device = device
		world:step(dt, view)
		world:updateCamera(dt)
		hud:step(match, view)
		input:setContext(hud.context == "defense" and "defense" or "attack")
		for _, e in match.events do
			Sfx.play(e.kind)
		end
		match.events = {}
		if match.ended and not c.finished then
			c.finished = true
			if onEnd then
				onEnd(c)
			end
		end
	end)
	current = c
	return c
end

-- ================================================================ ソロ
local startSolo

local function soloFinished(c)
	local r = c.match.result
	Net.event("MatchFinished"):FireServer({
		home = r.home,
		away = r.away,
		winner = r.winner,
		shootoutWin = r.shootout ~= nil and r.winner == 0,
	})
	hud.gui.Enabled = false
	menu:showResult(r, function()
		startSolo(menu.opts)
	end, function()
		backToMenu("play")
	end)
end

startSolo = function(opts)
	local forms = Config.FormationOrder
	local match = Match.new({
		random = randomFn,
		formation = { [0] = opts.formation, [1] = forms[rng:NextInteger(1, #forms)] },
		difficulty = opts.difficulty,
		length = opts.length,
		cup = opts.mode == "cup",
		tactics = { line = opts.line, press = opts.press },
		assist = opts.assist,
	})
	Net.event("MatchStarted"):FireServer({ length = opts.length, difficulty = opts.difficulty, cup = opts.mode == "cup" })
	local view = { seatId = SOLO_SEAT, myTeam = 0, online = false }
	runMatch(match, view, Input.localSink(match, SOLO_SEAT), opts, function(dt)
		match:update(dt)
	end, soloFinished)
	hud:setPauseHandlers({
		online = false,
		onOpen = function()
			if not match.paused then
				match:command(SOLO_SEAT, "pause")
			end
		end,
		onResume = function()
			if match.paused then
				match:command(SOLO_SEAT, "pause")
			end
		end,
		onQuit = function()
			-- 途中でやめた試合は報酬なし (MatchFinished を送らない)
			backToMenu("play")
		end,
	})
end

-- ================================================================ 練習 (コインは出ない。サーバーへは自己ベストだけ保存)
local startPractice

local function practiceKey(kind)
	for _, d in Menu.PRACTICE do
		if d.kind == kind then
			return d.pb
		end
	end
	return nil
end

local function practiceFinished(kind, pr, popts)
	hud.gui.Enabled = false
	local key = practiceKey(kind)
	local best = key and menu.opts[key] or 0
	local value = pr.result
	local isNew = Practice.better(kind, value, best > 0 and best or nil) and (value or 0) > 0
	if isNew and key then
		menu.opts[key] = value
		Net.event("SaveSettings"):FireServer(menu.opts)
	end
	stopMatch()
	menu:showPracticeResult(kind, value, best, isNew, function()
		startPractice(kind, popts)
	end, function()
		backToMenu("practice")
	end)
end

startPractice = function(kind, popts)
	popts = popts or {}
	local opts = menu.opts
	local pr = Practice.new(kind, {
		random = randomFn,
		assist = opts.assist,
		difficulty = opts.difficulty,
		defenders = popts.defenders,
	})
	local match = pr.match
	local view = { seatId = SOLO_SEAT, myTeam = 0, online = false }
	runMatch(match, view, Input.localSink(match, SOLO_SEAT), opts, function(dt)
		pr:update(dt)
		if pr.done then
			match.ended = true -- 結果画面へ (runMatch の onEnd)
		end
	end, function()
		practiceFinished(kind, pr, popts)
	end)
	hud:setPauseHandlers({
		online = false,
		onOpen = function()
			if not match.paused then
				match:command(SOLO_SEAT, "pause")
			end
		end,
		onResume = function()
			if match.paused then
				match:command(SOLO_SEAT, "pause")
			end
		end,
		onRestart = function()
			pr:restart()
		end,
		onQuit = function()
			backToMenu("practice")
		end,
	})
end

-- ================================================================ オンライン
local online = nil -- { remote }

local function onlineStart(info)
	local remote = RemoteMatch.new(info, player.UserId)
	local sink = Input.netSink(function(packet)
		Net.event("MatchInput"):FireServer(buffer.fromstring(packet))
	end)
	local view = { seatId = player.UserId, myTeam = remote.myTeam, online = true }
	local c = runMatch(remote, view, sink, menu.opts, function()
		remote:advance(os.clock())
	end, nil)
	remote.aimProvider = function()
		return c.input:currentAim()
	end
	online = { remote = remote }
	hud:setPauseHandlers({
		online = true,
		onQuit = function()
			Net.event("RoomLeave"):FireServer()
			online = nil
			backToMenu("online")
		end,
	})
end

--- サーバーの結果を「自分のチームが左」に直して、結果画面に出す。
local function onlineEnd(info)
	local r = info.result
	hud.gui.Enabled = false
	if r == nil then
		backToMenu("online")
		return
	end
	local mine = info.myTeam or 0
	local function swap(a, b)
		if mine == 0 then
			return a, b
		end
		return b, a
	end
	local home, away = swap(r.home, r.away)
	local sHome, sAway = swap(r.statsHome, r.statsAway)
	local winner = nil
	if r.winner ~= nil then
		winner = r.winner == mine and 0 or 1
	end
	local poss = mine == 0 and r.possession or (100 - r.possession)
	local shootout = nil
	if r.shootoutHome ~= nil then
		local a, b = swap(r.shootoutHome, r.shootoutAway)
		shootout = { home = a, away = b }
	end
	local view = {
		home = home,
		away = away,
		winner = winner,
		possession = poss,
		extra = r.extra,
		shootout = shootout,
		stats = { [0] = sHome, [1] = sAway },
	}
	stopMatch()
	menu:showResult(view, function()
		backToMenu("online")
	end, function()
		Net.event("RoomLeave"):FireServer()
		backToMenu("online")
	end)
	if info.reward then
		menu:setReward(info.reward)
	end
	online = nil
end

-- ================================================================ メニュー
local saveToken = 0
local bindToken = 0
local function saveBindings()
	bindToken += 1
	local token = bindToken
	task.delay(1.2, function()
		if token == bindToken then
			Net.event("SaveBindings"):FireServer(bindings)
		end
	end)
end
menu = Menu.new(menuGui, lang, {
	onBind = function(dev, action, slot, key)
		local removed
		bindings, removed = Bindings.assign(bindings, dev, action, slot, key)
		menu:setBindings(bindings)
		if removed ~= nil and key ~= nil then
			menu:toast(Locale.t(lang, "controls.moved", Bindings.display(key), Locale.t(lang, "action." .. removed)))
		end
		saveBindings()
	end,
	onPreset = function(name)
		bindings = Bindings.fromPreset(name)
		menu:setBindings(bindings)
		-- キーボードのみのプリセットは、狙いも WASD にする
		menu.opts.mouseAim = name ~= "keys"
		saveBindings()
		Net.event("SaveSettings"):FireServer(menu.opts)
	end,
	onStart = function(opts)
		startSolo(opts)
	end,
	onPractice = function(kind, popts)
		menu.opts.practiceDefenders = popts.defenders
		startPractice(kind, popts)
	end,
	onBuy = function(kind, id)
		Net.event("BuyItem"):FireServer(kind, id)
	end,
	onEquip = function(kind, id)
		Net.event("EquipItem"):FireServer(kind, id)
	end,
	onPrompt = function(kind, key)
		Net.event("PromptPurchase"):FireServer(kind, key)
	end,
	onSettings = function(opts)
		saveToken += 1
		local token = saveToken
		task.delay(1.2, function()
			if token == saveToken then
				Net.event("SaveSettings"):FireServer(opts)
			end
		end)
	end,
	onRoomCreate = function(mode, opts)
		Net.event("RoomCreate"):FireServer(mode, {
			length = opts.length,
			difficulty = opts.difficulty,
			cup = opts.mode == "cup",
			formation = opts.formation,
			assist = opts.assist,
		})
	end,
	onRoomJoin = function(id)
		Net.event("RoomJoin"):FireServer(id)
	end,
	onRoomLeave = function()
		Net.event("RoomLeave"):FireServer()
	end,
	onRoomTeam = function(team)
		Net.event("RoomTeam"):FireServer(team)
	end,
	onRoomOpts = function(opts)
		Net.event("RoomOpts"):FireServer({
			length = opts.length,
			difficulty = opts.difficulty,
			cup = opts.mode == "cup",
			formation = opts.formation,
			assist = opts.assist,
		})
	end,
	onRoomStart = function()
		Net.event("RoomStart"):FireServer()
	end,
})
menu.myId = player.UserId

Net.event("State").OnClientEvent:Connect(function(state)
	local first = profile == nil
	profile = state
	if first and state.bindings then
		bindings = Bindings.validate(state.bindings)
		menu:setBindings(bindings)
	end
	menu:setProfile(state)
	if first and state.readOnly then
		menu:toast(Locale.t(lang, "notify.readonly"))
	end
end)
Net.event("MatchReward").OnClientEvent:Connect(function(reward)
	menu:setReward(reward)
end)
Net.event("Notify").OnClientEvent:Connect(function(key, arg)
	menu:toast(Locale.t(lang, key, arg))
end)
Net.event("Rooms").OnClientEvent:Connect(function(list)
	menu:setRooms(list)
end)
Net.event("RoomState").OnClientEvent:Connect(function(room)
	menu:setRoom(room)
end)
Net.event("OnlineStart").OnClientEvent:Connect(function(info)
	onlineStart(info)
end)
Net.event("OnlineSnap").OnClientEvent:Connect(function(str)
	if online ~= nil then
		if typeof(str) == "buffer" then
			str = buffer.tostring(str)
		end
		online.remote:apply(str, os.clock())
	end
end)
Net.event("OnlineEnd").OnClientEvent:Connect(function(info)
	onlineEnd(info)
end)

Net.event("RequestState"):FireServer()
startDemo()
menu:show("play")
