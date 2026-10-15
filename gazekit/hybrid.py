"""hybrid エンジン: WebEyeTrack (BlazeGaze) の予測と、FaceMesh の虹彩位置を組み合わせた個人回帰。

録画した評価データ (tools/benchmark.py) で比較した結果、最も精度と頑健性のバランスが良かった構成:
  特徴量 = [WebEyeTrack の予測 x, y (アフィン補正後・カルマン前), 虹彩位置 u, v (両目平均), 開眼度]
  -> 標準化 -> 線形リッジ回帰 (点ごとの寄与を等しく、正則化は点単位の交差検証で選択)
顔の位置・距離の特徴量は、較正中の姿勢の範囲外で外挿が崩れる (姿勢を変えると誤差が数倍になる) ので使わない。
"""
from __future__ import annotations

import json
from typing import Optional, Sequence

import numpy as np

from .calibration import _expand, _ridge_fit


def stack_features(wet_px: np.ndarray, cls_feat: np.ndarray) -> np.ndarray:
    """wet_px: (N,2) WebEyeTrack の予測 [px]、cls_feat: (N,10) gazekit.face の特徴量。"""
    c = np.atleast_2d(cls_feat)
    u = (c[:, 0] + c[:, 2]) / 2
    v = (c[:, 1] + c[:, 3]) / 2
    return np.concatenate([np.atleast_2d(wet_px), u[:, None], v[:, None], c[:, 4:5]], axis=1)


class StackModel:
    def __init__(self, mean, std, coef, cv_error_px: float, lam: float):
        self.mean, self.std, self.coef = mean, std, coef
        self.cv_error_px, self.lam = cv_error_px, lam
        self.baseline_open: Optional[float] = None     # 瞬き判定の基準 (開眼時の目の縦横比)
        self.long_blink: Optional[float] = None
        self.n_points = 0

    def predict(self, x: np.ndarray) -> np.ndarray:
        return (_expand((np.atleast_2d(x) - self.mean) / self.std, 1) @ self.coef)[0]

    @staticmethod
    def fit(X: np.ndarray, Y: np.ndarray, G: np.ndarray,
            lams: Sequence[float] = (0.01, 0.1, 1, 10, 100, 1000), folds: int = 8) -> "StackModel":
        mean, std = X.mean(0), X.std(0) + 1e-9
        Xe = _expand((X - mean) / std, 1)
        cnt = {g: (G == g).sum() for g in np.unique(G)}
        Wt = np.array([1.0 / cnt[g] for g in G])
        Wt /= Wt.mean()
        ug = np.unique(G)
        best = None
        for lam in lams:
            errs = []
            for f in range(min(folds, len(ug))):
                te = np.isin(G, ug[f::folds])
                c = _ridge_fit(Xe[~te], Y[~te], lam, Wt[~te])
                P = Xe[te] @ c
                for g in np.unique(G[te]):
                    m = G[te] == g
                    errs.append(np.linalg.norm(P[m].mean(0) - Y[te][m][0]))
            e = float(np.sqrt(np.mean(np.square(errs))))
            if best is None or e < best[0]:
                best = (e, lam)
        e, lam = best
        return StackModel(mean, std, _ridge_fit(Xe, Y, lam, Wt), e, lam)

    def save(self, path):
        with open(path, "w") as f:
            json.dump({"mean": self.mean.tolist(), "std": self.std.tolist(), "coef": self.coef.tolist(),
                       "cv_error_px": self.cv_error_px, "lam": self.lam, "baseline_open": self.baseline_open,
                       "long_blink": self.long_blink, "n_points": self.n_points}, f)

    @staticmethod
    def load(path) -> Optional["StackModel"]:
        try:
            with open(path) as f:
                d = json.load(f)
        except (OSError, ValueError):
            return None
        m = StackModel(np.array(d["mean"]), np.array(d["std"]), np.array(d["coef"]), d["cv_error_px"], d["lam"])
        m.baseline_open, m.long_blink = d.get("baseline_open"), d.get("long_blink")
        m.n_points = d.get("n_points", 0)
        return m
