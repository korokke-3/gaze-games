--!nonstrict
--[[
	Hud — 画面上の表示 (スコア・時間・ポップアップ・ミニマップ・溜めゲージ・タイトル/結果)。
	文字列は Locale のキーで受け、ここで言語に解決する。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))

local PL, PW = Config.Pitch.Length, Config.Pitch.Width
local MATCH_TIME = Config.MatchTime
local KEYS = Config.Keys

local TAG_COLOR = {
	good = Color3.fromRGB(90, 255, 120),
	bad = Color3.fromRGB(255, 100, 100),
	skill = Color3.fromRGB(0, 230, 255),
	info = Color3.fromRGB(255, 255, 255),
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
		Size = UDim2.fromOffset(420, 44),
	})
	self.scoreText = text(self.scoreBar, { Size = UDim2.new(1, -16, 1, -8), Position = UDim2.fromOffset(8, 4) })

	-- セットプレーの案内
	self.setpText = text(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 62),
		Size = UDim2.fromOffset(760, 30),
		TextColor3 = Color3.fromRGB(255, 255, 160),
		Visible = false,
	})

	-- 中央のポップアップ (直近 2 つ)
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

	-- 一時停止
	self.pauseText = text(self.gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 60),
		Text = Locale.t(lang, "hud.paused"),
		Visible = false,
	})

	-- 溜めゲージ
	self.chargeBar = panel(self.gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -64),
		Size = UDim2.fromOffset(220, 16),
		Visible = false,
	})
	self.chargeFill = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(0, 200, 255),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
	}, self.chargeBar)
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, self.chargeFill)

	-- ミニマップ
	local mw = 190
	local mh = math.floor(mw * PW / PL)
	self.mapW, self.mapH = mw, mh
	self.minimap = new("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
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
	end
	self.ballDot = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, self.minimap)

	-- 操作説明 (H で隠す)
	self.help = panel(self.gui, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.fromOffset(520, 108),
	})
	local lines = {
		Locale.t(lang, "hud.help.title"),
		Locale.t(lang, "hud.help.attack"),
		Locale.t(lang, "hud.help.flick"),
		Locale.t(lang, "hud.help.defend"),
		Locale.t(lang, "hud.help.other"),
	}
	self.helpText = text(self.help, {
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.new(1, -16, 1, -8),
		Text = table.concat(lines, "\n"),
		TextSize = 13,
		TextScaled = false,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextStrokeTransparency = 1,
	})

	-- タイトル / 結果のオーバーレイ
	self.overlay = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(10, 25, 12),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
	}, self.gui)
	self.overlayTitle = text(self.overlay, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.28),
		Size = UDim2.fromOffset(720, 90),
		ZIndex = 21,
	})
	self.overlayBody = text(self.overlay, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(780, 70),
		TextWrapped = true,
		ZIndex = 21,
	})
	self.overlayButton = new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.65),
		Size = UDim2.fromOffset(280, 64),
		BackgroundColor3 = Color3.fromRGB(40, 170, 80),
		Font = Enum.Font.GothamBold,
		TextSize = 28,
		TextColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = true,
		ZIndex = 22,
	}, self.overlay)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, self.overlayButton)
	self._buttonConn = nil
	return self
end

function Hud:_showOverlay(title, body, buttonKey, onClick)
	self.overlayTitle.Text = title
	self.overlayBody.Text = body
	self.overlayButton.Text = Locale.t(self.lang, buttonKey)
	self.overlay.Visible = true
	if self._buttonConn then
		self._buttonConn:Disconnect()
	end
	self._buttonConn = self.overlayButton.Activated:Connect(function()
		self.overlay.Visible = false
		onClick()
	end)
end

function Hud:showTitle(onStart)
	self:_showOverlay(Locale.t(self.lang, "title"), Locale.t(self.lang, "subtitle"), "start", onStart)
end

function Hud:showResult(result, onRematch)
	local verdict = "result.draw"
	if result.home > result.away then
		verdict = "result.win"
	elseif result.home < result.away then
		verdict = "result.lose"
	end
	local body = string.format(
		"%d - %d   %s\n%s",
		result.home,
		result.away,
		Locale.t(self.lang, verdict),
		Locale.t(
			self.lang,
			"result.stats",
			result.passes,
			result.intercepted,
			result.skillBeat,
			result.skillTried,
			result.offside,
			result.fouls
		)
	)
	self:_showOverlay(Locale.t(self.lang, "result"), body, "rematch", onRematch)
end

function Hud:toggleHelp()
	self.help.Visible = not self.help.Visible
end

--- 試合の表示を更新する (毎フレーム)。
function Hud:step(match)
	local t = Locale.t
	local remain = math.max(0, MATCH_TIME - match.elapsed)
	local mm, ss = math.floor(remain / 60), math.floor(remain % 60)
	self.scoreText.Text = string.format("%s    %d:%02d", t(self.lang, "hud.score", match.score[0], match.score[1]), mm, ss)

	-- セットプレーの案内
	local sp = match.setp
	if sp ~= nil then
		local msg = t(self.lang, "setp." .. sp.kind)
		if sp.team == 0 and match:human(0) then
			msg ..= "  (" .. t(self.lang, "setp.hint")
			if sp.kind == "fk" or sp.kind == "pk" then
				msg ..= t(self.lang, "setp.hint.shoot")
			end
			msg ..= ")"
		end
		self.setpText.Text = msg
		self.setpText.Visible = true
	else
		self.setpText.Visible = false
	end

	-- ポップアップ (新しい順に最大 2 つ)
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
		lbl.TextColor3 = TAG_COLOR[p.tag] or TAG_COLOR.info
		lbl.TextTransparency = math.clamp((age - 0.9) / 0.4, 0, 1)
		lbl.Visible = true
	end
	for i = shown + 1, 2 do
		self.popupLabels[i].Visible = false
	end

	self.pauseText.Visible = match.paused

	-- シュートの溜め
	if match.charge ~= nil then
		local pw = math.min(1, (match.elapsed - match.charge) / 1.0)
		self.chargeBar.Visible = true
		self.chargeFill.Size = UDim2.fromScale(pw, 1)
		self.chargeFill.BackgroundColor3 = pw < 0.85 and Color3.fromRGB(0, 200, 255) or Color3.fromRGB(255, 80, 80)
	else
		self.chargeBar.Visible = false
	end

	-- ミニマップ
	local function mp(p)
		return UDim2.fromOffset((p.x / PL + 0.5) * self.mapW, (p.y / PW + 0.5) * self.mapH)
	end
	for i, p in match.pl do
		local d = self.dots[i]
		d.Position = mp(p.p)
		d.BackgroundColor3 = p.team == 0 and Color3.fromRGB(35, 110, 215) or Color3.fromRGB(205, 45, 45)
		d.Size = p == match.ctrl and UDim2.fromOffset(9, 9) or UDim2.fromOffset(6, 6)
	end
	self.ballDot.Position = mp(match.ball.p)
end

function Hud:destroy()
	self.gui:Destroy()
end

Hud.KEYS = KEYS
return Hud
