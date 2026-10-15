from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import cv2
import numpy as np

# MediaPipe FaceMesh (refine_landmarks=True で 478 点, 468- が虹彩)
# 被験者の右目(画像左) / 左目(画像右)。軸は常に「画像の左→右」に揃える。
R_EYE = dict(left=33, right=133, iris=468,
             lids=((159, 145), (158, 153), (160, 144)))
L_EYE = dict(left=362, right=263, iris=473,
             lids=((386, 374), (385, 380), (387, 373)))

# 頭部姿勢用の汎用3D顔モデル [mm] (x右, y下, z奥行き(カメラから遠ざかる向き), 鼻先が原点)
_POSE_IDX = (1, 152, 33, 263, 61, 291)
_POSE_MODEL = np.array([
    (0.0, 0.0, 0.0),        # 鼻先
    (0.0, 63.6, 12.5),      # 顎
    (-43.3, -32.7, 26.0),   # 被験者右目尻 (画像左)
    (43.3, -32.7, 26.0),    # 被験者左目尻 (画像右)
    (-28.9, 28.9, 24.1),    # 口角(画像左)
    (28.9, 28.9, 24.1),     # 口角(画像右)
], dtype=np.float64)

FEATURE_NAMES = ("uL", "vL", "uR", "vR", "open", "hx", "hy", "px", "py", "scale")


@dataclass
class FaceObs:
    features: np.ndarray       # shape (10,) 回帰入力 (FEATURE_NAMES)
    openness: float            # 両目の平均開眼度 (目の縦/横比)
    landmarks_px: np.ndarray   # (478,2) 画素座標 (描画用)


def _eye_features(pts: np.ndarray, e: dict):
    a, b = pts[e["left"]], pts[e["right"]]
    axis = b - a
    w = float(np.linalg.norm(axis)) + 1e-6
    ax = axis / w
    nrm = np.array([-ax[1], ax[0]])  # 軸を90度回した方向(画像下向きが正)
    d = pts[e["iris"]] - (a + b) / 2.0
    u, v = float(d @ ax) / w, float(d @ nrm) / w  # 目の幅で正規化、ロール不変
    lid = np.mean([np.linalg.norm(pts[i] - pts[j]) for i, j in e["lids"]]) / w
    return u, v, float(lid)


class FaceTracker:
    def __init__(self, width: int, height: int):
        import mediapipe as mp  # 遅延import (テスト時に不要)
        self._mesh = mp.solutions.face_mesh.FaceMesh(
            static_image_mode=False, max_num_faces=1, refine_landmarks=True,
            min_detection_confidence=0.5, min_tracking_confidence=0.5)
        self.w, self.h = width, height
        f = float(width)  # 内部パラメータの近似 (画角~53deg相当)
        self._K = np.array([[f, 0, width / 2], [0, f, height / 2], [0, 0, 1]], dtype=np.float64)
        self._rvec = None
        self._tvec = None

    def close(self):
        self._mesh.close()

    def process(self, bgr: np.ndarray) -> Optional[FaceObs]:
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        rgb.flags.writeable = False
        res = self._mesh.process(rgb)
        if not res.multi_face_landmarks:
            self._rvec = self._tvec = None
            return None
        lm = res.multi_face_landmarks[0].landmark
        pts = np.array([(p.x * self.w, p.y * self.h) for p in lm], dtype=np.float64)

        uR, vR, lidR = _eye_features(pts, R_EYE)
        uL, vL, lidL = _eye_features(pts, L_EYE)
        openness = 0.5 * (lidR + lidL)

        # 頭部姿勢 (OpenCV solvePnP)。回転行列の第3列(顔の前後軸)を yaw/pitch 相当の連続量として使う。
        img_pts = pts[list(_POSE_IDX)]
        ok = False
        if self._rvec is not None:
            ok, self._rvec, self._tvec = cv2.solvePnP(
                _POSE_MODEL, img_pts, self._K, None, self._rvec, self._tvec, True, cv2.SOLVEPNP_ITERATIVE)
        if not ok:
            ok, self._rvec, self._tvec = cv2.solvePnP(
                _POSE_MODEL, img_pts, self._K, None, flags=cv2.SOLVEPNP_ITERATIVE)
        if not ok:
            return None
        R, _ = cv2.Rodrigues(self._rvec)
        hx, hy = float(R[0, 2]), float(R[1, 2])

        c = 0.5 * (pts[R_EYE["left"]] + pts[L_EYE["right"]])  # 両目尻の中点 ~ 顔位置
        iod = float(np.linalg.norm(pts[R_EYE["left"]] - pts[L_EYE["right"]]))
        feat = np.array([uL, vL, uR, vR, openness,
                         hx, hy, c[0] / self.w, c[1] / self.h, iod / self.w])
        return FaceObs(feat, openness, pts)
