--!nonstrict
--[[
	クライアントのエントリポイント。
	試合のシミュレーションはこのクライアント上で動かす (1 人用で、入力の遅延を無くすため)。
	コイン・所持品・購入はサーバーが持つ (src/server)。試合結果はサーバーが丸めて報酬にする。
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

local World = require(script:WaitForChild("World"))
local Hud = require(script:WaitForChild("Hud"))
local Input = require(script:WaitForChild("Input"))
local Menu = require(script:WaitForChild("Menu"))
local Sfx = require(script:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local lang = Locale.langOf(player.LocaleId)
local rng = Random.new()

-- キャラクターを使わないので、標準の移動操作と UI を止める
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
local profile = nil -- サーバーから届く自分の状態 (コイン・所持品・設定)
local current = nil -- { match, world, input, conn, finished }
local demo = nil -- タイトル背景の CPU 同士の試合

local hud = Hud.new(lang)
hud.gui.Enabled = false -- 試合中だけ表示する

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

--- 装備中のキット / ボールを、見た目の設定にする。
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

-- ================================================================ 試合の開始・終了
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
	local match = Match.new({
		random = randomFn,
		ctrlKind = { [0] = "cpu", [1] = "cpu" },
		length = 600,
	})
	local world = World.new(match, lang, currentStyle({ camera = 1 }))
	local conn = RunService.RenderStepped:Connect(function(dt)
		match:update(dt)
		world:step(dt)
		world:updateCamera(dt)
		if match.ended then
			match.events = {}
		end
	end)
	demo = { match = match, world = world, conn = conn }
end

local function backToMenu()
	stopMatch()
	hud.gui.Enabled = false
	applyTime(false)
	startDemo()
	menu:show("play")
end

local startMatch

local function finishMatch(c)
	local r = c.match.result
	c.finished = true
	Net.event("MatchFinished"):FireServer({
		home = r.home,
		away = r.away,
		winner = r.winner,
		shootoutWin = r.shootout ~= nil and r.winner == 0,
	})
	hud.gui.Enabled = false
	menu:showResult(r, function()
		startMatch(menu.opts)
	end, backToMenu)
end

startMatch = function(opts)
	stopMatch()
	stopDemo()
	menu:hide()
	local cup = opts.mode == "cup"
	local forms = Config.FormationOrder
	local aiForm = forms[rng:NextInteger(1, #forms)]
	local match = Match.new({
		random = randomFn,
		formation = { [0] = opts.formation, [1] = aiForm },
		difficulty = opts.difficulty,
		length = opts.length,
		cup = cup,
		tactics = { line = opts.line, press = opts.press },
	})
	Net.event("MatchStarted"):FireServer({ length = opts.length, difficulty = opts.difficulty, cup = cup })
	applyTime(opts.night)
	local world = World.new(match, lang, currentStyle(opts))
	local input = Input.new(match, hud.gui, lang, function()
		hud:toggleHelp()
	end)
	hud.gui.Enabled = true
	local c = { match = match, world = world, input = input, finished = false }
	c.conn = RunService.RenderStepped:Connect(function(dt)
		match:update(dt)
		world:step(dt)
		world:updateCamera(dt)
		hud:step(match)
		for _, e in match.events do
			Sfx.play(e.kind)
		end
		match.events = {}
		if match.ended and not c.finished then
			finishMatch(c)
		end
	end)
	current = c
end

-- ================================================================ メニュー・サーバーとのやり取り
local saveToken = 0
menu = Menu.new(menuGui, lang, {
	onStart = function(opts)
		startMatch(opts)
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
		-- 変更が落ち着いてから保存する (サーバー側は連打を間引くため)
		saveToken += 1
		local token = saveToken
		task.delay(1.2, function()
			if token == saveToken then
				Net.event("SaveSettings"):FireServer(opts)
			end
		end)
	end,
})

Net.event("State").OnClientEvent:Connect(function(state)
	local first = profile == nil
	profile = state
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

Net.event("RequestState"):FireServer()
startDemo()
menu:show("play")
