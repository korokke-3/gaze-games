--!strict
--[[
	Monetization — ゲームパスと開発者製品 (コインパック) の購入処理。

	- ProcessReceipt は idempotent: 購入 ID を保存し、二重付与しない。
	- 保存に失敗した場合は NotProcessedYet を返し、Roblox に再試行させる。
	- ID が 0 (未作成) の商品は購入を受け付けない。
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Data = require(script.Parent.Data)
local Store = require(script.Parent.Store)

local Monetization = {}

local MAX_RECEIPTS = 100

local function productByIdMap()
	local map = {}
	for key, def in Config.Monetization.Products do
		if def.id ~= 0 then
			map[def.id] = { key = key, def = def }
		end
	end
	return map
end

local function passByIdMap()
	local map = {}
	for key, def in Config.Monetization.Passes do
		if def.id ~= 0 then
			map[def.id] = key
		end
	end
	return map
end

--- クライアントの購入ボタン。kind: "pass" | "product"
function Monetization.prompt(player: Player, kind: any, key: any)
	if typeof(kind) ~= "string" or typeof(key) ~= "string" then
		return
	end
	if kind == "pass" then
		local def = (Config.Monetization.Passes :: any)[key]
		if def == nil or def.id == 0 or Store.hasPass(player, key) then
			return
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, def.id)
		end)
	elseif kind == "product" then
		local def = (Config.Monetization.Products :: any)[key]
		if def == nil or def.id == 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, def.id)
		end)
	end
end

function Monetization.start()
	local products = productByIdMap()
	local passes = passByIdMap()

	MarketplaceService.ProcessReceipt = function(info)
		local player = Players:GetPlayerByUserId(info.PlayerId)
		if player == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local entry = products[info.ProductId]
		local data = Data.get(player)
		if entry == nil or data == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local rid = tostring(info.PurchaseId)
		if data.receipts[rid] then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		data.receipts[rid] = os.time()
		-- 古いレシートを間引く (無限に増やさない)
		local count, oldestKey, oldest = 0, nil, math.huge
		for k, t in data.receipts do
			count += 1
			if t < oldest then
				oldestKey, oldest = k, t
			end
		end
		if count > MAX_RECEIPTS and oldestKey ~= nil then
			data.receipts[oldestKey] = nil
		end
		data.coins += entry.def.coins
		Data.markDirty(player)
		if not Data.isReadOnly(player) and not Data.save(player, false) then
			-- 保存できなかった: 付与を取り消して再試行させる
			data.coins -= entry.def.coins
			data.receipts[rid] = nil
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		Net.event("Notify"):FireClient(player, "notify.coins", entry.def.coins)
		Store.push(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		local name = passes[passId]
		if name ~= nil and wasPurchased then
			Store.setPass(player, name, true)
			Net.event("Notify"):FireClient(player, "notify.pass")
			Store.push(player)
		end
	end)
end

return Monetization
