from __future__ import annotations

import os
from typing import Dict, Tuple

import cv2
import numpy as np

# OpenCV の putText は日本語を描けないので、Pillow + Noto Sans CJK で描いた文字画像を貼り付ける。
# 同じ文字列は画像をキャッシュして再利用する (毎フレーム描き直すと重い)。
_FONT_CANDIDATES = (
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/fonts-japanese-gothic.ttf",
    "/usr/share/fonts/truetype/takao-gothic/TakaoPGothic.ttf",
    "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
)


class JText:
    def __init__(self):
        self.path = next((p for p in _FONT_CANDIDATES if os.path.exists(p)), None)
        try:
            from PIL import Image, ImageDraw, ImageFont  # noqa: F401
            self._pil = True
        except ImportError:
            self._pil = False
        self.ok = self._pil and self.path is not None
        self._fonts: Dict[int, object] = {}
        self._cache: Dict[Tuple, np.ndarray] = {}

    def _font(self, size):
        from PIL import ImageFont
        f = self._fonts.get(size)
        if f is None:
            f = ImageFont.truetype(self.path, size, index=0)   # ttc の 0 番 = JP
            self._fonts[size] = f
        return f

    def _patch(self, text, size, color, stroke):
        key = (text, size, color, stroke)
        p = self._cache.get(key)
        if p is not None:
            return p
        from PIL import Image, ImageDraw
        font = self._font(size)
        x0, y0, x1, y1 = font.getbbox(text, stroke_width=stroke)
        w, h = max(1, x1 - x0) + 4, max(1, y1 - y0) + 4
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(img).text((2 - x0, 2 - y0), text, font=font, fill=(color[2], color[1], color[0], 255),
                                 stroke_width=stroke, stroke_fill=(0, 0, 0, 255))
        a = np.array(img)
        p = np.dstack([a[:, :, 2], a[:, :, 1], a[:, :, 0], a[:, :, 3]])   # RGBA -> BGRA
        if len(self._cache) > 600:
            self._cache.clear()
        self._cache[key] = p
        return p

    def size(self, text, size=36, stroke=2):
        if not self.ok:
            (w, h), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, size / 36.0, 2)
            return w, h
        p = self._patch(text, size, (255, 255, 255), stroke)
        return p.shape[1], p.shape[0]

    def draw(self, canvas, text, org, size=36, color=(255, 255, 255), anchor="c", stroke=2):
        """org: anchor='c' なら中心, 'l' なら左端の縦中央, 'r' なら右端の縦中央。複数行は \\n で区切る。"""
        lines = text.split("\n")
        if len(lines) > 1:
            lh = int(size * 1.35)
            y = org[1] - lh * (len(lines) - 1) / 2.0
            for ln in lines:
                self.draw(canvas, ln, (org[0], int(y)), size, color, anchor, stroke)
                y += lh
            return
        if not self.ok:   # フォントが無い環境: ASCII のみ表示できる
            from .viz import put_text
            sc = size / 36.0
            (w, h), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, sc, 2)
            put_text(canvas, text, (org[0], org[1] + h // 2), sc, color, 2, anchor)
            return
        p = self._patch(text, size, color, stroke)
        h, w = p.shape[:2]
        x = org[0] - (w // 2 if anchor == "c" else (w if anchor == "r" else 0))
        y = org[1] - h // 2
        H, W = canvas.shape[:2]
        x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, W), min(y + h, H)
        if x0 >= x1 or y0 >= y1:
            return
        sub = p[y0 - y:y1 - y, x0 - x:x1 - x]
        a = sub[:, :, 3:4].astype(np.float32) / 255.0
        roi = canvas[y0:y1, x0:x1]
        roi[:] = (roi * (1 - a) + sub[:, :, :3] * a).astype(np.uint8)


JT = JText()
