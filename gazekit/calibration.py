from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np

# ---------------------------------------------------------------- 軌跡 -----

def _chaikin(pts: np.ndarray, it: int = 2) -> np.ndarray:
    for _ in range(it):
        q = 0.75 * pts[:-1] + 0.25 * pts[1:]
        r = 0.25 * pts[:-1] + 0.75 * pts[1:]
        new = np.empty((2 * len(q) + 2, 2))
        new[0], new[-1] = pts[0], pts[-1]
        new[1:-1:2], new[2:-1:2] = q, r
        pts = new
    return pts


class CalibrationPath:
    """画面全体を網羅する滑らかな追従軌跡。横6行の蛇行 + 縦3列の蛇行 (角は丸めて急旋回を避ける)。
    座標は画面ピクセル。時間 t[s] -> 点位置。速度は画面幅/秒で指定。"""

    def __init__(self, w: int, h: int, margin: float = 0.07, rows: int = 6,
                 cols: int = 3, speed: float = 0.5, ease: float = 1.0):
        xs = np.linspace(margin, 1 - margin, cols)
        ys = np.linspace(margin, 1 - margin, rows)
        pts: List[Tuple[float, float]] = []
        for i, y in enumerate(ys):
            row = [(margin, y), (1 - margin, y)]
            pts += row if i % 2 == 0 else row[::-1]
        for i, x in enumerate(xs):
            col = [(x, margin), (x, 1 - margin)] if i % 2 == 0 else [(x, 1 - margin), (x, margin)]
            pts += col
        P = np.array(pts) * np.array([w, h])
        P = _chaikin(P, 2)
        seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
        self.s = np.concatenate([[0], np.cumsum(seg)])   # 累積弧長 [px]
        self.P = P
        self.duration = self.s[-1] / (speed * w) + ease
        self.speed_px = speed * w
        self.ease = ease  # 開始時の静止/加速時間

    def at(self, t: float) -> np.ndarray:
        # 最初の ease 秒は始点で静止 (被験者が点を見つける時間)
        s = max(0.0, t - self.ease) * self.speed_px
        s = min(s, self.s[-1])
        return np.array([np.interp(s, self.s, self.P[:, 0]), np.interp(s, self.s, self.P[:, 1])])


# ---------------------------------------------------------------- 回帰 -----

RAW_NAMES = ("uL", "vL", "uR", "vR", "open", "hx", "hy", "px", "py", "scale")
# 特徴量セットの候補。少データ(十数点)では少ない特徴量ほど過学習しにくいので、交差検証で自動選択する。
FEATURE_SETS = (
    ("u", "v", "open", "hy"),
    ("u", "v", "open"),
    ("u", "v", "open", "hx", "hy"),
    ("u", "v", "hy"),
    ("u", "v", "open", "hx", "hy", "px", "py"),       # 頭の向き + 位置 (頭を動かした較正データがある場合に有効)
    ("u", "v", "open", "hx", "hy", "px", "py", "scale"),
    ("uL", "vL", "uR", "vR", "open", "hy"),
    RAW_NAMES,
)


def derive(F: np.ndarray, cols) -> np.ndarray:
    """生の10次元特徴量から、cols で指定した派生特徴量(u,v は両目の平均)を取り出す。"""
    F = np.atleast_2d(F)
    out = []
    for c in cols:
        if c == "u":
            out.append((F[:, 0] + F[:, 2]) / 2)
        elif c == "v":
            out.append((F[:, 1] + F[:, 3]) / 2)
        else:
            out.append(F[:, RAW_NAMES.index(c)])
    return np.stack(out, axis=1)


def _expand(Z: np.ndarray, degree: int) -> np.ndarray:
    cols = [np.ones((len(Z), 1)), Z]
    if degree >= 2:
        n = Z.shape[1]
        cols.append(np.stack([Z[:, i] * Z[:, j] for i in range(n) for j in range(i, n)], axis=1))
    return np.concatenate(cols, axis=1)


def _ridge_fit(X: np.ndarray, Y: np.ndarray, lam: float, wts: Optional[np.ndarray] = None) -> np.ndarray:
    pen = lam * np.eye(X.shape[1])
    pen[0, 0] = 0.0  # 切片は正則化しない
    if wts is not None:
        Xw = X * wts[:, None]
        return np.linalg.solve(X.T @ Xw + pen, Xw.T @ Y)
    return np.linalg.solve(X.T @ X + pen, X.T @ Y)


@dataclass
class GazeModel:
    mean: np.ndarray
    std: np.ndarray
    degree: int
    coef: np.ndarray          # (n_terms, 2)
    screen: Tuple[int, int]
    lag: float
    cv_error_px: float
    baseline_open: float
    n_samples: int
    train_F: Optional[np.ndarray] = None   # 追加学習(refit)用に学習サンプルを保持
    train_Y: Optional[np.ndarray] = None
    train_G: Optional[np.ndarray] = None   # サンプルが属する注視点グループ
    cols: Optional[Tuple[str, ...]] = None  # 使用する特徴量 (None: 旧プロファイル=生の10次元)

    def predict(self, feat: np.ndarray) -> np.ndarray:
        z = (derive(np.asarray(feat, dtype=np.float64), self.cols or RAW_NAMES) - self.mean) / self.std
        y = (_expand(z, self.degree) @ self.coef)[0]
        return np.array([min(max(y[0], -0.1 * self.screen[0]), 1.1 * self.screen[0]),
                         min(max(y[1], -0.1 * self.screen[1]), 1.1 * self.screen[1])])

    def save(self, path: str):
        d = dict(mean=self.mean.tolist(), std=self.std.tolist(), degree=self.degree,
                 coef=self.coef.tolist(), screen=list(self.screen), lag=self.lag,
                 cv_error_px=self.cv_error_px, baseline_open=self.baseline_open,
                 n_samples=self.n_samples,
                 train_F=None if self.train_F is None else self.train_F.tolist(),
                 train_Y=None if self.train_Y is None else self.train_Y.tolist(),
                 train_G=None if self.train_G is None else self.train_G.tolist(),
                 cols=None if self.cols is None else list(self.cols))
        with open(path, "w") as f:
            json.dump(d, f)

    @staticmethod
    def load(path: str) -> "GazeModel":
        with open(path) as f:
            d = json.load(f)
        return GazeModel(np.array(d["mean"]), np.array(d["std"]), d["degree"], np.array(d["coef"]),
                         tuple(d["screen"]), d["lag"], d["cv_error_px"], d["baseline_open"],
                         d["n_samples"],
                         None if d.get("train_F") is None else np.array(d["train_F"]),
                         None if d.get("train_Y") is None else np.array(d["train_Y"]),
                         None if d.get("train_G") is None else np.array(d["train_G"]),
                         None if d.get("cols") is None else tuple(d["cols"]))


class CalibrationRecorder:
    """キャリブレーション中の (時刻, 特徴量) を貯め、後で軌跡との対応を取って学習する。"""

    def __init__(self, path: CalibrationPath):
        self.path = path
        self.t: List[float] = []
        self.feat: List[np.ndarray] = []

    def add(self, t_rel: float, feat: Optional[np.ndarray]):
        if feat is not None:
            self.t.append(t_rel)
            self.feat.append(feat)

    # --- 学習 ---
    def fit(self, screen: Tuple[int, int], open_ratio_min: float = 0.75,
            lags: Sequence[float] = (0.0, 0.1, 0.2, 0.3)) -> Optional[GazeModel]:
        if len(self.t) < 120:
            return None
        T = np.array(self.t)
        F = np.stack(self.feat)
        base = float(np.median(F[:, 4]))
        keep = F[:, 4] >= open_ratio_min * base       # 瞬き/半目のフレームを除外
        T, F = T[keep], F[keep]
        keep2 = T >= self.path.ease + 0.3             # 開始直後(追従が安定する前)を除外
        T, F = T[keep2], F[keep2]
        if len(T) < 120:
            return None

        mean, std = F.mean(0), F.std(0) + 1e-9
        Z = (F - mean) / std
        best = None
        for lag in lags:
            Y = np.stack([self.path.at(t - lag) for t in T])  # 眼は目標より少し遅れて動く
            for degree in (1, 2):
                X = _expand(Z, degree)
                for lam in (0.1, 1.0, 10.0, 100.0):
                    err = self._cv(X, Y, lam, T)
                    if best is None or err < best[0]:
                        best = (err, lag, degree, lam)
        err, lag, degree, lam = best
        Y = np.stack([self.path.at(t - lag) for t in T])
        X = _expand(Z, degree)
        # 外れ値(誤追従/誤検出)を除いて再学習: 残差が MAD の3.5倍超を除外 (Huber風の重み付け1回)
        coef = _ridge_fit(X, Y, lam)
        res = np.linalg.norm(X @ coef - Y, axis=1)
        mad = np.median(np.abs(res - np.median(res))) * 1.4826 + 1e-6
        inl = res < np.median(res) + 3.5 * mad
        if inl.sum() > 0.6 * len(inl):
            coef = _ridge_fit(X[inl], Y[inl], lam)
        return GazeModel(mean, std, degree, coef, screen, lag, float(err), base, int(len(T)),
                         F[inl] if inl.sum() > 0.6 * len(inl) else F, Y[inl] if inl.sum() > 0.6 * len(inl) else Y)

    @staticmethod
    def _cv(X, Y, lam, T, folds: int = 5, block: float = 1.0) -> float:
        """時間ブロック(1秒)を巡回で5分割する交差検証。RMS誤差[px]を返す。"""
        fid = (np.floor((T - T[0]) / block).astype(int)) % folds
        errs = []
        for k in range(folds):
            te = fid == k
            if te.sum() < 5 or (~te).sum() < X.shape[1]:
                continue
            c = _ridge_fit(X[~te], Y[~te], lam)
            errs.append(np.linalg.norm(X[te] @ c - Y[te], axis=1))
        if not errs:
            return 1e9
        e = np.concatenate(errs)
        return float(np.sqrt(np.mean(e ** 2)))


def clean_group(F: np.ndarray, k: float = 3.0) -> np.ndarray:
    """1つの注視点で集めたフレームから外れ値(サッカード直後・瞬き・誤検出)を除く。"""
    if len(F) < 6:
        return F
    core = F[:, :4]                          # 虹彩の相対位置(両目)
    med = np.median(core, axis=0)
    d = np.linalg.norm(core - med, axis=1)
    mad = np.median(np.abs(d - np.median(d))) * 1.4826 + 1e-4
    return F[d < np.median(d) + k * mad]


def _group_cv(X, Y, W, G, lam, folds: int = 8) -> float:
    """注視点グループ単位の交差検証。見ていない点への汎化誤差を、各注視で予測を平均した値
    (実行時の平滑化後に近い) について RMS[px] で返す。"""
    ug = np.unique(G)
    k = min(folds, len(ug))
    if k < 3:
        return float("nan")
    fold_of = {g: i % k for i, g in enumerate(ug)}
    fid = np.array([fold_of[g] for g in G])
    errs = []
    for f in range(k):
        te = fid == f
        tr = ~te
        if tr.sum() < 10:
            continue
        c = _ridge_fit(X[tr], Y[tr], lam, W[tr])
        P = X[te] @ c
        for g in np.unique(G[te]):
            m = G[te] == g
            errs.append(np.linalg.norm(P[m].mean(0) - Y[te][m][0]))
    if not errs:
        return float("nan")
    return float(np.sqrt(np.mean(np.square(errs))))


def fit_groups(F: np.ndarray, Y: np.ndarray, G: np.ndarray, screen: Tuple[int, int],
               base_open: float, group_w: Optional[np.ndarray] = None,
               lam_grid=(0.1, 1.0, 10.0, 100.0, 1000.0)) -> GazeModel:
    """注視点(グループ)ごとに集めたサンプルから回帰を学習する。
    各グループの寄与はフレーム数に依らず等しい。次数と正則化は「グループ抜き交差検証」で選ぶ。"""
    cnt = {g: (G == g).sum() for g in np.unique(G)}
    W = np.array([1.0 / cnt[g] for g in G])
    if group_w is not None:
        W = W * group_w
    W = W / W.mean()
    best = None
    for cols in FEATURE_SETS:
        D = derive(F, cols)
        mean, std = D.mean(0), D.std(0) + 1e-9
        Z = (D - mean) / std
        for degree in (1, 2):
            X = _expand(Z, degree)
            for lam in lam_grid:
                e = _group_cv(X, Y, W, G, lam)
                if np.isnan(e):
                    continue
                if best is None or e < best[0]:
                    best = (e, cols, degree, lam, mean, std, Z)
    if best is None:                       # グループが少なすぎる: 少ない特徴量の線形で妥協
        cols = FEATURE_SETS[1]
        D = derive(F, cols)
        mean, std = D.mean(0), D.std(0) + 1e-9
        best = (float("nan"), cols, 1, 10.0, mean, std, (D - mean) / std)
    e, cols, degree, lam, mean, std, Z = best
    X = _expand(Z, degree)
    coef = _ridge_fit(X, Y, lam, W)
    return GazeModel(mean, std, degree, coef, screen, 0.0, float(e), base_open, int(len(F)), F, Y, G, cols)


def _err_on(m: GazeModel, Fv, Yv) -> float:
    P = np.stack([m.predict(f) for f in Fv])
    return float(np.sqrt(np.mean(np.sum((P - Yv) ** 2, axis=1))))


def refit(model: GazeModel, F_new: np.ndarray, Y_new: np.ndarray, groups: np.ndarray,
          max_train: int = 4000):
    """追加で集めた注視点サンプルを既存データに足して再学習する。
    新グループの 1/4 を検証用に取り分け、旧モデルと再学習モデルを同じデータで比べる。
    戻り値: (採用すべきモデル, 旧モデルの検証誤差px, 新モデルの検証誤差px)"""
    ug = np.unique(groups)
    hold = np.isin(groups, ug[::4])
    if len(ug) < 4 or hold.all():
        return model, float("nan"), float("nan")
    if model.train_F is not None:
        F_old, Y_old = model.train_F, model.train_Y
        G_old = model.train_G if model.train_G is not None else np.arange(len(F_old)) // 30
    else:
        F_old, Y_old, G_old = np.empty((0, F_new.shape[1])), np.empty((0, 2)), np.empty(0, dtype=int)
    off = (int(G_old.max()) + 1) if len(G_old) else 0
    G_new = groups + off

    def combine(mask, w):
        F = np.concatenate([F_old, F_new[mask]])
        Y = np.concatenate([Y_old, Y_new[mask]])
        G = np.concatenate([G_old, G_new[mask]])
        gw = np.concatenate([np.ones(len(F_old)), np.full(int(mask.sum()), w)])
        return F, Y, G, gw

    e_old = _err_on(model, F_new[hold], Y_new[hold])
    best = (float("inf"), 1.0)
    for w in (1.0, 4.0, 16.0):     # 新データの重み: 現在の姿勢/環境をどれだけ優先するか
        F, Y, G, gw = combine(~hold, w)
        tmp = fit_groups(F, Y, G, model.screen, model.baseline_open, gw)
        e = _err_on(tmp, F_new[hold], Y_new[hold])
        if e < best[0]:
            best = (e, w)
    e_new, w = best
    F, Y, G, gw = combine(np.ones(len(F_new), bool), w)
    final = fit_groups(F, Y, G, model.screen, model.baseline_open, gw)
    if len(final.train_F) > max_train:
        final.train_F, final.train_Y, final.train_G = (
            final.train_F[-max_train:], final.train_Y[-max_train:], final.train_G[-max_train:])
    return (final if e_new < e_old else model), e_old, e_new


def estimate_latency(model: GazeModel, items) -> Optional[float]:
    """点が切り替わってから、推定視線が前の点→新しい点の中間に達するまでの時間[s]の中央値。
    items: [(t_rel(n,), feats(n,10), prev_xy, new_xy), ...]。人の反応時間 + カメラ/処理遅延の合計。"""
    lats = []
    for t, F, A, B in items:
        A, B = np.asarray(A, float), np.asarray(B, float)
        d = B - A
        L2 = float(d @ d)
        if L2 < 150.0 ** 2 or len(t) < 8:
            continue
        P = np.stack([model.predict(f) for f in F])
        sprog = ((P - A) @ d) / L2                         # 0: 前の点, 1: 新しい点
        sm = np.array([np.median(sprog[max(0, i - 1):i + 2]) for i in range(len(sprog))])
        for i in range(1, len(sm) - 3):
            if sm[i] >= 0.5 and sm[i - 1] < 0.5 and np.all(sm[i:i + 3] >= 0.4):
                f = (0.5 - sm[i - 1]) / max(sm[i] - sm[i - 1], 1e-6)
                lats.append(float(t[i - 1] + f * (t[i] - t[i - 1])))
                break
    if len(lats) < 3:
        return None
    return float(np.median(lats))
