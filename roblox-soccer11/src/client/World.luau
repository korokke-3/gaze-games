--!nonstrict
--[[
	World — Match の状態を Workspace のパーツに映す (描画専用。ロジックは持たない)。
	コートの座標 (x: 攻撃方向, y: 横) は Workspace の (X, Z) に対応させる。
	カメラは真上から少し手前に傾けて、ボールを追いかける。
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Locale = require(Shared:WaitForChild("Locale"))

local S = Config.View.Studs
local PL, PW = Config.Pitch.Length, Config.Pitch.Width
local GOAL_W, GOAL_H = Config.Pitch.GoalWidth, Config.Pitch.GoalHeight
local BOX_L, BOX_W = Config.Pitch.BoxLength, Config.Pitch.BoxWidth
local SIX_L, SIX_W = Config.Pitch.SixLength, Config.Pitch.SixWidth
local PEN_SPOT = Config.Pitch.PenaltySpot

local function rgb(t)
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function toWorld(x, y, h)
	return Vector3.new(x * S, h or 0, y * S)
end

local function newPart(props, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local function newLabel(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Font = Enum.Font.GothamBold
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.3
	for k, v in props or {} do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local function billboard(adornee, size, offset)
	local g = Instance.new("BillboardGui")
	g.Size = size
	g.StudsOffset = offset
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.Adornee = adornee
	g.Parent = adornee
	return g
end

-- ================================================================ コート
local WHITE = Color3.fromRGB(235, 235, 235)

local function buildPitch(folder)
	-- 芝 (外周に余白)
	newPart({
		Name = "Grass",
		Size = Vector3.new(PL * S + 90, 1, PW * S + 70),
		Position = Vector3.new(0, -0.5, 0),
		Color = Color3.fromRGB(40, 105, 40),
	}, folder)
	for i = -11, 10 do
		if i % 2 == 0 then
			newPart({
				Name = "Stripe",
				Size = Vector3.new(5 * S, 0.05, PW * S),
				Position = Vector3.new((i * 5 + 2.5) * S, 0.03, 0),
				Color = Color3.fromRGB(46, 118, 46),
			}, folder)
		end
	end
	local function line(x1, y1, x2, y2, thick)
		local a, b = toWorld(x1, y1, 0.08), toWorld(x2, y2, 0.08)
		local len = (b - a).Magnitude
		local mid = (a + b) / 2
		local p = newPart({
			Name = "Line",
			Size = Vector3.new(thick or 0.4, 0.05, len + (thick or 0.4)),
			Color = WHITE,
		}, folder)
		p.CFrame = CFrame.lookAt(mid, b)
	end
	local function rect(x1, y1, x2, y2)
		line(x1, y1, x2, y1)
		line(x2, y1, x2, y2)
		line(x2, y2, x1, y2)
		line(x1, y2, x1, y1)
	end
	rect(-PL / 2, -PW / 2, PL / 2, PW / 2)
	line(0, -PW / 2, 0, PW / 2)
	-- センターサークル
	local seg, r = 40, 9.15
	for i = 0, seg - 1 do
		local a0, a1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
		line(r * math.cos(a0), r * math.sin(a0), r * math.cos(a1), r * math.sin(a1))
	end
	for _, sd in { -1, 1 } do
		local gx = sd * PL / 2
		rect(gx, -BOX_W / 2, gx - sd * BOX_L, BOX_W / 2)
		rect(gx, -SIX_W / 2, gx - sd * SIX_L, SIX_W / 2)
		newPart({
			Name = "Spot",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.05, 1.2, 1.2),
			CFrame = CFrame.new(toWorld(gx - sd * PEN_SPOT, 0, 0.1)) * CFrame.Angles(0, 0, math.rad(90)),
			Color = WHITE,
		}, folder)
		-- ゴール (ポスト・バー・ネット)
		local postH = GOAL_H * S
		for _, side in { -1, 1 } do
			newPart({
				Name = "Post",
				Size = Vector3.new(0.7, postH, 0.7),
				Position = toWorld(gx, side * GOAL_W / 2, postH / 2),
				Color = Color3.fromRGB(245, 245, 245),
			}, folder)
		end
		newPart({
			Name = "Crossbar",
			Size = Vector3.new(0.7, 0.7, GOAL_W * S + 0.7),
			Position = toWorld(gx, 0, postH),
			Color = Color3.fromRGB(245, 245, 245),
		}, folder)
		newPart({
			Name = "Net",
			Size = Vector3.new(0.2, postH, GOAL_W * S),
			Position = toWorld(gx + sd * 2.5, 0, postH / 2),
			Color = Color3.fromRGB(230, 230, 230),
			Transparency = 0.65,
		}, folder)
	end
end

-- ================================================================ World
local World = {}
World.__index = World

function World.new(match, lang)
	local self = setmetatable({}, World)
	self.match = match
	self.lang = lang
	self.folder = Instance.new("Folder")
	self.folder.Name = "SoccerWorld"
	self.folder.Parent = Workspace
	buildPitch(self.folder)

	self.actors = {} -- player -> { body, nose, shadow, cursor, nextMark, skill, skillUntil }
	for _, pl in match.pl do
		local col
		if pl.team == 0 then
			col = pl.gk and Config.View.HomeKeeperColor or Config.View.HomeColor
		else
			col = pl.gk and Config.View.AwayKeeperColor or Config.View.AwayColor
		end
		local body = newPart({
			Name = "Player",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2.8, 2.8, 2.8),
			Color = rgb(col),
		}, self.folder)
		local nose = newPart({ Name = "Face", Size = Vector3.new(0.9, 0.9, 1.4), Color = Color3.new(1, 1, 1) }, self.folder)
		local shadow = newPart({
			Name = "Shadow",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.05, 3.2, 3.2),
			Color = Color3.fromRGB(25, 65, 25),
		}, self.folder)

		local num = billboard(body, UDim2.fromOffset(44, 22), Vector3.new(0, 2.6, 0))
		newLabel(num, { Text = tostring(pl.num), TextColor3 = Color3.new(1, 1, 1) })

		local cursor = billboard(body, UDim2.fromOffset(40, 30), Vector3.new(0, 5.2, 0))
		newLabel(cursor, { Text = "▼", TextColor3 = Color3.fromRGB(255, 255, 120) })
		cursor.Enabled = false

		local nextMark = billboard(body, UDim2.fromOffset(30, 22), Vector3.new(0, 5.0, 0))
		newLabel(nextMark, { Text = "▽ U", TextColor3 = Color3.fromRGB(120, 230, 255) })
		nextMark.Enabled = false

		local skill = billboard(body, UDim2.fromOffset(180, 30), Vector3.new(0, 7.5, 0))
		local skillLabel = newLabel(skill, { Text = "", TextColor3 = Color3.fromRGB(0, 230, 255) })
		skill.Enabled = false

		self.actors[pl] = {
			body = body,
			nose = nose,
			shadow = shadow,
			cursor = cursor,
			nextMark = nextMark,
			skill = skill,
			skillLabel = skillLabel,
			baseColor = rgb(col),
		}
	end

	self.ball = newPart({
		Name = "Ball",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.7, 1.7, 1.7),
		Color = Color3.new(1, 1, 1),
	}, self.folder)
	self.ballShadow = newPart({
		Name = "BallShadow",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.05, 1.6, 1.6),
		Color = Color3.fromRGB(25, 65, 25),
	}, self.folder)

	local m = match.ball.p
	self.focus = Vector3.new(m.x * S, 0, m.y * S)
	return self
end

function World:destroy()
	self.folder:Destroy()
end

--- 表示を Match の現在の状態に合わせる。
function World:step(dt)
	local match = self.match
	local human = match:human(0)
	local b = match.ball
	local defending = human and (b.owner == nil or b.owner.team ~= 0)
	local nxt = defending and match:nextCursor() or nil
	local labelFor = {}
	for _, lb in match.labels do
		labelFor[lb.player] = lb
	end

	for pl, a in self.actors do
		local pos = toWorld(pl.p.x, pl.p.y, 1.4)
		a.body.Position = pos
		local fwd = Vector3.new(pl.face.x, 0, pl.face.y)
		local nosePos = pos + fwd * 1.7 + Vector3.new(0, 0.3, 0)
		a.nose.CFrame = CFrame.lookAt(nosePos, nosePos + fwd)
		a.shadow.CFrame = CFrame.new(toWorld(pl.p.x, pl.p.y, 0.08)) * CFrame.Angles(0, 0, math.rad(90))
		if pl.slide > 0 then
			a.body.Color = Color3.new(1, 1, 1)
		elseif pl.stun > 0 then
			a.body.Color = a.baseColor:Lerp(Color3.new(1, 1, 1), 0.5)
		else
			a.body.Color = a.baseColor
		end
		a.cursor.Enabled = human and pl == match.ctrl
		a.nextMark.Enabled = pl == nxt and pl ~= match.ctrl
		local lb = labelFor[pl]
		if lb ~= nil then
			a.skillLabel.Text = Locale.t(self.lang, lb.key)
			a.skill.Enabled = true
		else
			a.skill.Enabled = false
		end
	end

	-- ボール (高さは見た目を少し強調)
	local bz = 0.9 + b.z * S * 0.8
	self.ball.Position = toWorld(b.p.x, b.p.y, bz)
	self.ballShadow.CFrame = CFrame.new(toWorld(b.p.x, b.p.y, 0.1)) * CFrame.Angles(0, 0, math.rad(90))
end

--- ボールを追うカメラ。画面に約 HalfWidth*2 [m] を映し、コート外を映しすぎないよう範囲を制限する。
function World:updateCamera(dt)
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	local V = Config.View
	local b = self.match.ball.p
	local limX = math.max(0, PL / 2 + 4 - V.HalfWidth)
	local limY = math.max(0, PW / 2 + 4 - V.HalfHeight)
	local target = Vector3.new(math.clamp(b.x, -limX, limX) * S, 0, math.clamp(b.y, -limY, limY) * S)
	local k = math.min(1, dt * V.CameraFollow)
	self.focus = self.focus:Lerp(target, k)

	-- 横幅が HalfWidth*2 [m] ちょうど入る距離 (縦長画面でも切れない)
	local vp = cam.ViewportSize
	local aspect = vp.X / math.max(vp.Y, 1)
	cam.FieldOfView = 50
	local hFov = 2 * math.atan(math.tan(math.rad(cam.FieldOfView / 2)) * aspect)
	local dist = (V.HalfWidth * S) / math.tan(hFov / 2)
	local dir = Vector3.new(V.CameraDir[1], V.CameraDir[2], V.CameraDir[3]).Unit
	cam.CFrame = CFrame.lookAt(self.focus + dir * dist, self.focus)
end

return World
