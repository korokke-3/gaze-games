--!nonstrict
--[[
	Bindings — 操作の割り当て (キーボード + マウス / ゲームパッド)。純粋なデータと関数だけ。

	bindings = {
	  preset = "mouse" | "keys" | "custom",
	  kb  = { [action] = { "W", "Up" } },   キーボード・マウス: 1 操作に 2 つまで
	  pad = { [action] = { "ButtonA" } },   ゲームパッド: 1 操作に 1 つ
	}
	キーの名前は Roblox の KeyCode 名 (マウスは "MouseButton1" 〜 "MouseButton3")。
	1 つのキーは 1 つの操作にしか割り当てない (重なったら元の操作から外す)。
]]

local Bindings = {}

-- 操作の一覧 (表示順)。group は操作設定画面の見出し
Bindings.ACTIONS = {
	{ id = "moveUp", group = "move" },
	{ id = "moveDown", group = "move" },
	{ id = "moveLeft", group = "move" },
	{ id = "moveRight", group = "move" },
	{ id = "dash", group = "move" },
	{ id = "pass", group = "kick" },
	{ id = "shoot", group = "kick" },
	{ id = "through", group = "kick" },
	{ id = "lofted", group = "kick" },
	{ id = "l1", group = "mod" },
	{ id = "r1", group = "mod" },
	{ id = "l2", group = "mod" },
	{ id = "runCall", group = "mod" },
	{ id = "flickUp", group = "rs" },
	{ id = "flickDown", group = "rs" },
	{ id = "flickLeft", group = "rs" },
	{ id = "flickRight", group = "rs" },
	{ id = "levelUp", group = "other" },
	{ id = "levelDown", group = "other" },
	{ id = "pause", group = "other" },
	{ id = "help", group = "other" },
}

-- ゲームパッドで割り当てられる操作 (移動と右スティックはスティックなので対象外)
Bindings.PAD_ACTIONS = {
	pass = true,
	shoot = true,
	through = true,
	lofted = true,
	dash = true,
	l1 = true,
	r1 = true,
	l2 = true,
	runCall = true,
	levelUp = true,
	levelDown = true,
	pause = true,
	help = true,
}

-- 試合へ送る論理ボタン
Bindings.BUTTON_ACTIONS = {
	pass = true,
	shoot = true,
	through = true,
	lofted = true,
	dash = true,
	l1 = true,
	r1 = true,
	l2 = true,
}

Bindings.MAX_KB = 2
Bindings.MAX_PAD = 1

-- 割り当てられるキー (チャット "/"・メニュー Esc・F キー等の Roblox が使うキーは除く)
local KB_ALLOWED = {}
for c in string.gmatch("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ".") do
	KB_ALLOWED[c] = true
end
for _, k in {
	"Zero",
	"One",
	"Two",
	"Three",
	"Four",
	"Five",
	"Six",
	"Seven",
	"Eight",
	"Nine",
	"Space",
	"LeftShift",
	"RightShift",
	"LeftControl",
	"RightControl",
	"LeftAlt",
	"RightAlt",
	"Tab",
	"Up",
	"Down",
	"Left",
	"Right",
	"Comma",
	"Period",
	"Semicolon",
	"Quote",
	"LeftBracket",
	"RightBracket",
	"Minus",
	"Equals",
	"BackSlash",
	"Backquote",
	"Insert",
	"Home",
	"End",
	"PageUp",
	"PageDown",
	"KeypadZero",
	"KeypadOne",
	"KeypadTwo",
	"KeypadThree",
	"KeypadFour",
	"KeypadFive",
	"KeypadSix",
	"KeypadSeven",
	"KeypadEight",
	"KeypadNine",
	"MouseButton1",
	"MouseButton2",
	"MouseButton3",
} do
	KB_ALLOWED[k] = true
end
local PAD_ALLOWED = {}
for _, k in {
	"ButtonA",
	"ButtonB",
	"ButtonX",
	"ButtonY",
	"ButtonL1",
	"ButtonR1",
	"ButtonL2",
	"ButtonR2",
	"ButtonL3",
	"ButtonR3",
	"DPadUp",
	"DPadDown",
	"DPadLeft",
	"DPadRight",
	"ButtonStart",
	"ButtonSelect",
} do
	PAD_ALLOWED[k] = true
end
Bindings.KB_ALLOWED = KB_ALLOWED
Bindings.PAD_ALLOWED = PAD_ALLOWED

local PAD_DEFAULT = {
	pass = { "ButtonA" },
	shoot = { "ButtonX" },
	through = { "ButtonY" },
	lofted = { "ButtonB" },
	dash = { "ButtonR2" },
	l1 = { "ButtonL1" },
	r1 = { "ButtonR1" },
	l2 = { "ButtonL2" },
	runCall = { "ButtonR3" },
	levelUp = { "DPadUp" },
	levelDown = { "DPadDown" },
	pause = { "ButtonStart" },
	help = { "ButtonSelect" },
}

-- プリセット: マウス中心 (既定) / キーボードのみ (eFootball の PS 配置を手元のキーへ)
Bindings.PRESETS = {
	mouse = {
		moveUp = { "W" },
		moveDown = { "S" },
		moveLeft = { "A" },
		moveRight = { "D" },
		dash = { "LeftShift" },
		pass = { "MouseButton1", "K" },
		shoot = { "MouseButton2", "J" },
		through = { "Space", "MouseButton3" },
		lofted = { "E", "L" },
		l1 = { "Q" },
		r1 = { "R" },
		l2 = { "F" },
		runCall = { "G" },
		flickUp = { "Up" },
		flickDown = { "Down" },
		flickLeft = { "Left" },
		flickRight = { "Right" },
		levelUp = { "C" },
		levelDown = { "Z" },
		pause = { "P" },
		help = { "H" },
	},
	keys = {
		moveUp = { "W" },
		moveDown = { "S" },
		moveLeft = { "A" },
		moveRight = { "D" },
		dash = { "LeftShift" },
		pass = { "K" },
		shoot = { "J" },
		through = { "I" },
		lofted = { "L" },
		l1 = { "Q" },
		r1 = { "E" },
		l2 = { "F" },
		runCall = { "G" },
		flickUp = { "Up" },
		flickDown = { "Down" },
		flickLeft = { "Left" },
		flickRight = { "Right" },
		levelUp = { "C" },
		levelDown = { "Z" },
		pause = { "P" },
		help = { "H" },
	},
}

local function copyList(t)
	local out = {}
	for i, v in t do
		out[i] = v
	end
	return out
end

--- プリセットから作る。
function Bindings.fromPreset(name)
	local preset = Bindings.PRESETS[name] or Bindings.PRESETS.mouse
	local b = { preset = Bindings.PRESETS[name] and name or "mouse", kb = {}, pad = {} }
	for _, a in Bindings.ACTIONS do
		b.kb[a.id] = copyList(preset[a.id] or {})
		if Bindings.PAD_ACTIONS[a.id] then
			b.pad[a.id] = copyList(PAD_DEFAULT[a.id] or {})
		end
	end
	return b
end

function Bindings.default()
	return Bindings.fromPreset("mouse")
end

--- 外から来た割り当て (保存データ・クライアントの送信) を、安全な形に直す。
--- 不正なキー・重なり・数の超過は捨て、足りない操作は既定値で埋めない (外したままも許す)。
function Bindings.validate(raw)
	if type(raw) ~= "table" then
		return Bindings.default()
	end
	local out = { preset = "custom", kb = {}, pad = {} }
	if raw.preset == "mouse" or raw.preset == "keys" then
		out.preset = raw.preset
	end
	local function clean(src, allowed, max, actionSet)
		local used = {}
		local dst = {}
		for _, a in Bindings.ACTIONS do
			if actionSet == nil or actionSet[a.id] then
				local list = {}
				local given = type(src) == "table" and src[a.id] or nil
				if type(given) == "table" then
					for i = 1, math.min(#given, 8) do
						local k = given[i]
						if #list < max and type(k) == "string" and allowed[k] and not used[k] then
							used[k] = true
							table.insert(list, k)
						end
					end
				end
				dst[a.id] = list
			end
		end
		return dst
	end
	out.kb = clean(raw.kb, KB_ALLOWED, Bindings.MAX_KB, nil)
	out.pad = clean(raw.pad, PAD_ALLOWED, Bindings.MAX_PAD, Bindings.PAD_ACTIONS)
	-- 後から増えた操作 (保存データに項目が無い) は、空いていれば既定のキーを入れる
	local function fill(src, dst, defaults)
		local used = {}
		for _, list in dst do
			for _, k in list do
				used[k] = true
			end
		end
		for id, list in dst do
			if (type(src) ~= "table" or src[id] == nil) and #list == 0 then
				for _, k in defaults[id] or {} do
					if not used[k] then
						used[k] = true
						table.insert(list, k)
					end
				end
			end
		end
	end
	fill(raw.kb, out.kb, Bindings.PRESETS[out.preset] or Bindings.PRESETS.mouse)
	fill(raw.pad, out.pad, PAD_DEFAULT)
	return out
end

--[[
	割り当てを変える。device = "kb" | "pad"、slot = 1 / 2、key = nil なら外す。
	そのキーが他の操作に使われていたら、そちらから外す。
	戻り値: 新しい bindings, 外された操作 (なければ nil)
]]
function Bindings.assign(bindings, device, action, slot, key)
	local b = Bindings.validate(bindings)
	local map = device == "pad" and b.pad or b.kb
	local max = device == "pad" and Bindings.MAX_PAD or Bindings.MAX_KB
	local allowed = device == "pad" and PAD_ALLOWED or KB_ALLOWED
	if map[action] == nil or slot < 1 or slot > max then
		return b, nil
	end
	if key ~= nil and not allowed[key] then
		return b, nil
	end
	local removedFrom = nil
	if key ~= nil then
		for a, list in map do
			for i = #list, 1, -1 do
				if list[i] == key and not (a == action and i == slot) then
					table.remove(list, i)
					if a ~= action then
						removedFrom = a
					end
				end
			end
		end
	end
	local list = map[action]
	if key == nil then
		if list[slot] ~= nil then
			table.remove(list, slot)
		end
	elseif slot <= #list then
		list[slot] = key
	else
		table.insert(list, key)
	end
	b.preset = "custom"
	return b, removedFrom
end

--- 入力の引き当て: キー名 -> 操作。
function Bindings.lookup(bindings)
	local b = bindings or Bindings.default()
	local kb, pad = {}, {}
	for a, list in b.kb or {} do
		for _, k in list do
			kb[k] = a
		end
	end
	for a, list in b.pad or {} do
		for _, k in list do
			pad[k] = a
		end
	end
	return { kb = kb, pad = pad }
end

-- どの指で押すか (WASD に手を置き、右手はマウス)。操作設定の図と、試合中のガイドの色分けに使う
Bindings.FINGER = {
	Tab = "pinky",
	CapsLock = "pinky",
	LeftShift = "pinky",
	LeftControl = "pinky",
	One = "pinky",
	Two = "ring",
	Q = "ring",
	A = "ring",
	Z = "ring",
	Three = "middle",
	W = "middle",
	S = "middle",
	X = "middle",
	Four = "index",
	Five = "index",
	E = "index",
	R = "index",
	T = "index",
	D = "index",
	F = "index",
	G = "index",
	C = "index",
	V = "index",
	B = "index",
	Space = "thumb",
	LeftAlt = "thumb",
	MouseButton1 = "rindex",
	MouseButton2 = "rmiddle",
	MouseButton3 = "rmiddle",
}
Bindings.FINGER_ORDER = { "pinky", "ring", "middle", "index", "thumb", "rindex", "rmiddle" }
Bindings.FINGER_COLORS = {
	pinky = { 186, 140, 255 },
	ring = { 110, 170, 255 },
	middle = { 110, 220, 150 },
	index = { 255, 185, 90 },
	thumb = { 255, 140, 190 },
	rindex = { 255, 120, 100 },
	rmiddle = { 120, 220, 230 },
}

--- そのキーを押す指 (左手のホームポジション + 右手マウスの前提。それ以外は nil)。
function Bindings.fingerOf(key)
	return key and Bindings.FINGER[key] or nil
end

-- 画面に出す名前
local DISPLAY = {
	MouseButton1 = "L-Click",
	MouseButton2 = "R-Click",
	MouseButton3 = "M-Click",
	LeftShift = "Shift",
	RightShift = "R-Shift",
	LeftControl = "Ctrl",
	RightControl = "R-Ctrl",
	LeftAlt = "Alt",
	RightAlt = "R-Alt",
	Up = "↑",
	Down = "↓",
	Left = "←",
	Right = "→",
	Zero = "0",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	Comma = ",",
	Period = ".",
	Semicolon = ";",
	Quote = "'",
	LeftBracket = "[",
	RightBracket = "]",
	Minus = "-",
	Equals = "=",
	BackSlash = "\\",
	Backquote = "`",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "LB",
	ButtonR1 = "RB",
	ButtonL2 = "LT",
	ButtonR2 = "RT",
	ButtonL3 = "LS",
	ButtonR3 = "RS",
	DPadUp = "D-Pad ↑",
	DPadDown = "D-Pad ↓",
	DPadLeft = "D-Pad ←",
	DPadRight = "D-Pad →",
	ButtonStart = "Start",
	ButtonSelect = "Select",
}

function Bindings.display(key)
	if key == nil then
		return "—"
	end
	if DISPLAY[key] then
		return DISPLAY[key]
	end
	local kp = string.match(key, "^Keypad(%a+)$")
	if kp then
		return "Num " .. (DISPLAY[kp] or kp)
	end
	return key
end

--- その操作に割り当てたキーの表記 ("L-Click / K")。
function Bindings.label(bindings, device, action)
	local map = device == "pad" and bindings.pad or bindings.kb
	local list = map and map[action] or nil
	if list == nil or #list == 0 then
		return "—"
	end
	local names = {}
	for _, k in list do
		table.insert(names, Bindings.display(k))
	end
	return table.concat(names, " / ")
end

return Bindings
