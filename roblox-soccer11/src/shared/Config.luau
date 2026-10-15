--!strict
--[[
	Config — 試合の数値をすべてここに集約する。バランス調整でロジックを触る必要はない。
	距離は m、時間は秒。コートの x が攻撃方向 (HOME は +x へ攻める)、y が横方向。
]]

local Config = {}

Config.MatchTime = 300 -- 1 試合の長さ [s]

Config.Pitch = {
	Length = 105.0,
	Width = 68.0,
	GoalWidth = 7.32,
	GoalHeight = 2.44,
	BoxLength = 16.5, -- ペナルティエリア
	BoxWidth = 40.3,
	SixLength = 5.5, -- ゴールエリア
	SixWidth = 18.3,
	PenaltySpot = 11.0,
}

Config.Player = {
	Radius = 0.6,
	ControlRadius = 1.1, -- この距離内でボールを受けられる
	Speed = 6.5,
	Dash = 8.6,
	Dribble = 0.88, -- ボールを持つと速度に掛かる
	AccAI = 14.0, -- 加速度の上限 [m/s^2] (急に止まったり向きを変えたりしない)
	AccHuman = 28.0,
	DecideEvery = 0.3, -- CPU のボール保持者が判断する間隔 [s]
}

Config.Physics = {
	Friction = 4.0,
	Gravity = 9.8,
}

-- 4-3-3 (HOME が +x 方向へ攻める時の基準位置 [m]) と役割。順番は選手 index (0 = GK)。
Config.Formation = {
	{ x = -50, y = 0, role = "GK", num = 1 },
	{ x = -34, y = -22, role = "LB", num = 3 },
	{ x = -37, y = -8, role = "CB", num = 4 },
	{ x = -37, y = 8, role = "CB", num = 5 },
	{ x = -34, y = 22, role = "RB", num = 2 },
	{ x = -24, y = 0, role = "DM", num = 6 },
	{ x = -16, y = -12, role = "CM", num = 8 },
	{ x = -16, y = 12, role = "CM", num = 10 },
	{ x = -4, y = -24, role = "LW", num = 11 },
	{ x = -3, y = 0, role = "ST", num = 9 },
	{ x = -4, y = 24, role = "RW", num = 7 },
}

-- キー割り当て (スマホ版バーチャルパッドのボタン構成をキーボードに写したもの)
Config.Keys = {
	pass = "K",
	through = "I",
	shoot = "J",
	cursor = "U",
	slide = "L",
	left_tap = "Q",
}

-- 技のコマンド (ダッシュをタップしてから WASD を弾く)。向きは「進行方向を前」とした相対方向:
--   F 前, B 後ろ, S 横 (左右どちらか), X 最初の S と逆の横。上から順に照合する。
Config.SkillCommands = {
	{ seq = { "F", "B", "S" }, name = "marseille" },
	{ seq = { "B", "S", "F" }, name = "marseille" },
	{ seq = { "S", "B", "X" }, name = "marseille" },
	{ seq = { "S", "X" }, name = "elastico" },
	{ seq = { "F", "S" }, name = "scissors" },
	{ seq = { "S" }, name = "double_touch" },
	{ seq = { "B" }, name = "drag_back" },
}
Config.SkillDuration = { double_touch = 0.45, elastico = 0.5, scissors = 0.55, marseille = 0.65, drag_back = 0.4 }
Config.SkillBase = { double_touch = 0.6, elastico = 0.65, scissors = 0.5, marseille = 0.55, drag_back = 0.45 }

-- 見た目 (Roblox 側の表示だけに使う。試合ロジックは参照しない)
Config.View = {
	Studs = 2, -- 1m = 2 studs
	HalfWidth = 41, -- 画面の横幅の半分に映す距離 [m] (横長の元版は約 82m 分)
	HalfHeight = 24, -- カメラが追従する範囲の縦方向の余裕 [m]
	CameraDir = { 0, 0.86, 0.5 }, -- 注視点からカメラへの向き (真上から少しだけ手前に傾ける)
	CameraFollow = 4.0, -- 追従の速さ (大きいほど速い)
	HomeColor = { 35, 110, 215 },
	AwayColor = { 205, 45, 45 },
	HomeKeeperColor = { 230, 200, 40 },
	AwayKeeperColor = { 160, 60, 160 },
}

return Config
