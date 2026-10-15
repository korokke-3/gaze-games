--!nonstrict
--[[
	Sfx — Roblox に内蔵された効果音だけを使う (アセット ID に依存しない)。
	ファイルが無い環境では無音になるだけで、エラーにはならない。
	歓声・実況・BGM は音源が無いため未実装。
]]

local SoundService = game:GetService("SoundService")

local PATHS = {
	kick = { id = "rbxasset://sounds/kickhit.wav", volume = 0.6 },
	whistle = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5 },
	goal = { id = "rbxasset://sounds/victory.wav", volume = 0.7 },
	card = { id = "rbxasset://sounds/button.wav", volume = 0.6 },
	save = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.5 },
}

local Sfx = {}
local cache = {}

function Sfx.play(kind)
	local def = PATHS[kind]
	if def == nil then
		return
	end
	local s = cache[kind]
	if s == nil then
		s = Instance.new("Sound")
		s.Name = "Sfx_" .. kind
		s.SoundId = def.id
		s.Volume = def.volume
		s.Parent = SoundService
		cache[kind] = s
	end
	pcall(function()
		s.TimePosition = 0
		s:Play()
	end)
end

return Sfx
