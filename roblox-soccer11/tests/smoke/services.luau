--!nocheck
-- サービスの stub と、モジュールの読み込み (bundle が Modules テーブルを用意する)

Calls = {} -- Net の送信記録 { name, kind, args, player }
NetHandlers = {} -- name -> { fn }

local function netEvent(name)
	local e = {}
	NetHandlers[name] = NetHandlers[name] or {}
	local function sig()
		return {
			Connect = function(_, fn)
				table.insert(NetHandlers[name], fn)
				return { Disconnect = function() end }
			end,
		}
	end
	e.OnClientEvent = sig()
	e.OnServerEvent = sig()
	function e:FireServer(...)
		table.insert(Calls, { name = name, kind = "FireServer", args = { ... } })
	end
	function e:FireClient(player, ...)
		table.insert(Calls, { name = name, kind = "FireClient", player = player, args = { ... } })
	end
	return e
end
local netCache = {}
NetStub = {
	event = function(name)
		if netCache[name] == nil then
			netCache[name] = netEvent(name)
		end
		return netCache[name]
	end,
}

PlayerGui = Instance.new("Folder")
PlayerGui.Name = "PlayerGui"
local PlayerScripts = Instance.new("Folder")
PlayerScripts.Name = "PlayerScripts"

LocalPlayer = {
	Name = "Tester",
	UserId = 1001,
	LocaleId = "en-us",
	Parent = true,
	WaitForChild = function(_, name)
		if name == "PlayerGui" then
			return PlayerGui
		end
		return PlayerScripts
	end,
}

local players = { LocalPlayer = LocalPlayer, list = {} }
players.PlayerAdded = NewSignal(nil, "PlayerAdded")
players.PlayerRemoving = NewSignal(nil, "PlayerRemoving")
function players:GetPlayers()
	return self.list
end
function players:GetPlayerByUserId(id)
	for _, p in self.list do
		if p.UserId == id then
			return p
		end
	end
	return nil
end
Players_ = players

-- DataStore (メモリ)
local memory = {}
DataStoreMemory = memory
local dataStoreService = {
	GetDataStore = function()
		return {
			UpdateAsync = function(_, key, fn)
				local result = fn(memory[key])
				if result ~= nil then
					memory[key] = result
				end
				return result
			end,
		}
	end,
}

OwnedPasses = {}
Prompts = {}
local market = {
	UserOwnsGamePassAsync = function(_, userId, passId)
		return OwnedPasses[passId] == true
	end,
	PromptGamePassPurchase = function(_, player, id)
		table.insert(Prompts, { kind = "pass", id = id })
	end,
	PromptProductPurchase = function(_, player, id)
		table.insert(Prompts, { kind = "product", id = id })
	end,
	PromptGamePassPurchaseFinished = NewSignal(nil, "PromptGamePassPurchaseFinished"),
}

local rs = Instance.new("Folder")
rs.Name = "ReplicatedStorage"
local camera = Instance.new("Camera")
camera.ViewportSize = Vector2.new(1280, 720)
camera.FieldOfView = 70
camera.ViewportPointToRay = function(_, x, y)
	-- 真上から少し手前に傾けたカメラ (おおよそ)
	return { Origin = Vector3.new(0, 120, 70), Direction = Vector3.new((x - 640) / 640, -1, (y - 360) / 360 - 0.6).Unit }
end
local workspace_ = Instance.new("Folder")
workspace_.Name = "Workspace"
workspace_.CurrentCamera = camera

local services = {
	Players = players,
	RunService = {
		IsServer = function()
			return ServerMode == true
		end,
		RenderStepped = NewSignal(nil, "RenderStepped"),
		Heartbeat = NewSignal(nil, "Heartbeat"),
	},
	ReplicatedStorage = rs,
	Workspace = workspace_,
	Lighting = Instance.new("Folder"),
	SoundService = Instance.new("Folder"),
	StarterGui = { SetCoreGuiEnabled = function() end },
	UserInputService = {
		TouchEnabled = true,
		KeyboardEnabled = true,
		InputBegan = NewSignal(nil, "InputBegan"),
		InputEnded = NewSignal(nil, "InputEnded"),
		InputChanged = NewSignal(nil, "InputChanged"),
		TouchStarted = NewSignal(nil, "TouchStarted"),
		GetMouseLocation = function()
			return Vector2.new(640, 360)
		end,
	},
	MarketplaceService = market,
	DataStoreService = dataStoreService,
}
market_ = market

game = {
	JobId = "job-1",
	GetService = function(_, name)
		return services[name] or Instance.new("Folder")
	end,
	BindToClose = function(_, fn)
		BindToCloseFn = fn
	end,
}
workspace = workspace_

-- Instance ツリー (script.Parent / WaitForChild の解決用)
local function node(parent, name, modulePath)
	local n = Instance.new("Folder")
	n._p.Name = name
	n._module = modulePath
	n.Parent = parent
	return n
end
Shared = node(rs, "Shared")
for _, nme in { "Config", "Locale", "Rewards", "Match", "Net", "Snapshot", "Bindings" } do
	node(Shared, nme, "shared/" .. nme)
end
ClientRoot = node(nil, "Client", "client/init")
for _, nme in { "World", "Hud", "Input", "Menu", "Sfx", "RemoteMatch", "Rig" } do
	node(ClientRoot, nme, "client/" .. nme)
end
ServerRoot = node(nil, "Server", "server/init")
local servicesFolder = node(ServerRoot, "Services")
for _, nme in { "Data", "Store", "Matches", "Monetization", "Rooms" } do
	node(servicesFolder, nme, "server/Services/" .. nme)
end

local loaded = {}
function Require(inst)
	local path = inst._module
	if path == nil then
		error("require: not a module: " .. tostring(inst._p.Name))
	end
	if loaded[path] == nil then
		if path == "shared/Net" then
			loaded[path] = { v = NetStub }
		else
			local fn = Modules[path]
			if fn == nil then
				error("module not bundled: " .. path)
			end
			loaded[path] = { v = fn(inst, Require) }
		end
	end
	return loaded[path].v
end
function Load(path)
	local inst = ({ ["client/init"] = ClientRoot, ["server/init"] = ServerRoot })[path]
	return Require(inst)
end

-- テスト用ヘルパー
function Fire(sigName, ...)
	for _, h in Handlers do
		if h.sig == sigName and not h.dead then
			h.fn(...)
		end
	end
end
function Frames(n, dt)
	dt = dt or 1 / 30
	for _ = 1, n do
		FakeClock += dt
		Fire("RenderStepped", dt)
		RunPending()
	end
end
function FindButton(text)
	for i = #Handlers, 1, -1 do
		local h = Handlers[i]
		if h.sig == "Activated" and not h.dead and h.owner ~= nil and not h.owner._destroyed and h.owner._p.Text == text then
			return h
		end
	end
	return nil
end
function Press(name)
	Fire("InputBegan", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = name } }, false)
end
function Release(name)
	Fire("InputEnded", { UserInputType = Enum.UserInputType.Keyboard, KeyCode = { Name = name } })
end
function NetFire(name, ...)
	FakeClock += 1.5 -- 連打制限 (throttle) に掛からないよう、呼び出しごとに時間を進める
	for _, fn in NetHandlers[name] or {} do
		fn(...)
	end
end
function CallsOf(name)
	local out = {}
	for _, c in Calls do
		if c.name == name then
			table.insert(out, c)
		end
	end
	return out
end
Failures = 0
function Check(name, cond, detail)
	if cond then
		print("  ok   " .. name)
	else
		Failures += 1
		print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
	end
end
