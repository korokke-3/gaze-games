--!nonstrict
--[[
	クライアントのエントリポイント。
	試合のシミュレーションはこのクライアント上で動かす (1 人用で、入力の遅延を無くすため)。
	収益化やランキングなどサーバーを必要とする機能を足す時は、Match をサーバーへ移す。
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Locale = require(Shared:WaitForChild("Locale"))
local Match = require(Shared:WaitForChild("Match"))

local World = require(script:WaitForChild("World"))
local Hud = require(script:WaitForChild("Hud"))
local Input = require(script:WaitForChild("Input"))

local player = Players.LocalPlayer
local lang = Locale.langOf(player.LocaleId)

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

local hud = Hud.new(lang)

local current = nil -- { match, world, input, conn }

local function stopMatch()
	if current == nil then
		return
	end
	current.conn:Disconnect()
	current.input:destroy()
	current.world:destroy()
	current = nil
end

local rng = Random.new()
local startMatch

startMatch = function()
	stopMatch()
	local match = Match.new({
		random = function()
			return rng:NextNumber()
		end,
	})
	local world = World.new(match, lang)
	local input = Input.new(match, hud.gui, lang, function()
		hud:toggleHelp()
	end)
	local finished = false
	local conn = RunService.RenderStepped:Connect(function(dt)
		match:update(dt)
		world:step(dt)
		world:updateCamera(dt)
		hud:step(match)
		if match.ended and not finished then
			finished = true
			hud:showResult(match.result, function()
				startMatch()
			end)
		end
	end)
	current = { match = match, world = world, input = input, conn = conn }
end

-- タイトルの背景にはデモ用の試合 (CPU 同士) を流す
do
	local demo = Match.new({
		random = function()
			return rng:NextNumber()
		end,
		ctrlKind = { [0] = "cpu", [1] = "cpu" },
	})
	local world = World.new(demo, lang)
	local conn = RunService.RenderStepped:Connect(function(dt)
		demo:update(dt)
		world:step(dt)
		world:updateCamera(dt)
		hud:step(demo)
	end)
	hud:showTitle(function()
		conn:Disconnect()
		world:destroy()
		startMatch()
	end)
end
