--!nonstrict
--[[
	Input — キーボード + マウス / ゲームパッド / タッチを、試合の論理入力に変換する。
	  移動 (アナログ) / 狙い (360°) / ボタン (pass, through, lofted, shoot, dash, l1, r1, l2) / 右スティック / コマンド

	送り先 (sink) は 2 種類:
	  Input.localSink(match, seatId)  ソロ: 手元の Match へ直接
	  Input.netSink(send)             オンライン: サーバーへ (ボタンの変化は即時、移動・狙いは 20 回/秒)

	キーボード (PlayStation の配置に対応):
	  WASD = 左スティック / マウス = 狙い (360°) / Shift = R2 (ダッシュ・強いキック)
	  K or 左クリック = × (パス / プレッシャー) / I = △ (スルー / GK 飛び出し) / L = ○ (浮き球 / スライディング)
	  J or 右クリック = □ (シュート / ショルダーチャージ) / Q = L1 / E = R1 / F = L2 (マッチアップ)
	  矢印 = 右スティック (フェイント / 方向指定の切替 / カーブ) / Z・C = 攻守レベル / P = 一時停止 / H = 操作表示
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))
local Snapshot = require(Shared:WaitForChild("Snapshot"))

local S = Config.View.Studs
local MOUSE_AIM_HOLD = 3.0 -- マウスを動かしてから、この秒数は狙いをマウスで決める

local KEY_BUTTON = {
	K = "pass",
	I = "through",
	L = "lofted",
	J = "shoot",
	LeftShift = "dash",
	RightShift = "dash",
	Q = "l1",
	E = "r1",
	F = "l2",
	-- ゲームパッド
	ButtonA = "pass",
	ButtonY = "through",
	ButtonB = "lofted",
	ButtonX = "shoot",
	ButtonR2 = "dash",
	ButtonL1 = "l1",
	ButtonR1 = "r1",
	ButtonL2 = "l2",
}
local KEY_FLICK = {
	Up = { 0, -1 },
	Down = { 0, 1 },
	Left = { -1, 0 },
	Right = { 1, 0 },
}
local KEY_CMD = {
	Z = "levelDown",
	C = "levelUp",
	DPadDown = "levelDown",
	DPadUp = "levelUp",
	P = "pause",
	ButtonStart = "pause",
}
local MOVE_KEYS = { W = { 0, -1 }, S = { 0, 1 }, A = { -1, 0 }, D = { 1, 0 } }

local Input = {}
Input.__index = Input

-- ================================================================ 送り先
function Input.localSink(match, seatId)
	return {
		setMove = function(_, x, y)
			match:setMove(seatId, x, y)
		end,
		setAim = function(_, x, y)
			match:setAim(seatId, x, y)
		end,
		press = function(_, b)
			match:press(seatId, b)
		end,
		release = function(_, b)
			match:release(seatId, b)
		end,
		flick = function(_, x, y)
			match:flick(seatId, x, y)
		end,
		command = function(_, c)
			match:command(seatId, c)
		end,
		tick = function() end,
	}
end

--- send(packet: string) でサーバーへ送る。
function Input.netSink(send)
	local st = { move = { x = 0, y = 0 }, aim = nil, buttons = {}, dirty = false, acc = 0, keep = 0 }
	local function flush(extra)
		local packet = Snapshot.packInput({
			move = st.move,
			aim = st.aim,
			buttons = st.buttons,
			flick = extra and extra.flick,
			cmd = extra and extra.cmd,
		})
		send(packet)
		st.dirty = false
		st.keep = 0
	end
	return {
		setMove = function(_, x, y)
			if math.abs(x - st.move.x) > 0.02 or math.abs(y - st.move.y) > 0.02 then
				st.move = { x = x, y = y }
				st.dirty = true
			end
		end,
		setAim = function(_, x, y)
			if x == nil then
				if st.aim ~= nil then
					st.aim = nil
					st.dirty = true
				end
			else
				local n = math.sqrt(x * x + y * y)
				if n > 1e-6 then
					local a = { x = x / n, y = y / n }
					if st.aim == nil or math.abs(a.x - st.aim.x) + math.abs(a.y - st.aim.y) > 0.02 then
						st.aim = a
						st.dirty = true
					end
				end
			end
		end,
		press = function(_, b)
			st.buttons[b] = true
			flush()
		end,
		release = function(_, b)
			st.buttons[b] = nil
			flush()
		end,
		flick = function(_, x, y)
			flush({ flick = { x = x, y = y } })
		end,
		command = function(_, c)
			flush({ cmd = c })
		end,
		tick = function(_, dt)
			st.acc += dt
			st.keep += dt
			if (st.dirty and st.acc >= 1 / Config.Online.InputRate) or st.keep > 1 then
				st.acc = 0
				flush()
			end
		end,
	}
end

--[[
	opts: {
	  gui: タッチ UI を置く ScreenGui
	  lang: 言語
	  sink: 送り先
	  ctrlPos: () -> { x, y } | nil  操作中の選手の位置 (マウスの狙いの計算用)
	  onToggleHelp: () -> ()
	  onDevice: (device: "keyboard" | "gamepad" | "touch") -> ()
	  allowPause: boolean
	}
]]
function Input.new(opts)
	local self = setmetatable({}, Input)
	self.opts = opts
	self.sink = opts.sink
	self.lang = opts.lang
	self.conns = {}
	self.keysDown = {}
	self.buttons = {} -- 論理ボタン -> 押しているソースの数
	self.stick = { x = 0, y = 0 } -- ゲームパッドの左スティック
	self.touchMove = { x = 0, y = 0 }
	self.rs = { x = 0, y = 0, armed = true } -- ゲームパッドの右スティック
	self.lastMouseMove = -99
	self.mouseHeld = false
	self.lastMove = { x = 0, y = 0 }
	self.lastAim = nil
	self.device = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and "touch" or "keyboard"
	self.clock = 0
	self.context = "attack"

	local function conn(sig, fn)
		table.insert(self.conns, sig:Connect(fn))
	end
	conn(UserInputService.InputBegan, function(input, processed)
		self:_began(input, processed)
	end)
	conn(UserInputService.InputEnded, function(input)
		self:_ended(input)
	end)
	conn(UserInputService.InputChanged, function(input, processed)
		self:_changed(input, processed)
	end)
	if UserInputService.TouchEnabled then
		self:_buildTouch()
	end
	return self
end

function Input:_setDevice(d)
	if self.device ~= d then
		self.device = d
		if self.opts.onDevice then
			self.opts.onDevice(d)
		end
	end
end

function Input:_buttonDown(b)
	local n = (self.buttons[b] or 0) + 1
	self.buttons[b] = n
	if n == 1 then
		self.sink:press(b)
	end
end

function Input:_buttonUp(b)
	local n = (self.buttons[b] or 0) - 1
	if n <= 0 then
		if self.buttons[b] ~= nil then
			self.buttons[b] = nil
			self.sink:release(b)
		end
	else
		self.buttons[b] = n
	end
end

function Input:_began(input, processed)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		if processed then
			return
		end
		self:_setDevice("keyboard")
		local name = input.KeyCode.Name
		if name == "H" then
			if self.opts.onToggleHelp then
				self.opts.onToggleHelp()
			end
			return
		end
		self.keysDown[name] = true
		self:_key(name, true)
	elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 then
		if processed then
			return
		end
		self:_setDevice("keyboard")
		self.mouseHeld = true
		self.lastMouseMove = self.clock
		self:_buttonDown(t == Enum.UserInputType.MouseButton1 and "pass" or "shoot")
	elseif t == Enum.UserInputType.Gamepad1 then
		self:_setDevice("gamepad")
		local name = input.KeyCode.Name
		if name == "ButtonSelect" then
			if self.opts.onToggleHelp then
				self.opts.onToggleHelp()
			end
			return
		end
		self:_key(name, true)
	end
end

function Input:_ended(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		local name = input.KeyCode.Name
		self.keysDown[name] = nil
		self:_key(name, false)
	elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 then
		self.mouseHeld = false
		self:_buttonUp(t == Enum.UserInputType.MouseButton1 and "pass" or "shoot")
	elseif t == Enum.UserInputType.Gamepad1 then
		self:_key(input.KeyCode.Name, false)
	elseif t == Enum.UserInputType.Touch and self.touch then
		self:_touchEnded(input)
	end
end

function Input:_changed(input, processed)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement then
		self.lastMouseMove = self.clock
	elseif t == Enum.UserInputType.Gamepad1 then
		local name = input.KeyCode.Name
		local pos = input.Position
		if name == "Thumbstick1" then
			self:_setDevice("gamepad")
			self.stick = { x = pos.X, y = -pos.Y }
		elseif name == "Thumbstick2" then
			local mag = math.sqrt(pos.X * pos.X + pos.Y * pos.Y)
			if mag > 0.7 and self.rs.armed then
				self.rs.armed = false
				self.sink:flick(pos.X, -pos.Y)
			elseif mag < 0.3 then
				self.rs.armed = true
			end
		end
	elseif t == Enum.UserInputType.Touch and self.touch then
		self:_touchChanged(input)
	end
end

function Input:_key(name, down)
	local b = KEY_BUTTON[name]
	if b ~= nil then
		if down then
			self:_buttonDown(b)
		else
			self:_buttonUp(b)
		end
		return
	end
	if down then
		local f = KEY_FLICK[name]
		if f ~= nil then
			self.sink:flick(f[1], f[2])
			return
		end
		local c = KEY_CMD[name]
		if c ~= nil and (c ~= "pause" or self.opts.allowPause) then
			self.sink:command(c)
		end
	end
end

--- 毎フレーム: 移動と狙いを計算して送る。
function Input:update(dt)
	self.clock += dt
	-- 移動: キーボード (8 方向) とスティック (アナログ) の合成
	local mx, my = 0, 0
	for k, v in MOVE_KEYS do
		if self.keysDown[k] then
			mx += v[1]
			my += v[2]
		end
	end
	local kn = math.sqrt(mx * mx + my * my)
	if kn > 0 then
		mx, my = mx / kn, my / kn
	end
	local sx, sy = self.stick.x, self.stick.y
	if math.sqrt(sx * sx + sy * sy) < Config.Controls.DeadZone then
		sx, sy = 0, 0
	end
	mx += sx + self.touchMove.x
	my += sy + self.touchMove.y
	local n = math.sqrt(mx * mx + my * my)
	if n > 1 then
		mx, my = mx / n, my / n
	end
	self.sink:setMove(mx, my)
	self.lastMove = { x = mx, y = my }
	-- 狙い: マウスを最近動かした / クリック中なら、選手からマウスの指す地点への向き
	local aim = nil
	if self.device == "keyboard" and (self.mouseHeld or self.clock - self.lastMouseMove < MOUSE_AIM_HOLD) then
		aim = self:_mouseAim()
	end
	if aim ~= nil then
		self.sink:setAim(aim.x, aim.y)
	else
		self.sink:setAim(nil)
	end
	self.lastAim = aim
	self.sink:tick(dt)
end

--- マウスが指すピッチ上の点への向き (操作中の選手から)。
function Input:_mouseAim()
	local cam = workspace.CurrentCamera
	local pos = self.opts.ctrlPos and self.opts.ctrlPos()
	if cam == nil or pos == nil then
		return nil
	end
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t <= 0 then
		return nil
	end
	local hit = ray.Origin + ray.Direction * t
	local px, py = hit.X / S, hit.Z / S
	local dx, dy = px - pos.x, py - pos.y
	if math.sqrt(dx * dx + dy * dy) < 0.5 then
		return nil
	end
	return { x = dx, y = dy }
end

--- 画面に出す狙い (マウス or スティック)。World の矢印表示に使う。
function Input:currentAim()
	if self.lastAim then
		return self.lastAim
	end
	local m = self.lastMove
	if math.sqrt(m.x * m.x + m.y * m.y) > Config.Controls.DeadZone then
		return m
	end
	return nil
end

-- ================================================================ タッチ (eFootball スマホ版の配置)
local TOUCH_BUTTONS = {
	-- id, 論理ボタン, 列, 行, 攻撃のラベル, 守備のラベル
	{ "shoot", "shoot", 1, 1, "touch.shoot", "touch.charge" },
	{ "pass", "pass", 2, 1, "touch.pass", "touch.pressure" },
	{ "through", "through", 1, 2, "touch.through", "touch.gk" },
	{ "lofted", "lofted", 2, 2, "touch.lofted", "touch.slide" },
	{ "dash", "dash", 3, 1, "touch.dash", "touch.dash" },
	{ "l1", "l1", 3, 2, "touch.l1", "touch.switch" },
	{ "r1", "r1", 3, 3, "touch.r1", "touch.callpress" },
	{ "l2", "l2", 2, 3, "touch.l2", "touch.matchup" },
}

function Input:_buildTouch()
	local touch = { buttons = {}, stickInput = nil, swipe = {} }
	self.touch = touch
	local root = Instance.new("Frame")
	root.Name = "TouchControls"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = self.opts.gui
	touch.root = root

	-- 左: アナログスティック (移動・狙い)
	local base = Instance.new("Frame")
	base.AnchorPoint = Vector2.new(0, 1)
	base.Position = UDim2.new(0, 24, 1, -24)
	base.Size = UDim2.fromOffset(160, 160)
	base.BackgroundColor3 = Color3.new(1, 1, 1)
	base.BackgroundTransparency = 0.8
	base.Parent = root
	Instance.new("UICorner", base).CornerRadius = UDim.new(1, 0)
	local thumb = Instance.new("Frame")
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Position = UDim2.fromScale(0.5, 0.5)
	thumb.Size = UDim2.fromOffset(64, 64)
	thumb.BackgroundColor3 = Color3.new(1, 1, 1)
	thumb.BackgroundTransparency = 0.35
	thumb.Parent = base
	Instance.new("UICorner", thumb).CornerRadius = UDim.new(1, 0)
	touch.base, touch.thumb = base, thumb
	base.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and touch.stickInput == nil then
			self:_setDevice("touch")
			touch.stickInput = input
			self:_touchChanged(input)
		end
	end)

	-- 右: ボタン
	for _, def in TOUCH_BUTTONS do
		local id, logical, col, row, atk = def[1], def[2], def[3], def[4], def[5]
		local b = Instance.new("TextButton")
		b.Name = "Touch_" .. id
		b.AnchorPoint = Vector2.new(1, 1)
		local big = id == "shoot" or id == "pass"
		b.Size = UDim2.fromOffset(big and 92 or 74, big and 92 or 74)
		b.Position = UDim2.new(1, -18 - (col - 1) * 96, 1, -150 - (row - 1) * 92)
		b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		b.BackgroundTransparency = 0.3
		b.Text = Locale.t(self.lang, atk)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 15
		b.TextWrapped = true
		b.AutoButtonColor = false
		b.Parent = root
		Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
		touch.buttons[id] = { button = b, def = def }
		local held = false
		b.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and not held then
				held = true
				self:_setDevice("touch")
				b.BackgroundColor3 = Color3.fromRGB(40, 170, 80)
				self:_buttonDown(logical)
			end
		end)
		b.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and held then
				held = false
				b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
				self:_buttonUp(logical)
			end
		end)
	end
	-- 右側の空いた所をスワイプ = 右スティック
	table.insert(
		self.conns,
		UserInputService.TouchStarted:Connect(function(input, processed)
			if processed then
				return
			end
			local cam = workspace.CurrentCamera
			if cam and input.Position.X > cam.ViewportSize.X * 0.5 then
				touch.swipe[input] = { x = input.Position.X, y = input.Position.Y, t = self.clock }
			end
		end)
	)
end

function Input:_touchChanged(input)
	local touch = self.touch
	if touch.stickInput ~= input then
		return
	end
	local base = touch.base
	local center = base.AbsolutePosition + base.AbsoluteSize / 2
	local d = Vector2.new(input.Position.X, input.Position.Y) - center
	local radius = base.AbsoluteSize.X / 2
	local clamped = d.Magnitude > radius and d.Unit * radius or d
	touch.thumb.Position = UDim2.new(0.5, clamped.X, 0.5, clamped.Y)
	self.touchMove = { x = clamped.X / radius, y = clamped.Y / radius }
end

function Input:_touchEnded(input)
	local touch = self.touch
	if touch.stickInput == input then
		touch.stickInput = nil
		touch.thumb.Position = UDim2.fromScale(0.5, 0.5)
		self.touchMove = { x = 0, y = 0 }
	end
	local sw = touch.swipe[input]
	if sw ~= nil then
		touch.swipe[input] = nil
		local dx, dy = input.Position.X - sw.x, input.Position.Y - sw.y
		if math.sqrt(dx * dx + dy * dy) > 40 and self.clock - sw.t < 0.5 then
			self.sink:flick(dx, dy)
		end
	end
end

--- 攻撃 / 守備でタッチボタンの表示を切り替える。
function Input:setContext(ctx)
	if self.context == ctx then
		return
	end
	self.context = ctx
	if self.touch == nil then
		return
	end
	for _, entry in self.touch.buttons do
		local def = entry.def
		entry.button.Text = Locale.t(self.lang, ctx == "defense" and def[6] or def[5])
	end
end

function Input:destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	self.conns = {}
	for b in self.buttons do
		self.sink:release(b)
	end
	self.buttons = {}
	if self.touch then
		self.touch.root:Destroy()
		self.touch = nil
	end
end

return Input
