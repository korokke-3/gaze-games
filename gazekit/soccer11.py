"""目線サッカー 11人制: eFootball 風の操作・ルールの見下ろし型サッカー (オリジナル作品)。

コート 105m x 68m、両チーム 4-3-3。カメラはボールを追い、右下にミニマップ。
操作: eFootball スマホ版 (バーチャルパッド) のボタン構成をキーボードに写したもの (KEYS 参照)。
  左スティック = WASD, ボタンのフリック = ボタンのキー + 矢印キー (押している矢印の向きにフリックしたことになる)
  攻撃: パス(K) タップ グラウンダー / ↑↓ フライパス (クロスエリアではクロス) / ← インパクトグラウンダー / → インパクトフライ
        スルーパス(I) タップ スルー / ↑↓ フライスルー / ← → インパクトスルー
        シュート(J, 長押しでパワー) / ↑ ループ / ↓ コントロール / ← → インパクトシュート
        ダッシュ(Shift) 長押し / タップしてから WASD を弾くとフェイント (SKILL_COMMANDS)
        左側(Q) 2回タップ: ドリブル停止 (ダッシュ中はボディコンタクト)
  守備: マッチアップ(K) 長押し / ↑ チームプレス,  プレス(I) 長押しでボールに寄せる / ↓ (自陣) GK 飛び出し,
        カーソル(U) タップ カーソルチェンジ / + 矢印 その方向の選手へ,  左側(Q) 2回タップ ショルダーチャージ,
        タックル(J) / スライディング(L) (スマホ版の一覧で未確認のため、家庭用版の割り当てに準じる)
  P 一時停止, Esc メニュー
ルール: スローイン, ゴールキック, コーナーキック, オフサイド, ファウル (FK / エリア内は PK), キックオフ
視線: 見つめている味方へのパスコースを CPU が読む / ノールックパス / PK ではキーパーが見ている側に跳ぶ
各チームの操作主体 (人 / CPU) は self.ctrl_kind で切り替えられる (将来の対戦用)。
"""
from __future__ import annotations

import math
import random
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np

from .games import Scene
from .jtext import JT

PL, PW = 105.0, 68.0              # コートの長さ・幅 [m]
GOAL_W, GOAL_H = 7.32, 2.44
BOX_L, BOX_W = 16.5, 40.3         # ペナルティエリア
SIX_L, SIX_W = 5.5, 18.3
PEN_SPOT = 11.0
P_R = 0.6
CONTROL_R = 1.1
SPEED, DASH, DRIBBLE = 6.5, 8.6, 0.88
FRICTION = 4.0
GRAV = 9.8
MATCH_TIME = 300.0
ACC_AI, ACC_HUMAN = 14.0, 28.0    # 加速度の上限 [m/s^2] (急に止まったり向きを変えたりしない)
DECIDE_EVERY = 0.3                # CPU のボール保持者が判断する間隔 [s]
HOME, AWAY = 0, 1

# eFootball スマホ版 (バーチャルパッド) のボタン -> キーボード。ボタンの「フリック」は、キー + 矢印キー (向き)。
KEYS = {"pass": "k", "through": "i", "shoot": "j", "cursor": "u", "slide": "l", "left_tap": "q"}
# 守備では、パスの位置が「マッチアップ」、スルーパスの位置が「プレス」ボタンになる
BTN = {"pass": "パス", "through": "スルーパス", "shoot": "シュート", "cursor": "カーソル"}

# 技のコマンド (ダッシュをタップしてから WASD を弾く)。向きは「進行方向を前」とした相対方向:
#   F 前, B 後ろ, S 横 (左右どちらか), X 最初の S と逆の横。上から順に照合する。差し替え自由。
SKILL_COMMANDS = [
    (("F", "B", "S"), "marseille"), (("B", "S", "F"), "marseille"), (("S", "B", "X"), "marseille"),
    (("S", "X"), "elastico"),
    (("F", "S"), "scissors"),
    (("S",), "double_touch"),
    (("B",), "drag_back"),
]
SKILL_NAME = {"double_touch": "ダブルタッチ", "elastico": "エラシコ", "scissors": "シザーズ",
              "marseille": "マルセイユルーレット", "drag_back": "ドラッグバック"}
SKILL_DUR = {"double_touch": 0.45, "elastico": 0.5, "scissors": 0.55, "marseille": 0.65, "drag_back": 0.4}
SKILL_BASE = {"double_touch": 0.6, "elastico": 0.65, "scissors": 0.5, "marseille": 0.55, "drag_back": 0.45}

# 4-3-3 (HOME が +x 方向へ攻める時の基準位置 [m]) と役割
FORM = [((-50, 0), "GK"), ((-34, -22), "LB"), ((-37, -8), "CB"), ((-37, 8), "CB"), ((-34, 22), "RB"),
        ((-24, 0), "DM"), ((-16, -12), "CM"), ((-16, 12), "CM"), ((-4, -24), "LW"), ((-3, 0), "ST"),
        ((-4, 24), "RW")]
NUMBERS = [1, 3, 4, 5, 2, 6, 8, 10, 11, 9, 7]


def norm(v) -> np.ndarray:
    v = np.asarray(v, float)
    n = float(np.hypot(v[0], v[1]))
    return v / n if n > 1e-9 else np.zeros(2)


class P:
    def __init__(self, team, i):
        self.team, self.i = team, i
        self.role = FORM[i][1]
        self.num = NUMBERS[i]
        self.p = np.zeros(2)
        self.v = np.zeros(2)
        self.face = np.array([1.0 if team == HOME else -1.0, 0.0])
        self.stun = 0.0
        self.cd = 0.0          # タックル等のクールダウン
        self.slide = 0.0       # スライディング中の残り時間
        self.next_decide = 0.0 # CPU のボール保持者: 次に判断する時刻
        self.ddir = None       # CPU のボール保持者: いまのドリブル方向
        self.skill: Optional[dict] = None   # 実行中の技
        self.skill_log: List[float] = []    # 技を使った時刻 (連発すると読まれる)

    @property
    def gk(self):
        return self.i == 0


class Ball:
    def __init__(self):
        self.p = np.zeros(2)
        self.v = np.zeros(2)
        self.z = 0.0
        self.vz = 0.0
        self.owner: Optional[P] = None
        self.last: Optional[P] = None           # 最後に触った選手
        self.kicker: Optional[P] = None
        self.kick_t = -9.0
        self.kind = ""
        self.target: Optional[P] = None
        self.nolook = False
        self.offside: Optional[P] = None        # キックの瞬間にオフサイド位置だった受け手


class Soccer11(Scene):
    cursor = True
    full_frame = True        # 背景を自分で全面に描く (App は塗りつぶしを省略できる)

    def __init__(self, w, h, keys=None, seed: Optional[int] = None, ctrl_kind=("human", "cpu")):
        super().__init__(w, h)
        self.keys = keys
        self.rng = random.Random(seed)
        self.ctrl_kind = list(ctrl_kind)
        self.scale = w / 82.0                   # 画面に約82m分を映す
        self.cam = np.zeros(2)
        self.pl: List[P] = [P(t, i) for t in (HOME, AWAY) for i in range(11)]
        self.ball = Ball()
        self.score = [0, 0]
        self.elapsed = 0.0
        self.t_last: Optional[float] = None
        self.paused = False
        self.ended = False
        self.ctrl: P = self.team(HOME)[9]
        # セットプレー: None or dict(kind, team, pos, t0, taker)
        self.setp: Optional[dict] = None
        self.popups: List[Tuple[float, str, Tuple[int, int, int]]] = []
        self.stats = {"nolook": 0, "read": 0, "passes": 0, "intercepted": 0, "offside": 0, "fouls": 0}
        # 入力
        self._ev: Dict[str, float] = {}
        self.charge: Optional[float] = None     # シュートのため始めた時刻
        # 視線
        self.gaze = None
        self.attn: Dict[int, float] = {}
        self.watched: Optional[P] = None
        self.reader: Optional[P] = None
        self.goal_look = 0.0
        self.presser: Dict[int, Optional[P]] = {HOME: None, AWAY: None}   # ボールに寄せる役 (すぐには入れ替えない)
        self.chase: Dict[int, Tuple[np.ndarray, bool]] = {}               # こぼれ球・パスに向かう選手の目標
        self.rs_buf: List[Tuple[float, np.ndarray]] = []                  # 技の入力列 (弾いた方向)
        self.skill_arm_until = -1.0                                       # この時刻まで WASD が技の入力になる
        self._shift_t: Optional[float] = None
        self.skill_stats = {"tried": 0, "beat": 0}
        self.kickoff(HOME)

    # ================================================================ 基本
    def team(self, t) -> List[P]:
        return self.pl[t * 11:(t + 1) * 11]

    @staticmethod
    def sgn(team) -> int:
        return 1 if team == HOME else -1          # 攻撃方向 (+x / -x)

    def opp_goal(self, team) -> np.ndarray:
        return np.array([self.sgn(team) * PL / 2, 0.0])

    def human(self, team) -> bool:
        return self.ctrl_kind[team] == "human"

    def to_px(self, p) -> Tuple[int, int]:
        return (int(self.W / 2 + (p[0] - self.cam[0]) * self.scale),
                int(self.H * 0.52 + (p[1] - self.cam[1]) * self.scale))

    def to_world(self, q) -> np.ndarray:
        return np.array([(q[0] - self.W / 2) / self.scale + self.cam[0],
                         (q[1] - self.H * 0.52) / self.scale + self.cam[1]])

    def popup(self, s, col=(255, 255, 255)):
        self.popups.append((self.elapsed, s, col))

    def place_formation(self, attacking: Optional[int] = None):
        for p in self.pl:
            (x, y), _ = FORM[p.i]
            s = self.sgn(p.team)
            p.p[:] = (s * x * (0.55 if p.i else 1.0) - (0 if p.i else 0), s * y)
            if p.gk:
                p.p[:] = (-s * (PL / 2 - 1.5), 0)
            p.v[:] = 0
            p.stun = p.slide = 0.0

    def kickoff(self, team):
        self.place_formation()
        st = self.team(team)[9]
        st.p[:] = (-self.sgn(team) * 0.8, 0.0)
        b = self.ball
        b.p[:] = 0
        b.v[:] = 0
        b.z = b.vz = 0
        b.owner, b.last, b.target, b.offside = st, st, None, None
        self.setp = None
        if self.human(team):
            self.ctrl = st

    # ================================================================ 入力
    def held(self, *names) -> bool:
        if self.keys is not None and getattr(self.keys, "available", False):
            if any(self.keys.is_down(n) for n in names):
                return True
        return any(self.elapsed - self._ev.get(n, -9) < 0.28 for n in names)

    def move_dir(self) -> np.ndarray:
        dx = (1 if self.held("d") else 0) - (1 if self.held("a") else 0)
        dy = (1 if self.held("s") else 0) - (1 if self.held("w") else 0)
        return norm((dx, dy))

    def flick(self) -> Optional[str]:
        """いま押している (または直前に押した) 矢印キー = ボタンをフリックした向き。"""
        for name, tag in (("Up", "up"), ("Down", "down"), ("Left", "left"), ("Right", "right")):
            if self.held(name):
                return tag
        return None

    def on_key(self, k: int):
        arrows = {82: "Up", 84: "Down", 81: "Left", 83: "Right"}              # waitKey の矢印コード
        ch = chr(k).lower() if 0 <= k < 256 else ""
        if k in arrows:
            self._ev[arrows[k]] = self.elapsed
            return
        if ch:
            self._ev[ch] = self.elapsed
        wasd = {"w": (0.0, -1.0), "s": (0.0, 1.0), "a": (-1.0, 0.0), "d": (1.0, 0.0)}
        if ch in wasd and self.elapsed < self.skill_arm_until and self.ball.owner is self.ctrl \
                and self.ctrl.skill is None:
            d = np.array(wasd[ch])
            if not (self.rs_buf and np.allclose(self.rs_buf[-1][1], d) and self.elapsed - self.rs_buf[-1][0] < 0.15):
                self.rs_buf.append((self.elapsed, d))                 # キーリピートは1回として数える
            self.skill_arm_until = max(self.skill_arm_until, self.elapsed + 0.3)
            return
        if ch == "p":
            self.paused = not self.paused
            return
        if self.paused or self.ended:
            return
        b = self.ball
        mine = b.owner is self.ctrl
        K = KEYS
        fl = self.flick()
        if self.setp is not None and self.setp["team"] == HOME and self.human(HOME):
            if ch == K["pass"]:
                self.take_setpiece("lofted" if fl in ("up", "down") else "pass")
            elif ch == K["through"]:
                self.take_setpiece("lthrough" if fl in ("up", "down") else "through")
            elif ch == K["shoot"] and self.setp["kind"] in ("fk", "pk"):
                self.charge = self.elapsed
                self.charge_flick = fl
            return
        if ch == K["left_tap"]:
            self.left_tap()
            return
        if mine:
            if ch == K["pass"]:
                wide = abs(self.ctrl.p[1]) > 20 and self.sgn(HOME) * self.ctrl.p[0] > PL / 2 - 30   # クロスエリア
                if fl in ("up", "down"):
                    self.kick("lofted", cross=wide)
                elif fl == "left":
                    self.kick("pass", impact=True, cross=wide)
                elif fl == "right":
                    self.kick("lofted", impact=True, cross=wide)
                else:
                    self.kick("pass", cross=wide)
            elif ch == K["through"]:
                if fl in ("up", "down"):
                    self.kick("lthrough")
                elif fl == "left":
                    self.kick("through", impact=True)
                elif fl == "right":
                    self.kick("lthrough", impact=True)
                else:
                    self.kick("through")
            elif ch == K["shoot"] and self.charge is None:
                self.charge = self.elapsed
                self.charge_flick = fl
            return
        # 守備
        if ch == K["slide"] and b.owner is not None and b.owner.team != HOME:
            self.start_slide(self.ctrl)
        elif ch == K["shoot"]:
            self.stand_tackle(self.ctrl)
        elif ch == K["pass"] and fl == "up":
            self.team_press_until = self.elapsed + 4.0                 # マッチアップを上へ: チームプレス
            self.popup("チームプレス", (255, 255, 160))
        elif ch == K["through"] and fl == "down" and self.sgn(HOME) * b.p[0] < 0:
            self.gk_rush_until = self.elapsed + 1.5                    # プレスを下へ (自陣): GK 飛び出し
        elif ch == K["cursor"]:
            if fl is not None:
                self.manual_cursor(np.array({"up": (0.0, -1.0), "down": (0.0, 1.0), "left": (-1.0, 0.0),
                                             "right": (1.0, 0.0)}[fl]))
            else:
                nxt = self.next_cursor()
                if nxt is not None:
                    self.set_ctrl(nxt)

    def left_tap(self):
        """左側 (Q) の2回タップ: 攻撃ではドリブル停止 / ダッシュ中はボディコンタクト, 守備ではショルダーチャージ。"""
        prev = getattr(self, "_q_t", -9.0)
        self._q_t = self.elapsed
        if self.elapsed - prev > 0.35:
            return
        p, b = self.ctrl, self.ball
        if b.owner is p:
            if self.held("Shift_L", "Shift_R"):
                self.shield_until = self.elapsed + 1.5
                self.popup("ボディコンタクト", (255, 255, 160))
            else:
                p.v[:] = 0                                              # その場で止める
        elif b.owner is not None and b.owner.team != p.team and np.linalg.norm(b.owner.p - p.p) < 1.6:
            p.cd = 0.0
            self.try_tackle(p, 30.0, 1.0)                               # ショルダーチャージ (体を当てて奪う)

    def on_gaze(self, p, t):
        self.gaze = p

    # ================================================================ 技 (スキルムーブ)
    def match_skill(self, p: P):
        """右スティック入力列を、進行方向に対する相対方向 (F/B/S/X) に直してコマンド表と照合する。"""
        f = p.face if np.linalg.norm(p.v) < 0.5 else norm(p.v)
        n = np.array([-f[1], f[0]])
        seq, first_side = [], None
        for _, d in self.rs_buf[-3:]:
            a, b_ = float(d @ f), float(d @ n)
            if abs(a) >= abs(b_):
                tok = "F" if a > 0 else "B"
            else:
                side = 1 if b_ > 0 else -1
                if first_side is None:
                    first_side = side
                tok = "S" if side == first_side else "X"
            if not seq or seq[-1] != tok:
                seq.append(tok)
        for cmd, name in SKILL_COMMANDS:
            if tuple(seq[-len(cmd):]) == cmd and len(seq) >= len(cmd):
                # 抜ける側: 最後に弾いた横方向 (無ければ、近い相手と逆側)
                last_side = None
                for _, d in reversed(self.rs_buf):
                    if abs(float(d @ n)) > abs(float(d @ f)):
                        last_side = 1 if float(d @ n) > 0 else -1
                        break
                if last_side is None:
                    opp = min(self.team(1 - p.team), key=lambda q: np.linalg.norm(q.p - p.p))
                    last_side = -1 if float((opp.p - p.p) @ n) > 0 else 1
                return name, f, n * last_side
        return None

    def start_skill(self, p: P, name: str, f: np.ndarray, side: np.ndarray):
        p.skill = {"name": name, "t0": self.elapsed, "f": f.copy(), "n": side.copy(), "judged": False,
                   "dur": SKILL_DUR[name]}
        p.skill_log = [t for t in p.skill_log if self.elapsed - t < 4.0] + [self.elapsed]
        if p.team == HOME:
            self.skill_stats["tried"] += 1
        q = self.to_px(p.p)
        self.popups_at = getattr(self, "popups_at", [])
        self.popups_at.append((self.elapsed, SKILL_NAME[name], p))

    def skill_motion(self, p: P, u: float):
        """技の途中 (u: 0..1) の、ボールの位置 (選手からの相対) と選手の速度。"""
        sk = p.skill
        f, n, name = sk["f"], sk["n"], sk["name"]
        r = P_R + 0.35
        if name == "double_touch":       # 横へ1タッチ -> 斜め前へもう1タッチ
            ball = f * r + n * (1.3 * min(1.0, u / 0.45)) + f * (0.9 * max(0.0, u - 0.45) / 0.55)
            vel = n * 3.5 if u < 0.45 else norm(f * 0.8 + n * 0.6) * DASH * 0.85
        elif name == "elastico":         # 外に見せて (逆側へ少し), 内へ大きく切り返す
            fake = -n * 0.6 * math.sin(math.pi * min(1.0, u / 0.35))
            cut = n * 1.4 * max(0.0, u - 0.35) / 0.65
            ball = f * r + fake + cut
            vel = -n * 1.0 if u < 0.35 else norm(f * 0.5 + n * 0.85) * DASH * 0.8
        elif name == "scissors":         # 体を逆へ振って (ボールは動かさない), 横へ持ち出す
            ball = f * r + (n * 1.0 * max(0.0, u - 0.6) / 0.4)
            vel = -n * 2.0 * math.sin(math.pi * min(1.0, u / 0.6)) if u < 0.6 else norm(f * 0.6 + n * 0.8) * DASH * 0.8
        elif name == "marseille":        # ボールの周りを回転して、体を入れ替える
            ang = 2 * math.pi * u
            ball = (f * math.cos(ang) + n * math.sin(ang)) * r
            vel = n * 2.5 + f * 1.5 * u
        else:                            # drag_back: ボールを引いて向きを変える
            ball = f * r * (1 - 2 * u) + n * 0.3 * u
            vel = -f * 1.5 if u < 0.6 else norm(-f * 0.3 + n) * SPEED * 0.8
        return ball, vel

    def judge_skill(self, p: P):
        """技の決め所: 近くの守備者がつられたか。技の種類・相手の体勢・連発・視線で確率が変わる。"""
        sk = p.skill
        n, f = sk["n"], sk["f"]
        beat_any, read = False, False
        gaze_mod = 0.0
        if p.team == HOME and self.human(HOME) and self.gaze is not None:
            g = self.to_world(self.gaze) - p.p
            side = float(g @ n)
            if side > 2.0:
                gaze_mod = -0.3          # 抜く方向を見ている: 読まれる
            elif side < -2.0:
                gaze_mod = +0.25         # 逆を見ている: 目線フェイント
        spam = 0.2 * max(0, len([t for t in p.skill_log if self.elapsed - t < 3.0]) - 1)
        for q in self.team(1 - p.team):
            d = q.p - p.p
            if np.linalg.norm(d) > 1.8 or q.gk:
                continue
            prob = SKILL_BASE[sk["name"]] + gaze_mod - spam
            rush = float(q.v @ norm(-d))                          # 勢いよく寄せてきている
            prob += 0.15 if rush > 3 else (-0.1 if np.linalg.norm(q.v) < 1 and float(norm(d) @ f) > 0.7 else 0)
            if not self.human(q.team) or q is not self.ctrl or not self.held(KEYS["pass"]):
                pass
            else:
                prob -= 0.15                                      # マッチアップで構えている人間は引っかかりにくい
            if self.rng.random() < prob:
                q.stun = max(q.stun, 0.7)
                beat_any = True
            else:
                read = True
                if self.rng.random() < 0.5 and self.ball.owner is p:
                    p.skill = None
                    self.ball.owner = q
                    self.ball.last = q
                    q.cd = 0.6
                    if self.human(q.team):
                        self.ctrl = q
                    self.popup("止められた!" if p.team == HOME else "ボール奪取!",
                               (90, 90, 255) if p.team == HOME else (90, 255, 120))
                    return
        if beat_any:
            if p.team == HOME:
                self.skill_stats["beat"] += 1
                self.popup("抜いた!" + (" (目線フェイント)" if gaze_mod > 0 else ""), (0, 220, 255))
            else:
                self.popup("抜かれた…", (90, 90, 255))
        elif read and p.team == HOME:
            self.popup("読まれた!", (90, 90, 255))

    def run_skill(self, p: P, dt: float):
        sk = p.skill
        u = (self.elapsed - sk["t0"]) / sk["dur"]
        if not sk["judged"] and u >= 0.4:
            sk["judged"] = True
            self.judge_skill(p)
            if p.skill is None:
                return
        if u >= 1.0 or self.ball.owner is not p:
            p.skill = None
            return
        _, vel = self.skill_motion(p, u)
        p.v = vel

    # ================================================================ 視線を読む
    def update_attention(self, dt):
        g = self.to_world(self.gaze) if self.gaze is not None else None
        carrier = self.ball.owner
        best, bd = None, 4.0
        if g is not None and carrier is not None and carrier.team == HOME:
            for p in self.team(HOME):
                if p is carrier:
                    continue
                d = float(np.linalg.norm(p.p - g))
                if d < bd:
                    best, bd = p, d
        for p in self.team(HOME):
            a = self.attn.get(id(p), 0.0) * math.exp(-dt / 0.7) + (dt if p is best else 0.0)
            self.attn[id(p)] = min(a, 1.5)
        cand = max(self.team(HOME), key=lambda p: self.attn.get(id(p), 0))
        self.watched = cand if self.attn[id(cand)] > 0.3 and cand is not carrier else None
        gl = 0.0
        if g is not None and g[0] > PL / 2 - 20:
            gl = float(np.clip(g[1] / (GOAL_W / 2), -1, 1))
        self.goal_look += (gl - self.goal_look) * min(1.0, dt * 3)

    # ================================================================ キック
    def pick_receiver(self, c: P, d: np.ndarray) -> Optional[P]:
        best, bs = None, -1e9
        for p in self.team(c.team):
            if p is c:
                continue
            v = p.p - c.p
            dist = float(np.linalg.norm(v))
            if dist < 2:
                continue
            s = 2.2 * float(norm(v) @ d) - dist / 45.0
            if p.gk:
                s -= 1.0
            if s > bs:
                best, bs = p, s
        return best

    def second_last_x(self, team) -> float:
        """team から見た相手の、後ろから2人目の x (攻撃方向の座標)。"""
        s = self.sgn(team)
        xs = sorted((s * q.p[0] for q in self.team(1 - team)), reverse=True)
        return xs[1]

    def kick(self, kind, c: Optional[P] = None, target: Optional[P] = None, power: float = 0.7, aim_y=None,
             style: str = "", impact: bool = False, cross: bool = False):
        b = self.ball
        c = c or b.owner
        if c is None:
            return
        human = self.human(c.team) and c is self.ctrl
        d = self.move_dir() if human else np.zeros(2)
        if not d.any():
            d = c.face.copy()
        b.nolook = False
        b.offside = None
        s = self.sgn(c.team)
        if kind == "shot":
            g = self.opp_goal(c.team)
            if aim_y is None:
                aim_y = float(np.clip(d[1], -1, 1)) * (GOAL_W / 2 - 0.5)
            err = (0.4 + 2.2 * max(0.0, power - 0.75)) * self.rng.gauss(0, 1)     # 強すぎるとぶれる
            if style == "impact":                                   # インパクトシュート: 強烈
                power = min(1.0, power + 0.15)
            if style == "control":                                  # コントロールシュート: 正確だが遅い
                err *= 0.4
                power = min(power, 0.7)
            tgt = np.array([g[0], aim_y + err])
            u = norm(tgt - c.p)
            spd = 18 + 14 * power
            dist = float(np.linalg.norm(tgt - c.p))
            if style == "loop":                                     # ループシュート: キーパーの頭上を越す
                tf = float(np.clip(dist / 14.0, 0.8, 2.0))
                b.v = u * (dist / tf) * 0.95
                b.z, b.vz = 0.1, 0.5 * GRAV * tf * 0.92
            else:
                b.v = u * spd
                tf = dist / spd
                peak = 0.3 + 3.2 * max(0.0, power - 0.55) + abs(self.rng.gauss(0, 0.25))   # 強いほど浮く
                b.z, b.vz = 0.1, (peak + 0.5 * GRAV * tf * tf) / max(tf, 0.1) * 0.5
            b.target = None
            if human and abs(self.goal_look) > 0.35 and np.sign(self.goal_look) != np.sign(aim_y) and abs(aim_y) > 1:
                b.nolook = True
                self.popup("NO LOOK SHOT!", (0, 220, 255))
        else:
            tgt_p = target
            if tgt_p is None and cross:          # クロス: ゴール前にいる味方へ
                box = [m for m in self.team(c.team) if m is not c and abs(m.p[1]) < BOX_W / 2
                       and s * m.p[0] > PL / 2 - BOX_L - 2]
                tgt_p = min(box, key=lambda m: abs(m.p[1])) if box else None
            tgt_p = tgt_p or self.pick_receiver(c, d)
            if tgt_p is None:
                return
            lead = {"pass": 0.4, "lofted": 0.9, "through": 1.0, "lthrough": 1.1}[kind]
            dest = tgt_p.p + tgt_p.v * lead
            if kind in ("through", "lthrough"):
                dest = dest + np.array([s * 7.0, 0.0])
            dest[0] = np.clip(dest[0], -PL / 2 + 1, PL / 2 - 1)
            dest[1] = np.clip(dest[1], -PW / 2 + 1, PW / 2 - 1)
            dist = float(np.linalg.norm(dest - c.p))
            u = norm(dest - c.p)
            if kind in ("lofted", "lthrough"):
                T = float(np.clip(dist / 20.0, 0.7, 2.2))
                b.v = u * (dist / T)
                b.z, b.vz = 0.1, 0.5 * GRAV * T
            else:
                v0 = math.sqrt(2 * FRICTION * dist) + 3.5
                b.v = u * min(v0, 26.0)
                b.z = b.vz = 0.0
            if impact:                            # インパクトパス: 速く鋭い (カットされにくい)
                b.v = b.v * 1.3
            b.target = tgt_p
            # オフサイド: 受け手が相手陣内で、ボールと後ろから2人目の相手より前にいる
            rx = s * tgt_p.p[0]
            if rx > 0 and rx > s * c.p[0] and rx > self.second_last_x(c.team) + 0.3:
                b.offside = tgt_p
            if c.team == HOME and self.human(HOME):
                self.stats["passes"] += 1
                if self.watched is not None and tgt_p is not self.watched and self.attn.get(id(self.watched), 0) > 0.45:
                    b.nolook = True
                    self.stats["nolook"] += 1
                    self.popup("NO LOOK PASS!", (0, 220, 255))
                    for q in self.team(AWAY):
                        q.stun = max(q.stun, 0.4)
                elif self.watched is tgt_p:
                    self.stats["read"] += 1
        b.kind = kind
        b.owner = None
        b.kicker = b.last = c
        b.kick_t = self.elapsed
        b.p = c.p + norm(b.v) * (P_R + 0.3)
        self.charge = None

    def start_slide(self, p: P):
        if p.cd > 0 or p.slide > 0:
            return
        p.slide, p.cd = 0.45, 1.4
        p.v = p.face * 10.0

    def try_tackle(self, p: P, rate: float, dt: float):
        """立ったままの奪取 (マッチアップ / CPU の寄せ)。"""
        b = self.ball
        if b.owner is None or b.owner.team == p.team or p.cd > 0 or b.owner.skill is not None:
            return
        if self.human(b.owner.team) and b.owner is self.ctrl and self.elapsed < getattr(self, "shield_until", -1):
            rate *= 0.5                                       # ボディコンタクトでボールを守る
        if np.linalg.norm(b.p - p.p) < 1.3 and self.rng.random() < rate * dt:
            p.cd = 0.9
            if self.rng.random() < 0.55:
                b.owner.stun = 0.5
                b.owner = p
                b.last = p
                if self.human(p.team):
                    self.ctrl = p
                    self.popup("ボール奪取!", (90, 255, 120))

    def stand_tackle(self, p: P):
        """□ (守備): 相手がドリブル中ならタックル、こぼれ球が近ければクリア。"""
        b = self.ball
        if p.cd > 0:
            return
        p.cd = 0.7
        if b.owner is not None and b.owner.team != p.team and b.owner.skill is None:
            if np.linalg.norm(b.p - p.p) < 1.6:
                if self.rng.random() < 0.55:
                    b.owner.stun = 0.5
                    b.owner = p
                    b.last = p
                    self.popup("ボール奪取!", (90, 255, 120))
        elif b.owner is None and np.linalg.norm(b.p - p.p) < 2.0 and b.z < 1.5:
            d = norm(self.opp_goal(p.team) - p.p + np.array([0, self.rng.uniform(-15, 15)]))
            b.v = d * 24.0
            b.z, b.vz = 0.1, 7.0
            b.kicker = b.last = p
            b.kick_t = self.elapsed
            b.kind, b.target, b.offside = "clear", None, None
            self.popup("クリア", (220, 220, 220))

    def defend_score(self, p: P) -> float:
        """守備でカーソルを渡す選手の良さ (小さいほど良い): ボールに近く、ボールより自陣ゴール側にいる選手。"""
        b = self.ball
        s = self.sgn(p.team)
        d = float(np.linalg.norm(p.p - b.p))
        goal_side = s * p.p[0] < s * b.p[0] + 1.0
        return d + (0.0 if goal_side else 12.0) + 0.1 * abs(p.p[1] - b.p[1])

    def next_cursor(self) -> Optional[P]:
        """L1 を押したときに切り替わる選手 (常に画面に表示する)。"""
        cands = [p for p in self.team(HOME) if p is not self.ctrl and not p.gk]
        if not cands:
            return None
        if self.ball.owner is None and self.ball.target is not None and self.ball.target.team == HOME \
                and self.ball.target is not self.ctrl:
            return self.ball.target
        return min(cands, key=self.defend_score)

    def manual_cursor(self, d: np.ndarray):
        """R スティック (守備): 今の選手から見て、その方向にいる味方へ。"""
        best, bs = None, -1e9
        for p in self.team(HOME):
            if p is self.ctrl or p.gk:
                continue
            v = p.p - self.ctrl.p
            dist = float(np.linalg.norm(v))
            cosv = float(norm(v) @ d)
            if cosv < 0.5:
                continue
            sc = cosv - dist / 40.0
            if sc > bs:
                best, bs = p, sc
        if best is not None:
            self.set_ctrl(best)

    def set_ctrl(self, p: P):
        self.ctrl = p
        self._switch_t = self.elapsed

    def switch_player(self):
        cands = [p for p in self.team(HOME) if p is not self.ctrl and not p.gk]
        if cands:
            self.ctrl = min(cands, key=lambda p: np.linalg.norm(p.p - self.ball.p))

    # ================================================================ セットプレー
    def start_setpiece(self, kind: str, team: int, pos, note: str):
        b = self.ball
        b.owner = None
        b.v[:] = 0
        b.z = b.vz = 0
        b.p = np.array(pos, float)
        b.target = b.offside = None
        others = sorted([p for p in self.team(team) if not p.gk or kind in ("gk", "fk")],
                        key=lambda p: np.linalg.norm(p.p - b.p))
        taker = others[0]
        if kind == "gk":
            taker = self.team(team)[0]
        if kind == "pk":
            taker = self.team(team)[9]
            for p in self.pl:            # PK: 他の選手はエリア外へ
                if p is not taker and not p.gk:
                    p.p[0] = np.clip(p.p[0], -PL / 2 + BOX_L + 1, PL / 2 - BOX_L - 1)
            gk = self.team(1 - team)[0]
            gk.p[:] = (self.sgn(team) * (PL / 2 - 0.5), 0)
        back = norm(b.p - self.opp_goal(team)) if kind != "throw" else np.array([0.0, np.sign(b.p[1])])
        taker.p = b.p + back * (P_R + 0.4)
        taker.v[:] = 0
        taker.face = -back
        self.setp = {"kind": kind, "team": team, "t0": self.elapsed, "taker": taker}
        if self.human(team):
            self.ctrl = taker
        self.popup(note, (255, 255, 255))

    def take_setpiece(self, how: str, power: float = 0.75):
        sp = self.setp
        if sp is None:
            return
        taker = sp["taker"]
        self.ball.owner = taker
        self.setp = None
        if sp["kind"] == "pk" or (sp["kind"] == "fk" and how == "shot"):
            self.kick("shot", taker, power=power)
        elif sp["kind"] == "corner" and how == "pass":
            self.kick("lofted", taker)
        else:
            self.kick(how, taker)
        if sp["kind"] == "throw":
            self.ball.offside = None          # スローインにオフサイドはない

    def cpu_setpiece(self):
        sp = self.setp
        if sp is None or self.human(sp["team"]) or self.elapsed - sp["t0"] < 1.3:
            return
        if sp["kind"] == "pk":
            self.ball.owner = sp["taker"]
            self.setp = None
            self.kick("shot", sp["taker"], power=0.8, aim_y=self.rng.choice([-1, 1]) * self.rng.uniform(1.5, 3.2))
            return
        how = "lofted" if sp["kind"] in ("corner", "gk") else "pass"
        taker = sp["taker"]
        mates = [p for p in self.team(sp["team"]) if p is not taker]
        tgt = max(mates, key=lambda m: self.lane_clear(taker.p, m.p, sp["team"]) - 0.02 * np.linalg.norm(m.p - taker.p))
        self.ball.owner = taker
        self.setp = None
        self.kick(how, taker, target=tgt)

    # ================================================================ AI
    def lane_clear(self, a, b, team) -> float:
        ab = b - a
        L2 = float(ab @ ab) + 1e-9
        best = 99.0
        for p in self.team(1 - team):
            tt = float(np.clip((p.p - a) @ ab / L2, 0, 1))
            best = min(best, float(np.linalg.norm(a + tt * ab - p.p)))
        return best

    def shape_targets(self) -> Dict[int, np.ndarray]:
        """チームの陣形: ボール位置に応じて全体が押し上げ/後退/横スライドする。"""
        b = self.ball
        att = b.owner.team if b.owner is not None else (b.last.team if b.last is not None else HOME)
        tg = {}
        for team in (HOME, AWAY):
            s = self.sgn(team)
            bx = s * b.p[0]                                      # 自チームの攻撃方向で見たボールの x
            attacking = att == team
            for p in self.team(team):
                (fx, fy), role = FORM[p.i]
                if p.gk:
                    gx = -s * (PL / 2 - 1.5)
                    gy = float(np.clip(b.p[1] * 0.15, -3, 3))
                    if team == AWAY and self.human(HOME):
                        gy = float(np.clip(gy + self.goal_look * 1.6, -3.2, 3.2))
                    tg[id(p)] = np.array([gx, gy])
                    if team == HOME and self.elapsed < getattr(self, "gk_rush_until", -1):
                        tg[id(p)] = b.p.copy()                      # GK 飛び出し
                    continue
                push = (bx * 0.55 + (14 if attacking else -2))
                if not attacking and team == HOME and self.elapsed < getattr(self, "team_press_until", -1):
                    push += 8                                       # チームプレス: 全体を押し上げる
                x = float(np.clip(fx + push, -PL / 2 + 6, PL / 2 - 4))
                if not attacking:
                    x = min(x, bx + 4 if role not in ("LW", "RW", "ST") else bx + 12)
                spread = 1.15 if attacking else 0.8
                y = fy * spread + b.p[1] * s * 0.3 * s
                if attacking and role in ("LW", "RW", "ST"):
                    lim = self.second_last_x(team) - 0.5          # 前線はオフサイドラインの手前で待つ
                    x = min(x + 6, lim)
                tg[id(p)] = np.array([s * x, float(np.clip(y, -PW / 2 + 2, PW / 2 - 2))])
        # 守備側: 最も近い選手が寄せる。視線を読む CPU はパスコースに入る
        self.reader = None
        for team in (HOME, AWAY):
            if att == team or b.owner is None:
                continue
            defs = [p for p in self.team(team) if not p.gk]
            near = min(defs, key=lambda p: np.linalg.norm(p.p - b.p))
            cur = self.presser.get(team)
            if cur is None or cur not in defs or (
                    np.linalg.norm(near.p - b.p) < np.linalg.norm(cur.p - b.p) - 3.0):
                cur = near                         # 3m 以上近い選手が出るまで、寄せる役は入れ替えない
            self.presser[team] = cur
            presser = cur
            tg[id(presser)] = b.p + b.owner.v * 0.3
            if team == HOME and self.elapsed < getattr(self, "team_press_until", -1):
                second_p = min((p for p in defs if p is not presser), key=lambda p: np.linalg.norm(p.p - b.p))
                tg[id(second_p)] = b.p.copy()                       # チームプレス: 2人目も寄せる
            if team == AWAY and b.owner.team == HOME and self.human(HOME) and self.watched is not None:
                lane = b.owner.p + (self.watched.p - b.owner.p) * 0.5
                rd = min((p for p in defs if p is not presser), key=lambda p: np.linalg.norm(p.p - lane))
                tg[id(rd)] = lane
                self.reader = rd
        return tg

    def ball_future(self, horizon: float = 3.0, step: float = 0.1):
        """今の速度から、ボールが今後どこを通るか (時刻, 位置, 高さ) を予測する (update_ball と同じ物理)。"""
        b = self.ball
        p, v, z, vz = b.p.copy(), b.v.copy(), b.z, b.vz
        out = []
        t = 0.0
        while t < horizon:
            t += step
            if z > 0 or vz > 0:
                vz -= GRAV * step
                z += vz * step
                if z <= 0:
                    z, vz = 0.0, (-vz * 0.35 if abs(vz) > 2.5 else 0.0)
                    v = v * 0.75
            else:
                sp = float(np.linalg.norm(v))
                if sp > 0:
                    v = v * max(0.0, sp - FRICTION * step) / sp
            p = p + v * step
            out.append((t, p.copy(), z))
        return out

    def plan_chasers(self):
        """ボールが誰のものでもない時: 各チームで一番早く追いつける選手を、その地点へ向かわせる。
        パスの受け手は自分が追う (パスから離れていかない)。"""
        self.chase = {}
        b = self.ball
        if b.owner is not None or self.setp is not None:
            return
        fut = self.ball_future()
        for team in (HOME, AWAY):
            best = None
            for p in self.team(team):
                if p.gk and not (abs(b.p[0]) > PL / 2 - BOX_L and np.sign(b.p[0]) == -self.sgn(team)):
                    continue
                if p is self.ctrl and self.human(team):
                    continue
                for (t, q, z) in fut:
                    if z < 1.9 and np.linalg.norm(q - p.p) <= DASH * 0.9 * t + CONTROL_R:
                        if best is None or t < best[0]:
                            best = (t, p, q)
                        break
            if b.target is not None and b.target.team == team and not (b.target is self.ctrl and self.human(team)):
                # パスの受け手: 到着点 (受け手に一番近い軌道上の点) へ
                q = min(fut, key=lambda f: np.linalg.norm(f[1] - b.target.p))[1]
                self.chase[id(b.target)] = (q, True)
            elif best is not None:
                self.chase[id(best[1])] = (best[2], True)
            elif fut:
                p = min((p for p in self.team(team) if not p.gk), key=lambda p: np.linalg.norm(p.p - fut[-1][1]))
                self.chase[id(p)] = (fut[-1][1], True)

    @staticmethod
    def steer(p: P, desired: np.ndarray, acc: float, dt: float):
        dv = desired - p.v
        n = float(np.linalg.norm(dv))
        lim = acc * dt
        p.v = p.v + (dv if n <= lim else dv / n * lim)

    def ai_speed(self, dist: float, urgent: bool) -> float:
        if dist < 0.6:
            return 0.0
        if urgent:
            top = DASH * 0.92
        elif dist > 12:
            top = SPEED * 0.85          # ジョグ
        elif dist > 3:
            top = SPEED * 0.6
        else:
            top = SPEED * 0.4           # 歩いて位置を微調整
        return top * min(1.0, dist / 2.5)

    def cpu_carrier(self, c: P, dt):
        """CPU のボール保持者。DECIDE_EVERY 秒ごとに、シュート / パス / ドリブル方向を決める。"""
        if c.skill is not None:
            return
        if self.elapsed >= c.next_decide or c.ddir is None:
            c.next_decide = self.elapsed + DECIDE_EVERY * self.rng.uniform(0.8, 1.2)
            if self.cpu_decide(c):
                return
        self.steer(c, c.ddir * SPEED * DRIBBLE, ACC_AI, dt)

    def cpu_decide(self, c: P) -> bool:
        team = c.team
        goal = self.opp_goal(team)
        s = self.sgn(team)
        opp = self.team(1 - team)
        nd = min(float(np.linalg.norm(q.p - c.p)) for q in opp)
        dg = float(np.linalg.norm(goal - c.p))
        # シュート: ゴールに近く、角度があるとき
        if abs(c.p[1]) < 20 and (dg < 16 and self.rng.random() < 0.6 or dg < 24 and self.rng.random() < 0.15):
            self.kick("shot", c, power=self.rng.uniform(0.55, 0.85),
                      aim_y=self.rng.uniform(-GOAL_W / 2 + 0.6, GOAL_W / 2 - 0.6))
            return True
        # パス: 寄せられている時は高い確率で、そうでなくても時々。コースの空いた味方へ
        if nd < 3.0 and self.rng.random() < 0.6 or self.rng.random() < 0.12:
            best, bs = None, -1e9
            for m in self.team(team):
                if m is c or m.gk:
                    continue
                clear = self.lane_clear(c.p, m.p, team)
                if clear < 2.0:
                    continue
                sc = clear * 0.3 + 0.06 * s * (m.p[0] - c.p[0]) - 0.02 * np.linalg.norm(m.p - c.p)
                if s * m.p[0] > self.second_last_x(team) + 0.3 and s * m.p[0] > 0:
                    sc -= 5                                        # オフサイド位置は避ける
                if sc > bs:
                    best, bs = m, sc
            if best is not None:
                far = np.linalg.norm(best.p - c.p) > 28
                wide = abs(c.p[1]) > 22 and s * c.p[0] > PL / 2 - 25
                self.kick("lofted" if (far or wide) else "pass", c, target=best)
                return True
        # 目の前に相手がいたら、ときどき技で抜きにかかる
        front = [q for q in opp if np.linalg.norm(q.p - c.p) < 2.2 and float(norm(q.p - c.p) @ norm(goal - c.p)) > 0.4]
        if front and self.rng.random() < 0.3 and not [t for t in c.skill_log if self.elapsed - t < 2.5]:
            f = norm(goal - c.p)
            n = np.array([-f[1], f[0]])
            side = n if float((front[0].p - c.p) @ n) < 0 else -n
            self.start_skill(c, self.rng.choice(["double_touch", "elastico", "scissors", "marseille"]), f, side)
            return True
        # ドリブル: ゴール方向を中心に7方向を、前進量と空いている空間で評価して選ぶ
        g = norm(goal - c.p)
        best, bs = None, -1e9
        for ang in (-90, -60, -30, 0, 30, 60, 90):
            a = math.radians(ang)
            d = np.array([g[0] * math.cos(a) - g[1] * math.sin(a), g[0] * math.sin(a) + g[1] * math.cos(a)])
            ahead = c.p + d * 4.0
            space = min(6.0, min(float(np.linalg.norm(q.p + q.v * 0.6 - ahead)) for q in opp))
            sc = 1.0 * float(d @ g) + 1.2 * space / 6.0
            if abs(ahead[1]) > PW / 2 - 2 or abs(ahead[0]) > PL / 2 - 1:
                sc -= 2.0                                          # タッチラインに向かわない
            if c.ddir is not None:
                sc += 0.25 * float(d @ c.ddir)                     # 急に向きを変えすぎない
            if sc > bs:
                best, bs = d, sc
        c.ddir = best
        return False

    # ================================================================ 更新
    def update(self, t):
        if self.t_last is None:
            self.t_last = t
        dt = min(0.05, t - self.t_last)
        self.t_last = t
        if self.paused or self.ended or dt <= 0:
            return
        self.elapsed += dt
        if self.elapsed >= MATCH_TIME:
            self.ended = True
            self.request = ("result", ("soccer11", ["%d - %d" % tuple(self.score),
                                                    "ノールックパス %d / 読まれたパス %d / 技で抜いた %d / %d 回" % (
                                                        self.stats["nolook"], self.stats["read"],
                                                        self.skill_stats["beat"], self.skill_stats["tried"])]))
            return
        b = self.ball
        self.update_attention(dt)
        if self.setp is not None:
            self.cpu_setpiece()
            # シュートの溜め (FK / PK)
            if self.charge is not None and not self.held(KEYS["shoot"]):
                pw = min(1.0, (self.elapsed - self.charge) / 1.0)
                self.take_setpiece("shot", power=max(0.3, pw))
            self.follow_camera(dt)
            return
        # シュートの溜め: シュートボタンを離した瞬間に打つ。フリックの向き: ↑ ループ / ↓ コントロール / ←→ インパクト
        if self.charge is not None and b.owner is self.ctrl and not self.held(KEYS["shoot"]):
            pw = max(0.3, min(1.0, (self.elapsed - self.charge) / 1.0))
            fl = getattr(self, "charge_flick", None) or self.flick()
            style = {"up": "loop", "down": "control", "left": "impact", "right": "impact"}.get(fl, "")
            self.kick("shot", self.ctrl, power=pw, style=style)
        if self.charge is not None and b.owner is not self.ctrl:
            self.charge = None
        # ダッシュボタン (Shift) の短押しを検出 -> 技の入力受付を開始 (押しっぱなしはダッシュ)
        if self.keys is not None and getattr(self.keys, "available", False):
            sh = self.keys.is_down("Shift_L") or self.keys.is_down("Shift_R")
            if sh and self._shift_t is None:
                self._shift_t = self.elapsed
            elif not sh and self._shift_t is not None:
                if self.elapsed - self._shift_t < 0.25 and b.owner is self.ctrl:
                    self.skill_arm_until = self.elapsed + 0.6
                    self.rs_buf = []
                self._shift_t = None
        # 技の入力: 最後に弾いてから 0.18 秒で確定して照合 (2〜3回の連続入力を待つ)
        if self.rs_buf and self.elapsed - self.rs_buf[-1][0] > 0.18:
            if b.owner is self.ctrl and self.ctrl.skill is None:
                m = self.match_skill(self.ctrl)
                if m is not None:
                    self.start_skill(self.ctrl, *m)
            self.rs_buf = []
        self.rs_buf = [x for x in self.rs_buf if self.elapsed - x[0] < 0.6]
        tg = self.shape_targets()
        self.plan_chasers()
        # 操作選手の自動切り替え (守備では「ボールに近く、自陣ゴール側にいる」選手へ。頻繁には変えない)
        if b.owner is not None and b.owner.team == HOME:
            self.ctrl = b.owner
        elif self.ctrl.gk:
            self.set_ctrl(self.next_cursor() or self.ctrl)
        elif b.owner is None and b.target is not None and b.target.team == HOME:
            self.ctrl = b.target
        elif self.elapsed - getattr(self, "_switch_t", -9) > 1.0:
            best = self.next_cursor()
            if best is not None and self.defend_score(self.ctrl) > self.defend_score(best) + 8.0:
                self.set_ctrl(best)
        second = None
        for p in self.pl:
            p.cd = max(0.0, p.cd - dt)
            if p.slide > 0:
                p.slide -= dt
                self.slide_contact(p)
                p.v *= 0.93
            elif p.stun > 0:
                p.stun -= dt
                p.v *= 0.85
            elif p.skill is not None:
                self.run_skill(p, dt)
            elif p is self.ctrl and self.human(HOME):
                d = self.move_dir()
                sp = DASH if self.held("Shift_L", "Shift_R") else SPEED
                if b.owner is p:
                    sp *= DRIBBLE * (0.8 if self.elapsed < getattr(self, "shield_until", -1) else 1.0)
                if self.held(KEYS["through"]) and b.owner is not None and b.owner.team == AWAY:
                    d = norm(b.owner.p - p.p)                     # プレス (長押し): ボールに寄せる
                    sp = DASH * 0.95
                    self.try_tackle(p, 1.0, dt)
                if self.held(KEYS["pass"]) and b.owner is not None and b.owner.team == AWAY:
                    # マッチアップ: ボール保持者とゴールの間に入り、間合いを詰める
                    goal = -self.opp_goal(HOME)
                    spot = b.owner.p + norm(goal - b.owner.p) * 1.2
                    d = norm(spot - p.p) if not d.any() else norm(norm(spot - p.p) + 0.5 * d)
                    sp = SPEED * 0.95
                    self.try_tackle(p, 1.4, dt)
                self.steer(p, d * sp, ACC_HUMAN, dt)
            elif p is b.owner and not self.human(p.team):
                self.cpu_carrier(p, dt)
                if b.owner is not p:
                    continue
            elif p is b.owner:
                self.steer(p, np.zeros(2), ACC_HUMAN, dt)
            else:
                urgent = False
                if id(p) in self.chase:
                    target, urgent = self.chase[id(p)]
                else:
                    target = tg[id(p)]
                    if p is second or p is self.presser.get(p.team):
                        urgent = True
                    if p is second:
                        target = b.p
                v = target - p.p
                dist = float(np.linalg.norm(v))
                self.steer(p, norm(v) * self.ai_speed(dist, urgent), ACC_AI, dt)
                if b.owner is not None and b.owner.team != p.team and dist < 1.6:
                    self.try_tackle(p, 1.0 if not self.human(p.team) else 0.6, dt)
            p.p += p.v * dt
            p.p[0] = np.clip(p.p[0], -PL / 2 - 2, PL / 2 + 2)
            p.p[1] = np.clip(p.p[1], -PW / 2 - 2, PW / 2 + 2)
            if np.linalg.norm(p.v) > 0.3 and p.slide <= 0 and p.skill is None:
                p.face = norm(p.v)
        self.update_ball(dt)
        self.follow_camera(dt)

    def slide_contact(self, p: P):
        b = self.ball
        if b.owner is None or b.owner.team == p.team:
            if b.owner is None and np.linalg.norm(b.p - p.p) < 1.2 and b.z < 0.5:
                b.v = p.face * 6
                b.last = p
            return
        o = b.owner
        if np.linalg.norm(b.p - p.p) < 1.0:                     # 先にボールに触れた: クリーン
            b.owner = None
            b.v = p.face * 7 + o.v * 0.3
            b.last = p
            p.slide = 0
            self.popup("ナイスタックル!", (90, 255, 120)) if self.human(p.team) else None
        elif np.linalg.norm(o.p - p.p) < 1.2:                   # 先に足に当たった: ファウル
            p.slide = 0
            o.stun = 0.8
            self.foul(p, o)

    def foul(self, fouler: P, victim: P):
        self.stats["fouls"] += 1
        team = victim.team
        s = self.sgn(team)
        in_box = s * victim.p[0] > PL / 2 - BOX_L and abs(victim.p[1]) < BOX_W / 2
        if in_box:
            self.start_setpiece("pk", team, (s * (PL / 2 - PEN_SPOT), 0.0), "ファウル! PK")
        else:
            self.start_setpiece("fk", team, victim.p.copy(), "ファウル! フリーキック")

    def update_ball(self, dt):
        b = self.ball
        if b.owner is not None:
            o = b.owner
            if o.skill is not None:
                u = min(1.0, (self.elapsed - o.skill["t0"]) / o.skill["dur"])
                b.p = o.p + self.skill_motion(o, u)[0]
                b.v = o.v.copy()
                b.z = 0
                return
            b.p = o.p + o.face * (P_R + 0.35)
            b.v = o.v.copy()
            b.z = 0
            return
        if b.z > 0 or b.vz > 0:
            b.vz -= GRAV * dt
            b.z += b.vz * dt
            if b.z <= 0:
                b.z = 0
                b.vz = -b.vz * 0.35 if abs(b.vz) > 2.5 else 0
                b.v *= 0.75
        else:
            sp = float(np.linalg.norm(b.v))
            if sp > 0:
                b.v *= max(0.0, sp - FRICTION * dt) / sp
        b.p += b.v * dt
        # ゴール・ゴールライン
        if abs(b.p[0]) >= PL / 2:
            side = 1 if b.p[0] > 0 else -1          # +x 側のゴールは HOME が攻める
            att = HOME if side == 1 else AWAY
            if abs(b.p[1]) < GOAL_W / 2 and b.z < GOAL_H:
                self.score[att] += 1
                self.popup("GOAL!!" if self.human(att) else "失点…", (90, 255, 120) if self.human(att) else (90, 90, 255))
                self.kickoff(1 - att)
                return
            last_team = b.last.team if b.last is not None else att
            if last_team == att:
                self.start_setpiece("gk", 1 - att, (side * (PL / 2 - SIX_L), side * 0 + self.rng.choice([-1, 1]) * 4),
                                    "ゴールキック")
            else:
                self.start_setpiece("corner", att, (side * (PL / 2 - 0.5), np.sign(b.p[1]) * (PW / 2 - 0.5)),
                                    "コーナーキック")
            return
        if abs(b.p[1]) >= PW / 2:
            last_team = b.last.team if b.last is not None else HOME
            self.start_setpiece("throw", 1 - last_team,
                                (float(np.clip(b.p[0], -PL / 2 + 1, PL / 2 - 1)), np.sign(b.p[1]) * (PW / 2 - 0.3)),
                                "スローイン")
            return
        self.try_receive()

    def try_receive(self):
        b = self.ball
        sp = float(np.linalg.norm(b.v))
        for p in sorted(self.pl, key=lambda q: np.linalg.norm(q.p - b.p)):
            d = float(np.linalg.norm(p.p - b.p))
            if d > 3:
                break
            if p is b.kicker and self.elapsed - b.kick_t < 0.3:
                continue
            if p.stun > 0 or p.slide > 0:
                continue
            mine = b.kicker is not None and p.team == b.kicker.team
            reach = CONTROL_R
            hmax = 1.9                        # 頭で触れる高さ
            if p.gk and abs(p.p[0]) > PL / 2 - BOX_L:
                reach, hmax = 1.7, 2.6
                if b.kind == "shot" and b.nolook and not mine:
                    reach = 0.9
            if b.z > hmax:
                continue
            if not mine and b.kind in ("pass", "through", "lofted", "lthrough") and sp > 5:
                if b.nolook:
                    reach *= 0.55
                elif b.target is self.watched and self.watched is not None and p.team == AWAY:
                    reach *= 1.2
            if d < reach and (sp < 24 or not mine or p.gk):
                # オフサイド: キックの瞬間にオフサイド位置だった味方が受けた
                if mine and b.offside is p:
                    self.stats["offside"] += 1 if p.team == HOME else 0
                    self.start_setpiece("fk", 1 - p.team, p.p.copy(), "オフサイド")
                    return
                if not mine and b.kicker is not None and b.kicker.team == HOME and b.kind != "shot":
                    self.stats["intercepted"] += 1
                    self.popup("読まれていた!" if (b.target is self.watched and self.watched) else "カットされた!",
                               (90, 90, 255))
                if p.gk and not mine and b.kind == "shot":
                    self.popup("セーブ!" if p.team == AWAY else "ナイスセーブ!", (200, 200, 255))
                b.owner = p
                b.last = p
                b.v[:] = 0
                b.z = b.vz = 0
                b.target = b.offside = None
                if self.human(p.team):
                    self.ctrl = p
                return

    def follow_camera(self, dt):
        half_w = self.W / 2 / self.scale
        half_h = self.H * 0.52 / self.scale
        tgt = np.array([np.clip(self.ball.p[0], -PL / 2 - 4 + half_w, PL / 2 + 4 - half_w),
                        np.clip(self.ball.p[1], -PW / 2 - 4 + half_h, PW / 2 + 4 - half_h)])
        self.cam += (tgt - self.cam) * min(1.0, dt * 4)

    # ================================================================ 描画
    def render(self, c, t, ring):
        self.update(t)
        W, H = self.W, self.H
        self.blit_pitch(c)
        b = self.ball
        # 読まれているパスコース
        if b.owner is not None and b.owner.team == HOME and self.watched is not None and self.human(HOME):
            a, z = self.to_px(b.owner.p), self.to_px(self.watched.p)
            for i in range(0, 16, 2):
                p0 = (a[0] + (z[0] - a[0]) * i // 16, a[1] + (z[1] - a[1]) * i // 16)
                p1 = (a[0] + (z[0] - a[0]) * (i + 1) // 16, a[1] + (z[1] - a[1]) * (i + 1) // 16)
                cv2.line(c, p0, p1, (60, 60, 255), 3, cv2.LINE_AA)
            if self.reader is not None:
                q = self.to_px(self.reader.p)
                JT.draw(c, "読んでる!", (q[0], q[1] - 34), 20, (90, 90, 255))
        rad = max(6, int(P_R * self.scale * 1.1))
        defending = self.human(HOME) and (b.owner is None or b.owner.team != HOME)
        nxt = self.next_cursor() if defending else None          # カーソル (U) で切り替わる選手 (小さく表示)
        for p in self.pl:
            q = self.to_px(p.p)
            if not (-30 < q[0] < W + 30 and -30 < q[1] < H + 30):
                continue
            col = (215, 110, 35) if p.team == HOME else (45, 45, 205)
            if p.gk:
                col = (40, 200, 230) if p.team == HOME else (160, 60, 160)
            cv2.circle(c, (q[0] + 2, q[1] + 3), rad, (25, 65, 25), -1, cv2.LINE_AA)
            cv2.circle(c, q, rad, col, -1, cv2.LINE_AA)
            if p.slide > 0:
                cv2.circle(c, q, rad + 4, (255, 255, 255), 2, cv2.LINE_AA)
            f = self.to_px(p.p + p.face * P_R * 1.4)
            cv2.line(c, q, f, (255, 255, 255), 2, cv2.LINE_AA)
            cv2.putText(c, str(p.num), (q[0] - 6 * len(str(p.num)), q[1] + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                        (255, 255, 255), 1, cv2.LINE_AA)
            if p.team == HOME and self.attn.get(id(p), 0) > 0.05:
                cv2.circle(c, q, rad + 6, (0, 220, 255), max(1, int(4 * min(1.0, self.attn[id(p)] / 0.6))), cv2.LINE_AA)
            if p is self.ctrl and self.human(HOME):
                cv2.drawMarker(c, (q[0], q[1] - rad - 14), (255, 255, 255), cv2.MARKER_TRIANGLE_DOWN, 16, 3)
            elif p is nxt:
                cv2.drawMarker(c, (q[0], q[1] - rad - 12), (120, 230, 255), cv2.MARKER_TRIANGLE_DOWN, 11, 1)
                cv2.putText(c, "U", (q[0] + 8, q[1] - rad - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (120, 230, 255), 1,
                            cv2.LINE_AA)
            if p.stun > 0 and p.team == AWAY:
                JT.draw(c, "?", (q[0] + rad, q[1] - rad), 22, (0, 230, 255))
        bq = self.to_px(b.p)
        cv2.circle(c, (bq[0] + 2, bq[1] + 3), 6, (25, 65, 25), -1, cv2.LINE_AA)
        by = bq[1] - int(b.z * self.scale * 0.6)
        cv2.circle(c, (bq[0], by), 6 + int(b.z * 1.5), (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(c, (bq[0], by), 6 + int(b.z * 1.5), (30, 30, 30), 1, cv2.LINE_AA)
        # シュートの溜めゲージ
        if self.charge is not None:
            pw = min(1.0, (self.elapsed - self.charge) / 1.0)
            q = self.to_px(self.ctrl.p)
            cv2.rectangle(c, (q[0] - 30, q[1] + rad + 8), (q[0] + 30, q[1] + rad + 16), (40, 40, 40), -1)
            cv2.rectangle(c, (q[0] - 30, q[1] + rad + 8), (q[0] - 30 + int(60 * pw), q[1] + rad + 16),
                          (0, 200, 255) if pw < 0.85 else (60, 60, 255), -1)
        for (t0, name, pl) in getattr(self, "popups_at", []):
            if self.elapsed - t0 < 0.9:
                q = self.to_px(pl.p)
                JT.draw(c, name, (q[0], q[1] - rad - 34), 24, (0, 230, 255) if pl.team == HOME else (120, 120, 255))
        self.popups_at = [x for x in getattr(self, "popups_at", []) if self.elapsed - x[0] < 0.9]
        self.draw_minimap(c)
        mm, ss = divmod(int(max(0, MATCH_TIME - self.elapsed)), 60)
        cv2.rectangle(c, (W // 2 - 230, 4), (W // 2 + 230, 50), (20, 20, 20), -1)
        JT.draw(c, "あなた %d - %d CPU    %d:%02d" % (self.score[0], self.score[1], mm, ss), (W // 2, 27), 32,
                (255, 255, 255))
        if self.setp is not None:
            msg = {"throw": "スローイン", "corner": "コーナーキック", "gk": "ゴールキック", "fk": "フリーキック",
                   "pk": "PK"}[self.setp["kind"]]
            if self.setp["team"] == HOME:
                msg += "  (WASD で方向 + パスK (↑↓でフライ) / スルーI" + (
                    " / シュートJ 長押し" if self.setp["kind"] in ("fk", "pk") else "") + ")"
                if self.setp["kind"] == "pk":
                    msg += "  キーパーはあなたの視線を読む!"
            JT.draw(c, msg, (W // 2, 80), 28, (255, 255, 160))
        JT.draw(c, "攻撃: パスK  スルーI  シュートJ(長押し)  ダッシュShift  ←↑↓→+ボタン=フリック  フェイント Shiftタップ→WASD  "
                   "停止 Q×2  |  守備: マッチアップK(↑チームプレス)  プレスI  タックルJ  スライディングL  カーソルU(+矢印)  "
                   "ショルダーチャージ Q×2  P 一時停止", (W // 2, H - 14), 17, (230, 230, 230))
        for k, (t0, s, col) in enumerate(self.popups[-2:]):
            age = self.elapsed - t0
            if age < 1.3:
                JT.draw(c, s, (W // 2, int(H * (0.25 + 0.11 * k) - 40 * age)), 56, col, stroke=4)
        self.popups = [x for x in self.popups if self.elapsed - x[0] < 1.3]
        if self.paused:
            JT.draw(c, "一時停止中 (P で再開)", (W // 2, H // 2), 56, (255, 255, 255), stroke=5)

    BG_MARGIN = 16.0     # 背景画像に含めるコート外の余白 [m]

    def build_pitch(self):
        """芝とラインを、コート全体の大きな1枚の画像として一度だけ描いておく (毎フレームは切り出すだけ)。"""
        m, sc = self.BG_MARGIN, self.scale
        Wb, Hb = int((PL + 2 * m) * sc), int((PW + 2 * m) * sc)
        bg = np.full((Hb, Wb, 3), (40, 105, 40), np.uint8)

        def px(x, y):
            return int((x + PL / 2 + m) * sc), int((y + PW / 2 + m) * sc)
        for i in range(-11, 11):
            if i % 2 == 0:
                cv2.rectangle(bg, px(i * 5, -PW / 2), px((i + 1) * 5, PW / 2), (46, 118, 46), -1)
        wh = (235, 235, 235)
        cv2.rectangle(bg, px(-PL / 2, -PW / 2), px(PL / 2, PW / 2), wh, 2)
        cv2.line(bg, px(0, -PW / 2), px(0, PW / 2), wh, 2)
        cv2.circle(bg, px(0, 0), int(9.15 * sc), wh, 2, cv2.LINE_AA)
        for sd in (-1, 1):
            gx = sd * PL / 2
            for (l, w_) in ((BOX_L, BOX_W), (SIX_L, SIX_W)):
                a, z = px(gx, -w_ / 2), px(gx - sd * l, w_ / 2)
                cv2.rectangle(bg, (min(a[0], z[0]), a[1]), (max(a[0], z[0]), z[1]), wh, 2)
            cv2.circle(bg, px(gx - sd * PEN_SPOT, 0), 3, wh, -1)
            a, z = px(gx, -GOAL_W / 2), px(gx + sd * 2, GOAL_W / 2)
            cv2.rectangle(bg, (min(a[0], z[0]), a[1]), (max(a[0], z[0]), z[1]), (200, 200, 200), 3)
        self._bg = bg

    def blit_pitch(self, c):
        if getattr(self, "_bg", None) is None:
            self.build_pitch()
        bg, sc, m = self._bg, self.scale, self.BG_MARGIN
        x0 = int(round((self.cam[0] + PL / 2 + m) * sc - self.W / 2))
        y0 = int(round((self.cam[1] + PW / 2 + m) * sc - self.H * 0.52))
        if 0 <= x0 and 0 <= y0 and x0 + self.W <= bg.shape[1] and y0 + self.H <= bg.shape[0]:
            np.copyto(c, bg[y0:y0 + self.H, x0:x0 + self.W])     # 普段はこれだけ (一括コピー)
            return
        if getattr(self, "_grass", None) is None or self._grass.shape != c.shape:
            self._grass = np.empty_like(c)
            self._grass[:, :] = (40, 105, 40)
        np.copyto(c, self._grass)
        sx0, sy0 = max(x0, 0), max(y0, 0)
        sx1, sy1 = min(x0 + self.W, bg.shape[1]), min(y0 + self.H, bg.shape[0])
        if sx1 > sx0 and sy1 > sy0:
            c[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = bg[sy0:sy1, sx0:sx1]

    def draw_minimap(self, c):
        W, H = self.W, self.H
        mw = int(W * 0.17)
        mh = int(mw * PW / PL)
        x0, y0 = W - mw - 16, H - mh - 40
        sub = c[y0:y0 + mh, x0:x0 + mw]
        sub[:] = (sub * 0.35).astype(np.uint8) + np.array([20, 60, 20], np.uint8)
        cv2.rectangle(c, (x0, y0), (x0 + mw, y0 + mh), (220, 220, 220), 1)
        cv2.line(c, (x0 + mw // 2, y0), (x0 + mw // 2, y0 + mh), (200, 200, 200), 1)

        def mp(p):
            return int(x0 + (p[0] / PL + 0.5) * mw), int(y0 + (p[1] / PW + 0.5) * mh)
        for p in self.pl:
            cv2.circle(c, mp(p.p), 3, (215, 110, 35) if p.team == HOME else (45, 45, 205), -1)
        cv2.circle(c, mp(self.ball.p), 3, (255, 255, 255), -1)
        if self.gaze is not None:
            cv2.circle(c, mp(self.to_world(self.gaze)), 4, (0, 220, 255), 1)
