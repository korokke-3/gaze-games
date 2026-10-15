"""WebEyeTrack (Davalos+ 2025, arXiv:2508.19544) と同じ構成の視線推定エンジン。

元実装 https://github.com/RedForestAI/WebEyeTrack (MIT License) の Python 版
(webeyetrack/webeyetrack.py, model_based.py, utilities.py, filter.py, demo/main.py) を移植した。
計算は元実装と同じ式・同じ順序で行い、速度のために配列演算へまとめたところも結果は変わらない。
元実装との違いは「推論ライブラリ」だけ:
  - BlazeGaze のエンコーダ: TensorFlow/Keras -> ONNX に変換して OpenCV DNN (cv2.dnn) で実行
  - 視線 MLP と個人適応 (Adam): TensorFlow -> numpy (同じ式の手書き勾配)

処理の流れ (論文 Fig.2):
  MediaPipe FaceLandmarker (478点 + 顔の変換行列)
    -> 目の画像 (ホモグラフィで正面化, 128x512)        obtain_eyepatch
    -> 頭部ベクトル (顔の向き)                            get_head_vector
    -> 顔の3D位置 [cm] (虹彩径1.2cmで尺度を決めた顔の3D復元)  face_reconstruction
    -> BlazeGaze: CNN埋め込み(512) + 頭部(3) + 顔位置(3) -> MLP -> 画面上の正規化座標 [-0.5, 0.5]
    -> アフィン補正 -> カルマンフィルタ
個人適応 (論文 3.2, demo): 較正点で MLP だけを Adam (lr=1e-4, 10 step, MAE[cm]) で更新する。
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "models")

# ---- constants.py ----
LEFT_EYE_HORIZONTAL_LANDMARKS = [362, 263]
RIGHT_EYE_HORIZONTAL_LANDMARKS = [33, 133]
LEFT_EYE_EAR_LANDMARKS = [362, 385, 387, 263, 373, 380]
RIGHT_EYE_EAR_LANDMARKS = [133, 158, 160, 33, 144, 153]
RIGHT_IRIS_LANDMARKS = [468, 470, 469, 472, 471]   # center, top, right, bottom, left
LEFT_IRIS_LANDMARKS = [473, 475, 474, 477, 476]
AVERAGE_IRIS_SIZE_CM = 1.2
LEFTMOST_LANDMARK = 356
RIGHTMOST_LANDMARK = 127
VERTICAL_FOV_DEGREES = 60
NEAR, FAR = 1.0, 10000
MAX_STEP_CM = 5
EAR_THRESHOLD = 0.2


# ---- utilities.py ----
def rotation_matrix_to_euler_angles(R):
    pitch = np.degrees(np.arcsin(-R[2, 0]))
    yaw = np.degrees(np.arctan2(R[2, 1], R[2, 2]))
    roll = np.degrees(np.arctan2(R[1, 0], R[0, 0]))
    return pitch, yaw, roll


def euler_angles_to_rotation_matrix(pitch, yaw, roll):
    pitch, yaw, roll = np.radians(pitch), np.radians(yaw), np.radians(roll)
    R_x = np.array([[1, 0, 0], [0, np.cos(pitch), -np.sin(pitch)], [0, np.sin(pitch), np.cos(pitch)]])
    R_y = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
    R_z = np.array([[np.cos(roll), -np.sin(roll), 0], [np.sin(roll), np.cos(roll), 0], [0, 0, 1]])
    return np.dot(R_z, np.dot(R_y, R_x))


def pitch_yaw_roll_to_gaze_vector(pitch, yaw, roll):
    p, y, r = np.radians(pitch), np.radians(yaw), np.radians(roll)
    v = np.array([np.cos(p) * np.sin(y), np.sin(p), -np.cos(p) * np.cos(y)])
    cr, sr = np.cos(r), np.sin(r)
    return np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]]) @ v


def create_perspective_matrix(aspect_ratio):
    P = np.zeros((4, 4), dtype=np.float32)
    f = 1.0 / np.tan(np.pi / 180.0 * VERTICAL_FOV_DEGREES / 2.0)
    denom = 1.0 / (NEAR - FAR)
    P[0, 0] = f / aspect_ratio
    P[1, 1] = f
    P[2, 2] = (NEAR + FAR) * denom
    P[2, 3] = -1.0
    P[3, 2] = 2.0 * FAR * NEAR * denom
    return P


def convert_uv_to_xyz_all(P, lm3):
    """convert_uv_to_xyz を全点に適用 (逆行列は全点で共通なので1回だけ計算)。"""
    inv = np.linalg.inv(P)
    ndc = np.stack([2 * lm3[:, 0] - 1, 1 - 2 * lm3[:, 1], -np.ones(len(lm3)), np.ones(len(lm3))], axis=1)
    w = ndc @ inv.T
    return np.stack([-(w[:, 0] / w[:, 3]), w[:, 1] / w[:, 3], lm3[:, 2]], axis=1)


def estimate_camera_intrinsics(h, w):
    return np.array([[w, 0, w / 2], [0, w, h / 2], [0, 0, 1]], dtype=np.float64)


def transform_3d_to_3d(pts, rt):
    ph = np.hstack([pts, np.ones((len(pts), 1), dtype=np.float32)])
    return (rt @ ph.T).T[:, :3]


def transform_3d_to_2d(cam, K):
    cs = (K @ cam.T).T
    zs = np.where(np.abs(cs[:, 2]) < 1e-6, 1e-6, cs[:, 2])
    cs[:, 0] /= zs
    cs[:, 1] /= zs
    return cs[:, :2].astype(np.int32)


def refine_depth_by_radial_magnitude(proj, det, old_z):
    center = det.mean(axis=0)
    v = det - proj
    vn = np.linalg.norm(v, axis=1)
    c = center - proj
    dots = np.sum(v * c, axis=1)
    total = np.sum(np.where(dots < 0, -vn, vn))
    delta = 1e-1 * (total / len(proj))
    return old_z + max(-MAX_STEP_CM, min(MAX_STEP_CM, delta))


# ---- model_based.py ----
def compute_ear(lm_px, idx):
    p1, p2, p3, p4, p5, p6 = (lm_px[i] for i in idx)
    return (np.linalg.norm(p2 - p6) + np.linalg.norm(p3 - p5)) / (2 * np.linalg.norm(p1 - p4))


def obtain_eyepatch(frame, lm_px, pad=(0.4, 0.2), crop=512, dst=(512, 128)):
    """顔の4点で顔をホモグラフィ正面化し、眉間(151)〜鼻(195)の帯を目の画像として切り出す。"""
    center = lm_px[4]
    src = np.array([lm_px[103], lm_px[150], lm_px[379], lm_px[332]], dtype=np.float32)
    src = src + np.array(pad) * (src - center)
    dst_pts = np.array([[0, 0], [0, crop], [crop, crop], [crop, 0]], dtype=np.float32)
    M, _ = cv2.findHomography(src, dst_pts)
    warped = cv2.warpPerspective(frame, M, (crop, crop))
    wl = np.dot(M, np.vstack((lm_px.T, np.ones((1, lm_px.shape[0])))))
    wl = (wl[:2, :] / wl[2, :]).T.astype(np.int32)
    patch = warped[wl[151][1]:wl[195][1], :]
    return cv2.resize(patch, dst)


def get_head_vector(rt):
    pitch, yaw, roll = rotation_matrix_to_euler_angles(rt[:3, :3])
    return pitch_yaw_roll_to_gaze_vector(-yaw, pitch, roll)


def estimate_face_width(lm2, face_rt):
    """虹彩の直径(平均1.2cm)と顔幅の比から顔幅[cm]を推定 (元実装と同じく正規化座標で計算)。"""
    d = []
    for iris in (LEFT_IRIS_LANDMARKS, RIGHT_IRIS_LANDMARKS):
        d.append(np.linalg.norm(lm2[iris[4], :2] - lm2[iris[2], :2]))
    ratio = np.mean(d) / np.linalg.norm(lm2[LEFTMOST_LANDMARK] - lm2[RIGHTMOST_LANDMARK])
    return AVERAGE_IRIS_SIZE_CM / ratio


def face_reconstruction(P, lm3, face_width_cm, face_rt, K, fw, fh, z0=60):
    """顔の3D復元: 正規化メッシュ -> 実寸[cm] -> 回転 -> 鼻位置合わせ -> 半径方向のずれで奥行きを反復修正。"""
    rel = convert_uv_to_xyz_all(P, lm3)
    rel = rel - rel[4]
    rel *= np.array([-1, -1, 1])
    rel /= np.linalg.norm(rel[LEFTMOST_LANDMARK] - rel[RIGHTMOST_LANDMARK])
    canon = rel * face_width_cm
    face_r = face_rt[:3, :3].copy()
    pitch, yaw, roll = rotation_matrix_to_euler_angles(np.linalg.inv(face_r))
    face_r = euler_angles_to_rotation_matrix(-yaw, pitch, roll)
    canon = canon @ np.linalg.inv(face_r).T
    face_r /= np.linalg.norm(face_r, axis=0).mean()
    T = np.eye(4, dtype=np.float32)
    T[:3, :3] = face_r
    T[:3, 3] = np.array([0, 0, z0], dtype=np.float32)
    proj = transform_3d_to_2d(transform_3d_to_3d(canon, T), K).astype(np.float32)
    det = lm3[:, :2] * np.array([fw, fh])
    shift = det[4] - proj[4]
    T[:3, 3] += np.array([shift[0] * (z0 / K[0, 0]), shift[1] * (z0 / K[1, 1]), 0.0], dtype=np.float32)
    first = T.copy()
    for _ in range(10):
        p2 = transform_3d_to_2d(transform_3d_to_3d(canon, T), K)
        new_z = refine_depth_by_radial_magnitude(p2, det, old_z=T[2, 3])
        if np.abs(new_z - T[2, 3]) < 0.25:
            break
        T[0, 3] = first[0, 3] * (new_z / z0)
        T[1, 3] = first[1, 3] * (new_z / z0)
        T[2, 3] = new_z
    return T, transform_3d_to_3d(canon, T)


def estimate_face_origin_3d(face3d):
    l = face3d[LEFT_EYE_HORIZONTAL_LANDMARKS].mean(axis=0)
    r = face3d[RIGHT_EYE_HORIZONTAL_LANDMARKS].mean(axis=0)
    return (l + r) / 2


# ---- filter.py ----
class KalmanFilter2D:
    def __init__(self, dt=0.1, process_noise=1e-5, measurement_noise=1e-2):
        self.x = np.zeros((4, 1))
        self.F = np.array([[1, 0, dt, 0], [0, 1, 0, dt], [0, 0, 1, 0], [0, 0, 0, 1]])
        self.H = np.array([[1, 0, 0, 0], [0, 1, 0, 0]])
        self.R = measurement_noise * np.eye(2)
        self.Q = process_noise * np.eye(4)
        self.P = np.eye(4)

    def step(self, z):
        self.x = self.F @ self.x
        self.P = self.F @ self.P @ self.F.T + self.Q
        z = np.reshape(z, (2, 1))
        y = z - self.H @ self.x
        S = self.H @ self.P @ self.H.T + self.R
        K = self.P @ self.H.T @ np.linalg.inv(S)
        self.x = self.x + K @ y
        self.P = (np.eye(4) - K @ self.H) @ self.P
        return self.x[:2].flatten()


# ---- BlazeGaze (OpenCV DNN + numpy) ----
class GazeMLP:
    """[埋め込み512 | 頭部3 | 顔位置3] -> Dense16-ReLU -> Dense16-ReLU -> Dense2。個人適応はこの重みだけ更新する。"""
    NAMES = ("W0", "b0", "W1", "b1", "W2", "b2")

    def __init__(self, params: Dict[str, np.ndarray]):
        self.p = {k: params[k].astype(np.float32).copy() for k in self.NAMES}

    def forward(self, x):
        p = self.p
        z1 = x @ p["W0"] + p["b0"]
        a1 = np.maximum(z1, 0)
        z2 = a1 @ p["W1"] + p["b1"]
        a2 = np.maximum(z2, 0)
        return a2 @ p["W2"] + p["b2"], (x, z1, a1, z2, a2)

    def backward(self, cache, d_out):
        x, z1, a1, z2, a2 = cache
        p = self.p
        g = {"W2": a2.T @ d_out, "b2": d_out.sum(0)}
        dz2 = (d_out @ p["W2"].T) * (z2 > 0)
        g["W1"], g["b1"] = a1.T @ dz2, dz2.sum(0)
        dz1 = (dz2 @ p["W1"].T) * (z1 > 0)
        g["W0"], g["b0"] = x.T @ dz1, dz1.sum(0)
        return g


class KerasAdam:
    """Keras 3 の Adam と同じ更新式 (元実装は beta_1=0.85, beta_2=0.9, epsilon=1e-8)。"""

    def __init__(self, lr, b1=0.85, b2=0.9, eps=1e-8):
        self.lr, self.b1, self.b2, self.eps = lr, b1, b2, eps
        self.t = 0
        self.m: Dict[str, np.ndarray] = {}
        self.v: Dict[str, np.ndarray] = {}

    def apply(self, params, grads):
        self.t += 1
        alpha = self.lr * np.sqrt(1 - self.b2 ** self.t) / (1 - self.b1 ** self.t)
        for k, g in grads.items():
            g = g.astype(np.float32)
            m = self.m.setdefault(k, np.zeros_like(g))
            v = self.v.setdefault(k, np.zeros_like(g))
            m += (g - m) * (1 - self.b1)
            v += (np.square(g) - v) * (1 - self.b2)
            params[k] -= (m * alpha / (np.sqrt(v) + self.eps)).astype(np.float32)


def compute_affine_transform(src, dst):
    A, _, _, _ = np.linalg.lstsq(np.hstack([src, np.ones((src.shape[0], 1))]), dst, rcond=None)
    return A.T


@dataclass
class WetObs:
    landmarks_px: np.ndarray       # (478, 2) 描画・瞬き用
    openness: float                # gazekit の長い瞬き検出用 (目の縦横比)
    closed: bool                   # 元実装の EAR < 0.2 判定
    eye_patch: Optional[np.ndarray]
    head_vector: Optional[np.ndarray]
    face_origin_3d: Optional[np.ndarray]
    features = None                # 旧エンジン互換


class WebEyeTrackEngine:
    def __init__(self, screen_px: Tuple[int, int], screen_cm: Tuple[float, float]):
        import mediapipe as mp
        from mediapipe.tasks import python as mpt
        from mediapipe.tasks.python import vision
        opts = vision.FaceLandmarkerOptions(
            base_options=mpt.BaseOptions(model_asset_path=os.path.join(MODELS, "face_landmarker_v2_with_blendshapes.task")),
            output_face_blendshapes=True, output_facial_transformation_matrixes=True, num_faces=1)
        self._mp = mp
        self.landmarker = vision.FaceLandmarker.create_from_options(opts)
        self.encoder = cv2.dnn.readNetFromONNX(os.path.join(MODELS, "blazegaze_encoder.onnx"))
        self.base_params = dict(np.load(os.path.join(MODELS, "blazegaze_mlp.npz")))
        self.mlp = GazeMLP(self.base_params)
        self.screen_px = screen_px
        self.screen_cm = np.array(screen_cm, dtype=np.float32)
        self.kalman = KalmanFilter2D()
        self.affine: Optional[np.ndarray] = None
        self.face_width_cm: Optional[float] = None
        self.K = None
        self.P = None
        # 較正データ (元実装の calib_data と同じ: 適応1回ぶんを1要素として最大100, クリックは60秒で失効)
        self.calib: List[dict] = []
        self.max_points, self.click_ttl = 100, 60.0
        self.n_adapt = 0
        self.last_open: Optional[WetObs] = None

    def close(self):
        self.landmarker.close()

    def reset(self):
        """個人適応を捨てて、事前学習 (MPIIFaceGaze) の重みに戻す。"""
        self.mlp = GazeMLP(self.base_params)
        self.kalman = KalmanFilter2D()
        self.affine = None
        self.face_width_cm = None
        self.calib = []
        self.n_adapt = 0

    # --- 1フレームの前処理 ---
    def process(self, frame) -> Optional[WetObs]:
        h, w = frame.shape[:2]
        # 元実装はカメラの BGR 画像をそのまま SRGB として渡している (学習時も同じ) ので、まず同じ条件で検出する。
        # ただし MediaPipe は RGB 前提で、BGR では顔を見失う画像がある -> その時だけ RGB で再試行する。
        res = self.landmarker.detect(self._mp.Image(image_format=self._mp.ImageFormat.SRGB,
                                                    data=np.ascontiguousarray(frame)))
        if not res.face_landmarks:
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            res = self.landmarker.detect(self._mp.Image(image_format=self._mp.ImageFormat.SRGB, data=rgb))
            if not res.face_landmarks:
                return None
        lm = np.array([[p.x, p.y, p.z] for p in res.face_landmarks[0]])
        rt = np.array(res.facial_transformation_matrixes[0])
        px = lm[:, :2] * np.array([w, h])
        closed = (compute_ear(px, LEFT_EYE_EAR_LANDMARKS) < EAR_THRESHOLD or
                  compute_ear(px, RIGHT_EYE_EAR_LANDMARKS) < EAR_THRESHOLD)
        from .face import L_EYE, R_EYE, _eye_features
        openness = 0.5 * (_eye_features(px, R_EYE)[2] + _eye_features(px, L_EYE)[2])
        try:
            patch = obtain_eyepatch(frame, px)
            hv = get_head_vector(rt)
            if self.face_width_cm is None:
                self.face_width_cm = estimate_face_width(lm[:, :2], rt)
            if self.K is None:
                self.K = estimate_camera_intrinsics(h, w)
                self.P = create_perspective_matrix(w / h)
            _, face3d = face_reconstruction(self.P, lm, self.face_width_cm, rt, self.K, w, h)
            fo = estimate_face_origin_3d(face3d)
        except Exception:
            return WetObs(px, openness, True, None, None, None)
        o = WetObs(px, openness, closed, patch, hv.astype(np.float32), fo.astype(np.float32))
        if not closed:
            self.last_open = o
        return o

    def embed(self, patches: List[np.ndarray]) -> np.ndarray:
        out = []
        for p in patches:
            self.encoder.setInput(cv2.dnn.blobFromImage(p.astype(np.float32) / 255.0))
            out.append(self.encoder.forward().reshape(-1))
        return np.stack(out).astype(np.float32)

    def _inputs(self, obs_list: List[WetObs]):
        # 前処理スレッドで計算済みの入力 (o.X) があればそれを使う (CNN をメインスレッドで回さない)
        if all(getattr(o, "X", None) is not None for o in obs_list):
            return np.stack([o.X for o in obs_list]).astype(np.float32)
        e = self.embed([o.eye_patch for o in obs_list])
        hv = np.stack([o.head_vector for o in obs_list])
        fo = np.stack([o.face_origin_3d for o in obs_list])
        return np.concatenate([e, hv, fo], axis=1).astype(np.float32)

    # --- 推論 (元実装の step) ---
    def predict_norm(self, o: WetObs) -> Optional[np.ndarray]:
        """正規化座標 [-0.5,0.5] (画面中心が0)。目を閉じていれば None。"""
        if o is None or o.closed or o.eye_patch is None:
            return None
        pog, _ = self.mlp.forward(self._inputs([o]))
        pog = pog[0]
        if self.affine is not None:
            pog = self.affine @ np.append(pog, 1.0)
        return self.kalman.step(np.array([float(pog[0]), float(pog[1])]))

    def inputs_one(self, o: WetObs) -> np.ndarray:
        """1フレームの BlazeGaze 入力 [埋め込み512 | 頭部3 | 顔位置3]。"""
        return self._inputs([o])[0]

    def raw_px(self, X: np.ndarray) -> np.ndarray:
        """入力 (N,518) から、アフィン補正後・カルマンフィルタ前の予測 [px] (hybrid エンジン用)。"""
        pog, _ = self.mlp.forward(np.atleast_2d(X).astype(np.float32))
        if self.affine is not None:
            pog = pog @ self.affine[:, :2].T + self.affine[:, 2]
        return (pog + 0.5) * np.array(self.screen_px)

    def predict_px(self, o: WetObs) -> Optional[np.ndarray]:
        n = self.predict_norm(o)
        if n is None:
            return None
        # demo と同じく画面内にクリップ (x: ±0.5, y: ±0.45)
        n = np.array([np.clip(n[0], -0.5, 0.5), np.clip(n[1], -0.45, 0.45)])
        return (n + 0.5) * np.array(self.screen_px)

    # --- 個人適応 (元実装の adapt) ---
    def _prune(self):
        if len(self.calib) > self.max_points:
            self.calib = self.calib[-self.max_points:]
        now = time.time()
        self.calib = [c for c in self.calib if not (c["type"] == "click" and now - c["t"] > self.click_ttl)]

    def adapt(self, obs_list: List[WetObs], pog_norms: np.ndarray, steps_inner=10, inner_lr=1e-4,
              affine_transform=True, pt_type="calib_dot") -> np.ndarray:
        return self.adapt_X(self._inputs(obs_list), pog_norms, steps_inner, inner_lr, affine_transform, pt_type)

    def adapt_X(self, X_new: np.ndarray, pog_norms: np.ndarray, steps_inner=10, inner_lr=1e-4,
                affine_transform=True, pt_type="calib_dot") -> np.ndarray:
        """adapt() と同じ処理を、埋め込み済みの入力 X_new (N,518) で行う。"""
        self._prune()
        X_new = np.asarray(X_new, dtype=np.float32)
        Y_new = np.asarray(pog_norms, dtype=np.float32).reshape(-1, 2)
        X = np.concatenate([X_new] + [c["X"] for c in self.calib])
        Y = np.concatenate([Y_new] + [c["Y"] for c in self.calib])
        opt = KerasAdam(inner_lr)
        if affine_transform and len(Y) > 3:
            pred, _ = self.mlp.forward(X)
            self.affine = compute_affine_transform(pred.astype(np.float64), Y.astype(np.float64))
        B = len(Y)
        preds = None
        for _ in range(steps_inner):
            out, cache = self.mlp.forward(X)
            if affine_transform and self.affine is not None:
                A = self.affine.astype(np.float32)
                preds = out @ A[:, :2].T + A[:, 2]
                d_preds = np.sign(preds - Y) * self.screen_cm / (2 * B)     # d MAE[cm]
                d_out = d_preds @ A[:, :2]
            else:
                preds = out
                d_out = np.sign(preds - Y) * self.screen_cm / (2 * B)
            opt.apply(self.mlp.p, self.mlp.backward(cache, d_out.astype(np.float32)))
        self.calib.append({"X": X_new, "Y": Y_new, "t": time.time(), "type": pt_type})
        self.n_adapt += 1
        return preds

    @staticmethod
    def mae_cm(pred, y, screen_cm):
        return float(np.mean(np.abs((np.asarray(pred) - np.asarray(y)) * np.asarray(screen_cm))))

    # --- 保存 / 読み込み ---
    def save(self, path):
        d = {"screen_px": np.array(self.screen_px), "screen_cm": self.screen_cm,
             "face_width_cm": np.array(-1.0 if self.face_width_cm is None else self.face_width_cm),
             "affine": np.zeros((0,)) if self.affine is None else self.affine,
             "n_calib": np.array(len(self.calib))}
        for k, v in self.mlp.p.items():
            d["mlp_" + k] = v
        for i, c in enumerate(self.calib):
            d["calX%d" % i], d["calY%d" % i] = c["X"], c["Y"]
            d["calT%d" % i] = np.array([c["t"]])
            d["calK%d" % i] = np.array(c["type"])
        np.savez(path, **d)

    def load(self, path) -> bool:
        d = np.load(path, allow_pickle=False)
        if tuple(d["screen_px"]) != tuple(self.screen_px):
            return False
        self.mlp = GazeMLP({k: d["mlp_" + k] for k in GazeMLP.NAMES})
        self.affine = d["affine"] if d["affine"].size else None
        fw = float(d["face_width_cm"])
        self.face_width_cm = None if fw < 0 else fw
        self.calib = [{"X": d["calX%d" % i], "Y": d["calY%d" % i], "t": float(d["calT%d" % i][0]),
                       "type": str(d["calK%d" % i])} for i in range(int(d["n_calib"]))]
        self.n_adapt = len(self.calib)
        return True


def screen_size_cm(default=(53.1, 29.8)) -> Tuple[float, float]:
    """xrandr の物理サイズ [mm] から画面の大きさ [cm] を得る (元実装は screeninfo を使用)。"""
    import re
    import subprocess
    try:
        out = subprocess.run(["xrandr"], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r" connected (?:primary )?\d+x\d+\+\d+\+\d+ .*?(\d+)mm x (\d+)mm", out)
        if m and int(m.group(1)) > 0 and int(m.group(2)) > 0:
            return int(m.group(1)) / 10.0, int(m.group(2)) / 10.0
    except Exception:
        pass
    return default
