--!strict
--[[
	Data — プレイヤーのセーブ (コイン・所持品・設定・統計)。

	- DataStore の取得は遅延 + pcall。未公開の Place / Studio の API 無効時でも落ちず、
	  メモリのみで動作する (require の連鎖で全滅する事故を避ける)。
	- セッションロック: 別サーバーが保持している間は上書きしない (サーバー移動時の巻き戻し事故対策)。
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local STORE_NAME = "Soccer11_v1"
local LOCK_TIMEOUT = 120 -- 秒。これを過ぎたロックは無効 (サーバー落ち対策)
local AUTOSAVE = 60

local Data = {}

local store: GlobalDataStore? = nil
local sessions: { [Player]: { data: any, readOnly: boolean, dirty: boolean } } = {}
local jobId = if game.JobId ~= "" then game.JobId else "studio"

local function getStore(): GlobalDataStore?
	if store == nil then
		local ok, s = pcall(function()
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		if ok then
			store = s
		end
	end
	return store
end

function Data.default()
	return {
		version = 1,
		coins = 0,
		kits = { classic = true },
		balls = { classic = true },
		equipped = { kit = "classic", ball = "classic" },
		stats = { matches = 0, wins = 0, draws = 0, losses = 0, goals = 0 },
		settings = {},
		receipts = {},
	}
end

--- 足りない項目を既定値で埋める (バージョンアップ時の互換)。
local function reconcile(data: any)
	local d = Data.default()
	for k, v in d do
		if data[k] == nil then
			data[k] = v
		end
	end
	for k, v in d.stats do
		if data.stats[k] == nil then
			data.stats[k] = v
		end
	end
	return data
end

local function key(player: Player): string
	return "u_" .. tostring(player.UserId)
end

function Data.load(player: Player)
	local st = getStore()
	local readOnly = false
	local data = nil
	if st ~= nil then
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return st:UpdateAsync(key(player), function(old)
					old = old or {}
					local lock = old.lock
					if lock and lock.jobId ~= jobId and os.time() - lock.time < LOCK_TIMEOUT then
						return nil -- 別のサーバーが保持中: 取得しない
					end
					old.lock = { jobId = jobId, time = os.time() }
					old.data = old.data or Data.default()
					return old
				end)
			end)
			if ok and result ~= nil then
				data = result.data
				break
			end
			if ok and result == nil then
				task.wait(2)
			else
				break -- API 無効など。リトライしても無駄
			end
		end
		if data == nil then
			readOnly = true -- 取得できなかった: このセッションは保存しない (上書き事故を避ける)
		end
	else
		readOnly = true
	end
	data = reconcile(data or Data.default())
	sessions[player] = { data = data, readOnly = readOnly, dirty = false }
	return data, readOnly
end

function Data.get(player: Player): any?
	local s = sessions[player]
	return s and s.data
end

function Data.isReadOnly(player: Player): boolean
	local s = sessions[player]
	return s == nil or s.readOnly
end

function Data.markDirty(player: Player)
	local s = sessions[player]
	if s then
		s.dirty = true
	end
end

--- 保存。release = true ならロックも手放す (退出時)。成功したら true。
function Data.save(player: Player, release: boolean?): boolean
	local s = sessions[player]
	local st = getStore()
	if s == nil or st == nil or s.readOnly then
		return false
	end
	local ok = pcall(function()
		st:UpdateAsync(key(player), function(old)
			old = old or {}
			if old.lock and old.lock.jobId ~= jobId and os.time() - old.lock.time < LOCK_TIMEOUT then
				return nil -- 他のサーバーに取られている: 上書きしない
			end
			old.data = s.data
			if release then
				old.lock = nil
			else
				old.lock = { jobId = jobId, time = os.time() }
			end
			return old
		end)
	end)
	if ok then
		s.dirty = false
	end
	return ok
end

function Data.release(player: Player)
	Data.save(player, true)
	sessions[player] = nil
end

function Data.start()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE)
			for player, s in sessions do
				if s.dirty and player.Parent ~= nil then
					task.spawn(Data.save, player, false)
				end
			end
		end
	end)
	game:BindToClose(function()
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				Data.save(player, true)
				pending -= 1
			end)
		end
		local t = os.clock()
		while pending > 0 and os.clock() - t < 20 do
			task.wait(0.2)
		end
	end)
end

Data.Config = Config
return Data
