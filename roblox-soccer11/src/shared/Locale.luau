--!strict
--[[
	Locale — 英語が正典、日本語は LocaleId が "ja" で始まる場合に自動で切り替える。
	試合ロジック (Match) は文字列ではなくキーを返し、表示側がここで解決する。
]]

local Locale = {}

local EN = {
	["title"] = "Soccer 11",
	["subtitle"] = "11-a-side top-down football. Beat the CPU in 5 minutes.",
	["start"] = "Kick off",
	["rematch"] = "Play again",
	["result"] = "Full time",
	["result.win"] = "You win!",
	["result.lose"] = "You lose...",
	["result.draw"] = "Draw",
	["result.stats"] = "Passes %d / Intercepted %d / Skill beats %d of %d / Offsides %d / Fouls %d",
	["hud.score"] = "YOU %d - %d CPU",
	["hud.paused"] = "Paused (P to resume)",
	["hud.help.title"] = "Controls (H to hide)",
	["hud.help.attack"] = "Attack: Pass K / Through I / Shoot J (hold) / Dash Shift / Skill: tap Shift then flick WASD",
	["hud.help.flick"] = "Hold an arrow key while pressing a button to flick: ↑↓ lofted / loop, ← → impact",
	["hud.help.defend"] = "Defend: Mark K (↑ team press) / Press I / Tackle J / Slide L / Switch U (+arrow)",
	["hud.help.other"] = "Q twice: stop dribble / shoulder charge   P: pause",
	["setp.throw"] = "Throw-in",
	["setp.corner"] = "Corner kick",
	["setp.gk"] = "Goal kick",
	["setp.fk"] = "Free kick",
	["setp.pk"] = "Penalty kick",
	["setp.hint"] = "WASD to aim + Pass K (↑↓ lofted) / Through I",
	["setp.hint.shoot"] = " / Shoot J (hold)",
	["popup.goal"] = "GOAL!!",
	["popup.concede"] = "Conceded...",
	["popup.beat"] = "Beat him!",
	["popup.beaten"] = "Beaten...",
	["popup.stopped"] = "Stopped!",
	["popup.steal"] = "Won the ball!",
	["popup.lost"] = "Dispossessed!",
	["popup.read"] = "Read!",
	["popup.teampress"] = "Team press",
	["popup.body"] = "Body contact",
	["popup.clear"] = "Clearance",
	["popup.nicetackle"] = "Nice tackle!",
	["popup.foul_pk"] = "Foul! Penalty",
	["popup.foul_fk"] = "Foul! Free kick",
	["popup.offside"] = "Offside",
	["popup.cut"] = "Intercepted!",
	["popup.save"] = "Save!",
	["popup.nicesave"] = "Great save!",
	["skill.double_touch"] = "Double touch",
	["skill.elastico"] = "Elastico",
	["skill.scissors"] = "Scissors",
	["skill.marseille"] = "Marseille turn",
	["skill.drag_back"] = "Drag back",
	["touch.pass"] = "Pass",
	["touch.through"] = "Through",
	["touch.shoot"] = "Shoot",
	["touch.dash"] = "Dash",
	["touch.switch"] = "Switch",
	["touch.slide"] = "Slide",
	["touch.lob"] = "Lob",
	["touch.stop"] = "Stop",
}

local JA = {
	["title"] = "サッカー 11",
	["subtitle"] = "11人制の見下ろし型サッカー。5分間でCPUに勝とう。",
	["start"] = "キックオフ",
	["rematch"] = "もう一度",
	["result"] = "試合終了",
	["result.win"] = "勝利!",
	["result.lose"] = "敗北…",
	["result.draw"] = "引き分け",
	["result.stats"] = "パス %d / カットされた %d / 技で抜いた %d / %d 回 / オフサイド %d / ファウル %d",
	["hud.score"] = "あなた %d - %d CPU",
	["hud.paused"] = "一時停止中 (P で再開)",
	["hud.help.title"] = "操作 (H で隠す)",
	["hud.help.attack"] = "攻撃: パス K / スルー I / シュート J(長押し) / ダッシュ Shift / 技: Shift をタップ→WASD を弾く",
	["hud.help.flick"] = "ボタンと一緒に矢印キーを押すとフリック: ↑↓ フライ・ループ, ← → インパクト",
	["hud.help.defend"] = "守備: マッチアップ K(↑チームプレス) / プレス I / タックル J / スライディング L / カーソル U(+矢印)",
	["hud.help.other"] = "Q を2回: ドリブル停止・ショルダーチャージ   P: 一時停止",
	["setp.throw"] = "スローイン",
	["setp.corner"] = "コーナーキック",
	["setp.gk"] = "ゴールキック",
	["setp.fk"] = "フリーキック",
	["setp.pk"] = "PK",
	["setp.hint"] = "WASD で方向 + パス K (↑↓でフライ) / スルー I",
	["setp.hint.shoot"] = " / シュート J (長押し)",
	["popup.goal"] = "GOAL!!",
	["popup.concede"] = "失点…",
	["popup.beat"] = "抜いた!",
	["popup.beaten"] = "抜かれた…",
	["popup.stopped"] = "止められた!",
	["popup.steal"] = "ボール奪取!",
	["popup.lost"] = "ボール奪取された!",
	["popup.read"] = "読まれた!",
	["popup.teampress"] = "チームプレス",
	["popup.body"] = "ボディコンタクト",
	["popup.clear"] = "クリア",
	["popup.nicetackle"] = "ナイスタックル!",
	["popup.foul_pk"] = "ファウル! PK",
	["popup.foul_fk"] = "ファウル! フリーキック",
	["popup.offside"] = "オフサイド",
	["popup.cut"] = "カットされた!",
	["popup.save"] = "セーブ!",
	["popup.nicesave"] = "ナイスセーブ!",
	["skill.double_touch"] = "ダブルタッチ",
	["skill.elastico"] = "エラシコ",
	["skill.scissors"] = "シザーズ",
	["skill.marseille"] = "マルセイユルーレット",
	["skill.drag_back"] = "ドラッグバック",
	["touch.pass"] = "パス",
	["touch.through"] = "スルー",
	["touch.shoot"] = "シュート",
	["touch.dash"] = "ダッシュ",
	["touch.switch"] = "交代",
	["touch.slide"] = "スライド",
	["touch.lob"] = "ロブ",
	["touch.stop"] = "止める",
}

Locale.Tables = { en = EN, ja = JA }

--- LocaleId ("ja-jp" など) から言語コードを決める。
function Locale.langOf(localeId: string?): string
	if localeId and string.sub(string.lower(localeId), 1, 2) == "ja" then
		return "ja"
	end
	return "en"
end

--- キーを文字列にする。未定義なら英語、それも無ければキー自体を返す。
function Locale.t(lang: string, key: string, ...: any): string
	local dict = (Locale.Tables :: { [string]: { [string]: string } })[lang] or EN
	local s = dict[key] or EN[key] or key
	if select("#", ...) > 0 then
		return string.format(s, ...)
	end
	return s
end

return Locale
