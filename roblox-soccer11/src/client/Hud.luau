--!nonstrict
--[[
	Hud — 試合中の表示 (スコア・時間・ポップアップ・ミニマップ・パワーゲージ・スタミナ・操作ガイド)。
	ローカルの Match とオンラインの RemoteMatch の両方を同じように表示する。

	view: { seatId, myTeam, device = "keyboard" | "gamepad" | "touch" }
	操作ガイドは、状況 (攻撃 / 守備 / セットプレー) と入力機器に合わせて中身が変わる。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))

local PL, PW = Config.Pitch.Length, Config.Pitch.Width

local GOOD = Color3.fromRGB(90, 255, 120)
local BAD = Color3.fromRGB(255, 100, 100)
local INFO = Color3.fromRGB(255, 255, 255)

local Bindings = require(Shared:WaitForChild("Bindings"))

-- 操作ガイド: { 表記の作り方, 説明のキー }
--   { "pass" }            その操作のキー
--   { "l1", "+", "pass" }  組み合わせ (各操作の 1 つ目のキー)
--   "aim" / "flick" / "flickLR" / "moves" / "zoom"  特別な表記
local GUIDE = {
	attack = {
		{ "aim", "guide.aim" },
		{ { "pass" }, "guide.pass" },
		{ { "through" }, "guide.through" },
		{ { "lofted" }, "guide.lofted" },
		{ { "shoot" }, "guide.shoot" },
		{ { "dash" }, "guide.dash" },
		{ { "l1", "+", "pass" }, "guide.l1" },
		{ { "r1", "+", "shoot" }, "guide.r1" },
		{ "flick", "guide.feint" },
		{ "zoom", "guide.zoom" },
	},
	defense = {
		{ { "pass" }, "guide.pressure" },
		{ { "l2" }, "guide.matchup" },
		{ { "r1" }, "guide.callpress" },
		{ { "shoot" }, "guide.charge" },
		{ { "lofted" }, "guide.slide" },
		{ { "l1" }, "guide.switch" },
		{ "flick", "guide.switchdir" },
		{ { "through" }, "guide.gk" },
		{ { "levelDown", "/", "levelUp" }, "guide.level" },
	},
	setpiece = {
		{ "aim", "guide.sp.aim" },
		{ { "pass" }, "guide.sp.pass" },
		{ { "lofted" }, "guide.sp.lofted" },
		{ { "through" }, "guide.sp.through" },
		{ { "shoot" }, "guide.sp.shoot" },
		{ "flickLR", "guide.sp.curl" },
	},
	keeper = {
		{ "moves", "guide.pk.dive" },
	},
}

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props or {} do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function text(parent, props)
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		TextScaled = true,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base, parent)
end

local function panel(parent, props)
	local base = { BackgroundColor3 = Color3.fromRGB(20, 20, 20), BackgroundTransparency = 0.25, BorderSizePixel = 0 }
	for k, v in props do
		base[k] = v
	end
	local f = new("Frame", base, parent)
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, f)
	return f
end

local Hud = {}
Hud.__index = Hud

function Hud.new(lang)
	local self = setmetatable({}, Hud)
	self.lang = lang
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.gui = new("ScreenGui", {
		Name = "SoccerHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
	}, playerGui)

	-- スコアと時間
	self.scoreBar = panel(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(460, 44),
	})
	self.scoreText = text(self.scoreBar, { Size = UDim2.new(1, -16, 1, -8), Position = UDim2.fromOffset(8, 4) })
	self.periodText = text(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 54),
		Size = UDim2.fromOffset(360, 20),
		TextSize = 14,
		TextScaled = false,
		TextColor3 = Color3.fromRGB(200, 230, 210),
	})
	self.setpText = text(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 76),
		Size = UDim2.fromOffset(760, 28),
		TextColor3 = Color3.fromRGB(255, 255, 160),
		Visible = false,
	})
	self.replayText = text(self.gui, {
		Position = UDim2.fromOffset(16, 64),
		Size = UDim2.fromOffset(320, 34),
		TextColor3 = Color3.fromRGB(255, 120, 120),
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
	})
	self.popupLabels = {}
	for i = 1, 2 do
		self.popupLabels[i] = text(self.gui, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.25 + 0.11 * (i - 1), 0),
			Size = UDim2.fromOffset(560, 56),
			TextStrokeTransparency = 0,
			Visible = false,
		})
	end
	self.pauseText = text(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 60),
		Text = Locale.t(lang, "hud.paused"),
		Visible = false,
	})

	-- パワーゲージ (溜めている間)
	self.gauge = panel(self.gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -70),
		Size = UDim2.fromOffset(300, 26),
		Visible = false,
	})
	self.gaugeFill = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(0, 200, 255),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
	}, self.gauge)
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, self.gaugeFill)
	self.gaugeText = text(self.gauge, {
		Size = UDim2.fromScale(1, 1),
		TextScaled = false,
		TextSize = 15,
		ZIndex = 2,
	})

	-- スタミナ
	self.staminaBar = panel(self.gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -40),
		Size = UDim2.fromOffset(220, 10),
	})
	self.staminaFill = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(120, 230, 120),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, self.staminaBar)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, self.staminaFill)

	-- ミニマップ
	local mw = 190
	local mh = math.floor(mw * PW / PL)
	self.mapW, self.mapH = mw, mh
	self.minimap = new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 60),
		Size = UDim2.fromOffset(mw, mh),
		BackgroundColor3 = Color3.fromRGB(20, 60, 20),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, self.gui)
	new("UIStroke", { Color = Color3.fromRGB(220, 220, 220), Thickness = 1 }, self.minimap)
	new("Frame", {
		BackgroundColor3 = Color3.fromRGB(200, 200, 200),
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(0, 1, 1, 0),
	}, self.minimap)
	self.dots = {}
	for i = 1, 22 do
		self.dots[i] = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(6, 6),
			BorderSizePixel = 0,
		}, self.minimap)
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, self.dots[i])
	end
	self.ballDot = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, self.minimap)

	-- 操作ガイド (状況と入力機器で中身が変わる)
	self.guide = panel(self.gui, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.fromOffset(360, 40),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, self.guide)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}, self.guide)
	self.guideKey = nil
	self.helpVisible = true
	self.bindings = Bindings.default()
	self.mouseAim = true
	self.bindVersion = 0
	return self
end

--- 操作の割り当てが変わった時 (ガイドの表記を作り直す)。
function Hud:setBindings(b, mouseAim)
	self.bindings = b or Bindings.default()
	self.mouseAim = mouseAim ~= false
	self.bindVersion += 1
	self.guideKey = nil
end

--- ガイドの 1 行の表記。
function Hud:_glyph(spec, device)
	local b = self.bindings
	local dev = device == "gamepad" and "pad" or "kb"
	local function first(action)
		local map = dev == "pad" and b.pad or b.kb
		local list = map[action]
		return Bindings.display(list and list[1])
	end
	if spec == "aim" then
		if dev == "pad" then
			return "LS"
		end
		return self.mouseAim and "Mouse" or (first("moveUp") .. first("moveLeft") .. first("moveDown") .. first("moveRight"))
	elseif spec == "moves" then
		return dev == "pad" and "LS" or (first("moveUp") .. first("moveLeft") .. first("moveDown") .. first("moveRight"))
	elseif spec == "flick" then
		return dev == "pad" and "RS" or (first("flickLeft") .. " " .. first("flickUp") .. " " .. first("flickRight") .. " " .. first("flickDown"))
	elseif spec == "flickLR" then
		return dev == "pad" and "RS" or (first("flickLeft") .. " " .. first("flickRight"))
	elseif spec == "zoom" then
		return dev == "pad" and "—" or "Wheel"
	end
	if #spec == 1 then
		return Bindings.label(b, dev, spec[1])
	end
	local parts = {}
	for _, x in spec do
		if x == "+" or x == "/" then
			table.insert(parts, " " .. x .. " ")
		else
			table.insert(parts, first(x))
		end
	end
	return table.concat(parts)
end

function Hud:toggleHelp()
	self.helpVisible = not self.helpVisible
	self.guide.Visible = self.helpVisible
end

--- 操作ガイドを作り直す (状況・機器が変わった時だけ)。
function Hud:_renderGuide(context, device)
	local key = context .. ":" .. device .. ":" .. self.bindVersion
	if self.guideKey == key then
		return
	end
	self.guideKey = key
	for _, c in self.guide:GetChildren() do
		if not c:IsA("UIComponent") then
			c:Destroy()
		end
	end
	local title = text(self.guide, {
		Size = UDim2.new(1, 0, 0, 18),
		TextScaled = false,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(255, 230, 120),
		Text = Locale.t(self.lang, "guide.title." .. context) .. "   " .. Locale.t(self.lang, "guide.hide"),
		LayoutOrder = 0,
	})
	title.TextStrokeTransparency = 1
	if device == "touch" then
		text(self.guide, {
			Size = UDim2.new(1, 0, 0, 34),
			TextScaled = false,
			TextSize = 13,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = Locale.t(self.lang, "guide.touch"),
			TextStrokeTransparency = 1,
			LayoutOrder = 1,
		})
		return
	end
	for i, row in GUIDE[context] do
		local glyph = self:_glyph(row[1], device)
		local r = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = i }, self.guide)
		local g = new("Frame", {
			BackgroundColor3 = Color3.fromRGB(235, 235, 235),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(112, 18),
		}, r)
		new("UICorner", { CornerRadius = UDim.new(0, 5) }, g)
		local gl = text(g, {
			Size = UDim2.fromScale(1, 1),
			TextScaled = false,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(20, 20, 20),
			Text = glyph,
		})
		gl.TextStrokeTransparency = 1
		local d = text(r, {
			Position = UDim2.fromOffset(120, 0),
			Size = UDim2.new(1, -120, 1, 0),
			TextScaled = false,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = Locale.t(self.lang, row[2]),
		})
		d.TextStrokeTransparency = 1
	end
end

--- 自分の状況: "attack" | "defense" | "setpiece" | "keeper"
function Hud.context(match, s, myTeam)
	local b = match.ball
	local ctrl = s and s.ctrl
	local sp = match.setp
	if sp ~= nil then
		if ctrl ~= nil and sp.taker == ctrl then
			return "setpiece"
		end
		if sp.kind == "pk" and sp.team ~= myTeam then
			return "keeper"
		end
	end
	if b.owner ~= nil and b.owner.team == myTeam then
		return "attack"
	end
	if b.owner == nil and ctrl ~= nil then
		local dx, dy = b.p.x - ctrl.p.x, b.p.y - ctrl.p.y
		if dx * dx + dy * dy < 36 then
			return "attack"
		end
	end
	return "defense"
end

function Hud:teamName(match, team, myTeam)
	if team == myTeam then
		return Locale.t(self.lang, "hud.team.you")
	elseif match:human(team) then
		return Locale.t(self.lang, "hud.team.rival")
	end
	return Locale.t(self.lang, "hud.team.cpu")
end

--- 毎フレーム。view: { seatId, myTeam, device }
function Hud:step(match, view)
	local t = Locale.t
	local myTeam = view.myTeam or 0
	local s = match:seat(view.seatId)
	local length = match.matchTime or Config.MatchTime
	local remain = math.max(0, length - match.elapsed)
	if match.period == "extra" then
		remain = math.max(0, (match.boundaries and match.boundaries[match.bIndex] or length) - match.elapsed)
	end
	local mm, ss = math.floor(remain / 60), math.floor(remain % 60)
	self.scoreText.Text = string.format(
		"%s  %d - %d  %s    %d:%02d",
		self:teamName(match, 0, myTeam),
		match.score[0],
		match.score[1],
		self:teamName(match, 1, myTeam),
		mm,
		ss
	)

	-- 前後半・延長・PK 戦
	local periodKey
	if match.mode == "shootout" then
		periodKey = "hud.period.pk"
	elseif match.period == "extra" then
		periodKey = match.bIndex <= 3 and "hud.period.e1" or "hud.period.e2"
	else
		periodKey = match.bIndex <= 1 and "hud.period.h1" or "hud.period.h2"
	end
	local ptext = t(self.lang, periodKey)
	if match.shoot ~= nil then
		ptext ..= "   " .. t(self.lang, "hud.pk", match.shoot.goals[0], match.shoot.goals[1])
	end
	local lv = match.level and match.level[myTeam] or 0
	if lv ~= 0 then
		ptext ..= "   " .. t(self.lang, "hud.level", (lv > 0 and "+" or "") .. tostring(lv))
	end
	self.periodText.Text = ptext
	self.replayText.Visible = match.mode == "replay"
	if match.mode == "replay" then
		self.replayText.Text = "▶ " .. t(self.lang, "hud.replay")
	end

	-- セットプレー
	local sp = match.setp
	if sp ~= nil then
		local msg = t(self.lang, "setp." .. sp.kind)
		if s ~= nil and sp.taker == s.ctrl then
			msg ..= "  " .. t(self.lang, sp.kind == "pk" and "setp.hint.pk" or "setp.hint")
		elseif sp.kind == "pk" and sp.team ~= myTeam then
			msg ..= "  " .. t(self.lang, "setp.hint.keeper")
		end
		self.setpText.Text = msg
		self.setpText.Visible = true
	else
		self.setpText.Visible = false
	end

	-- ポップアップ (得をしたチームが自分なら緑、相手なら赤)
	local shown = 0
	for i = #match.popups, 1, -1 do
		if shown >= 2 then
			break
		end
		local p = match.popups[i]
		shown += 1
		local lbl = self.popupLabels[shown]
		local age = match.elapsed - p.t
		lbl.Text = t(self.lang, p.key)
		lbl.TextColor3 = p.team == nil and INFO or (p.team == myTeam and GOOD or BAD)
		lbl.TextTransparency = math.clamp((age - 0.9) / 0.4, 0, 1)
		lbl.Visible = true
	end
	for i = shown + 1, 2 do
		self.popupLabels[i].Visible = false
	end
	self.pauseText.Visible = match.paused == true

	-- パワーゲージ
	local pw = s and match:chargePower(s)
	if pw ~= nil then
		self.gauge.Visible = true
		self.gaugeFill.Size = UDim2.fromScale(pw, 1)
		self.gaugeFill.BackgroundColor3 = pw < 0.4 and Color3.fromRGB(0, 200, 255)
			or (pw < 0.8 and Color3.fromRGB(255, 200, 60) or Color3.fromRGB(255, 80, 80))
		local kind = (s.charge and s.charge.btn) or s.kind or "pass"
		self.gaugeText.Text = t(self.lang, "gauge." .. kind) .. "  " .. math.floor(pw * 100) .. "%"
	else
		self.gauge.Visible = false
	end

	-- スタミナ
	local c = s and s.ctrl
	if c ~= nil then
		local f = math.clamp(c.stamina / Config.Stamina.Max, 0, 1)
		self.staminaFill.Size = UDim2.fromScale(f, 1)
		self.staminaFill.BackgroundColor3 = c.exhausted and Color3.fromRGB(255, 90, 90)
			or (f < 0.35 and Color3.fromRGB(255, 190, 60) or Color3.fromRGB(120, 230, 120))
	end

	-- ミニマップ (操作中の選手は大きく)
	local controlled = {}
	for _, x in match.seats do
		if x.ctrl ~= nil then
			controlled[x.ctrl] = x.id == view.seatId and "me" or "other"
		end
	end
	local function mp(p)
		return UDim2.fromOffset((p.x / PL + 0.5) * self.mapW, (p.y / PW + 0.5) * self.mapH)
	end
	for i, p in match.pl do
		local d = self.dots[i]
		d.Visible = not p.out
		d.Position = mp(p.p)
		d.BackgroundColor3 = p.team == 0 and Color3.fromRGB(35, 110, 215) or Color3.fromRGB(205, 45, 45)
		local who = controlled[p]
		d.Size = who == "me" and UDim2.fromOffset(10, 10) or (who == "other" and UDim2.fromOffset(8, 8) or UDim2.fromOffset(6, 6))
	end
	self.ballDot.Position = mp(match.ball.p)

	-- 操作ガイド
	local ctx = Hud.context(match, s, myTeam)
	self.context = ctx
	if self.helpVisible then
		self:_renderGuide(ctx, view.device or "keyboard")
	end
end

function Hud:destroy()
	self.gui:Destroy()
end

return Hud
