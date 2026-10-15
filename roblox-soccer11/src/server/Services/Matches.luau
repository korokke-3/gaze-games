--!strict
--[[
	Matches — 試合の開始 / 終了の受付と、コイン報酬の付与。

	試合のシミュレーションはクライアントで動くので、結果の申告は信用しない:
	  - 試合時間・難易度は、開始時にサーバーが記録した値を使う (終了時の申告は使わない)
	  - 実時間で規定時間の 80% 以上経っていなければ報酬なし
	  - 得点・勝敗は丸めて、1 試合の報酬に上限を設ける
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Rewards = require(Shared:WaitForChild("Rewards"))
local Data = require(script.Parent.Data)
local Store = require(script.Parent.Store)

local Matches = {}

local MIN_REAL_RATIO = 0.8 -- 実時間でこれ以上経っていないと報酬なし
local sessions: { [Player]: { t: number, length: number, difficulty: number, cup: boolean } } = {}

function Matches.start(player: Player, cfg: any)
	if typeof(cfg) ~= "table" then
		return
	end
	local length = (cfg :: any).length
	if not Rewards.isValidLength(length) then
		length = Config.MatchTime
	end
	local diff = (cfg :: any).difficulty
	if typeof(diff) ~= "number" or diff < 1 or diff > #Config.Difficulties then
		diff = Config.DefaultDifficulty
	end
	sessions[player] = {
		t = os.clock(),
		length = length,
		difficulty = math.floor(diff),
		cup = (cfg :: any).cup == true,
	}
end

function Matches.finish(player: Player, raw: any)
	local session = sessions[player]
	sessions[player] = nil
	local data = Data.get(player)
	if session == nil or data == nil then
		return
	end
	local report = Rewards.sanitize(raw)
	local realElapsed = os.clock() - session.t
	if realElapsed < session.length * MIN_REAL_RATIO then
		Net.event("Notify"):FireClient(player, "notify.too_short")
		return
	end
	local vip = Store.hasPass(player, "VIP")
	local coins, parts = Rewards.compute(session, report, vip)
	data.coins += coins
	data.stats.matches += 1
	data.stats.goals += math.min(report.home, 30)
	if report.winner == 0 then
		data.stats.wins += 1
	elseif report.winner == 1 then
		data.stats.losses += 1
	else
		data.stats.draws += 1
	end
	Data.markDirty(player)
	Net.event("MatchReward"):FireClient(player, { coins = coins, parts = parts, total = data.coins })
	Store.push(player)
end

function Matches.remove(player: Player)
	sessions[player] = nil
end

return Matches
