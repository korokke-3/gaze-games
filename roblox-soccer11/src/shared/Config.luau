--!strict
--[[
	Config — 試合の数値をすべてここに集約する。バランス調整でロジックを触る必要はない。
	距離は m、時間は秒。コートの x が攻撃方向 (HOME は +x へ攻める)、y が横方向。
]]

local Config = {}

Config.MatchTime = 300 -- 1 試合 (前後半の合計) の既定の長さ [s]
Config.MatchLengths = { 180, 300, 600 } -- 選べる試合時間 [s]
Config.ExtraTime = 60 -- 延長戦 1 本の長さ [s] (カップ戦で同点の時、2 本)
Config.HalfTimeBreak = 3.0 -- ハーフタイムの表示時間 [s]
Config.ShootoutRounds = 5 -- PK 戦の本数 (以降はサドンデス)

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

-- フォーメーション (HOME が +x へ攻める時の基準位置 [m])。順番は選手 index (0 = GK)。
Config.Formations = {
	["433"] = Config.Formation,
	["442"] = {
		{ x = -50, y = 0, role = "GK", num = 1 },
		{ x = -34, y = -22, role = "LB", num = 3 },
		{ x = -37, y = -8, role = "CB", num = 4 },
		{ x = -37, y = 8, role = "CB", num = 5 },
		{ x = -34, y = 22, role = "RB", num = 2 },
		{ x = -18, y = -24, role = "LM", num = 11 },
		{ x = -20, y = -8, role = "CM", num = 8 },
		{ x = -20, y = 8, role = "CM", num = 6 },
		{ x = -18, y = 24, role = "RM", num = 7 },
		{ x = -4, y = -7, role = "ST", num = 9 },
		{ x = -4, y = 7, role = "ST", num = 10 },
	},
	["4231"] = {
		{ x = -50, y = 0, role = "GK", num = 1 },
		{ x = -34, y = -22, role = "LB", num = 3 },
		{ x = -37, y = -8, role = "CB", num = 4 },
		{ x = -37, y = 8, role = "CB", num = 5 },
		{ x = -34, y = 22, role = "RB", num = 2 },
		{ x = -26, y = -8, role = "DM", num = 6 },
		{ x = -26, y = 8, role = "DM", num = 8 },
		{ x = -12, y = -24, role = "LW", num = 11 },
		{ x = -12, y = 0, role = "CAM", num = 10 },
		{ x = -12, y = 24, role = "RW", num = 7 },
		{ x = -3, y = 0, role = "ST", num = 9 },
	},
	["352"] = {
		{ x = -50, y = 0, role = "GK", num = 1 },
		{ x = -38, y = -12, role = "CB", num = 4 },
		{ x = -38, y = 0, role = "CB", num = 5 },
		{ x = -38, y = 12, role = "CB", num = 3 },
		{ x = -24, y = -28, role = "LWB", num = 11 },
		{ x = -18, y = -10, role = "CM", num = 8 },
		{ x = -24, y = 0, role = "DM", num = 6 },
		{ x = -18, y = 10, role = "CM", num = 10 },
		{ x = -24, y = 28, role = "RWB", num = 7 },
		{ x = -4, y = -7, role = "ST", num = 9 },
		{ x = -4, y = 7, role = "ST", num = 19 },
	},
}
Config.FormationOrder = { "433", "442", "4231", "352" }
Config.ForwardRoles = { LW = true, RW = true, ST = true, CF = true }

-- 戦術: ライン (前へ +, 後ろへ -) とプレスの強さ。全体の押し上げ [m] と寄せの距離に効く。
Config.Tactics = {
	Line = { -6, 0, 6 }, -- 低い / 標準 / 高い
	Press = { 0.7, 1.0, 1.3 }, -- 弱い / 標準 / 強い (CPU が寄せる強さ)
}

-- 難易度。CPU の 速さ / 判断の遅さ / シュートのぶれ / 奪取率 / GK が正しい側へ跳ぶ確率。
Config.Difficulties = {
	{ key = "beginner", aiSpeed = 0.88, aiDecide = 1.6, aiShotErr = 1.6, aiTackle = 0.6, gkReact = 0.25 },
	{ key = "amateur", aiSpeed = 0.94, aiDecide = 1.25, aiShotErr = 1.3, aiTackle = 0.8, gkReact = 0.35 },
	{ key = "regular", aiSpeed = 1.0, aiDecide = 1.0, aiShotErr = 1.0, aiTackle = 1.0, gkReact = 0.45 },
	{ key = "pro", aiSpeed = 1.05, aiDecide = 0.85, aiShotErr = 0.8, aiTackle = 1.15, gkReact = 0.58 },
	{ key = "superstar", aiSpeed = 1.1, aiDecide = 0.7, aiShotErr = 0.6, aiTackle = 1.3, gkReact = 0.7 },
}
Config.DefaultDifficulty = 3

-- 選手能力 (ポジション別の基準。個体差は ±6%)。足の速さ / シュート / パス / 守備 / スタミナ
Config.Attributes = {
	GK = { speed = 0.85, shoot = 0.6, pass = 0.8, tackle = 1.0, stamina = 1.0 },
	CB = { speed = 0.93, shoot = 0.8, pass = 0.9, tackle = 1.1, stamina = 1.0 },
	LB = { speed = 1.0, shoot = 0.85, pass = 0.95, tackle = 1.0, stamina = 1.05 },
	RB = { speed = 1.0, shoot = 0.85, pass = 0.95, tackle = 1.0, stamina = 1.05 },
	LWB = { speed = 1.0, shoot = 0.85, pass = 0.95, tackle = 1.0, stamina = 1.1 },
	RWB = { speed = 1.0, shoot = 0.85, pass = 0.95, tackle = 1.0, stamina = 1.1 },
	DM = { speed = 0.97, shoot = 0.9, pass = 1.05, tackle = 1.1, stamina = 1.0 },
	CM = { speed = 1.0, shoot = 1.0, pass = 1.05, tackle = 0.95, stamina = 1.0 },
	LM = { speed = 1.02, shoot = 0.95, pass = 1.0, tackle = 0.9, stamina = 1.0 },
	RM = { speed = 1.02, shoot = 0.95, pass = 1.0, tackle = 0.9, stamina = 1.0 },
	CAM = { speed = 1.0, shoot = 1.05, pass = 1.1, tackle = 0.9, stamina = 1.0 },
	LW = { speed = 1.05, shoot = 1.0, pass = 0.95, tackle = 0.85, stamina = 1.0 },
	RW = { speed = 1.05, shoot = 1.0, pass = 0.95, tackle = 0.85, stamina = 1.0 },
	ST = { speed = 1.03, shoot = 1.12, pass = 0.9, tackle = 0.8, stamina = 1.0 },
}
Config.AttributeSpread = 0.06

-- スタミナ。ダッシュで消耗し、尽きると速度が落ちる (最低 MinFactor 倍)。
Config.Stamina = {
	Max = 100,
	DashDrain = 12, -- ダッシュ中 [/s]
	RunDrain = 2, -- 通常の走り [/s]
	Regen = 9, -- ほぼ止まっている時 [/s]
	MinFactor = 0.78,
	DashMin = 12, -- これ未満ではダッシュできない
	HalfTimeRecover = 35, -- ハーフタイムでの回復
}

-- カード。悪質なスライディングで出る。2 枚目のイエローで退場。
Config.Cards = {
	YellowChance = 0.45, -- 背後・足への接触 (ファウル) 1 回あたり
	RedChance = 0.08, -- 一発退場
}

-- キーパーのダイブ (セーブ)。飛ぶ速さ [m/s] と反応までの時間 [s]
Config.Keeper = { DiveSpeed = 9.0, Reaction = 0.18 }

-- ヘディング・ボレー: 届く高さ [m] と、ゴールに向けて打てる距離 [m]
Config.Header = { MinZ = 0.9, MaxZ = 2.6, Reach = 1.7, ShotRange = 20, CpuChance = 0.45 }

-- ゴールリプレイ。直前の秒数と再生速度
Config.Replay = { Seconds = 6, Speed = 0.8, Step = 0.05 }

-- 操作 (eFootball に合わせた入力の扱い)
Config.Controls = {
	DeadZone = 0.15, -- これ未満のスティック入力は無視
	AutopilotDelay = 0.6, -- 操作中の選手に入力が無い時、この秒数で AI が補助を始める
	GaugeTime = 1.0, -- パワーゲージが満タンになるまで [s]
	DefaultAssist = 1, -- パスの補助 0: マニュアル / 1: 標準 / 2: フル
	AssistCone = { 0, 35, 60 }, -- 補助ごとの、受け手を探す角度 [度]
	AssistPowerWeight = { 1, 0.5, 0 }, -- 補助ごとの、パワーゲージが距離に効く割合
	PenaltyPower = 0.8, -- PK のパワー (固定)
	SetpieceAutoTake = 8, -- 人間のセットプレーを放置した時、代わりに蹴るまで [s]
	PointSnap = 6, -- マウスで指した地点から、この距離 [m] 内の味方を受け手にする
	ThroughReach = 30, -- スペースへのスルーで、受け手 (走り込む味方) を探す距離 [m]
	ZoomRange = { 26, 56 }, -- マウスホイールのズーム (画面の横幅の半分に映す距離 [m])
	SkillWindow = 0.32, -- 右スティック (WASD の 2 回押し) を弾いてから、技を確定するまで [s]。この間に次を弾くとコンビネーション
}

-- オンライン (協力 / 対戦)。試合はサーバーで動かす
Config.Online = {
	TickRate = 30, -- サーバーの試合の更新 [回/秒]
	SnapshotRate = 15, -- クライアントへの送信 [回/秒]
	InputRate = 20, -- クライアントからの入力の送信 [回/秒] (ボタンの変化は即時)
	InterpDelay = 0.1, -- クライアントの補間の遅れ [s]
	MaxPerTeam = 3, -- 1 チームの人数 (eFootball の協力と同じ 3 人まで)
	MaxRooms = 20,
	MaxInputsPerSecond = 80,
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

-- 報酬 (コイン)。サーバーが試合の結果から計算する。クライアントの申告は上限で丸める。
Config.Rewards = {
	Base = 30,
	Win = 25,
	Draw = 10,
	PerGoal = 6,
	MaxGoalsCounted = 5,
	CleanSheet = 12,
	ShootoutWin = 10,
	DifficultyBonus = { 0.8, 0.9, 1.0, 1.15, 1.3 }, -- 難易度ごとの倍率
	LengthBonus = { [180] = 0.7, [300] = 1.0, [600] = 1.6 },
	Max = 200, -- 1 試合の上限 (VIP 倍率の前)
	MinElapsedRatio = 0.8, -- 実時間で試合時間のこの割合以上が経っていないと報酬なし (ソロ・オンライン共通)
}

-- キット (自チームの色)。コインで解放する。勝敗には影響しない。
Config.Kits = {
	{ id = "classic", price = 0, color = { 35, 110, 215 }, keeper = { 230, 200, 40 } },
	{ id = "crimson", price = 300, color = { 200, 40, 60 }, keeper = { 240, 240, 240 } },
	{ id = "emerald", price = 400, color = { 30, 160, 90 }, keeper = { 250, 170, 40 } },
	{ id = "midnight", price = 600, color = { 40, 50, 110 }, keeper = { 90, 220, 255 } },
	{ id = "sunset", price = 800, color = { 240, 120, 50 }, keeper = { 60, 60, 70 } },
	{ id = "gold", price = 0, vip = true, color = { 230, 180, 40 }, keeper = { 30, 30, 30 } },
}

-- ボール (色と軌跡)。
Config.Balls = {
	{ id = "classic", price = 0, color = { 255, 255, 255 } },
	{ id = "fire", price = 500, color = { 255, 140, 40 }, trail = { 255, 90, 20 } },
	{ id = "ice", price = 500, color = { 150, 220, 255 }, trail = { 120, 200, 255 } },
	{ id = "gold", price = 0, vip = true, color = { 255, 215, 70 }, trail = { 255, 200, 40 } },
}

-- 課金。ID は Experience (Universe 10771015719) に作成した値。0 にすると購入ボタンが無効になる。
Config.Monetization = {
	Passes = {
		VIP = { id = 2037158593, price = 399 }, -- コイン 2 倍・ゴールドのキットとボール
		AllKits = { id = 2037608600, price = 199 }, -- 全キット・全ボールを解放
	},
	Products = {
		Coins500 = { id = 3718731061, coins = 500, price = 49 },
		Coins2000 = { id = 3718731068, coins = 2000, price = 149 },
		Coins10000 = { id = 3718731072, coins = 10000, price = 499 },
	},
	VipCoinMultiplier = 2,
}

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
	-- カメラのプリセット。画面の横幅の半分に映す距離 [m]
	CameraPresets = { 52, 41, 30 }, -- ワイド / ノーマル / ズーム
	Night = { ClockTime = 21, Brightness = 2.6 },
	Day = { ClockTime = 14, Brightness = 2 },
}

return Config
