--!strict
--[[
	Store — キット / ボールの所持・購入 (コイン)・装備と、状態のクライアントへの送信。
	勝敗に影響するものは売らない (見た目だけ)。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Data = require(script.Parent.Data)
local Bindings = require(Shared:WaitForChild("Bindings"))

local Store = {}

-- ゲームパスの所持 (セッション中のキャッシュ。保存はしない)
local passes: { [Player]: { VIP: boolean, AllKits: boolean } } = {}

local function catalog(kind: string): any?
	if kind == "kit" then
		return Config.Kits
	elseif kind == "ball" then
		return Config.Balls
	end
	return nil
end

local function find(kind: string, id: string): any?
	local list = catalog(kind)
	if list == nil then
		return nil
	end
	for _, item in list do
		if item.id == id then
			return item
		end
	end
	return nil
end

function Store.hasPass(player: Player, name: string): boolean
	local p = passes[player]
	return p ~= nil and (p :: any)[name] == true
end

function Store.setPass(player: Player, name: string, owned: boolean)
	local p = passes[player]
	if p == nil then
		p = { VIP = false, AllKits = false }
		passes[player] = p
	end
	;(p :: any)[name] = owned
end

--- 起動時に、設定済みのゲームパスの所持を確認する。
function Store.refreshPasses(player: Player)
	for name, def in Config.Monetization.Passes do
		if def.id ~= 0 then
			local ok, owned = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
			end)
			Store.setPass(player, name, ok and owned == true)
		else
			Store.setPass(player, name, false)
		end
	end
end

--- その項目を使えるか。
function Store.owns(player: Player, kind: string, id: string): boolean
	local item = find(kind, id)
	local data = Data.get(player)
	if item == nil or data == nil then
		return false
	end
	if item.vip then
		return Store.hasPass(player, "VIP") -- VIP 限定は VIP パスだけ (全解放パスにも含めない)
	end
	if item.price == 0 or Store.hasPass(player, "AllKits") then
		return true
	end
	local owned = if kind == "kit" then data.kits else data.balls
	return owned[id] == true
end

function Store.state(player: Player)
	local data = Data.get(player)
	if data == nil then
		return nil
	end
	local owned = { kit = {}, ball = {} }
	for _, k in Config.Kits do
		owned.kit[k.id] = Store.owns(player, "kit", k.id)
	end
	for _, b in Config.Balls do
		owned.ball[b.id] = Store.owns(player, "ball", b.id)
	end
	return {
		coins = data.coins,
		owned = owned,
		equipped = data.equipped,
		passes = {
			VIP = Store.hasPass(player, "VIP"),
			AllKits = Store.hasPass(player, "AllKits"),
		},
		stats = data.stats,
		settings = data.settings,
		bindings = data.bindings or Bindings.default(),
		readOnly = Data.isReadOnly(player),
		-- ID 未作成の商品はクライアントで購入ボタンを無効にする
		available = {
			VIP = Config.Monetization.Passes.VIP.id ~= 0,
			AllKits = Config.Monetization.Passes.AllKits.id ~= 0,
			Coins500 = Config.Monetization.Products.Coins500.id ~= 0,
			Coins2000 = Config.Monetization.Products.Coins2000.id ~= 0,
			Coins10000 = Config.Monetization.Products.Coins10000.id ~= 0,
		},
	}
end

function Store.push(player: Player)
	local s = Store.state(player)
	if s ~= nil then
		Net.event("State"):FireClient(player, s)
	end
end

function Store.buy(player: Player, kind: any, id: any)
	if typeof(kind) ~= "string" or typeof(id) ~= "string" then
		return
	end
	local item = find(kind, id)
	local data = Data.get(player)
	if item == nil or data == nil then
		return
	end
	if Store.owns(player, kind, id) then
		return
	end
	if item.vip then
		Net.event("Notify"):FireClient(player, "notify.vip_only")
		return
	end
	if data.coins < item.price then
		Net.event("Notify"):FireClient(player, "notify.not_enough")
		return
	end
	data.coins -= item.price
	local owned = if kind == "kit" then data.kits else data.balls
	owned[id] = true
	Data.markDirty(player)
	Net.event("Notify"):FireClient(player, "notify.bought")
	Store.push(player)
end

function Store.equip(player: Player, kind: any, id: any)
	if typeof(kind) ~= "string" or typeof(id) ~= "string" then
		return
	end
	local data = Data.get(player)
	if data == nil or not Store.owns(player, kind, id) then
		return
	end
	data.equipped[kind] = id
	Data.markDirty(player)
	Store.push(player)
end

-- 設定として保存してよいキーと型
local SETTING_KEYS = {
	mode = "string",
	length = "number",
	difficulty = "number",
	formation = "string",
	line = "number",
	press = "number",
	camera = "number",
	night = "boolean",
	assist = "number",
	mouseAim = "boolean",
}

function Store.saveSettings(player: Player, raw: any)
	local data = Data.get(player)
	if data == nil or typeof(raw) ~= "table" then
		return
	end
	for k, t in SETTING_KEYS do
		local v = (raw :: any)[k]
		if typeof(v) == t then
			if t == "string" then
				v = string.sub(v, 1, 12)
			end
			data.settings[k] = v
		end
	end
	Data.markDirty(player)
end

--- 操作の割り当てを保存する (不正なキーは Bindings.validate で捨てる)。
function Store.saveBindings(player: Player, raw: any)
	local data = Data.get(player)
	if data == nil then
		return
	end
	data.bindings = Bindings.validate(raw)
	Data.markDirty(player)
end

function Store.remove(player: Player)
	passes[player] = nil
end

return Store
