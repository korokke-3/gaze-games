--!strict
--[[
	サーバーのエントリポイント。保存・購入・報酬の受け口だけを持つ (試合の計算はクライアント)。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) -- RemoteEvent を生成する

local Data = require(script.Services.Data)
local Store = require(script.Services.Store)
local Matches = require(script.Services.Matches)
local Monetization = require(script.Services.Monetization)
local Rooms = require(script.Services.Rooms)

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
	Rooms.remove(player)
	Matches.remove(player)
	Store.remove(player)
	lastCall[player] = nil
	Data.release(player)
end)

Net.event("RequestState").OnServerEvent:Connect(function(player)
	if not throttled(player, "state", 0.5) then
		Store.push(player)
		Net.event("Rooms"):FireClient(player, Rooms.list())
	end
end)

-- ================================================================ オンライン (協力 / 対戦)
Net.event("RoomList").OnServerEvent:Connect(function(player)
	if not throttled(player, "roomlist", 0.5) then
		Net.event("Rooms"):FireClient(player, Rooms.list())
	end
end)
Net.event("RoomCreate").OnServerEvent:Connect(function(player, mode, opts)
	if not throttled(player, "room", 0.5) then
		Rooms.create(player, mode, opts)
	end
end)
Net.event("RoomJoin").OnServerEvent:Connect(function(player, id)
	if typeof(id) == "number" and not throttled(player, "room", 0.5) then
		Rooms.join(player, id)
	end
end)
Net.event("RoomLeave").OnServerEvent:Connect(function(player)
	Rooms.leave(player)
end)
Net.event("RoomTeam").OnServerEvent:Connect(function(player, team)
	if not throttled(player, "room", 0.3) then
		Rooms.setTeam(player, team)
	end
end)
Net.event("RoomPos").OnServerEvent:Connect(function(player, index)
	if not throttled(player, "roompos", 0.2) then
		Rooms.setPos(player, index)
	end
end)
Net.event("RoomOpts").OnServerEvent:Connect(function(player, opts)
	if not throttled(player, "roomopts", 0.3) then
		Rooms.setOpts(player, opts)
	end
end)
Net.event("RoomStart").OnServerEvent:Connect(function(player)
	if not throttled(player, "room", 0.5) then
		Rooms.start(player)
	end
end)
Net.event("MatchInput").OnServerEvent:Connect(function(player, packet)
	Rooms.input(player, packet)
end)
RunService.Heartbeat:Connect(function(dt)
	Rooms.tick(dt)
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
Net.event("SaveBindings").OnServerEvent:Connect(function(player, bindings)
	if not throttled(player, "bindings", 1) then
		Store.saveBindings(player, bindings)
	end
end)
Net.event("SaveSettings").OnServerEvent:Connect(function(player, settings)
	if not throttled(player, "settings", 1) then
		Store.saveSettings(player, settings)
	end
end)
