"""視線 + 長い瞬きで遊ぶシーン群 (メニュー / クイズ / モグラたたき / 結果画面)。

視線誤差は約100pxあるので、的はすべて画面の数分の一の大きさにしている。
各シーンは on_gaze / on_long_blink / tick / render を持ち、画面遷移したいときは
self.request に (行き先, 引数) を入れる。App がそれを見て切り替える。
"""
from __future__ import annotations

import json
import math
import os
import random
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np

from .jtext import JT

Rect = Tuple[int, int, int, int]


def inside(p, r: Rect, margin: float = 0.0) -> bool:
    x, y, w, h = r
    mx, my = margin * w, margin * h
    return x - mx <= p[0] <= x + w + mx and y - my <= p[1] <= y + h + my


def center(r: Rect) -> Tuple[int, int]:
    return r[0] + r[2] // 2, r[1] + r[3] // 2


class RectSelector:
    """視線による選択: 領域に dwell 秒とどまったら選択を切り替える。
    選択中の領域は少し広げて判定し(ヒステリシス)、境界付近で選択がチラつかないようにする。"""

    def __init__(self, rects: List[Rect], dwell: float = 0.15, margin: float = 0.12):
        self.rects = rects
        self.dwell, self.margin = dwell, margin
        self.hover: Optional[int] = None
        self._cand: Optional[int] = None
        self._cand_t = 0.0

    def hit(self, p) -> Optional[int]:
        for i, r in enumerate(self.rects):
            if inside(p, r):
                return i
        return None

    def update(self, p, t: float):
        if self.hover is not None and inside(p, self.rects[self.hover], self.margin):
            self._cand = None
            return
        h = self.hit(p)
        if h is None:
            self._cand = None
            return
        if h != self._cand:
            self._cand, self._cand_t = h, t
        elif t - self._cand_t >= self.dwell:
            self.hover, self._cand = h, None


def draw_panel(c, r: Rect, fill, border, thick=2):
    x, y, w, h = r
    cv2.rectangle(c, (x, y), (x + w, y + h), fill, -1)
    cv2.rectangle(c, (x, y), (x + w, y + h), border, thick)


def draw_confirm_bar(c, r: Rect, ring: float):
    """長い瞬きの進行度をパネル下端のバーで表示する。"""
    if ring <= 0:
        return
    x, y, w, h = r
    cv2.rectangle(c, (x, y + h - 14), (x + int(w * ring), y + h), (0, 255, 120), -1)


class Scene:
    cursor = True        # App が視線カーソルを描くか

    def __init__(self, w: int, h: int):
        self.W, self.H = w, h
        self.request: Optional[Tuple[str, object]] = None

    def on_gaze(self, p, t):
        pass

    def on_long_blink(self, t):
        pass

    def tick(self, t):
        pass

    def on_key(self, k: int):
        pass

    def render(self, c, t, ring):
        pass


# ------------------------------------------------------------------ メニュー --

class Menu(Scene):
    ITEMS = [("soccer11", "目線サッカー 11人制", "eFootball風の操作とルール / 視線を読むCPU"),
             ("football", "目線フットサル", "5人制 / CPUがあなたの視線を読む"),
             ("quiz", "クイズ", "4択を視線で答える"),
             ("mole", "モグラたたき", "見つめて叩く / 爆弾に注意"),
             ("draw", "おえかき", "SPACEを押している間だけ描く"),
             ("heat", "視線ヒートマップ", "どこを見ていたかを可視化"),
             ("refine", "追加学習", "点を見るだけで精度を上げる"),
             ("calib", "再較正", "最初からやり直す")]

    def __init__(self, w, h):
        super().__init__(w, h)
        cols, rows = 4, 2
        x0, x1, y0, y1 = 0.04 * w, 0.96 * w, 0.2 * h, 0.95 * h
        gap = 0.02 * w
        bw, bh = (x1 - x0 - (cols - 1) * gap) / cols, (y1 - y0 - (rows - 1) * gap) / rows
        rects = []
        for i in range(len(self.ITEMS)):
            r, cc = divmod(i, cols)
            rects.append((int(x0 + cc * (bw + gap)), int(y0 + r * (bh + gap)), int(bw), int(bh)))
        self.sel = RectSelector(rects)

    def on_gaze(self, p, t):
        self.sel.update(p, t)

    def on_long_blink(self, t):
        if self.sel.hover is not None:
            self.request = (self.ITEMS[self.sel.hover][0], None)

    def choose(self, i: int):
        if 0 <= i < len(self.ITEMS):
            self.request = (self.ITEMS[i][0], None)

    def render(self, c, t, ring):
        JT.draw(c, "視線メニュー", (self.W // 2, int(0.07 * self.H)), 56, (255, 255, 255))
        JT.draw(c, "見て選び、長い瞬きで決定  (キー 1〜8 でも選択 / Q: 終了)", (self.W // 2, int(0.14 * self.H)), 28,
                (190, 190, 190))
        for i, (key, title, sub) in enumerate(self.ITEMS):
            r = self.sel.rects[i]
            sel = i == self.sel.hover
            draw_panel(c, r, (110, 80, 30) if sel else (55, 55, 55), (0, 220, 255) if sel else (110, 110, 110),
                       6 if sel else 2)
            cx, cy = center(r)
            JT.draw(c, title, (cx, cy - 25), 50, (255, 255, 255))
            JT.draw(c, sub, (cx, cy + 45), 20, (200, 200, 200))
            JT.draw(c, str(i + 1), (r[0] + 30, r[1] + 30), 26, (150, 150, 150))
            if sel:
                draw_confirm_bar(c, r, ring)


# ------------------------------------------------------------------ 結果画面 --

class Result(Scene):
    def __init__(self, w, h, game: str, lines: List[str]):
        super().__init__(w, h)
        self.game, self.lines = game, lines
        bw, bh = int(0.36 * w), int(0.26 * h)
        y = int(0.66 * h)
        self.sel = RectSelector([(int(0.1 * w), y, bw, bh), (int(0.9 * w) - bw, y, bw, bh)])

    def on_gaze(self, p, t):
        self.sel.update(p, t)

    def on_long_blink(self, t):
        if self.sel.hover == 0:
            self.request = (self.game, None)
        elif self.sel.hover == 1:
            self.request = ("menu", None)

    def render(self, c, t, ring):
        y = int(0.14 * self.H)
        for i, ln in enumerate(self.lines):
            JT.draw(c, ln, (self.W // 2, y), 64 if i == 0 else 40, (255, 255, 255) if i == 0 else (210, 210, 210))
            y += 90 if i == 0 else 60
        for i, lab in enumerate(["もう一度", "メニューへ"]):
            r = self.sel.rects[i]
            sel = i == self.sel.hover
            draw_panel(c, r, (110, 80, 30) if sel else (55, 55, 55), (0, 220, 255) if sel else (110, 110, 110),
                       6 if sel else 2)
            JT.draw(c, lab, center(r), 56, (255, 255, 255))
            if sel:
                draw_confirm_bar(c, r, ring)


# ------------------------------------------------------------------ クイズ --

TRIVIA = [
    ("日本で一番高い山は？", "富士山", ["北岳", "槍ヶ岳", "阿蘇山"]),
    ("OpenCV で読み込んだカラー画像の\n色チャンネルの並びは？", "BGR", ["RGB", "HSV", "YUV"]),
    ("8ビット画像の画素値の最大値は？", "255", ["256", "127", "1023"]),
    ("太陽系で一番大きい惑星は？", "木星", ["土星", "地球", "海王星"]),
    ("二進数 1010 を十進数にすると？", "10", ["8", "12", "5"]),
    ("光の三原色に含まれないのは？", "黄", ["赤", "緑", "青"]),
    ("三角形の内角の和は？", "180°", ["90°", "270°", "360°"]),
    ("1時間は何秒？", "3600秒", ["600秒", "6000秒", "36000秒"]),
    ("Haar-like 特徴で顔検出をする\nOpenCV のクラスは？", "CascadeClassifier", ["BFMatcher", "VideoWriter", "KalmanFilter"]),
    ("3D の座標を 2D の画面に写すために\nOpenGL で使う行列は？", "射影行列", ["単位行列", "共分散行列", "ヤコビ行列"]),
    ("水の化学式は？", "H2O", ["CO2", "O2", "NaCl"]),
    ("円周率を小数第2位まで書くと？", "3.14", ["3.16", "3.12", "3.41"]),
    ("このアプリで虹彩の位置を求めるのに\n使っているライブラリは？", "MediaPipe", ["TensorFlow.js", "dlib", "YOLO"]),
    ("このアプリで頭の向きを求めるのに\n使っている OpenCV の関数は？", "solvePnP", ["findContours", "Canny", "warpAffine"]),
    ("1km は何 m？", "1000m", ["100m", "10000m", "10m"]),
]


def _arith(rng: random.Random):
    if rng.random() < 0.5:
        a, b = rng.randint(12, 89), rng.randint(12, 89)
        q, ans = "%d + %d = ?" % (a, b), a + b
    else:
        a, b = rng.randint(3, 9), rng.randint(12, 29)
        q, ans = "%d × %d = ?" % (a, b), a * b
    wrong = set()
    while len(wrong) < 3:
        d = rng.choice([-10, -2, -1, 1, 2, 10, -9, 9, 11, -11])
        if ans + d > 0 and ans + d != ans:
            wrong.add(ans + d)
    return q, str(ans), [str(x) for x in wrong]


class Quiz(Scene):
    N = 8
    FEEDBACK = 1.6

    def __init__(self, w, h, seed: Optional[int] = None):
        super().__init__(w, h)
        rng = random.Random(seed)
        qs = [_arith(rng) for _ in range(3)] + rng.sample(TRIVIA, self.N - 3)
        rng.shuffle(qs)
        self.qs = []
        for q, a, wr in qs:
            opts = [a] + list(wr)
            rng.shuffle(opts)
            self.qs.append((q, opts, opts.index(a)))
        gx, gy = 0.025 * w, 0.03 * h
        x0, y0, x1, y1 = 0.04 * w, 0.3 * h, 0.96 * w, 0.97 * h
        bw, bh = (x1 - x0 - gx) / 2, (y1 - y0 - gy) / 2
        self.sel = RectSelector([(int(x0 + c * (bw + gx)), int(y0 + r * (bh + gy)), int(bw), int(bh))
                                 for r in range(2) for c in range(2)])
        self.i = 0
        self.score = 0
        self.answered: Optional[int] = None
        self.t_answer = 0.0
        self.t_start: Optional[float] = None

    def on_gaze(self, p, t):
        if self.answered is None:
            self.sel.update(p, t)

    def on_long_blink(self, t):
        if self.answered is None and self.sel.hover is not None:
            self.answered = self.sel.hover
            self.t_answer = t
            if self.answered == self.qs[self.i][2]:
                self.score += 1

    def tick(self, t):
        if self.t_start is None:
            self.t_start = t
        if self.answered is not None and t - self.t_answer > self.FEEDBACK:
            self.i += 1
            self.answered = None
            self.sel.hover = None
            if self.i >= len(self.qs):
                el = t - self.t_start
                best = update_best("quiz", self.score)
                lines = ["%d / %d 問正解" % (self.score, len(self.qs)),
                         "かかった時間 %.0f 秒    自己ベスト %d 問" % (el, best)]
                self.request = ("result", ("quiz", lines))

    def render(self, c, t, ring):
        if self.i >= len(self.qs):
            return
        q, opts, ans = self.qs[self.i]
        JT.draw(c, "第 %d 問 / %d      正解 %d" % (self.i + 1, len(self.qs), self.score), (self.W // 2, int(0.04 * self.H)),
                26, (170, 170, 170))
        JT.draw(c, q, (self.W // 2, int(0.16 * self.H)), 52, (255, 255, 255))
        for k, r in enumerate(self.sel.rects):
            if self.answered is None:
                sel = k == self.sel.hover
                fill = (110, 80, 30) if sel else (55, 55, 55)
                border = (0, 220, 255) if sel else (110, 110, 110)
            else:
                sel = False
                fill = (40, 140, 40) if k == ans else ((40, 40, 170) if k == self.answered else (45, 45, 45))
                border = (110, 110, 110)
            draw_panel(c, r, fill, border, 6 if sel else 2)
            JT.draw(c, opts[k], center(r), 64, (255, 255, 255))
            JT.draw(c, "ABCD"[k], (r[0] + 34, r[1] + 34), 30, (170, 170, 170))
            if sel:
                draw_confirm_bar(c, r, ring)
        if self.answered is not None:
            ok = self.answered == ans
            JT.draw(c, "正解！" if ok else "ざんねん…", (self.W // 2, int(0.63 * self.H)), 110,
                    (90, 255, 120) if ok else (90, 90, 255), stroke=5)


# ------------------------------------------------------------------ モグラたたき --

class _Mole:
    def __init__(self, kind: str, t: float, life: float):
        self.kind, self.t0, self.life = kind, t, life
        self.hit_t: Optional[float] = None


class Mole(Scene):
    DURATION = 45.0
    HIT_DWELL = 0.45      # 見つめ続けたら叩く時間 [s]
    POINTS = {"normal": 10, "gold": 30, "bomb": -20}

    def __init__(self, w, h, seed: Optional[int] = None):
        super().__init__(w, h)
        self.rng = random.Random(seed)
        x0, y0, x1, y1 = 0.1 * w, 0.14 * h, 0.9 * w, 0.98 * h
        gx, gy = 0.02 * w, 0.02 * h
        bw, bh = (x1 - x0 - 2 * gx) / 3, (y1 - y0 - 2 * gy) / 3
        self.cells = [(int(x0 + c * (bw + gx)), int(y0 + r * (bh + gy)), int(bw), int(bh))
                      for r in range(3) for c in range(3)]
        self.sel = RectSelector(self.cells, dwell=0.08, margin=0.08)
        self.moles: Dict[int, _Mole] = {}
        self.t_start: Optional[float] = None
        self.next_spawn = 0.0
        self.score = 0
        self.combo = 0
        self.hits = 0
        self.misses = 0
        self.dwell_cell: Optional[int] = None
        self.dwell_t0 = 0.0
        self.gaze = None
        self.popups: List[Tuple[float, int, int, str, Tuple[int, int, int]]] = []
        self.shake_until = 0.0
        self.ended = False

    # --- ゲーム進行 ---
    def _elapsed(self, t):
        return 0.0 if self.t_start is None else t - self.t_start

    def tick(self, t):
        if self.t_start is None:
            self.t_start = t
            self.next_spawn = t + 1.0
        el = self._elapsed(t)
        if el >= self.DURATION:
            if not self.ended:
                self.ended = True
                best = update_best("mole", self.score)
                self.request = ("result", ("mole", ["スコア %d" % self.score,
                                                    "命中 %d / 見逃し %d    自己ベスト %d" % (self.hits, self.misses, best)]))
            return
        # 寿命切れ
        for k in list(self.moles):
            m = self.moles[k]
            if m.hit_t is not None and t - m.hit_t > 0.35:
                del self.moles[k]
            elif m.hit_t is None and t - m.t0 > m.life:
                if m.kind != "bomb":
                    self.misses += 1
                    self.combo = 0
                del self.moles[k]
        # 出現 (時間とともに速く・短く)
        speed = 1.0 + 0.8 * el / self.DURATION
        if t >= self.next_spawn and len(self.moles) < 3:
            free = [i for i in range(9) if i not in self.moles]
            if free:
                k = self.rng.choice(free)
                r = self.rng.random()
                kind = "gold" if r < 0.12 else ("bomb" if r < 0.32 else "normal")
                life = {"normal": 2.6, "gold": 1.7, "bomb": 2.4}[kind] / speed
                self.moles[k] = _Mole(kind, t, life)
            self.next_spawn = t + self.rng.uniform(0.5, 1.1) / speed
        # 見つめ続けたら叩く
        h = self.sel.hover
        if h is not None and h == self.dwell_cell and h in self.moles and self.moles[h].hit_t is None:
            if t - max(self.dwell_t0, self.moles[h].t0 + 0.15) >= self.HIT_DWELL:
                self._hit(h, t)

    def _hit(self, k, t):
        m = self.moles[k]
        m.hit_t = t
        pts = self.POINTS[m.kind]
        if m.kind == "bomb":
            self.combo = 0
            self.shake_until = t + 0.35
        else:
            self.combo += 1
            self.hits += 1
            pts += 2 * max(0, self.combo - 1)          # コンボボーナス
        self.score += pts
        cx, cy = center(self.cells[k])
        self.popups.append((t, cx, cy - 60, ("+%d" % pts) if pts > 0 else str(pts),
                            (90, 255, 120) if pts > 0 else (90, 90, 255)))

    def on_gaze(self, p, t):
        self.gaze = p
        prev = self.sel.hover
        self.sel.update(p, t)
        if self.sel.hover != prev or self.dwell_cell is None:
            self.dwell_cell, self.dwell_t0 = self.sel.hover, t

    def on_long_blink(self, t):
        h = self.sel.hover
        if h is not None and h in self.moles and self.moles[h].hit_t is None:
            self._hit(h, t)

    # --- 描画 ---
    def _draw_mole(self, c, k, m: _Mole, t):
        x, y, w, h = self.cells[k]
        cx = x + w // 2
        hole_y = y + int(h * 0.78)
        rad = int(min(w, h) * 0.28)
        rise = min(1.0, (t - m.t0) / 0.15)
        if m.hit_t is None and m.life - (t - m.t0) < 0.2:
            rise = max(0.0, (m.life - (t - m.t0)) / 0.2)
        cy = hole_y - int(rad * 1.1 * rise)
        if m.kind == "bomb":
            cv2.circle(c, (cx, cy), rad, (40, 40, 40), -1, cv2.LINE_AA)
            cv2.circle(c, (cx - rad // 3, cy - rad // 3), rad // 5, (110, 110, 110), -1, cv2.LINE_AA)
            cv2.line(c, (cx + rad // 2, cy - rad + 4), (cx + rad // 2 + 18, cy - rad - 22), (60, 160, 200), 5)
            if int(t * 10) % 2 == 0:
                cv2.circle(c, (cx + rad // 2 + 20, cy - rad - 26), 9, (0, 200, 255), -1, cv2.LINE_AA)
            JT.draw(c, "爆弾", (cx, cy + 5), int(rad * 0.6), (90, 90, 255))
        else:
            body = (0, 200, 255) if m.kind == "gold" else (60, 100, 150)
            cv2.circle(c, (cx, cy), rad, body, -1, cv2.LINE_AA)
            cv2.ellipse(c, (cx, cy + rad // 3), (rad // 2, rad // 3), 0, 0, 360, (150, 190, 220), -1, cv2.LINE_AA)
            cv2.circle(c, (cx, cy + rad // 6), rad // 7, (60, 60, 200), -1, cv2.LINE_AA)   # 鼻
            for sx in (-1, 1):
                ex, ey = cx + sx * rad // 3, cy - rad // 4
                if m.hit_t is not None:   # 叩かれた: × の目
                    d = rad // 7
                    cv2.line(c, (ex - d, ey - d), (ex + d, ey + d), (20, 20, 20), 3)
                    cv2.line(c, (ex - d, ey + d), (ex + d, ey - d), (20, 20, 20), 3)
                else:                     # 黒目が視線の方向を見る
                    cv2.circle(c, (ex, ey), rad // 6, (255, 255, 255), -1, cv2.LINE_AA)
                    dx = dy = 0
                    if self.gaze is not None:
                        v = np.array([self.gaze[0] - ex, self.gaze[1] - ey], float)
                        n = np.linalg.norm(v) + 1e-6
                        dx, dy = int(v[0] / n * rad / 14), int(v[1] / n * rad / 14)
                    cv2.circle(c, (ex + dx, ey + dy), rad // 12, (20, 20, 20), -1, cv2.LINE_AA)
            if m.kind == "gold":
                JT.draw(c, "★", (cx, cy - rad - 12), 34, (0, 230, 255))
        # 穴の手前側の土で下半分を隠す
        cv2.ellipse(c, (cx, hole_y + rad // 3), (int(rad * 1.5), rad // 2), 0, 0, 360, (40, 70, 90), -1, cv2.LINE_AA)

    def render(self, c, t, ring):
        el = self._elapsed(t)
        off = (self.rng.randint(-12, 12), self.rng.randint(-12, 12)) if t < self.shake_until else (0, 0)
        for k, (x, y, w, h) in enumerate(self.cells):
            x, y = x + off[0], y + off[1]
            sel = k == self.sel.hover
            draw_panel(c, (x, y, w, h), (50, 80, 50), (0, 220, 255) if sel else (70, 110, 70), 5 if sel else 2)
            cx, hy = x + w // 2, y + int(h * 0.78)
            rad = int(min(w, h) * 0.28)
            cv2.ellipse(c, (cx, hy), (int(rad * 1.4), rad // 2), 0, 0, 360, (20, 30, 40), -1, cv2.LINE_AA)
        for k, m in self.moles.items():
            self._draw_mole(c, k, m, t)
        # 見つめている間の進行リング
        h = self.sel.hover
        if h is not None and h in self.moles and self.moles[h].hit_t is None:
            p = min(1.0, (t - max(self.dwell_t0, self.moles[h].t0 + 0.15)) / self.HIT_DWELL)
            if p > 0:
                cx, cy = center(self.cells[h])
                cv2.ellipse(c, (cx, cy), (int(self.cells[h][3] * 0.42),) * 2, -90, 0, 360 * p,
                            (0, 255, 255) if self.moles[h].kind != "bomb" else (60, 60, 255), 8, cv2.LINE_AA)
        for (t0, x, y, s, col) in self.popups:
            if t - t0 < 0.8:
                JT.draw(c, s, (x, int(y - 80 * (t - t0))), 56, col, stroke=4)
        self.popups = [p for p in self.popups if t - p[0] < 0.8]
        # 上部の表示
        JT.draw(c, "スコア %d" % self.score, (int(0.12 * self.W), int(0.06 * self.H)), 44, (255, 255, 255), anchor="l")
        if self.combo >= 2:
            JT.draw(c, "%d コンボ!" % self.combo, (self.W // 2, int(0.06 * self.H)), 44, (0, 230, 255))
        rem = max(0.0, self.DURATION - el)
        JT.draw(c, "残り %d 秒" % math.ceil(rem), (int(0.88 * self.W), int(0.06 * self.H)), 40, (255, 255, 255), anchor="r")
        cv2.rectangle(c, (int(0.1 * self.W), int(0.11 * self.H)),
                      (int(0.1 * self.W + 0.8 * self.W * rem / self.DURATION), int(0.11 * self.H) + 8), (0, 200, 120), -1)


# ------------------------------------------------------------------ 自己ベスト --

_BEST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "profiles", "highscore.json")


def update_best(game: str, score: int) -> int:
    try:
        with open(_BEST) as f:
            d = json.load(f)
    except (OSError, ValueError):
        d = {}
    best = max(int(d.get(game, score)), score)
    d[game] = best
    try:
        os.makedirs(os.path.dirname(_BEST), exist_ok=True)
        with open(_BEST, "w") as f:
            json.dump(d, f)
    except OSError:
        pass
    return best
