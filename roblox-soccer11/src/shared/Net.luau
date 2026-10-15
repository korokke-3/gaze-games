--!strict
--[[
	Net — RemoteEvent の一元管理。サーバー起動時に生成し、クライアントは WaitForChild で待つ。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EVENTS = {
	-- client -> server
	"RequestState", -- ()
	"MatchStarted", -- (config: { length, difficulty, cup })
	"MatchFinished", -- (report: { home, away, winner, shootoutWin })
	"BuyItem", -- (kind: "kit" | "ball", id: string)
	"EquipItem", -- (kind: "kit" | "ball", id: string)
	"PromptPurchase", -- (kind: "pass" | "product", key: string)
	"SaveSettings", -- (settings: table)
	"SaveBindings", -- (bindings: table)  操作の割り当て
	"RoomList", -- ()
	"RoomCreate", -- (mode: "coop" | "versus", opts: table)
	"RoomJoin", -- (id: number)
	"RoomLeave", -- ()
	"RoomTeam", -- (team: 0 | 1)
	"RoomOpts", -- (opts: table)  ホストだけ
	"RoomStart", -- ()  ホストだけ
	"MatchInput", -- (packet: string)  Snapshot.packInput

	-- server -> client
	"State", -- (state: table)  自分の完全な状態
	"MatchReward", -- (reward: { coins, parts, total })
	"Notify", -- (key: string, arg: any?)
	"Rooms", -- (list: table)
	"RoomState", -- (room: table | nil)
	"OnlineStart", -- (info: table)
	"OnlineSnap", -- (snapshot: string)
	"OnlineEnd", -- (info: { result, reward, myTeam, aborted })
}

local Net = {}
local root: Folder

if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild("Net")
	if existing then
		root = existing :: Folder
	else
		root = Instance.new("Folder")
		root.Name = "Net"
		root.Parent = ReplicatedStorage
		for _, name in EVENTS do
			local e = Instance.new("RemoteEvent")
			e.Name = name
			e.Parent = root
		end
	end
else
	root = ReplicatedStorage:WaitForChild("Net") :: Folder
end

function Net.event(name: string): RemoteEvent
	return root:WaitForChild(name) :: RemoteEvent
end

return Net
