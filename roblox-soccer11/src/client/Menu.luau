--!nonstrict
--[[
	Menu — 試合前のメニュー (設定・ショップ) と、試合後の結果画面。
	見た目だけを持ち、状態の変更は callbacks でサーバー / init.client に任せる。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))
local Bindings = require(Shared:WaitForChild("Bindings"))

local PANEL = Color3.fromRGB(24, 30, 28)
local ROW = Color3.fromRGB(38, 46, 42)
local GREEN = Color3.fromRGB(40, 170, 80)
local GOLD = Color3.fromRGB(230, 180, 40)
local GREY = Color3.fromRGB(90, 96, 94)

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props or {} do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function corner(parent, r)
	new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, parent)
end

local function label(parent, text, props)
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props or {} do
		base[k] = v
	end
	return new("TextLabel", base, parent)
end

local function button(parent, text, color, props)
	local base = {
		BackgroundColor3 = color or GREEN,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 16,
		AutoButtonColor = true,
	}
	for k, v in props or {} do
		base[k] = v
	end
	local b = new("TextButton", base, parent)
	corner(b, 8)
	return b
end

local Menu = {}
Menu.__index = Menu

-- 選択肢。value は保存・試合設定に使う値、key は Locale のキー (または文字列)
local function buildOptions(lang)
	local t = function(k, ...)
		return Locale.t(lang, k, ...)
	end
	local lengths = {}
	for _, l in Config.MatchLengths do
		table.insert(lengths, { value = l, text = t("menu.length.v", l / 60) })
	end
	local diffs = {}
	for i, d in Config.Difficulties do
		table.insert(diffs, { value = i, text = t("diff." .. d.key) })
	end
	local forms = {}
	for _, k in Config.FormationOrder do
		local a, b, c = string.sub(k, 1, 1), string.sub(k, 2, 2), string.sub(k, 3)
		table.insert(forms, { value = k, text = a .. "-" .. b .. "-" .. c })
	end
	return {
		{
			id = "mode",
			title = t("menu.mode"),
			values = {
				{ value = "quick", text = t("menu.mode.quick") },
				{ value = "cup", text = t("menu.mode.cup") },
			},
		},
		{ id = "length", title = t("menu.length"), values = lengths },
		{ id = "difficulty", title = t("menu.difficulty"), values = diffs },
		{ id = "formation", title = t("menu.formation"), values = forms },
		{
			id = "line",
			title = t("menu.line"),
			values = {
				{ value = 1, text = t("opt.low") },
				{ value = 2, text = t("opt.normal") },
				{ value = 3, text = t("opt.high") },
			},
		},
		{
			id = "press",
			title = t("menu.press"),
			values = {
				{ value = 1, text = t("opt.weak") },
				{ value = 2, text = t("opt.normal") },
				{ value = 3, text = t("opt.strong") },
			},
		},
		{
			id = "assist",
			title = t("menu.assist"),
			values = {
				{ value = 0, text = t("opt.assist0") },
				{ value = 1, text = t("opt.assist1") },
				{ value = 2, text = t("opt.assist2") },
			},
		},
		{
			id = "mouseAim",
			title = t("menu.aim"),
			values = { { value = true, text = t("opt.aim.mouse") }, { value = false, text = t("opt.aim.keys") } },
		},
		{
			id = "camera",
			title = t("menu.camera"),
			values = {
				{ value = 1, text = t("opt.wide") },
				{ value = 2, text = t("opt.normal") },
				{ value = 3, text = t("opt.zoom") },
			},
		},
		{
			id = "night",
			title = t("menu.time"),
			values = { { value = false, text = t("opt.day") }, { value = true, text = t("opt.night") } },
		},
	}
end

local DEFAULTS = {
	mode = "quick",
	length = 300,
	difficulty = Config.DefaultDifficulty,
	formation = "433",
	line = 2,
	press = 2,
	camera = 2,
	night = false,
	assist = Config.Controls.DefaultAssist,
	mouseAim = true,
	tipsDone = false,
}

--[[
	callbacks: { onStart(opts), onBuy(kind, id), onEquip(kind, id), onPrompt(kind, key), onSettings(opts) }
]]
function Menu.new(gui, lang, callbacks)
	local self = setmetatable({}, Menu)
	self.gui = gui
	self.lang = lang
	self.cb = callbacks
	self.profile = nil
	self.opts = {}
	for k, v in DEFAULTS do
		self.opts[k] = v
	end
	self.page = "play"
	self.optionDefs = buildOptions(lang)

	self.root = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(8, 20, 12),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 30,
	}, gui)

	self.title = label(self.root, Locale.t(lang, "title"), {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(420, 44),
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 31,
	})
	self.coins = label(self.root, "", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 16),
		Size = UDim2.fromOffset(240, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = GOLD,
		ZIndex = 31,
	})

	-- タブ
	self.tabs = {}
	local tabBar = new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 58),
		Size = UDim2.fromOffset(640, 40),
		ZIndex = 31,
	}, self.root)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 10),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, tabBar)
	for _, id in { "play", "online", "controls", "shop" } do
		local b = button(tabBar, Locale.t(lang, "menu." .. id), GREY, { Size = UDim2.fromOffset(150, 38), ZIndex = 32 })
		b.Activated:Connect(function()
			self:setPage(id)
		end)
		self.tabs[id] = b
	end

	-- 本文 (スクロール)
	self.scroll = new("ScrollingFrame", {
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 108),
		Size = UDim2.new(0.9, 0, 1, -128),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ZIndex = 31,
	}, self.root)
	corner(self.scroll, 12)
	new("UISizeConstraint", { MaxSize = Vector2.new(760, math.huge) }, self.scroll)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, self.scroll)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, self.scroll)

	-- トースト
	self.toastLabel = label(self.root, "", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(520, 34),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 255, 160),
		Visible = false,
		ZIndex = 40,
	})
	self.toastToken = 0

	-- 操作設定: キーの受付
	self.bindings = Bindings.default()
	self.ctrlDevice = "kb"
	self.capture = nil
	UserInputService.InputBegan:Connect(function(input)
		self:_captureInput(input)
	end)
	return self
end

-- ================================================================ 共通
function Menu:_clear()
	for _, c in self.scroll:GetChildren() do
		if not c:IsA("UIComponent") then
			c:Destroy()
		end
	end
end

local order = 0
local function nextOrder()
	order += 1
	return order
end

function Menu:_row(height)
	local f = new("Frame", {
		BackgroundColor3 = ROW,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or 46),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	}, self.scroll)
	corner(f, 8)
	return f
end

function Menu:_header(text)
	label(self.scroll, text, {
		Size = UDim2.new(1, 0, 0, 28),
		TextSize = 20,
		TextColor3 = Color3.fromRGB(200, 230, 210),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
end

function Menu:setPage(id)
	self.page = id
	for k, b in self.tabs do
		b.BackgroundColor3 = (k == id) and GREEN or GREY
	end
	self:_render()
end

function Menu:_render()
	order = 0
	self:_clear()
	if self.page == "play" then
		self:_renderPlay()
	elseif self.page == "online" then
		self:_renderOnline()
	elseif self.page == "controls" then
		self:_renderControls()
	else
		self:_renderShop()
	end
	local coins = self.profile and self.profile.coins or 0
	self.coins.Text = Locale.t(self.lang, "shop.coins", coins)
end

-- ================================================================ 試合設定
function Menu:_renderPlay()
	for _, def in self.optionDefs do
		local row = self:_row(46)
		label(row, def.title, { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.4, 0, 1, 0), ZIndex = 33 })
		local current = self.opts[def.id]
		local idx = 1
		for i, v in def.values do
			if v.value == current then
				idx = i
			end
		end
		local b = button(row, def.values[idx].text, GREY, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.new(0.55, 0, 0, 34),
			ZIndex = 33,
		})
		b.Activated:Connect(function()
			idx = idx % #def.values + 1
			self.opts[def.id] = def.values[idx].value
			b.Text = def.values[idx].text
			if self.cb.onSettings then
				self.cb.onSettings(self.opts)
			end
		end)
	end
	local start = button(self.scroll, Locale.t(self.lang, "start"), GREEN, {
		Size = UDim2.new(1, 0, 0, 56),
		TextSize = 24,
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	start.Activated:Connect(function()
		self.cb.onStart(self.opts)
	end)
end

-- ================================================================ オンライン (協力 / 対戦)
function Menu:_renderOnline()
	local t = function(k, ...)
		return Locale.t(self.lang, k, ...)
	end
	local room = self.room
	if room ~= nil then
		self:_header(t("online.room", room.id, t("online.mode." .. room.mode)))
		label(self.scroll, t("online.settings", room.length / 60, t("diff." .. Config.Difficulties[room.difficulty].key), room.cup and t("menu.mode.cup") or t("menu.mode.quick")), {
			Size = UDim2.new(1, 0, 0, 22),
			TextSize = 14,
			TextColor3 = Color3.fromRGB(180, 200, 190),
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
		for _, m in room.members do
			local row = self:_row(40)
			local teamText = room.mode == "coop" and "" or ("[" .. t(m.team == 0 and "online.team.home" or "online.team.away") .. "] ")
			label(row, teamText .. m.name .. (m.host and (" " .. t("online.host")) or ""), {
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.new(1, -24, 1, 0),
				TextColor3 = m.team == 0 and Color3.fromRGB(140, 190, 255) or Color3.fromRGB(255, 150, 150),
				ZIndex = 33,
			})
		end
		local isHost = false
		for _, m in room.members do
			if m.host and m.userId == self.myId then
				isHost = true
			end
		end
		if room.mode == "versus" then
			for _, team in { 0, 1 } do
				local b = button(self.scroll, t(team == 0 and "online.to_home" or "online.to_away"), GREY, {
					Size = UDim2.new(1, 0, 0, 38),
					LayoutOrder = nextOrder(),
					ZIndex = 32,
				})
				b.Activated:Connect(function()
					self.cb.onRoomTeam(team)
				end)
			end
		end
		if isHost then
			local apply = button(self.scroll, t("online.apply"), GREY, { Size = UDim2.new(1, 0, 0, 38), LayoutOrder = nextOrder(), ZIndex = 32 })
			apply.Activated:Connect(function()
				self.cb.onRoomOpts(self.opts)
			end)
			local start = button(self.scroll, t("online.start"), GREEN, {
				Size = UDim2.new(1, 0, 0, 52),
				TextSize = 22,
				LayoutOrder = nextOrder(),
				ZIndex = 32,
			})
			start.Activated:Connect(function()
				self.cb.onRoomStart()
			end)
		else
			label(self.scroll, t(room.state == "playing" and "online.playing" or "online.waiting"), {
				Size = UDim2.new(1, 0, 0, 28),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = nextOrder(),
				ZIndex = 32,
			})
		end
		local leave = button(self.scroll, t("online.leave"), Color3.fromRGB(150, 60, 60), {
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
		leave.Activated:Connect(function()
			self.cb.onRoomLeave()
		end)
		return
	end
	label(self.scroll, t("online.note"), {
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(180, 200, 190),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	for _, mode in { "coop", "versus" } do
		local b = button(self.scroll, t("online.create_" .. mode), GREEN, {
			Size = UDim2.new(1, 0, 0, 46),
			TextSize = 18,
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
		b.Activated:Connect(function()
			self.cb.onRoomCreate(mode, self.opts)
		end)
	end
	self:_header(t("online.rooms"))
	local rooms = self.rooms or {}
	if #rooms == 0 then
		label(self.scroll, t("online.none"), {
			Size = UDim2.new(1, 0, 0, 26),
			TextColor3 = Color3.fromRGB(180, 200, 190),
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
	end
	for _, r in rooms do
		local row = self:_row(46)
		label(row, string.format("#%d  %s  %s  (%d/%d)", r.id, t("online.mode." .. r.mode), r.host, r.count, r.cap), {
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.65, 0, 1, 0),
			ZIndex = 33,
		})
		local canJoin = r.state == "lobby" and r.count < r.cap
		local b = button(row, canJoin and t("online.join") or t("online.playing"), canJoin and GREEN or GREY, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(130, 34),
			ZIndex = 33,
			Active = canJoin,
			AutoButtonColor = canJoin,
		})
		if canJoin then
			b.Activated:Connect(function()
				self.cb.onRoomJoin(r.id)
			end)
		end
	end
end

function Menu:setRooms(list)
	self.rooms = list
	if self.root.Visible and self.page == "online" then
		self:_render()
	end
end

function Menu:setRoom(room)
	self.room = room
	if self.root.Visible and self.page == "online" then
		self:_render()
	end
end

-- ================================================================ 操作設定 (キー割り当て)
function Menu:setBindings(b)
	self.bindings = b
	if self.root.Visible and self.page == "controls" then
		self:_render()
	end
end

function Menu:_captureInput(input)
	local cap = self.capture
	if cap == nil then
		return
	end
	local t = input.UserInputType
	local key = nil
	if cap.device == "kb" then
		if t == Enum.UserInputType.Keyboard then
			key = input.KeyCode.Name
		elseif t == Enum.UserInputType.MouseButton1 then
			key = "MouseButton1"
		elseif t == Enum.UserInputType.MouseButton2 then
			key = "MouseButton2"
		elseif t == Enum.UserInputType.MouseButton3 then
			key = "MouseButton3"
		end
	elseif t == Enum.UserInputType.Gamepad1 then
		key = input.KeyCode.Name
	elseif t == Enum.UserInputType.Keyboard and input.KeyCode.Name == "Escape" then
		key = "Escape"
	end
	if key == nil then
		return
	end
	self.capture = nil
	if key == "Escape" then
		self:_render()
		return
	end
	if key == "Backspace" then
		self.cb.onBind(cap.device, cap.action, cap.slot, nil)
		return
	end
	local allowed = cap.device == "pad" and Bindings.PAD_ALLOWED or Bindings.KB_ALLOWED
	if not allowed[key] then
		self:toast(Locale.t(self.lang, "controls.notallowed", Bindings.display(key)))
		self:_render()
		return
	end
	self.cb.onBind(cap.device, cap.action, cap.slot, key)
end

function Menu:_renderControls()
	local t = function(k, ...)
		return Locale.t(self.lang, k, ...)
	end
	local b = self.bindings
	label(self.scroll, t("controls.note"), {
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(180, 200, 190),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	-- 機器の切り替え / プリセット
	local bar = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = nextOrder(), ZIndex = 32 }, self.scroll)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, bar)
	for _, dev in { "kb", "pad" } do
		local btn = button(bar, t("controls.device." .. dev), self.ctrlDevice == dev and GREEN or GREY, {
			Size = UDim2.new(0.5, -4, 1, 0),
			ZIndex = 33,
		})
		btn.Activated:Connect(function()
			self.ctrlDevice = dev
			self.capture = nil
			self:_render()
		end)
	end
	local bar2 = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = nextOrder(), ZIndex = 32 }, self.scroll)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, bar2)
	for _, preset in { "mouse", "keys" } do
		local btn = button(bar2, t("controls.preset." .. preset), b.preset == preset and GREEN or GREY, {
			Size = UDim2.new(1 / 3, -6, 1, 0),
			TextSize = 14,
			ZIndex = 33,
		})
		btn.Activated:Connect(function()
			self.capture = nil
			self.cb.onPreset(preset)
		end)
	end
	local reset = button(bar2, t("controls.reset"), Color3.fromRGB(150, 60, 60), {
		Size = UDim2.new(1 / 3, -6, 1, 0),
		TextSize = 14,
		ZIndex = 33,
	})
	reset.Activated:Connect(function()
		self.capture = nil
		self.cb.onPreset("mouse")
	end)
	if self.ctrlDevice == "pad" then
		label(self.scroll, t("controls.padonly"), {
			Size = UDim2.new(1, 0, 0, 22),
			TextSize = 14,
			TextColor3 = Color3.fromRGB(255, 230, 150),
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
	end
	local slots = self.ctrlDevice == "pad" and Bindings.MAX_PAD or Bindings.MAX_KB
	local map = self.ctrlDevice == "pad" and b.pad or b.kb
	local lastGroup = nil
	for _, a in Bindings.ACTIONS do
		if self.ctrlDevice == "pad" and not Bindings.PAD_ACTIONS[a.id] then
			continue
		end
		if a.group ~= lastGroup then
			lastGroup = a.group
			self:_header(t("controls.group." .. a.group))
		end
		local row = self:_row(42)
		label(row, t("action." .. a.id), {
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.5, -12, 1, 0),
			TextSize = 15,
			TextWrapped = true,
			ZIndex = 33,
		})
		local list = map[a.id] or {}
		for slot = 1, slots do
			local capturing = self.capture ~= nil and self.capture.action == a.id and self.capture.slot == slot and self.capture.device == self.ctrlDevice
			local key = list[slot]
			local text = capturing and t("controls.press") or Bindings.display(key)
			local w = 0.5 / slots
			local btn = button(row, text, capturing and GOLD or Color3.fromRGB(235, 235, 235), {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0.5 + w * (slot - 1), 4, 0.5, 0),
				Size = UDim2.new(w, -8, 0, 32),
				TextColor3 = capturing and Color3.new(1, 1, 1) or Color3.fromRGB(20, 20, 20),
				TextSize = 15,
				ZIndex = 33,
			})
			-- 2 つ目の枠は、1 つ目が空なら押せない (詰めて保存するため)
			if slot > #list + 1 then
				btn.AutoButtonColor = false
				btn.BackgroundTransparency = 0.6
			else
				btn.Activated:Connect(function()
					self.capture = { device = self.ctrlDevice, action = a.id, slot = slot }
					self:_render()
				end)
			end
		end
	end
end

-- ================================================================ ショップ
function Menu:_swatch(row, color)
	local sw = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(color[1], color[2], color[3]),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(10, 9),
		Size = UDim2.fromOffset(28, 28),
		ZIndex = 33,
	}, row)
	corner(sw, 14)
end

function Menu:_itemRow(kind, item)
	local p = self.profile
	local row = self:_row(46)
	self:_swatch(row, item.color)
	label(row, Locale.t(self.lang, kind .. "." .. item.id), {
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		ZIndex = 33,
	})
	local owned = p and p.owned[kind][item.id]
	local equipped = p and p.equipped[kind] == item.id
	local text, color, enabled
	if equipped then
		text, color, enabled = Locale.t(self.lang, "shop.equipped"), GREY, false
	elseif owned then
		text, color, enabled = Locale.t(self.lang, "shop.equip"), GREEN, true
	elseif item.vip then
		text, color, enabled = Locale.t(self.lang, "shop.vip_only"), GREY, false
	else
		text, color, enabled = Locale.t(self.lang, "shop.buy", item.price), GOLD, true
	end
	local b = button(row, text, color, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(150, 34),
		ZIndex = 33,
		Active = enabled,
		AutoButtonColor = enabled,
	})
	if enabled then
		b.Activated:Connect(function()
			if owned then
				self.cb.onEquip(kind, item.id)
			else
				self.cb.onBuy(kind, item.id)
			end
		end)
	end
end

function Menu:_passRow(key, textKey)
	local p = self.profile
	local def = Config.Monetization.Passes[key]
	local row = self:_row(52)
	label(row, Locale.t(self.lang, textKey), {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.62, 0, 1, 0),
		TextWrapped = true,
		TextSize = 15,
		ZIndex = 33,
	})
	local owned = p and p.passes[key]
	local avail = p and p.available[key]
	local text, color, enabled
	if owned then
		text, color, enabled = Locale.t(self.lang, "shop.owned"), GREY, false
	elseif not avail then
		text, color, enabled = Locale.t(self.lang, "shop.unavailable"), GREY, false
	else
		text, color, enabled = "R$ " .. def.price, GOLD, true
	end
	local b = button(row, text, color, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(130, 36),
		ZIndex = 33,
		Active = enabled,
		AutoButtonColor = enabled,
	})
	if enabled then
		b.Activated:Connect(function()
			self.cb.onPrompt("pass", key)
		end)
	end
end

function Menu:_renderShop()
	local p = self.profile
	if p == nil then
		self:_header("...")
		return
	end
	label(self.scroll, Locale.t(self.lang, "shop.note"), {
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(180, 200, 190),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	self:_header(Locale.t(self.lang, "shop.passes"))
	self:_passRow("VIP", "shop.vip")
	self:_passRow("AllKits", "shop.allkits")
	self:_header(Locale.t(self.lang, "shop.kits"))
	for _, k in Config.Kits do
		self:_itemRow("kit", k)
	end
	self:_header(Locale.t(self.lang, "shop.balls"))
	for _, b in Config.Balls do
		self:_itemRow("ball", b)
	end
	self:_header(Locale.t(self.lang, "shop.packs"))
	for _, key in { "Coins500", "Coins2000", "Coins10000" } do
		local def = Config.Monetization.Products[key]
		local row = self:_row(46)
		label(row, Locale.t(self.lang, "shop.pack", def.coins), {
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.5, 0, 1, 0),
			ZIndex = 33,
		})
		local avail = p.available[key]
		local b = button(row, avail and ("R$ " .. def.price) or Locale.t(self.lang, "shop.unavailable"), avail and GOLD or GREY, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(130, 34),
			ZIndex = 33,
			Active = avail,
			AutoButtonColor = avail,
		})
		if avail then
			b.Activated:Connect(function()
				self.cb.onPrompt("product", key)
			end)
		end
	end
end

-- ================================================================ 公開 API
function Menu:setProfile(profile)
	self.profile = profile
	-- 保存済みの設定を反映 (初回のみ)
	if profile and not self._settingsLoaded then
		self._settingsLoaded = true
		for k, v in profile.settings or {} do
			if DEFAULTS[k] ~= nil and typeof(v) == typeof(DEFAULTS[k]) then
				self.opts[k] = v
			end
		end
	end
	if self.root.Visible then
		self:_render()
	end
end

function Menu:show(page)
	self.root.Visible = true
	self:setPage(page or "play")
end

function Menu:hide()
	self.root.Visible = false
end

function Menu:toast(text)
	self.toastToken += 1
	local token = self.toastToken
	self.toastLabel.Text = text
	self.toastLabel.Visible = true
	task.delay(2.5, function()
		if self.toastToken == token then
			self.toastLabel.Visible = false
		end
	end)
end

-- ================================================================ 結果画面
--[[
	result: Match の result。onAgain / onMenu: ボタン。reward は後から setReward で届く。
]]
function Menu:showResult(result, onAgain, onMenu)
	self.root.Visible = true
	for _, b in self.tabs do
		b.Visible = false
	end
	order = 0
	self:_clear()
	local t = function(k, ...)
		return Locale.t(self.lang, k, ...)
	end
	local verdictKey = "result.draw"
	if result.winner == 0 then
		verdictKey = "result.win"
	elseif result.winner == 1 then
		verdictKey = "result.lose"
	end
	local head = string.format("%d - %d    %s", result.home, result.away, t(verdictKey))
	label(self.scroll, head, {
		Size = UDim2.new(1, 0, 0, 44),
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	local sub = {}
	if result.extra then
		table.insert(sub, t("result.extra"))
	end
	if result.shootout then
		table.insert(sub, t("result.pk", result.shootout.home, result.shootout.away))
	end
	if #sub > 0 then
		label(self.scroll, table.concat(sub, "  /  "), {
			Size = UDim2.new(1, 0, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Color3.fromRGB(255, 255, 160),
			LayoutOrder = nextOrder(),
			ZIndex = 32,
		})
	end
	self.rewardLabel = label(self.scroll, "", {
		Size = UDim2.new(1, 0, 0, 30),
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = GOLD,
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	-- スタッツ (自分 | 項目 | CPU)
	local s0, s1 = result.stats[0], result.stats[1]
	local rows = {
		{ "stat.poss", result.possession .. "%", (100 - result.possession) .. "%" },
		{ "stat.shots", s0.shots, s1.shots },
		{ "stat.ontarget", s0.onTarget, s1.onTarget },
		{ "stat.passes", s0.passOk .. "/" .. s0.passes, s1.passOk .. "/" .. s1.passes },
		{ "stat.corners", s0.corners, s1.corners },
		{ "stat.fouls", s0.fouls, s1.fouls },
		{ "stat.cards", s0.yellow .. " / " .. s0.red, s1.yellow .. " / " .. s1.red },
		{ "stat.saves", s0.saves, s1.saves },
	}
	for _, r in rows do
		local row = self:_row(34)
		label(row, tostring(r[2]), { Size = UDim2.new(0.25, 0, 1, 0), Position = UDim2.fromOffset(12, 0), ZIndex = 33 })
		label(row, t(r[1]), {
			Size = UDim2.new(0.5, 0, 1, 0),
			Position = UDim2.new(0.25, 0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Color3.fromRGB(200, 230, 210),
			ZIndex = 33,
		})
		label(row, tostring(r[3]), {
			Size = UDim2.new(0.25, -12, 1, 0),
			Position = UDim2.new(0.75, 0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 33,
		})
	end
	local again = button(self.scroll, t("result.again"), GREEN, {
		Size = UDim2.new(1, 0, 0, 50),
		TextSize = 22,
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	again.Activated:Connect(function()
		for _, b in self.tabs do
			b.Visible = true
		end
		onAgain()
	end)
	local back = button(self.scroll, t("menu.back"), GREY, {
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = nextOrder(),
		ZIndex = 32,
	})
	back.Activated:Connect(function()
		for _, b in self.tabs do
			b.Visible = true
		end
		onMenu()
	end)
end

function Menu:setReward(reward)
	if self.rewardLabel == nil or reward == nil then
		return
	end
	local t = function(k, ...)
		return Locale.t(self.lang, k, ...)
	end
	local text = t("result.coins", reward.coins)
	if reward.parts and reward.parts.vip then
		text ..= " " .. t("result.coins.vip", reward.parts.vip)
	end
	if reward.total then
		text ..= "   " .. t("result.total", reward.total)
	end
	self.rewardLabel.Text = text
end

return Menu
