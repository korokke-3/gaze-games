from __future__ import annotations

from collections import deque
from typing import List, Optional, Tuple

import cv2
import numpy as np

FONT = cv2.FONT_HERSHEY_SIMPLEX
BG = (28, 28, 28)


def put_text(img, s, org, scale=0.7, color=(235, 235, 235), thick=1, anchor="l"):
    """anchor: l(左寄せ) / c(中央) / r(右寄せ)。org は基準線の位置。"""
    (tw, th), _ = cv2.getTextSize(s, FONT, scale, thick)
    x, y = org
    if anchor == "c":
        x -= tw // 2
    elif anchor == "r":
        x -= tw
    cv2.putText(img, s, (int(x), int(y)), FONT, scale, (0, 0, 0), thick + 2, cv2.LINE_AA)
    cv2.putText(img, s, (int(x), int(y)), FONT, scale, color, thick, cv2.LINE_AA)


class Heatmap:
    """低解像度の累積バッファ。注視時間[s]を加算し、描画時にぼかして色付けする。"""

    def __init__(self, w: int, h: int, scale: int = 8, sigma_px: float = 45.0):
        self.w, self.h, self.s = w, h, scale
        self.acc = np.zeros((h // scale + 1, w // scale + 1), np.float32)
        self.sigma = sigma_px / scale
        self._n = 0
        self._cache = None

    def add(self, p, dt: float):
        x, y = int(p[0] / self.s), int(p[1] / self.s)
        if 0 <= y < self.acc.shape[0] and 0 <= x < self.acc.shape[1]:
            self.acc[y, x] += dt

    def reset(self):
        self.acc[:] = 0
        self._cache = None

    def draw(self, canvas: np.ndarray, strength: float = 0.75):
        # 重いので数フレームに1回だけ再計算してキャッシュを使い回す
        self._n += 1
        if self._cache is None or self._n % 6 == 0:
            self._cache = self._render(strength)
        if self._cache is not None:
            color, alpha = self._cache
            canvas[:] = (canvas * (1 - alpha) + color * alpha).astype(np.uint8)

    def _render(self, strength):
        blur = cv2.GaussianBlur(self.acc, (0, 0), self.sigma)
        m = blur.max()
        if m < 1e-6:
            return None
        n = blur / m
        color = cv2.applyColorMap((n * 255).astype(np.uint8), cv2.COLORMAP_JET)
        alpha = np.clip((n - 0.03) * 1.6, 0, 1)[..., None] * strength
        color = cv2.resize(color, (self.w, self.h), interpolation=cv2.INTER_LINEAR)
        alpha = cv2.resize(alpha, (self.w, self.h), interpolation=cv2.INTER_LINEAR)[..., None]
        return color.astype(np.float32), alpha.astype(np.float32)


class Trail:
    def __init__(self, seconds: float = 2.5):
        self.sec = seconds
        self.pts: deque = deque()

    def add(self, t: float, p):
        self.pts.append((t, int(p[0]), int(p[1])))
        while self.pts and t - self.pts[0][0] > self.sec:
            self.pts.popleft()

    def reset(self):
        self.pts.clear()

    def draw(self, canvas, now: float):
        pts = list(self.pts)
        for (t0, x0, y0), (t1, x1, y1) in zip(pts[:-1], pts[1:]):
            k = max(0.0, 1.0 - (now - t1) / self.sec)
            cv2.line(canvas, (x0, y0), (x1, y1), (int(255 * k), int(200 * k), int(60 * k)),
                     max(1, int(1 + 4 * k)), cv2.LINE_AA)


def draw_gaze_cursor(canvas, p, ring: float = 0.0, color=(0, 220, 255)):
    c = (int(p[0]), int(p[1]))
    cv2.circle(canvas, c, 14, color, 2, cv2.LINE_AA)
    cv2.circle(canvas, c, 3, color, -1, cv2.LINE_AA)
    if ring > 0:  # 長い瞬きの進行リング
        cv2.ellipse(canvas, c, (30, 30), -90, 0, 360 * ring, (0, 255, 120), 5, cv2.LINE_AA)


class Keypad:
    LABELS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "DEL", "0", "CLR"]

    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        x0, x1 = 0.22 * w, 0.78 * w
        y0, y1 = 0.26 * h, 0.94 * h
        gap = 0.012 * w
        bw = (x1 - x0 - 2 * gap) / 3
        bh = (y1 - y0 - 3 * gap) / 4
        self.rects: List[Tuple[int, int, int, int]] = []
        for i in range(12):
            r, c = divmod(i, 3)
            self.rects.append((int(x0 + c * (bw + gap)), int(y0 + r * (bh + gap)), int(bw), int(bh)))
        self.text = ""
        self.hover: Optional[int] = None     # 現在ラッチ中の選択ボタン
        self._cand: Optional[int] = None
        self._cand_t = 0.0
        self.flash: Tuple[int, float] = (-1, 0.0)

    def _hit(self, p, margin=0.0) -> Optional[int]:
        for i, (x, y, w, h) in enumerate(self.rects):
            mx, my = margin * w, margin * h
            if x - mx <= p[0] <= x + w + mx and y - my <= p[1] <= y + h + my:
                return i
        return None

    def update_gaze(self, p, t: float, dwell: float = 0.15):
        """視線による「選択」: ボタンに dwell 秒とどまったら選択を切替 (ヒステリシス付き)。"""
        if self.hover is not None and self._hit(p, 0.12) == self.hover:
            self._cand = None        # 現在の選択の拡張領域内にいる間は動かさない
            return
        h = self._hit(p)
        if h is None:
            self._cand = None
            return
        if h != self._cand:
            self._cand, self._cand_t = h, t
        elif t - self._cand_t >= dwell:
            self.hover, self._cand = h, None

    def press(self, t: float) -> Optional[str]:
        """長い瞬きによる「決定」。"""
        if self.hover is None:
            return None
        lab = self.LABELS[self.hover]
        if lab == "DEL":
            self.text = self.text[:-1]
        elif lab == "CLR":
            self.text = ""
        elif len(self.text) < 12:
            self.text += lab
        self.flash = (self.hover, t)
        return lab

    def draw(self, canvas, t: float, ring: float):
        put_text(canvas, "Gaze = select   /   Hold a long blink = confirm", (self.w // 2, int(0.07 * self.h)),
                 0.9, (200, 200, 200), 2, "c")
        x, y, w, h = int(0.22 * self.w), int(0.1 * self.h), int(0.56 * self.w), int(0.12 * self.h)
        cv2.rectangle(canvas, (x, y), (x + w, y + h), (60, 60, 60), -1)
        cv2.rectangle(canvas, (x, y), (x + w, y + h), (150, 150, 150), 2)
        put_text(canvas, self.text + ("_" if int(t * 2) % 2 == 0 else ""), (x + 25, y + int(h * 0.68)),
                 2.0, (255, 255, 255), 3)
        for i, (bx, by, bw, bh) in enumerate(self.rects):
            sel = i == self.hover
            fi, ft = self.flash
            flashing = fi == i and t - ft < 0.35
            col = (60, 190, 90) if flashing else ((120, 90, 30) if sel else (62, 62, 62))
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, -1)
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), (0, 220, 255) if sel else (110, 110, 110),
                          6 if sel else 2)
            put_text(canvas, self.LABELS[i], (bx + bw // 2, by + int(bh * 0.65)), 2.2, (255, 255, 255), 3, "c")
            if sel and ring > 0:  # 決定までの進行バー
                cv2.rectangle(canvas, (bx, by + bh - 10), (bx + int(bw * ring), by + bh), (0, 255, 120), -1)
