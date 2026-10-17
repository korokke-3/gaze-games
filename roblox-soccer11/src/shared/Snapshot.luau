--!nonstrict
--[[
	Snapshot — オンライン対戦 / 協力で、サーバーの試合状態をクライアントへ送るための圧縮形式。
	string.pack で 1 回あたり 300 バイト前後にする (22 人 + ボール + 進行状況 + 操作者)。

	encode(match, since) -> string, seq   since (通し番号) より後のポップアップ・技名と、効果音を含める
	decode(str) -> table
	packInput / unpackInput: クライアントの入力 (移動・狙い・ボタン・右スティック)
]]

local Snapshot = {}

local MODES = { play = 0, halftime = 1, replay = 2, shootout = 3 }
local MODE_NAMES = { [0] = "play", "halftime", "replay", "shootout" }
local SETP = { throw = 1, corner = 2, gk = 3, fk = 4, pk = 5 }
local SETP_NAMES = { "throw", "corner", "gk", "fk", "pk" }
local KICKS = { pass = 1, through = 2, lofted = 3, shoot = 4 }
local KICK_NAMES = { "pass", "through", "lofted", "shoot" }

Snapshot.BUTTONS = { "pass", "through", "lofted", "shoot", "dash", "l1", "r1", "l2" }

local function q(v, scale, lo, hi)
	local n = math.floor(v * scale + 0.5)
	return math.clamp(n, lo, hi)
end

local function indexOf(match, p)
	if p == nil then
		return 0
	end
	for i, x in match.pl do
		if x == p then
			return i
		end
	end
	return 0
end

--[[
	since: この通し番号より後に出たポップアップ等を含める (前回の送信で返した値)
	戻り値: 文字列, 次回の since
]]
function Snapshot.encode(match, since)
	since = since or 0
	local parts = {}
	local b = match.ball
	local flags = (match.flip and 1 or 0) + (match.paused and 2 or 0) + (match.ended and 4 or 0)
	local sp = match.setp
	local sh = match.shoot
	table.insert(
		parts,
		string.pack(
			"<fBBBBBBBBBBBB",
			match.elapsed,
			MODES[match.mode] or 0,
			match.bIndex,
			match.period == "extra" and 1 or 0,
			flags,
			math.min(match.score[0], 255),
			math.min(match.score[1], 255),
			sp and SETP[sp.kind] or 0,
			sp and sp.team or 0,
			sh and math.min(sh.goals[0], 254) or 255,
			sh and math.min(sh.goals[1], 254) or 255,
			match.level[0] + 2,
			match.level[1] + 2
		)
	)
	table.insert(
		parts,
		string.pack(
			"<hhHhhBB",
			q(b.p.x, 50, -32768, 32767),
			q(b.p.y, 50, -32768, 32767),
			q(math.max(b.z, 0), 100, 0, 65535),
			q(b.v.x, 10, -32768, 32767),
			q(b.v.y, 10, -32768, 32767),
			indexOf(match, b.owner),
			sp and indexOf(match, sp.taker) or 0
		)
	)
	for _, p in match.pl do
		local ang = math.atan2(p.face.y, p.face.x)
		local a = math.floor((ang / (2 * math.pi)) * 256 + 0.5) % 256
		local f = (p.out and 1 or 0)
			+ (p.gk and 2 or 0)
			+ (p.stun > 0 and 4 or 0)
			+ (p.slide > 0 and 8 or 0)
			+ (p.exhausted and 16 or 0)
			+ (p.skill ~= nil and 32 or 0)
			+ (p.dive ~= nil and 64 or 0)
		table.insert(
			parts,
			string.pack(
				"<hhBBB",
				q(p.p.x, 50, -32768, 32767),
				q(p.p.y, 50, -32768, 32767),
				a,
				q(p.stamina, 2.5, 0, 255),
				f
			)
		)
	end
	-- 操作者: id は数値 (UserId)。操作中の選手 / 溜め / プレビュー
	table.insert(parts, string.pack("<B", #match.seats))
	for _, s in match.seats do
		local kind = s.charge and KICKS[s.charge.btn] or 0
		local power = match:chargePower(s) or 0
		local prev = indexOf(match, match:previewReceiver(s))
		table.insert(parts, string.pack("<dBBBB", s.id, indexOf(match, s.ctrl), kind, q(power, 255, 0, 255), prev))
	end
	-- 新しいポップアップ / 技名 / 効果音
	local pops, labels = {}, {}
	for _, x in match.popups do
		if (x.seq or 0) > since then
			table.insert(pops, x)
		end
	end
	for _, x in match.labels do
		if (x.seq or 0) > since then
			table.insert(labels, x)
		end
	end
	table.insert(parts, string.pack("<B", math.min(#pops, 8)))
	for i = 1, math.min(#pops, 8) do
		local x = pops[i]
		table.insert(parts, string.pack("<s1B", x.key, x.team == nil and 255 or x.team))
	end
	table.insert(parts, string.pack("<B", math.min(#labels, 8)))
	for i = 1, math.min(#labels, 8) do
		local x = labels[i]
		table.insert(parts, string.pack("<s1B", x.key, indexOf(match, x.player)))
	end
	local evs = match.events or {}
	table.insert(parts, string.pack("<B", math.min(#evs, 8)))
	for i = 1, math.min(#evs, 8) do
		local e = evs[i]
		local idx = e.player and indexOf(match, e.player) or 0
		table.insert(parts, string.pack("<s1", idx > 0 and (e.kind .. ":" .. idx) or e.kind))
	end
	return table.concat(parts), match.seq or 0
end

function Snapshot.decode(str)
	local pos = 1
	local function read(fmt)
		local r = table.pack(string.unpack(fmt, str, pos))
		pos = r[r.n]
		return table.unpack(r, 1, r.n - 1)
	end
	local s = {}
	local elapsed, mode, bIndex, period, flags, s0, s1, spKind, spTeam, g0, g1, l0, l1 = read("<fBBBBBBBBBBBB")
	s.elapsed = elapsed
	s.mode = MODE_NAMES[mode] or "play"
	s.bIndex = bIndex
	s.period = period == 1 and "extra" or "regular"
	s.flip = bit32.band(flags, 1) ~= 0
	s.paused = bit32.band(flags, 2) ~= 0
	s.ended = bit32.band(flags, 4) ~= 0
	s.score = { [0] = s0, [1] = s1 }
	s.setp = spKind ~= 0 and { kind = SETP_NAMES[spKind], team = spTeam } or nil
	s.shoot = g0 ~= 255 and { goals = { [0] = g0, [1] = g1 } } or nil
	s.level = { [0] = l0 - 2, [1] = l1 - 2 }
	local bx, by, bz, bvx, bvy, owner, taker = read("<hhHhhBB")
	s.ball = { x = bx / 50, y = by / 50, z = bz / 100, vx = bvx / 10, vy = bvy / 10, owner = owner, taker = taker }
	if s.setp then
		s.setp.takerIndex = taker
	end
	s.pl = {}
	for i = 1, 22 do
		local x, y, a, st, f = read("<hhBBB")
		local ang = a / 256 * 2 * math.pi
		s.pl[i] = {
			x = x / 50,
			y = y / 50,
			fx = math.cos(ang),
			fy = math.sin(ang),
			stamina = st / 2.5,
			out = bit32.band(f, 1) ~= 0,
			gk = bit32.band(f, 2) ~= 0,
			stun = bit32.band(f, 4) ~= 0,
			slide = bit32.band(f, 8) ~= 0,
			exhausted = bit32.band(f, 16) ~= 0,
			skill = bit32.band(f, 32) ~= 0,
			dive = bit32.band(f, 64) ~= 0,
		}
	end
	s.seats = {}
	local ns = read("<B")
	for _ = 1, ns do
		local id, ctrl, kind, power, prev = read("<dBBBB")
		table.insert(s.seats, { id = id, ctrl = ctrl, kind = KICK_NAMES[kind], power = power / 255, preview = prev })
	end
	s.popups = {}
	for _ = 1, read("<B") do
		local key, team = read("<s1B")
		table.insert(s.popups, { key = key, team = team ~= 255 and team or nil })
	end
	s.labels = {}
	for _ = 1, read("<B") do
		local key, idx = read("<s1B")
		table.insert(s.labels, { key = key, index = idx })
	end
	s.events = {}
	for _ = 1, read("<B") do
		local raw = read("<s1")
		local kind, idx = string.match(raw, "^(%a+):(%d+)$")
		if kind then
			table.insert(s.events, { kind = kind, index = tonumber(idx) })
		else
			table.insert(s.events, { kind = raw })
		end
	end
	return s
end

-- ================================================================ 入力
--[[
	input: { move = {x,y}, aim = {x,y} | nil, point = {x,y} | nil, buttons = { pass = true, ... },
	         flick = {x,y} | nil, cmd = string | nil }
	point はマウスが指すピッチ上の地点 [m] (10cm 単位で送る)。
]]
function Snapshot.packInput(input)
	local mask = 0
	for i, name in Snapshot.BUTTONS do
		if input.buttons[name] then
			mask += 2 ^ (i - 1)
		end
	end
	local flags = (input.aim ~= nil and 1 or 0) + (input.point ~= nil and 2 or 0)
	local ax, ay = 0, 0
	if input.aim ~= nil then
		ax, ay = input.aim.x, input.aim.y
	end
	local px, py = 0, 0
	if input.point ~= nil then
		px, py = input.point.x, input.point.y
	end
	local fx, fy = 0, 0
	if input.flick then
		fx, fy = input.flick.x, input.flick.y
	end
	return string.pack(
		"<bbBbbhhBbbs1",
		q(input.move.x, 127, -127, 127),
		q(input.move.y, 127, -127, 127),
		flags,
		q(ax, 127, -127, 127),
		q(ay, 127, -127, 127),
		q(px, 10, -32768, 32767),
		q(py, 10, -32768, 32767),
		mask,
		q(fx, 127, -127, 127),
		q(fy, 127, -127, 127),
		input.cmd or ""
	)
end

function Snapshot.unpackInput(str)
	if type(str) ~= "string" or #str < 13 or #str > 64 then
		return nil
	end
	local ok, mx, my, flags, ax, ay, px, py, mask, fx, fy, cmd = pcall(string.unpack, "<bbBbbhhBbbs1", str)
	if not ok then
		return nil
	end
	local buttons = {}
	for i, name in Snapshot.BUTTONS do
		if bit32.band(mask, 2 ^ (i - 1)) ~= 0 then
			buttons[name] = true
		end
	end
	return {
		move = { x = mx / 127, y = my / 127 },
		aim = bit32.band(flags, 1) ~= 0 and { x = ax / 127, y = ay / 127 } or nil,
		point = bit32.band(flags, 2) ~= 0 and { x = px / 10, y = py / 10 } or nil,
		buttons = buttons,
		flick = (fx ~= 0 or fy ~= 0) and { x = fx / 127, y = fy / 127 } or nil,
		cmd = cmd ~= "" and cmd or nil,
	}
end

--- サーバー側: 前回のボタンと比べて press / release を Match に伝える。
function Snapshot.applyInput(match, seatId, input, prevButtons)
	match:setMove(seatId, input.move.x, input.move.y)
	if input.aim ~= nil then
		match:setAim(seatId, input.aim.x, input.aim.y)
	else
		match:setAim(seatId, nil)
	end
	if input.point ~= nil then
		match:setAimPoint(seatId, input.point.x, input.point.y)
	else
		match:setAimPoint(seatId, nil)
	end
	-- 押した順を保つため、修飾ボタン (l1/r1/dash/l2) を先に処理する
	local order = { "dash", "l1", "r1", "l2", "pass", "through", "lofted", "shoot" }
	for _, name in order do
		local now = input.buttons[name] == true
		local was = prevButtons[name] == true
		if now and not was then
			match:press(seatId, name)
		end
	end
	for _, name in order do
		local now = input.buttons[name] == true
		local was = prevButtons[name] == true
		if was and not now then
			match:release(seatId, name)
		end
	end
	if input.flick ~= nil then
		match:flick(seatId, input.flick.x, input.flick.y)
	end
	if input.cmd ~= nil and input.cmd ~= "pause" then
		match:command(seatId, input.cmd)
	end
	return input.buttons
end

return Snapshot
