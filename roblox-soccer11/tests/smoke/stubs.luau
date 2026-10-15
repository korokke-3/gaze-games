--!nocheck
--[[
	Roblox API の最小限のスタブ。Studio 無しでクライアント / サーバーのコードを実行して、
	実行時エラー (nil 参照・API の誤用) を洗い出すためのもの。見た目や物理は検証しない。
]]

-- ---------------------------------------------------------------- 何でも受け付けるダミー
local DummyMT = {}
local function dummy(name)
	return setmetatable({ __name = name or "dummy" }, DummyMT)
end
DummyMT.__index = function(t, k)
	local v = dummy(tostring(rawget(t, "__name")) .. "." .. tostring(k))
	rawset(t, k, v)
	return v
end
DummyMT.__call = function(t, ...)
	return dummy("call")
end
for _, ev in { "__add", "__sub", "__mul", "__div", "__unm", "__mod", "__pow", "__concat" } do
	DummyMT[ev] = function()
		return dummy("op")
	end
end
DummyMT.__lt = function()
	return false
end
DummyMT.__le = function()
	return false
end
DummyMT.__tostring = function(t)
	return rawget(t, "__name")
end

-- ---------------------------------------------------------------- 基本型
local V3 = {}
V3.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	elseif k == "Unit" then
		local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
		return setmetatable({ X = t.X / m, Y = t.Y / m, Z = t.Z / m }, V3)
	elseif k == "Lerp" then
		return function(a, b, f)
			return setmetatable({ X = a.X + (b.X - a.X) * f, Y = a.Y + (b.Y - a.Y) * f, Z = a.Z + (b.Z - a.Z) * f }, V3)
		end
	end
	return nil
end
V3.__add = function(a, b)
	return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, V3)
end
V3.__sub = function(a, b)
	return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }, V3)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	return setmetatable({ X = a.X * b, Y = a.Y * b, Z = a.Z * b }, V3)
end
V3.__div = function(a, b)
	return setmetatable({ X = a.X / b, Y = a.Y / b, Z = a.Z / b }, V3)
end
Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
	end,
}
local V2 = {}
V2.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y)
	elseif k == "Unit" then
		local m = math.sqrt(t.X * t.X + t.Y * t.Y)
		return setmetatable({ X = t.X / m, Y = t.Y / m }, V2)
	end
	return nil
end
V2.__add = function(a, b)
	return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y }, V2)
end
V2.__sub = function(a, b)
	return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y }, V2)
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	return setmetatable({ X = a.X * b, Y = a.Y * b }, V2)
end
V2.__div = function(a, b)
	return setmetatable({ X = a.X / b, Y = a.Y / b }, V2)
end
Vector2 = {
	new = function(x, y)
		return setmetatable({ X = x or 0, Y = y or 0 }, V2)
	end,
}
local CF = {}
CF.__index = function(t, k)
	return nil
end
CF.__mul = function(a, b)
	return setmetatable({ Position = a.Position }, CF)
end
CFrame = {
	new = function(a, y, z)
		local pos = type(a) == "number" and Vector3.new(a, y, z) or a or Vector3.new()
		return setmetatable({ Position = pos }, CF)
	end,
	lookAt = function(a, b)
		return setmetatable({ Position = a }, CF)
	end,
	Angles = function()
		return setmetatable({ Position = Vector3.new() }, CF)
	end,
}
Color3 = {
	fromRGB = function(r, g, b)
		return setmetatable({ R = r / 255, G = g / 255, B = b / 255 }, {
			__index = function(t, k)
				if k == "Lerp" then
					return function(a, o, f)
						return a
					end
				end
			end,
		})
	end,
	new = function(r, g, b)
		return Color3.fromRGB((r or 0) * 255, (g or 0) * 255, (b or 0) * 255)
	end,
}
UDim = {
	new = function(s, o)
		return { Scale = s or 0, Offset = o or 0 }
	end,
}
UDim2 = {
	new = function(xs, xo, ys, yo)
		return { X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }
	end,
	fromOffset = function(x, y)
		return UDim2.new(0, x, 0, y)
	end,
	fromScale = function(x, y)
		return UDim2.new(x, 0, y, 0)
	end,
}
ColorSequence = {
	new = function(c)
		return { c }
	end,
}
NumberSequence = {
	new = function(a, b)
		return { a, b }
	end,
}
Enum = dummy("Enum")
do
	local R = {}
	R.__index = R
	function R:NextNumber()
		return math.random()
	end
	function R:NextInteger(a, b)
		return math.random(a, b)
	end
	Random = {
		new = function()
			return setmetatable({}, R)
		end,
	}
end

-- ---------------------------------------------------------------- 時間 / task
FakeClock = 0
function FakeNow()
	return FakeClock
end
local pending = {}
local waitCount = 0
task = {
	spawn = function(f, ...)
		-- 無限ループ (自動保存など) は wait の回数で打ち切る。例外は握りつぶす
		local ok, err = pcall(f, ...)
		if not ok and not string.find(tostring(err), "loop guard", 1, true) then
			print("  (task.spawn error) " .. tostring(err))
		end
	end,
	delay = function(t, f)
		table.insert(pending, { t = FakeClock + t, f = f })
	end,
	wait = function(t)
		waitCount += 1
		if waitCount > 40 then
			waitCount = 0
			error("loop guard")
		end
		FakeClock += t or 0
		return t or 0
	end,
	defer = function(f, ...)
		return f(...)
	end,
}
function RunPending()
	local keep = {}
	for _, p in pending do
		if p.t <= FakeClock then
			p.f()
		else
			table.insert(keep, p)
		end
	end
	pending = keep
end

-- ---------------------------------------------------------------- シグナル
Handlers = {} -- { { sig = "Activated", text = "...", fn = f } }
local function newSignal(owner, name)
	local s = {}
	function s:Connect(fn)
		local h = { sig = name, owner = owner, fn = fn, text = owner and rawget(owner, "_p") and owner._p.Text or nil }
		table.insert(Handlers, h)
		return {
			Disconnect = function()
				h.dead = true
			end,
		}
	end
	function s:Wait() end
	return s
end

-- ---------------------------------------------------------------- Instance
local Inst = {}
local SIGNALS = {
	Activated = true, InputBegan = true, InputEnded = true, InputChanged = true, RenderStepped = true,
	Heartbeat = true, OnClientEvent = true, OnServerEvent = true, PlayerAdded = true, PlayerRemoving = true,
	PromptGamePassPurchaseFinished = true, Changed = true, MouseButton1Click = true,
}
local function isA(inst, cls)
	local c = inst._p.ClassName
	if c == cls then
		return true
	end
	if cls == "UIComponent" and string.sub(c, 1, 2) == "UI" then
		return true
	end
	if cls == "BasePart" and c == "Part" then
		return true
	end
	if cls == "GuiObject" and (c == "Frame" or c == "TextLabel" or c == "TextButton" or c == "ScrollingFrame") then
		return true
	end
	return false
end
local methods = {}
function methods.IsA(t, cls)
	return isA(t, cls)
end
function methods.Destroy(t)
	local parent = t._p.Parent
	if parent then
		for i, c in parent._c do
			if c == t then
				table.remove(parent._c, i)
				break
			end
		end
	end
	t._p.Parent = nil
	t._destroyed = true
end
function methods.GetChildren(t)
	return table.clone(t._c)
end
function methods.FindFirstChild(t, name)
	for _, c in t._c do
		if c._p.Name == name then
			return c
		end
	end
	return nil
end
function methods.WaitForChild(t, name)
	local c = methods.FindFirstChild(t, name)
	if c == nil then
		c = Instance.new("Folder")
		c.Name = name
		c.Parent = t
	end
	return c
end
function methods.GetDescendants(t)
	local out = {}
	for _, c in t._c do
		table.insert(out, c)
		for _, d in methods.GetDescendants(c) do
			table.insert(out, d)
		end
	end
	return out
end
Inst.__index = function(t, k)
	if type(k) == "string" and string.sub(k, 1, 1) == "_" then
		return rawget(t, k)
	end
	if methods[k] then
		return methods[k]
	end
	local v = t._p[k]
	if v ~= nil then
		return v
	end
	for _, c in t._c do
		if c._p.Name == k then
			return c
		end
	end
	if SIGNALS[k] then
		local s = newSignal(t, k)
		t._p[k] = s
		return s
	end
	local d = dummy((t._p.Name or "?") .. "." .. tostring(k))
	t._p[k] = d
	return d
end
Inst.__newindex = function(t, k, v)
	if type(k) == "string" and string.sub(k, 1, 1) == "_" then
		rawset(t, k, v)
	elseif k == "Parent" then
		local old = t._p.Parent
		if old then
			for i, c in old._c do
				if c == t then
					table.remove(old._c, i)
					break
				end
			end
		end
		t._p.Parent = v
		if v ~= nil then
			table.insert(v._c, t)
		end
	else
		t._p[k] = v
	end
end
local function makeInst(cls)
	local t = setmetatable({ _p = { ClassName = cls, Name = cls }, _c = {} }, Inst)
	return t
end
Instance = {
	new = function(cls, parent)
		local t = makeInst(cls)
		if parent then
			t.Parent = parent
		end
		return t
	end,
}
function MakeFolder(name, parent)
	local f = makeInst("Folder")
	f._p.Name = name
	if parent then
		f.Parent = parent
	end
	return f
end
function AddChild(parent, child, name)
	child._p.Name = name
	child.Parent = parent
	return child
end
NewSignal = newSignal
typeof = function(v) return type(v) end
