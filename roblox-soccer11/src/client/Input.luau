--!nonstrict
--[[
	Input — キーボードとタッチを Match のキー入力 (setKey / onKey) に変換する。
	Match は "W" "K" "Up" "Shift" のような文字列キーだけを知っていて、Roblox の入力 API には依存しない。

	タッチ: 左側のスティックで移動、右側のボタンで パス/スルー/シュート/ダッシュ/交代/スライド/
	ロブ(トグル: 押している間のフライ指定)/止める。
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))

local KEYS = Config.Keys

-- KeyCode.Name -> Match のキー名。ここに無いキーは無視する。
local KEY_MAP = {
	W = "W",
	A = "A",
	S = "S",
	D = "D",
	K = "K",
	I = "I",
	J = "J",
	L = "L",
	U = "U",
	Q = "Q",
	P = "P",
	Up = "Up",
	Down = "Down",
	Left = "Left",
	Right = "Right",
	LeftShift = "Shift",
	RightShift = "Shift",
}

local Input = {}
Input.__index = Input

function Input.new(match, gui, lang, onToggleHelp)
	local self = setmetatable({}, Input)
	self.match = match
	self.gui = gui
	self.lang = lang
	self.onToggleHelp = onToggleHelp
	self.conns = {}
	self.stick = nil -- { input, origin }
	self.stickKeys = { W = false, A = false, S = false, D = false }
	self.touchUi = nil

	table.insert(
		self.conns,
		UserInputService.InputBegan:Connect(function(input, processed)
			self:_began(input, processed)
		end)
	)
	table.insert(
		self.conns,
		UserInputService.InputEnded:Connect(function(input)
			self:_ended(input)
		end)
	)
	if UserInputService.TouchEnabled then
		self:_buildTouch()
	end
	return self
end

function Input:_press(name)
	self.match:setKey(name, true)
	if name ~= "Shift" then
		self.match:onKey(name)
	end
end

function Input:_release(name)
	self.match:setKey(name, false)
end

function Input:_began(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode == Enum.KeyCode.H then
		if self.onToggleHelp then
			self.onToggleHelp()
		end
		return
	end
	local name = KEY_MAP[input.KeyCode.Name]
	if name ~= nil then
		self:_press(name)
	end
end

function Input:_ended(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		local name = KEY_MAP[input.KeyCode.Name]
		if name ~= nil then
			self:_release(name)
		end
	elseif input.UserInputType == Enum.UserInputType.Touch and self.stick and self.stick.input == input then
		self:_stickEnd()
	end
end

-- ================================================================ タッチ
function Input:_setStickKey(name, on)
	if self.stickKeys[name] == on then
		return
	end
	self.stickKeys[name] = on
	if on then
		self:_press(name)
	else
		self:_release(name)
	end
end

function Input:_stickEnd()
	self.stick = nil
	for k in self.stickKeys do
		self:_setStickKey(k, false)
	end
	if self.thumb then
		self.thumb.Position = UDim2.fromScale(0.5, 0.5)
	end
end

function Input:_buildTouch()
	local ui = {}
	self.touchUi = ui
	-- タッチ UI は全部この 1 枚の下に置く (破棄が 1 回で済む)
	ui.root = Instance.new("Frame")
	ui.root.Name = "TouchControls"
	ui.root.BackgroundTransparency = 1
	ui.root.Size = UDim2.fromScale(1, 1)
	ui.root.Parent = self.gui
	local gui = ui.root

	-- スティック (画面左下)
	ui.base = Instance.new("Frame")
	ui.base.AnchorPoint = Vector2.new(0, 1)
	ui.base.Position = UDim2.new(0, 24, 1, -24)
	ui.base.Size = UDim2.fromOffset(150, 150)
	ui.base.BackgroundColor3 = Color3.new(1, 1, 1)
	ui.base.BackgroundTransparency = 0.75
	ui.base.Parent = gui
	Instance.new("UICorner", ui.base).CornerRadius = UDim.new(1, 0)
	self.thumb = Instance.new("Frame")
	self.thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	self.thumb.Position = UDim2.fromScale(0.5, 0.5)
	self.thumb.Size = UDim2.fromOffset(60, 60)
	self.thumb.BackgroundColor3 = Color3.new(1, 1, 1)
	self.thumb.BackgroundTransparency = 0.3
	self.thumb.Parent = ui.base
	Instance.new("UICorner", self.thumb).CornerRadius = UDim.new(1, 0)

	ui.base.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and self.stick == nil then
			self.stick = { input = input }
		end
	end)
	table.insert(
		self.conns,
		UserInputService.InputChanged:Connect(function(input)
			if self.stick == nil or input ~= self.stick.input then
				return
			end
			local center = ui.base.AbsolutePosition + ui.base.AbsoluteSize / 2
			local d = Vector2.new(input.Position.X, input.Position.Y) - center
			local radius = ui.base.AbsoluteSize.X / 2
			local clamped = d.Magnitude > radius and d.Unit * radius or d
			self.thumb.Position = UDim2.new(0.5, clamped.X, 0.5, clamped.Y)
			local dead = radius * 0.3
			self:_setStickKey("D", d.X > dead)
			self:_setStickKey("A", d.X < -dead)
			self:_setStickKey("S", d.Y > dead)
			self:_setStickKey("W", d.Y < -dead)
		end)
	)

	-- ボタン (画面右下。ミニマップの上に積む)
	local function button(labelKey, col, row, key, toggle)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(1, 1)
		b.Size = UDim2.fromOffset(84, 84)
		b.Position = UDim2.new(1, -16 - (col - 1) * 94, 1, -140 - (row - 1) * 94)
		b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		b.BackgroundTransparency = 0.35
		b.Text = Locale.t(self.lang, labelKey)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 16
		b.AutoButtonColor = false
		b.Parent = gui
		Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
		local active = false
		local function set(on)
			if active == on then
				return
			end
			active = on
			b.BackgroundColor3 = on and Color3.fromRGB(40, 170, 80) or Color3.fromRGB(30, 30, 30)
			if on then
				self:_press(key)
			else
				self:_release(key)
			end
		end
		b.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if toggle then
				set(not active)
			else
				set(true)
			end
		end)
		b.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and not toggle then
				set(false)
			end
		end)
		return b
	end
	button("touch.pass", 1, 1, KEYS.pass)
	button("touch.shoot", 2, 1, KEYS.shoot)
	button("touch.through", 1, 2, KEYS.through)
	button("touch.dash", 2, 2, "Shift")
	button("touch.switch", 1, 3, KEYS.cursor)
	button("touch.slide", 2, 3, KEYS.slide)
	button("touch.lob", 3, 1, "Up", true) -- 押している間フライ / ループ指定
	button("touch.stop", 3, 2, KEYS.left_tap)
end

function Input:destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	self.conns = {}
	if self.touchUi then
		self.touchUi.root:Destroy()
		self.touchUi = nil
	end
	-- 押しっぱなしのキーが残らないようにする
	self.match.down = {}
end

return Input
