"""目線フットサル: 5対5の見下ろし型サッカー。CPU があなたの「視線」を読んでくる。

操作 (キーボード):
  移動 WASD / 矢印, ダッシュ Shift
  攻撃: J パス / K スルーパス / L シュート   (方向は移動キーの向き。押していなければ向いている方向)
  守備: J タックル / I 操作選手の切り替え
  P 一時停止, Esc メニューへ
視線の仕掛け:
  - 味方を見つめると (attention)、CPU の守備がその味方へのパスコースを塞ぎにいく (画面に赤い線で表示)
  - 見ている味方とは別の味方にパスすると「ノールックパス」: 守備の反応が遅れ、カットされにくい
  - 見ている味方にそのままパスすると、読まれていてカットされやすい
  - ゴールの隅を見るとキーパーがそちらに寄る -> 逆を見てシュートすれば「ノールックシュート」
座標はメートル (コート 40m x 20m)。描画は OpenCV。
"""
from __future__ import annotations

import math
import random
from typing import List, Optional, Tuple

import cv2
import numpy as np

from .games import Scene
from .jtext import JT

L, Wd = 40.0, 20.0          # コートの長さ・幅 [m]
GOAL_W = 3.0 * 1.6          # ゴール幅 [m] (遊びやすさのため少し広め)
P_R = 0.55                  # 選手の半径
CONTROL_R = 0.9             # ボールを持てる距離
SPEED, DASH = 5.5, 7.5      # 選手の速さ [m/s]
CPU_SPEED = 5.0
FRICTION = 5.0              # ボールの減速 [m/s^2]
PASS_V, THROUGH_V, SHOT_V = 15.0, 13.0, 22.0
MATCH_TIME = 180.0
GK_REACH = 1.15             # キーパーが止められる距離 [m]
READ_BONUS = 1.15           # 読まれたパスをカットしやすくする倍率

HOME, AWAY = 0, 1
# 4-0 っぽい配置 (攻撃方向 +x の HOME 基準)。GK, 後ろ左右, 前左右
FORMATION = [(-18.5, 0.0), (-10.0, -5.0), (-10.0, 5.0), (-3.0, -5.5), (-3.0, 5.5)]


def norm(v):
    n = math.hypot(v[0], v[1])
    return (v[0] / n, v[1] / n) if n > 1e-9 else (0.0, 0.0)


class Player:
    def __init__(self, team: int, idx: int, pos):
        self.team, self.idx = team, idx
        self.p = np.array(pos, float)
        self.v = np.zeros(2)
        self.face = np.array([1.0 if team == HOME else -1.0, 0.0])
        self.stun = 0.0            # 反応が遅れる時間 (ノールックパスで騙された時など)
        self.tackle_cd = 0.0

    @property
    def gk(self):
        return self.idx == 0


class Ball:
    def __init__(self):
        self.p = np.zeros(2)
        self.v = np.zeros(2)
        self.owner: Optional[Player] = None
        self.last_kicker: Optional[Player] = None
        self.kick_t = -9.0
        self.kind = ""             # "pass" / "through" / "shot"
        self.target: Optional[Player] = None
        self.nolook = False


class FutsalGame(Scene):
    cursor = True

    def __init__(self, w, h, keys=None, seed: Optional[int] = None):
        super().__init__(w, h)
        self.keys = keys                # gazekit.oscontrol.KeyHold (押しっぱなし判定)
        self.rng = random.Random(seed)
        m = 0.06
        self.sx = (w * (1 - 2 * m)) / L
        self.sy = min((h * 0.86) / Wd, self.sx)
        self.ox = w / 2
        self.oy = h * 0.54
        self.players: List[Player] = []
        for team in (HOME, AWAY):
            for i, (x, y) in enumerate(FORMATION):
                s = 1 if team == HOME else -1
                self.players.append(Player(team, i, (s * x, s * y)))
        self.ball = Ball()
        self.score = [0, 0]
        self.t0: Optional[float] = None
        self.t_last: Optional[float] = None
        self.elapsed = 0.0
        self.paused = False
        self.ctrl: Player = self.team(HOME)[4]
        self.kickoff(HOME)
        # 視線
        self.gaze = None
        self.gaze_t = -9.0
        self.attn = {id(p): 0.0 for p in self.team(HOME)}
        self.watched: Optional[Player] = None
        self.goal_look = 0.0           # 相手ゴールのどちら側を見ているか (-1..1), キーパーが寄る
        # 演出
        self.popups: List[Tuple[float, str, Tuple[int, int, int]]] = []
        self.stats = {"nolook": 0, "read": 0, "passes": 0, "intercepted": 0}
        self._dir_t = {}
        self.ended = False

    # ------------------------------------------------------------ 補助
    def team(self, t) -> List[Player]:
        return [p for p in self.players if p.team == t]

    def to_px(self, p) -> Tuple[int, int]:
        return int(self.ox + p[0] * self.sx), int(self.oy + p[1] * self.sy)

    def to_world(self, q) -> np.ndarray:
        return np.array([(q[0] - self.ox) / self.sx, (q[1] - self.oy) / self.sy])

    def popup(self, text, color=(255, 255, 255)):
        self.popups.append((self.elapsed, text, color))

    def kickoff(self, team):
        for p in self.players:
            s = 1 if p.team == HOME else -1
            x, y = FORMATION[p.idx]
            p.p[:] = (s * x, s * y)
            p.v[:] = 0
            p.stun = 0
        taker = self.team(team)[4]
        taker.p[:] = (-0.8 if team == HOME else 0.8, 0.0)
        self.ball.p[:] = (0.0, 0.0)
        self.ball.v[:] = 0
        self.ball.owner = taker
        self.ball.target = None
        if team == HOME:
            self.ctrl = taker

    # ------------------------------------------------------------ 入力
    def held(self, *names) -> bool:
        if self.keys is not None and self.keys.available:
            return any(self.keys.is_down(n) for n in names)
        return any(self.elapsed - self._dir_t.get(n, -9) < 0.25 for n in names)

    def move_dir(self):
        dx = (1 if self.held("d", "Right") else 0) - (1 if self.held("a", "Left") else 0)
        dy = (1 if self.held("s", "Down") else 0) - (1 if self.held("w", "Up") else 0)
        return norm((dx, dy))

    def on_key(self, k: int):
        names = {ord("w"): "w", ord("a"): "a", ord("s"): "s", ord("d"): "d",
                 82: "Up", 84: "Down", 81: "Left", 83: "Right"}   # waitKey の矢印コード (Linux/GTK/Qt)
        if k in names:
            self._dir_t[names[k]] = self.elapsed
            return
        ch = chr(k).lower() if 0 <= k < 256 else ""
        if ch == "p":
            self.paused = not self.paused
        elif self.paused or self.ended:
            return
        elif ch == "j":
            if self.ball.owner is self.ctrl:
                self.kick("pass")
            else:
                self.tackle(self.ctrl)
        elif ch == "k" and self.ball.owner is self.ctrl:
            self.kick("through")
        elif ch == "l" and self.ball.owner is self.ctrl:
            self.kick("shot")
        elif ch == "i":
            self.switch_player()

    def on_gaze(self, p, t):
        self.gaze, self.gaze_t = p, t

    # ------------------------------------------------------------ 視線を読む
    def update_attention(self, dt):
        """味方の近く (3m 以内) を見ている時間を積算し、減衰させる。最大のものを「見ている味方」とする。"""
        g = None
        if self.gaze is not None and self.elapsed - (self.gaze_t - (self.t0 or 0)) < 1e9:
            g = self.to_world(self.gaze)
        best, bd = None, 3.0
        if g is not None:
            for p in self.team(HOME):
                if p is self.ball.owner:
                    continue
                d = float(np.linalg.norm(p.p - g))
                if d < bd:
                    best, bd = p, d
        for p in self.team(HOME):
            a = self.attn[id(p)] * math.exp(-dt / 0.7)
            if p is best:
                a += dt
            self.attn[id(p)] = min(a, 1.5)
        cand = max(self.team(HOME), key=lambda p: self.attn[id(p)])
        self.watched = cand if self.attn[id(cand)] > 0.3 and cand is not self.ball.owner else None
        # 相手ゴール付近を見ていれば、どちら側か (キーパーが寄る)
        gl = 0.0
        if g is not None and g[0] > L / 2 - 8:
            gl = max(-1.0, min(1.0, g[1] / (GOAL_W / 2)))
        self.goal_look += (gl - self.goal_look) * min(1.0, dt * 3)

    # ------------------------------------------------------------ キック
    def pick_teammate(self, carrier: Player, d) -> Optional[Player]:
        best, bs = None, -1e9
        for p in self.team(carrier.team):
            if p is carrier or p.gk and carrier.team == HOME and d[0] > 0:
                continue
            v = p.p - carrier.p
            dist = float(np.linalg.norm(v))
            if dist < 1.0:
                continue
            u = v / dist
            s = 2.0 * (u[0] * d[0] + u[1] * d[1]) - dist / 25.0
            if s > bs:
                best, bs = p, s
        return best

    def kick(self, kind: str, carrier: Optional[Player] = None, target: Optional[Player] = None, aim=None):
        c = carrier or self.ball.owner
        if c is None:
            return
        d = self.move_dir() if c.team == HOME and carrier is None else (0.0, 0.0)
        if d == (0.0, 0.0):
            d = tuple(c.face)
        b = self.ball
        b.nolook = False
        if kind == "shot":
            gx = L / 2 if c.team == HOME else -L / 2
            gy = aim if aim is not None else max(-GOAL_W / 2 + 0.4, min(GOAL_W / 2 - 0.4, d[1] * GOAL_W * 0.45))
            u = norm((gx - c.p[0], gy - c.p[1]))
            b.v = np.array(u) * SHOT_V
            b.target = None
            if c.team == HOME and abs(self.goal_look) > 0.35 and np.sign(self.goal_look) != np.sign(gy) and abs(gy) > 0.8:
                b.nolook = True
                self.popup("NO LOOK SHOT!", (0, 220, 255))
        else:
            tgt = target or self.pick_teammate(c, d)
            if tgt is None:
                return
            lead = 0.35 if kind == "pass" else 1.1
            dest = tgt.p + tgt.v * lead + (np.array([3.5 if c.team == HOME else -3.5, 0]) if kind == "through" else 0)
            u = norm(dest - c.p)
            dist = float(np.linalg.norm(dest - c.p))
            v0 = math.sqrt(2 * FRICTION * dist) + 3.0           # 受け手の所で少し速さが残るくらい
            b.v = np.array(u) * min(v0, PASS_V if kind == "pass" else THROUGH_V)
            b.target = tgt
            if c.team == HOME:
                self.stats["passes"] += 1
                if self.watched is not None and tgt is not self.watched and self.attn[id(self.watched)] > 0.45:
                    b.nolook = True                # 見ている味方とは別の味方へ: 守備が騙される
                    self.stats["nolook"] += 1
                    self.popup("NO LOOK PASS!", (0, 220, 255))
                    for p in self.team(AWAY):
                        p.stun = max(p.stun, 0.45)
                elif self.watched is tgt:
                    self.stats["read"] += 1
        b.kind = kind
        b.owner = None
        b.last_kicker = c
        b.kick_t = self.elapsed
        b.p = c.p + np.array(norm(b.v)) * (P_R + 0.2)

    def tackle(self, p: Player):
        b = self.ball
        if p.tackle_cd > 0 or b.owner is None or b.owner.team == p.team:
            return
        p.tackle_cd = 0.8
        if np.linalg.norm(b.owner.p - p.p) < 1.4 and self.rng.random() < 0.65:
            b.owner.stun = 0.6
            b.owner = p
            if p.team == HOME:
                self.ctrl = p
                self.popup("ボール奪取!", (90, 255, 120))

    def switch_player(self):
        cands = [p for p in self.team(HOME) if p is not self.ctrl and not p.gk]
        if cands:
            self.ctrl = min(cands, key=lambda p: np.linalg.norm(p.p - self.ball.p))

    # ------------------------------------------------------------ AI
    def ai_targets(self) -> dict:
        """各選手の目標位置。"""
        b = self.ball
        tg = {}
        bx = float(np.clip(b.p[0], -L / 2, L / 2))
        att = b.owner.team if b.owner is not None else (b.last_kicker.team if b.last_kicker else HOME)
        for p in self.players:
            s = 1 if p.team == HOME else -1
            fx, fy = FORMATION[p.idx]
            if p.gk:
                gx = -s * (L / 2 - 1.0)
                gy = float(np.clip(b.p[1] * 0.45, -GOAL_W / 2 + 0.3, GOAL_W / 2 - 0.3))
                if p.team == AWAY:
                    gy = float(np.clip(gy + self.goal_look * GOAL_W * 0.35, -GOAL_W / 2 + 0.3, GOAL_W / 2 - 0.3))
                tg[id(p)] = np.array([gx, gy])
                continue
            shift = bx * 0.55 + (6.0 * s if att == p.team else -2.0 * s)
            tg[id(p)] = np.array([np.clip(s * fx + shift, -L / 2 + 2, L / 2 - 2), s * fy * (1.15 if att == p.team else 0.8)])
        # 守備: 一番近い選手がボールへ、残りはマーク。視線を読んだ CPU はパスコースへ
        for team in (HOME, AWAY):
            if att == team:
                continue
            defs = [p for p in self.team(team) if not p.gk]
            presser = min(defs, key=lambda p: np.linalg.norm(p.p - b.p))
            tg[id(presser)] = b.p.copy()
            if team == AWAY and b.owner is not None and b.owner.team == HOME and self.watched is not None:
                lane = b.owner.p + (self.watched.p - b.owner.p) * 0.55
                reader = min([p for p in defs if p is not presser], key=lambda p: np.linalg.norm(p.p - lane))
                tg[id(reader)] = lane
                self.reader = reader
            elif team == AWAY:
                self.reader = None
        return tg

    def lane_clear(self, a: np.ndarray, b: np.ndarray, team: int) -> float:
        """a->b のパスコースから、相手 (team 以外) の選手までの最短距離 [m]。"""
        ab = b - a
        L2 = float(ab @ ab) + 1e-9
        best = 99.0
        for p in self.players:
            if p.team == team:
                continue
            tt = float(np.clip((p.p - a) @ ab / L2, 0, 1))
            best = min(best, float(np.linalg.norm(a + tt * ab - p.p)))
        return best

    def cpu_attack(self, c: Player, dt):
        """CPU (AWAY) のボール保持者: ゴールへ運ぶ。寄せられたら、コースの空いた味方へパス。近ければシュート。"""
        goal = np.array([-L / 2, 0.0])
        near = min(self.team(HOME), key=lambda p: np.linalg.norm(p.p - c.p))
        nd = float(np.linalg.norm(near.p - c.p))
        dist_goal = float(np.linalg.norm(goal - c.p))
        if dist_goal < 13 and self.rng.random() < 2.5 * dt:
            self.kick("shot", carrier=c, aim=self.rng.uniform(-GOAL_W / 2 + 0.5, GOAL_W / 2 - 0.5))
            return
        if (nd < 2.2 and self.rng.random() < 1.5 * dt) or self.rng.random() < 0.2 * dt:
            mates = [p for p in self.team(AWAY) if p is not c and not p.gk]
            scored = [(self.lane_clear(c.p, m.p, AWAY) + 0.08 * (c.p[0] - m.p[0]), m) for m in mates]
            sc, m = max(scored, key=lambda x: x[0])
            if self.lane_clear(c.p, m.p, AWAY) > 1.6:
                self.kick("pass", carrier=c, target=m)
                return
        # ドリブル: ゴール方向 + 寄せてくる相手から離れる向き
        away = c.p - near.p
        d = norm(np.array(norm(goal - c.p)) * 1.0 + np.array(norm(away)) * (1.2 if nd < 2.5 else 0.0))
        c.v = np.array(d) * CPU_SPEED * 0.95

    # ------------------------------------------------------------ 更新
    def update(self, t):
        if self.t_last is None:
            self.t_last = t
            self.t0 = t
        dt = min(0.05, t - self.t_last)
        self.t_last = t
        if self.paused or self.ended:
            return
        self.elapsed += dt
        if self.elapsed >= MATCH_TIME:
            self.ended = True
            self.request = ("result", ("football", ["%d - %d" % tuple(self.score),
                                                    "ノールックパス %d 回 / 読まれたパス %d 回 / パス %d 本" % (
                                                        self.stats["nolook"], self.stats["read"], self.stats["passes"])]))
            return
        self.update_attention(dt)
        b = self.ball
        tg = self.ai_targets()
        # 自動切り替え: 守備中は、操作中の選手がボールから遠すぎたら近い選手へ
        if b.owner is not None and b.owner.team == HOME:
            self.ctrl = b.owner
        elif self.ctrl.gk or (b.owner is not None and np.linalg.norm(self.ctrl.p - b.p) > 9):
            self.switch_player()
        for p in self.players:
            p.tackle_cd = max(0.0, p.tackle_cd - dt)
            if p.stun > 0:
                p.stun -= dt
                p.v *= 0.85
            elif p is self.ctrl:
                d = self.move_dir()
                sp = DASH if self.held("Shift_L", "Shift_R") else SPEED
                p.v = np.array(d) * sp
            elif p is b.owner and p.team == AWAY:
                self.cpu_attack(p, dt)
                if b.owner is not p:
                    continue
            else:
                v = tg[id(p)] - p.p
                dist = np.linalg.norm(v)
                sp = (CPU_SPEED if p.team == AWAY else SPEED * 0.9) * min(1.0, dist / 1.5)
                p.v = np.array(norm(v)) * sp
                # CPU の守備は、近くのボール保持者に自動でタックル
                if p.team == AWAY and b.owner is not None and b.owner.team == HOME and dist < 1.2 and self.rng.random() < 1.2 * dt:
                    self.tackle(p)
            p.p += p.v * dt
            p.p[0] = np.clip(p.p[0], -L / 2 + P_R, L / 2 - P_R)
            p.p[1] = np.clip(p.p[1], -Wd / 2 + P_R, Wd / 2 - P_R)
            if np.linalg.norm(p.v) > 0.3:
                p.face = np.array(norm(p.v))
        # ボール
        if b.owner is not None:
            o = b.owner
            b.p = o.p + o.face * (P_R + 0.25)
            b.v = o.v.copy()
            return
        sp = float(np.linalg.norm(b.v))
        if sp > 0:
            b.v *= max(0.0, sp - FRICTION * dt) / sp
        b.p += b.v * dt
        # ゴール判定
        if abs(b.p[0]) >= L / 2 and abs(b.p[1]) < GOAL_W / 2:
            scorer = HOME if b.p[0] > 0 else AWAY
            self.score[scorer] += 1
            self.popup("GOAL!!" if scorer == HOME else "失点…", (90, 255, 120) if scorer == HOME else (90, 90, 255))
            self.kickoff(AWAY if scorer == HOME else HOME)
            return
        # 壁で跳ね返る
        for ax, lim in ((0, L / 2), (1, Wd / 2)):
            if abs(b.p[ax]) > lim:
                b.p[ax] = math.copysign(lim, b.p[ax])
                b.v[ax] *= -0.6
        self.try_receive()

    def try_receive(self):
        b = self.ball
        sp = float(np.linalg.norm(b.v))
        for p in sorted(self.players, key=lambda q: np.linalg.norm(q.p - b.p)):
            d = float(np.linalg.norm(p.p - b.p))
            if p is b.last_kicker and self.elapsed - b.kick_t < 0.35:
                continue
            reach = CONTROL_R
            if p.gk:
                reach = GK_REACH                  # キーパーは手が届く
                if p.team == AWAY and b.kind == "shot" and b.nolook:
                    reach = 0.9                   # 逆を突かれたキーパー
            mine = b.last_kicker is not None and p.team == b.last_kicker.team
            if not mine and b.kind in ("pass", "through") and sp > 4:
                reach *= 0.6 if b.nolook else (READ_BONUS if b.target is self.watched and p.team == AWAY else 1.0)
            if d < reach and (sp < 18 or p.gk or not mine):
                if p.stun > 0 and not p.gk:
                    continue
                if not mine and b.last_kicker is not None and b.last_kicker.team == HOME and b.kind != "shot":
                    self.stats["intercepted"] += 1
                    self.popup("カットされた!" if b.target is not self.watched or not b.target else "読まれていた!",
                               (90, 90, 255))
                if p.gk and not mine and b.kind == "shot":
                    self.popup("セーブ!" if p.team == AWAY else "ナイスセーブ!", (200, 200, 255))
                b.owner = p
                b.v[:] = 0
                b.target = None
                if p.team == HOME:
                    self.ctrl = p
                return

    # ------------------------------------------------------------ 描画
    def render(self, c, t, ring):
        self.update(t)
        W, H = self.W, self.H
        c[:] = (40, 110, 40)
        x0, y0 = self.to_px((-L / 2, -Wd / 2))
        x1, y1 = self.to_px((L / 2, Wd / 2))
        for i in range(10):          # 芝の縞
            xa = x0 + (x1 - x0) * i // 10
            xb = x0 + (x1 - x0) * (i + 1) // 10
            if i % 2 == 0:
                cv2.rectangle(c, (xa, y0), (xb, y1), (46, 122, 46), -1)
        white = (235, 235, 235)
        cv2.rectangle(c, (x0, y0), (x1, y1), white, 3)
        cv2.line(c, ((x0 + x1) // 2, y0), ((x0 + x1) // 2, y1), white, 2)
        cv2.circle(c, self.to_px((0, 0)), int(3 * self.sx), white, 2, cv2.LINE_AA)
        for s in (-1, 1):
            cv2.ellipse(c, self.to_px((s * L / 2, 0)), (int(6 * self.sx), int(6 * self.sy)), 0,
                        90 if s > 0 else -90, 270 if s > 0 else 90, white, 2, cv2.LINE_AA)
            ga, gb = self.to_px((s * L / 2, -GOAL_W / 2)), self.to_px((s * (L / 2 + 1.2), GOAL_W / 2))
            cv2.rectangle(c, (min(ga[0], gb[0]), ga[1]), (max(ga[0], gb[0]), gb[1]), (210, 210, 210), 3)
        # 読まれているパスコース
        b = self.ball
        if b.owner is not None and b.owner.team == HOME and self.watched is not None:
            a, z = self.to_px(b.owner.p), self.to_px(self.watched.p)
            n = 14
            for i in range(0, n, 2):
                p0 = (a[0] + (z[0] - a[0]) * i // n, a[1] + (z[1] - a[1]) * i // n)
                p1 = (a[0] + (z[0] - a[0]) * (i + 1) // n, a[1] + (z[1] - a[1]) * (i + 1) // n)
                cv2.line(c, p0, p1, (60, 60, 255), 3, cv2.LINE_AA)
            r = getattr(self, "reader", None)
            if r is not None:
                rp = self.to_px(r.p)
                JT.draw(c, "読んでる!", (rp[0], rp[1] - 38), 22, (90, 90, 255))
        # 選手
        for p in self.players:
            q = self.to_px(p.p)
            col = (220, 120, 40) if p.team == HOME else (50, 50, 210)
            if p.gk:
                col = (40, 200, 230) if p.team == HOME else (160, 60, 160)
            rad = int(P_R * self.sx * 1.15)
            cv2.circle(c, (q[0] + 3, q[1] + 4), rad, (25, 70, 25), -1, cv2.LINE_AA)
            cv2.circle(c, q, rad, col, -1, cv2.LINE_AA)
            f = self.to_px(p.p + p.face * P_R * 1.3)
            cv2.line(c, q, f, (255, 255, 255), 2, cv2.LINE_AA)
            if p.team == HOME:
                a_ = self.attn[id(p)]
                if a_ > 0.05:
                    cv2.circle(c, q, rad + 6, (0, 220, 255), max(1, int(4 * min(1.0, a_ / 0.6))), cv2.LINE_AA)
            if p is self.ctrl:
                cv2.drawMarker(c, (q[0], q[1] - rad - 14), (255, 255, 255), cv2.MARKER_TRIANGLE_DOWN, 18, 3)
            if p.stun > 0 and p.team == AWAY:
                JT.draw(c, "?", (q[0] + rad, q[1] - rad), 26, (0, 230, 255))
        bp = self.to_px(b.p)
        cv2.circle(c, (bp[0] + 2, bp[1] + 3), 8, (25, 70, 25), -1, cv2.LINE_AA)
        cv2.circle(c, bp, 8, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(c, bp, 8, (30, 30, 30), 1, cv2.LINE_AA)
        # HUD
        mm, ss = divmod(int(max(0, MATCH_TIME - self.elapsed)), 60)
        JT.draw(c, "あなた %d - %d CPU" % tuple(self.score), (W // 2, 26), 40, (255, 255, 255))
        JT.draw(c, "%d:%02d" % (mm, ss), (W - 90, 26), 34, (255, 255, 255))
        JT.draw(c, "J パス  K スルー  L シュート  Shift ダッシュ  I 切替  P 一時停止  (味方を見つめるとCPUに読まれる)",
                (W // 2, H - 16), 20, (230, 230, 230))
        for k, (t0, s, col) in enumerate(self.popups[-2:]):
            age = self.elapsed - t0
            if age < 1.2:
                JT.draw(c, s, (W // 2, int(H * (0.26 + 0.12 * k) - 40 * age)), 60, col, stroke=4)
        self.popups = [x for x in self.popups if self.elapsed - x[0] < 1.2]
        if self.paused:
            JT.draw(c, "一時停止中 (P で再開)", (W // 2, H // 2), 56, (255, 255, 255), stroke=5)
