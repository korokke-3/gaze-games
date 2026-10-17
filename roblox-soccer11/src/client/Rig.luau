--!nonstrict
--[[
	Rig — 角ばった人型の選手 (胴・頭・腕・脚)。外部のモデルやアニメーション素材を使わず、
	毎フレーム、走り・キック・スライディング・キーパーのダイブ・よろけの姿勢を計算で作る。

	Rig.new(parent, colors) -> rig
	Rig.pose(rig, state, dt, outParts, outCFrames)   姿勢を計算して配列に足す (World がまとめて動かす)
	  state: { pos = Vector3 (足元), face = Vector3 (向き), speed (studs/s),
	           kickAge (蹴ってからの秒数 or nil), slide, dive (-1/0/1), stun, hidden }
]]

local Rig = {}

local U = 0.8 -- 1 ブロックの大きさ [studs]。背の高さは約 5.3U = 4.2 studs (≒ 2.1m)
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
	-- 歩幅のリズム (速いほど速く、大きく振る)
	rig.phase = (rig.phase + speed * dt * 0.95) % (2 * math.pi)
	local amp = math.clamp(speed / 14, 0, 1) * 0.95
	local swing = math.sin(rig.phase) * amp
	local lean = math.clamp(speed * 0.018, 0, 0.28)

	local hip
	local legL, legR, armL, armR = swing, -swing, -swing * 0.9, swing * 0.9
	local armSpreadL, armSpreadR = 0, 0
	if st.slide then
		-- スライディング: 後ろに倒れて、脚を前へ伸ばす
		hip = root * CFrame.new(0, 0.55, 0) * CFrame.Angles(1.15, 0, 0)
		legL, legR = 1.45, 1.25
		armL, armR = -0.6, -0.6
		armSpreadL, armSpreadR = 0.6, -0.6
	elseif st.dive and st.dive ~= 0 then
		-- キーパーのダイブ: 横へ倒れ込み、両腕を伸ばす
		local side = st.dive
		hip = root * CFrame.new(side * 0.9, 1.0, 0) * CFrame.Angles(0, 0, -side * 1.35)
		legL, legR = 0.1, -0.1
		armL, armR = math.pi, math.pi
		armSpreadL, armSpreadR = 0, 0
	else
		hip = root * CFrame.new(0, HIP_H, 0) * CFrame.Angles(-lean, 0, 0)
		if st.kickAge ~= nil and st.kickAge < 0.35 then
			-- キック: 右脚を後ろへ引いてから前へ振り抜く
			local u = st.kickAge / 0.35
			legR = -0.7 + 2.2 * math.sin(u * math.pi * 0.5)
			legL = -0.15
			armL, armR = 0.5, -0.4
			armSpreadL, armSpreadR = 0.5, -0.5
		elseif st.stun then
			-- よろけ: 少し後ろへ反って腕を広げる
			hip = root * CFrame.new(0, HIP_H, 0) * CFrame.Angles(0.25, 0, math.sin(rig.phase * 3) * 0.12)
			armSpreadL, armSpreadR = 0.9, -0.9
		end
	end
	local halfW = TORSO_W / 2
	put(rig.torso, hip * CFrame.new(0, TORSO_H / 2, 0))
	put(rig.head, hip * CFrame.new(0, TORSO_H + HEAD / 2 + 0.05, 0))
	-- 脚: 付け根 (腰) を軸に振る
	put(rig.legL, hip * CFrame.new(-LEG_W / 2, 0, 0) * CFrame.Angles(legL, 0, 0) * CFrame.new(0, -LEG_H / 2, 0))
	put(rig.legR, hip * CFrame.new(LEG_W / 2, 0, 0) * CFrame.Angles(legR, 0, 0) * CFrame.new(0, -LEG_H / 2, 0))
	-- 腕: 肩を軸に振る (脚と逆)
	put(
		rig.armL,
		hip * CFrame.new(-halfW - ARM_W / 2, TORSO_H, 0) * CFrame.Angles(armL, 0, armSpreadL) * CFrame.new(0, -ARM_H / 2, 0)
	)
	put(
		rig.armR,
		hip * CFrame.new(halfW + ARM_W / 2, TORSO_H, 0) * CFrame.Angles(armR, 0, armSpreadR) * CFrame.new(0, -ARM_H / 2, 0)
	)
end

Rig.HEIGHT = HIP_H + TORSO_H + HEAD
Rig.SKINS = #SKIN

return Rig
