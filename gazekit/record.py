"""評価用データの録画 (run_gaze.py --record)。

画面に点を順に出し、その間のカメラ画像と「見ていた点」を保存する。保存したセッションを
tools/benchmark.py に渡すと、複数の視線推定方式を同じデータ・同じ評価方法で比較できる。

セッションの構成 (約2分):
  calib  : 較正用。5x4 の静止点 + WebEyeTrack の4点 (±0.4) + 頭を動かす3点
  test   : 評価用。較正点と重ならないランダムな12点 (同じ姿勢)
  test_moved : 頭の位置を少し変えてから、評価用の点8つ (姿勢変化への強さ)
保存先: profiles/sessions/<日時>/  frames/*.jpg と labels.csv
"""
from __future__ import annotations

import csv
import os
import queue
import threading
import time
from typing import List, Optional, Tuple

import cv2
import numpy as np


class Segment:
    def __init__(self, kind: str, phase: str, xy: Optional[Tuple[float, float]], show: float, note: str = ""):
        self.kind, self.phase, self.xy, self.show, self.note = kind, phase, xy, show, note


def build_session(W: int, H: int, seed: int = 0) -> List[Segment]:
    rng = np.random.default_rng(seed)
    segs: List[Segment] = []
    segs.append(Segment("pause", "calib", None, 5.0, "点が出たら、その中心を見つめてください (クリック不要)。頭はなるべく動かさない"))
    pts = [(0.06 + 0.88 * c / 4, 0.08 + 0.84 * r / 3) for r in range(4) for c in range(5)]
    pts += [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)]          # WebEyeTrack の較正点 (±0.4)
    order = rng.permutation(len(pts))
    for i in order:
        segs.append(Segment("fix", "calib", (pts[i][0] * W, pts[i][1] * H), 1.6))
    segs.append(Segment("pause", "calib", None, 4.0, "次は、点を見たまま頭をゆっくり 左右・上下 に動かしてください"))
    for hx, hy in [(0.5, 0.5), (0.22, 0.28), (0.78, 0.72)]:
        segs.append(Segment("head", "calib", (hx * W, hy * H), 6.0))
    segs.append(Segment("pause", "test", None, 4.0, "評価用の点です。同じように点を見つめてください"))
    for _ in range(12):
        segs.append(Segment("fix", "test", (rng.uniform(0.08, 0.92) * W, rng.uniform(0.1, 0.9) * H), 1.6))
    segs.append(Segment("pause", "test_moved", None, 7.0,
                        "椅子ごと少し左右どちらかにずれるか、顔を10cmほど画面に近づけて、その姿勢のまま続けてください"))
    for _ in range(8):
        segs.append(Segment("fix", "test_moved", (rng.uniform(0.08, 0.92) * W, rng.uniform(0.1, 0.9) * H), 1.6))
    return segs


class SessionRecorder:
    def __init__(self, root: str, W: int, H: int, screen_cm: Tuple[float, float]):
        self.dir = os.path.join(root, time.strftime("%Y%m%d_%H%M%S"))
        os.makedirs(os.path.join(self.dir, "frames"), exist_ok=True)
        self.W, self.H = W, H
        self.segs = build_session(W, H)
        self.i = 0
        self.t_seg: Optional[float] = None
        self.n = 0
        self.done = False
        self._q: "queue.Queue" = queue.Queue(maxsize=256)
        self._csv = open(os.path.join(self.dir, "labels.csv"), "w", newline="")
        self._w = csv.writer(self._csv)
        self._w.writerow(["frame", "t", "seg", "kind", "phase", "x", "y", "t_in_seg"])
        with open(os.path.join(self.dir, "meta.txt"), "w") as f:
            f.write("screen_px %d %d\nscreen_cm %.1f %.1f\n" % (W, H, screen_cm[0], screen_cm[1]))
        self._th = threading.Thread(target=self._writer, daemon=True)
        self._th.start()

    def _writer(self):
        while True:
            item = self._q.get()
            if item is None:
                break
            path, img = item
            cv2.imwrite(path, img, [cv2.IMWRITE_JPEG_QUALITY, 92])

    def current(self) -> Optional[Segment]:
        return None if self.done else self.segs[self.i]

    def update(self, frame, t: float):
        """新しいカメラフレームごとに呼ぶ。表示中の点のフレームを保存し、時間が来たら次の点へ進む。"""
        if self.done:
            return
        if self.t_seg is None:
            self.t_seg = t
        seg = self.segs[self.i]
        el = t - self.t_seg
        if seg.kind != "pause" and el <= seg.show:
            name = "%06d.jpg" % self.n
            self._q.put((os.path.join(self.dir, "frames", name), frame.copy()))
            self._w.writerow([name, "%.4f" % t, self.i, seg.kind, seg.phase, "%.1f" % seg.xy[0], "%.1f" % seg.xy[1],
                              "%.4f" % el])
            self.n += 1
        if el >= seg.show:
            self.i += 1
            self.t_seg = t
            if self.i >= len(self.segs):
                self.finish()

    def finish(self):
        self.done = True
        self._q.put(None)
        self._th.join(timeout=30)
        self._csv.close()

    def progress(self) -> Tuple[int, int]:
        return self.i, len(self.segs)
