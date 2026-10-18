--!nonstrict
--[[
	Rig — 角ばった人型の選手 (胴・頭・腕・脚)。外部のモデルやアニメーション素材を使わず、
	毎フレーム姿勢を計算で作る。

	Rig.new(parent, colors) -> rig
	Rig.pose(rig, state, dt, outParts, outCFrames)   姿勢を計算して配列に足す (World がまとめて動かす)
	  state: {
	    pos = Vector3 (足元), face = Vector3 (向き), speed (studs/s),
	    action = { kind, age } | nil   キック・トラップ等 (kind は Rig.DURATION のキー)
	    skill = { name, u } | nil      足技 (u = 0..1 の進み具合)
	    slide, dive (-1/0/1), stun, hidden
	  }

	角度の向き: 脚・腕の x = 前へ振る (+)、z = 外へ開く (右脚は +、左脚は -)、y = つま先を外へ向ける。
	体: pitch = 前傾 (+)、roll = 右へ傾く (+)、lift = 浮く高さ、spin = その場で回る角度。
]]

local Rig = {}

local U = 0.7 -- 1 ブロックの大きさ [studs]。背の高さは約 5.2U = 3.64 studs (≒ 1.82m)
local LEG_H, LEG_W = 2 * U, 1 * U
local TORSO_H, TORSO_W, TORSO_D = 2 * U, 2 * U, 1 * U
local ARM_H, ARM_W = 2 * U, 1 * U
local HEAD = 1.2 * U
local HIP_H = LEG_H

local SKIN = {
	Color3.fromRGB(255, 220, 177),
	Color3.fromRGB(234, 192, 134),
	Color3.fromRGB(198, 134, 66),
	Color3.fromRGB(141, 85, 36),
	Color3.fromRGB(94, 61, 35),
}

-- 動作の長さ [s]
Rig.DURATION = {
	pass = 0.32,
	through = 0.32,
	lofted = 0.42,
	shot = 0.42,
	loop = 0.38,
	header = 0.45,
	throw = 0.5,
	save = 0.35,
	trap = 0.22,
	charge = 0.3,
	steal = 0.28,
}

local function part(parent, name, size, color)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--[[
	colors: { shirt = Color3, shorts = Color3, skin = index (1..5) }
]]
function Rig.new(parent, colors)
	local model = Instance.new("Model")
	model.Name = "Player"
	model.Parent = parent
	local skin = SKIN[((colors.skin or 1) - 1) % #SKIN + 1]
	local rig = {
		model = model,
		torso = part(model, "Torso", Vector3.new(TORSO_W, TORSO_H, TORSO_D), colors.shirt),
		head = part(model, "Head", Vector3.new(HEAD, HEAD, HEAD), skin),
		armL = part(model, "LeftArm", Vector3.new(ARM_W, ARM_H, ARM_W), colors.shirt),
		armR = part(model, "RightArm", Vector3.new(ARM_W, ARM_H, ARM_W), colors.shirt),
		legL = part(model, "LeftLeg", Vector3.new(LEG_W, LEG_H, LEG_W), colors.shorts),
		legR = part(model, "RightLeg", Vector3.new(LEG_W, LEG_H, LEG_W), colors.shorts),
		phase = 0,
	}
	rig.parts = { rig.torso, rig.head, rig.armL, rig.armR, rig.legL, rig.legR }
	return rig
end

function Rig.setColors(rig, shirt, shorts)
	if rig.shirt ~= shirt then
		rig.shirt = shirt
		rig.torso.Color = shirt
		rig.armL.Color = shirt
		rig.armR.Color = shirt
	end
	if rig.shorts ~= shorts then
		rig.shorts = shorts
		rig.legL.Color = shorts
		rig.legR.Color = shorts
	end
end

local HIDDEN = CFrame.new(0, -500, 0)

local function clamp01(x)
	return math.clamp(x, 0, 1)
end

-- 0..1 の山 (0 で 0、0.5 で 1、1 で 0)
local function bump(u)
	return math.sin(clamp01(u) * math.pi)
end

-- 振りかぶって (0..back まで後ろへ) から、前へ振り抜く (forward まで)
local function swingCurve(u, back, forward, split)
	split = split or 0.35
	if u < split then
		return -back * math.sin((u / split) * math.pi * 0.5)
	end
	local v = (u - split) / (1 - split)
	return -back + (back + forward) * math.sin(math.min(v * 1.3, 1) * math.pi * 0.5)
end

--- キック・トラップ等の動き。pose を書き換える。
local function applyAction(pose, kind, u)
	if kind == "pass" or kind == "through" then
		-- インサイドで押し出す: つま先を外へ向けて、前へ振る
		pose.R.x = swingCurve(u, 0.5, kind == "through" and 1.2 or 0.9)
		pose.R.y = kind == "through" and 0.3 or 0.65
		pose.R.z = -0.12
		pose.L.x = -0.1
		pose.pitch = kind == "through" and 0.16 or 0.08
		pose.AL.z, pose.AR.z = -0.45, 0.3
		pose.AL.x, pose.AR.x = 0.2, -0.2
	elseif kind == "lofted" then
		-- 浮き球・クロス・クリア: 大きく振って、のけぞる
		pose.R.x = swingCurve(u, 0.95, 1.65)
		pose.L.x = -0.15
		pose.pitch = -0.14 * bump(u)
		pose.AL.z, pose.AR.z = -0.85, 0.6
		pose.AL.x = 0.35
	elseif kind == "shot" then
		-- シュート: 深く振りかぶって、ボールに被さる。蹴った後は軽く跳ねる
		pose.R.x = swingCurve(u, 1.15, 1.95)
		pose.L.x = -0.2
		pose.pitch = 0.2
		pose.AL.x, pose.AL.z = 0.6, -0.75
		pose.AR.x = -0.45
		pose.lift = u > 0.6 and 0.2 * bump((u - 0.6) / 0.4) or 0
	elseif kind == "loop" then
		-- ループ: すくい上げる。振り抜きは短く、のけぞる
		pose.R.x = swingCurve(u, 0.7, 1.0)
		pose.R.y = 0.2
		pose.pitch = -0.18 * bump(u)
		pose.AL.z, pose.AR.z = -0.6, 0.45
	elseif kind == "header" then
		-- ヘディング: 跳んで、頭を前へ振る
		local b = bump(u)
		pose.lift = 1.3 * b
		pose.pitch = 0.55 * math.sin(clamp01(u * 1.2) * math.pi)
		pose.L.x, pose.R.x = -0.45 * b, -0.25 * b
		pose.AL.z, pose.AR.z = -0.9 * b, 0.9 * b
		pose.AL.x, pose.AR.x = 0.3, 0.3
	elseif kind == "throw" then
		-- スローイン: 両手を頭の後ろから前へ
		local e = math.sin(clamp01(u * 1.2) * math.pi * 0.5)
		local a = math.pi + 0.35 - (math.pi * 0.55 + 0.35) * e
		pose.AL.x, pose.AR.x = a, a
		pose.pitch = -0.25 + 0.4 * e
		pose.L.x, pose.R.x = 0.3, -0.3
	elseif kind == "save" then
		-- キーパーのキャッチ: 両手を前へ出して胸に抱える
		local b = bump(u)
		pose.AL.x, pose.AR.x = 1.9 * b + 0.3, 1.9 * b + 0.3
		pose.AL.z, pose.AR.z = 0.25 * b, -0.25 * b
		pose.pitch = 0.2 * b
		pose.lift = 0.3 * b
	elseif kind == "trap" then
		-- トラップ: 足を少し上げて止める
		pose.R.x = 0.5 * bump(u)
		pose.R.y = 0.4
		pose.pitch = 0.08
	elseif kind == "charge" then
		-- ショルダーチャージ: 肩から当たる
		local b = bump(u)
		pose.roll = -0.4 * b
		pose.side = -0.5 * b
		pose.AL.z = -0.1
		pose.AR.x = -0.3
	elseif kind == "steal" then
		-- 立ったまま足を出して奪う
		pose.R.x = 1.15 * bump(u)
		pose.R.y = 0.45
		pose.pitch = 0.22 * bump(u)
		pose.AL.z, pose.AR.z = -0.5, 0.5
	end
end

--- 足技の動き。u = 0..1
local function applySkill(pose, name, u)
	if name == "double_touch" then
		-- 横へ 1 タッチ → 斜め前へもう 1 タッチ
		pose.R.z = 0.6 * bump(u / 0.45)
		pose.R.x = 0.25 * bump(u / 0.45) + 0.85 * bump((u - 0.45) / 0.55)
		pose.roll = 0.18 * bump(u)
		pose.AL.z = -0.5
	elseif name == "elastico" then
		-- 足の外側で外へ持ち出し、内側へ素早く切り返す
		if u < 0.35 then
			pose.R.z = 0.75 * (u / 0.35)
			pose.roll = 0.15 * (u / 0.35)
		else
			local v = (u - 0.35) / 0.65
			pose.R.z = 0.75 - 1.35 * math.min(v * 1.6, 1)
			pose.roll = 0.15 - 0.35 * math.min(v * 1.6, 1)
		end
		pose.R.x = 0.3
		pose.AL.z, pose.AR.z = -0.6, 0.4
	elseif name == "scissors" then
		-- ボールをまたぐ: 右脚をボールの上で外から内へ回し、体を沈めて逆へ振る
		local b = bump(u / 0.6)
		pose.R.x = 0.55 * b
		pose.R.y = -1.2 * b
		pose.R.z = 0.35 * b
		pose.roll = -0.28 * b
		pose.lift = -0.2 * b
		pose.AL.z, pose.AR.z = -0.7 * b, 0.5 * b
	elseif name == "marseille" then
		-- マルセイユルーレット: 足裏でボールを引きながら、体ごと 1 回転
		pose.spin = -2 * math.pi * u
		pose.L.x = 0.45 * math.sin(2 * math.pi * u)
		pose.R.x = -pose.L.x
		pose.AL.z, pose.AR.z = -0.7, 0.7
		pose.pitch = 0.1
	else -- drag_back
		-- ドラッグバック: 足裏で前から後ろへ引く
		pose.R.x = 0.75 - 1.3 * clamp01(u)
		pose.R.y = 0.1
		pose.pitch = -0.15 * bump(u)
		pose.AL.z, pose.AR.z = -0.5, 0.5
	end
end

--- 姿勢を計算して、outParts / outCFrames に足す。
function Rig.pose(rig, st, dt, outParts, outCFrames)
	local function put(p, cf)
		table.insert(outParts, p)
		table.insert(outCFrames, cf)
	end
	if st.hidden then
		for _, p in rig.parts do
			put(p, HIDDEN)
		end
		return
	end
	local face = st.face
	if face.Magnitude < 1e-3 then
		face = Vector3.new(0, 0, -1)
	end
	local root = CFrame.lookAt(st.pos, st.pos + face)
	local speed = st.speed or 0
	-- 走り: 歩幅のリズム (速いほど速く、大きく振る)
	rig.phase = (rig.phase + speed * dt * 0.95) % (2 * math.pi)
	local amp = math.clamp(speed / 14, 0, 1) * 0.95
	local swing = math.sin(rig.phase) * amp
	local pose = {
		L = { x = swing, y = 0, z = 0 },
		R = { x = -swing, y = 0, z = 0 },
		AL = { x = -swing * 0.9, y = 0, z = 0 },
		AR = { x = swing * 0.9, y = 0, z = 0 },
		pitch = math.clamp(speed * 0.018, 0, 0.28),
		roll = 0,
		lift = 0,
		spin = 0,
		side = 0,
	}
	local hip
	if st.slide then
		-- スライディング: 後ろに倒れて、脚を前へ伸ばす
		hip = root * CFrame.new(0, 0.55, 0) * CFrame.Angles(1.15, 0, 0)
		pose.L.x, pose.R.x = 1.45, 1.25
		pose.AL.x, pose.AR.x = -0.6, -0.6
		pose.AL.z, pose.AR.z = -0.6, 0.6
	elseif st.dive and st.dive ~= 0 then
		-- キーパーのダイブ: 横へ倒れ込み、両腕を伸ばす
		local side = st.dive
		hip = root * CFrame.new(side * 0.9, 1.0, 0) * CFrame.Angles(0, 0, -side * 1.35)
		pose.L.x, pose.R.x = 0.1, -0.1
		pose.AL.x, pose.AR.x = math.pi, math.pi
	else
		local action = st.action
		if st.skill ~= nil then
			applySkill(pose, st.skill.name, clamp01(st.skill.u))
		elseif action ~= nil and Rig.DURATION[action.kind] and action.age < Rig.DURATION[action.kind] then
			applyAction(pose, action.kind, action.age / Rig.DURATION[action.kind])
		elseif st.stun then
			-- よろけ: 少し後ろへ反って腕を広げる
			pose.pitch = -0.25
			pose.roll = math.sin(rig.phase * 3) * 0.12
			pose.AL.z, pose.AR.z = -0.9, 0.9
		end
		hip = root
			* CFrame.Angles(0, pose.spin, 0)
			* CFrame.new(pose.side, HIP_H + pose.lift, 0)
			* CFrame.Angles(-pose.pitch, 0, -pose.roll)
	end
	local halfW = TORSO_W / 2
	local L, R, AL, AR = pose.L, pose.R, pose.AL, pose.AR
	put(rig.torso, hip * CFrame.new(0, TORSO_H / 2, 0))
	put(rig.head, hip * CFrame.new(0, TORSO_H + HEAD / 2 + 0.05, 0))
	-- 脚: 付け根 (腰) を軸に。左脚の「外へ開く」は -z
	put(rig.legL, hip * CFrame.new(-LEG_W / 2, 0, 0) * CFrame.Angles(L.x, -L.y, -L.z) * CFrame.new(0, -LEG_H / 2, 0))
	put(rig.legR, hip * CFrame.new(LEG_W / 2, 0, 0) * CFrame.Angles(R.x, R.y, R.z) * CFrame.new(0, -LEG_H / 2, 0))
	-- 腕: 肩を軸に
	put(rig.armL, hip * CFrame.new(-halfW - ARM_W / 2, TORSO_H, 0) * CFrame.Angles(AL.x, AL.y, AL.z) * CFrame.new(0, -ARM_H / 2, 0))
	put(rig.armR, hip * CFrame.new(halfW + ARM_W / 2, TORSO_H, 0) * CFrame.Angles(AR.x, AR.y, AR.z) * CFrame.new(0, -ARM_H / 2, 0))
end

Rig.HEIGHT = HIP_H + TORSO_H + HEAD
Rig.SKINS = #SKIN

return Rig
