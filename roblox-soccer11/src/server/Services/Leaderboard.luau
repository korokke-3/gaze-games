--!nonstrict
--[[
	Leaderboard — 練習の記録のランキング (全サーバー共通、OrderedDataStore)。
	  key = UserId、value = 記録 (タイムは 0.1 秒単位の整数で小さい順、回数は大きい順)
	練習はクライアントで動くので、記録は申告になる。ありえない値 (速すぎるタイム・総数を超える回数) は捨てる。
	コインなどの報酬には一切つながらない (順位の表示だけ)。
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Leaderboard = {}

-- 種類ごとの記録の形と、ありえる範囲
Leaderboard.KINDS = {
	pass = { rec = "time", min = 6.0, max = 900 },
	skills = { rec = "time", min = 2.5, max = 900 },
	shoot = { rec = "count", max = 10 },
	fk = { rec = "count", max = 5 },
	defend = { rec = "count", max = 5 },
}
local TOP = 10
local CACHE_SEC = 60

local stores = {} -- kind -> OrderedDataStore (遅延取得: 未公開の Place / Studio で例外を出しても落ちない)
local cache = {} -- kind -> { t, list }
local names = {} -- userId -> name

local function storeOf(kind)
	if stores[kind] == nil then
		local ok, s = pcall(function()
			return DataStoreService:GetOrderedDataStore("practice_" .. kind)
		end)
		if not ok then
			return nil
		end
		stores[kind] = s
	end
	return stores[kind]
end

--- 申告された記録を確かめる。戻り値: 保存する整数 (だめなら nil)
function Leaderboard.validate(kind, value)
	local k = Leaderboard.KINDS[kind]
	if k == nil or typeof(value) ~= "number" or value ~= value then
		return nil
	end
	if k.rec == "time" then
		if value < k.min or value > k.max then
			return nil
		end
		return math.floor(value * 10 + 0.5)
	end
	if value < 1 or value > k.max or value ~= math.floor(value) then
		return nil
	end
	return value
end

--- 記録を出す (自己ベストより良い時だけ更新)。
function Leaderboard.submit(player, kind, value)
	local v = Leaderboard.validate(kind, value)
	local store = v and storeOf(kind)
	if store == nil then
		return false
	end
	local isTime = Leaderboard.KINDS[kind].rec == "time"
	task.spawn(function()
		pcall(function()
			store:UpdateAsync(tostring(player.UserId), function(old)
				if typeof(old) == "number" and (isTime and old <= v or not isTime and old >= v) then
					return nil -- 前の方が良い
				end
				return v
			end)
		end)
		cache[kind] = nil
	end)
	names[player.UserId] = player.Name
	return true
end

local function nameOf(userId)
	if names[userId] ~= nil then
		return names[userId]
	end
	local p = Players:GetPlayerByUserId(userId)
	if p ~= nil then
		names[userId] = p.Name
		return p.Name
	end
	local ok, n = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	names[userId] = ok and n or ("#" .. tostring(userId))
	return names[userId]
end

--- 上位 10 人。戻り値: { { rank, name, userId, value } } (value はタイムなら秒)。取れなければ nil
function Leaderboard.top(kind)
	local k = Leaderboard.KINDS[kind]
	if k == nil then
		return nil
	end
	local c = cache[kind]
	if c ~= nil and os.clock() - c.t < CACHE_SEC then
		return c.list
	end
	local store = storeOf(kind)
	if store == nil then
		return nil
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(k.rec == "time", TOP):GetCurrentPage()
	end)
	if not ok or page == nil then
		return nil
	end
	local list = {}
	for i, e in page do
		local uid = tonumber(e.key)
		local value = e.value
		if k.rec == "time" then
			value = value / 10
		end
		table.insert(list, { rank = i, name = uid and nameOf(uid) or "?", userId = uid or 0, value = value })
	end
	cache[kind] = { t = os.clock(), list = list }
	return list
end

return Leaderboard
