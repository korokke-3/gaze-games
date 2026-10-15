--!strict
--[[
	サーバーのエントリポイント。保存・購入・報酬の受け口だけを持つ (試合の計算はクライアント)。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) -- RemoteEvent を生成する

local Data = require(script.Services.Data)
local Store = require(script.Services.Store)
local Matches = require(script.Services.Matches)
local Monetization = require(script.Services.Monetization)

Data.start()
Monetization.start()

-- 連打対策: 1 人あたり、種類ごとの最短間隔 [s]
local lastCall: { [Player]: { [string]: number } } = {}
local function throttled(player: Player, name: string, interval: number): boolean
	local t = lastCall[player]
	if t == nil then
		t = {}
		lastCall[player] = t
	end
	local now = os.clock()
	if t[name] ~= nil and now - t[name] < interval then
		return true
	end
	t[name] = now
	return false
end

local function onJoin(player: Player)
	Data.load(player)
	Store.refreshPasses(player)
	Store.push(player)
end

Players.PlayerAdded:Connect(onJoin)
for _, p in Players:GetPlayers() do
	task.spawn(onJoin, p)
end

Players.PlayerRemoving:Connect(function(player)
	Matches.remove(player)
	Store.remove(player)
	lastCall[player] = nil
	Data.release(player)
end)

Net.event("RequestState").OnServerEvent:Connect(function(player)
	if not throttled(player, "state", 0.5) then
		Store.push(player)
	end
end)
Net.event("MatchStarted").OnServerEvent:Connect(function(player, cfg)
	if not throttled(player, "start", 1) then
		Matches.start(player, cfg)
	end
end)
Net.event("MatchFinished").OnServerEvent:Connect(function(player, report)
	if not throttled(player, "finish", 1) then
		Matches.finish(player, report)
	end
end)
Net.event("BuyItem").OnServerEvent:Connect(function(player, kind, id)
	if not throttled(player, "buy", 0.3) then
		Store.buy(player, kind, id)
	end
end)
Net.event("EquipItem").OnServerEvent:Connect(function(player, kind, id)
	if not throttled(player, "equip", 0.2) then
		Store.equip(player, kind, id)
	end
end)
Net.event("PromptPurchase").OnServerEvent:Connect(function(player, kind, key)
	if not throttled(player, "prompt", 1) then
		Monetization.prompt(player, kind, key)
	end
end)
Net.event("SaveSettings").OnServerEvent:Connect(function(player, settings)
	if not throttled(player, "settings", 1) then
		Store.saveSettings(player, settings)
	end
end)
