--!strict
--[[
	Rewards — 試合の結果から獲得コインを計算する (純粋関数。Studio 無しで検証できる)。
	サーバーが、クライアントの申告を丸めたうえで呼ぶ。
]]

local Config = require(script.Parent.Config)

local Rewards = {}

local R = Config.Rewards

local function toInt(v: any, lo: number, hi: number): number
	if typeof(v) ~= "number" or v ~= v then
		return lo
	end
	return math.clamp(math.floor(v), lo, hi)
end

--- クライアントから届いた結果を、安全な形に丸める。
function Rewards.sanitize(raw: any): { home: number, away: number, winner: number?, shootoutWin: boolean }
	local t: any = if typeof(raw) == "table" then raw else {}
	local winner = nil
	if t.winner == 0 or t.winner == 1 then
		winner = t.winner
	end
	return {
		home = toInt(t.home, 0, 30),
		away = toInt(t.away, 0, 30),
		winner = winner,
		shootoutWin = t.shootoutWin == true,
	}
end

--- 選べる試合時間か (サーバーが検証に使う)。
function Rewards.isValidLength(length: any): boolean
	for _, l in Config.MatchLengths do
		if l == length then
			return true
		end
	end
	return false
end

--[[
	session: { length, difficulty, cup }  サーバーが MatchStarted で記録した値
	report:  Rewards.sanitize の戻り値
	vip:     VIP パスを持っているか
	戻り値: コイン数, 内訳
]]
function Rewards.compute(session: any, report: any, vip: boolean): (number, { [string]: number })
	local parts: { [string]: number } = {}
	local goals = math.min(report.home, R.MaxGoalsCounted)
	local coins = R.Base + goals * R.PerGoal
	parts.base = R.Base
	parts.goals = goals * R.PerGoal
	if report.winner == 0 then
		coins += R.Win
		parts.win = R.Win
		if report.shootoutWin then
			coins += R.ShootoutWin
			parts.shootout = R.ShootoutWin
		end
	elseif report.winner == nil and report.home == report.away then
		coins += R.Draw
		parts.draw = R.Draw
	end
	if report.away == 0 then
		coins += R.CleanSheet
		parts.cleanSheet = R.CleanSheet
	end
	local diff = toInt(session.difficulty, 1, #R.DifficultyBonus)
	local mult = R.DifficultyBonus[diff] * (R.LengthBonus[session.length] or 1)
	coins = math.min(math.floor(coins * mult), R.Max)
	parts.multiplier = math.floor(mult * 100 + 0.5)
	if vip then
		coins *= Config.Monetization.VipCoinMultiplier
		parts.vip = Config.Monetization.VipCoinMultiplier
	end
	return coins, parts
end

return Rewards
