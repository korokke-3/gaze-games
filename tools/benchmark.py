"""録画したセッション (run_gaze.py --record) で、視線推定の方式を同じ条件で比較する。

    .venv/bin/python tools/benchmark.py profiles/sessions/<日時>

比較する方式:
  classic        : 虹彩ランドマーク + 頭部姿勢 -> リッジ回帰 (特徴量・次数・正則化は点単位の交差検証で選択)
  wet_4pt        : WebEyeTrack の元の手順 (4点、各点で平均に最も近い1フレーム、アフィン + Adam 10step)
  wet_allpts     : WebEyeTrack の適応を、較正の全点 (各点1フレーム) で行う
  hybrid         : classic の特徴量 + BlazeGaze の CNN 埋め込み (PCA) + 頭部ベクトル + 顔の3D位置 -> リッジ回帰
  stack          : [WebEyeTrack の予測, 虹彩 u, v, 開眼度] -> 線形リッジ (= アプリの --engine hybrid)
評価: 較正に使っていない点 (test: 同じ姿勢 / test_moved: 姿勢を変えた後) で、
      点が出てから SETTLE 秒以降のフレームの誤差。px, cm, 視角[deg] で表示する。
"""
from __future__ import annotations

import csv
import os
import sys
from collections import defaultdict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from gazekit.calibration import _expand, _ridge_fit, fit_groups   # noqa: E402

SETTLE = 0.6


def load_session(d):
    rows = list(csv.DictReader(open(os.path.join(d, "labels.csv"))))
    meta = dict(l.split(None, 1) for l in open(os.path.join(d, "meta.txt")).read().strip().splitlines())
    W, H = (int(v) for v in meta["screen_px"].split())
    cw, ch = (float(v) for v in meta["screen_cm"].split())
    return rows, (W, H), (cw, ch)


def extract(d, rows, screen_px, screen_cm):
    """全フレームについて、classic の特徴量と WebEyeTrack の前処理結果を計算する (時間がかかるのでキャッシュ)。"""
    cache = os.path.join(d, "features.npz")
    if os.path.exists(cache):
        z = np.load(cache, allow_pickle=False)
        return {k: z[k] for k in z.files}
    from gazekit.face import FaceTracker
    from gazekit.wet import WebEyeTrackEngine
    eng = WebEyeTrackEngine(screen_px, screen_cm)
    ft = None
    N = len(rows)
    out = {"cls": np.full((N, 10), np.nan), "emb": np.full((N, 512), np.nan, np.float32),
           "hv": np.full((N, 3), np.nan), "fo": np.full((N, 3), np.nan), "closed": np.ones(N, bool),
           "open": np.full(N, np.nan)}
    for i, r in enumerate(rows):
        img = cv2.imread(os.path.join(d, "frames", r["frame"]))
        if img is None:
            continue
        if ft is None:
            ft = FaceTracker(img.shape[1], img.shape[0])
        o = ft.process(img)
        if o is not None:
            out["cls"][i] = o.features
            out["open"][i] = o.openness
        w = eng.process(img)
        if w is not None and w.eye_patch is not None:
            out["emb"][i] = eng.embed([w.eye_patch])[0]
            out["hv"][i], out["fo"][i], out["closed"][i] = w.head_vector, w.face_origin_3d, w.closed
        if i % 200 == 0:
            print("  features %d / %d" % (i, N), flush=True)
    np.savez(cache, **out)
    return out


def errors(P, Y, seg, valid, px_per_cm, dist_cm):
    """フレーム単位と、注視(点)ごとに平均した予測の誤差。"""
    e = np.linalg.norm(P[valid] - Y[valid], axis=1)
    fix = []
    for s in np.unique(seg[valid]):
        m = valid & (seg == s)
        fix.append(np.linalg.norm(P[m].mean(0) - Y[m][0]))
    fix = np.array(fix)

    def conv(px):
        cm = px / px_per_cm
        return px, cm, np.degrees(np.arctan(cm / dist_cm))
    return conv(float(np.mean(e))), conv(float(np.mean(fix))), int(valid.sum()), len(fix)


def main(d):
    rows, (W, H), (cw, ch) = load_session(d)
    print("session %s: %d frames, screen %dx%d px / %.1fx%.1f cm" % (d, len(rows), W, H, cw, ch))
    F = extract(d, rows, (W, H), (cw, ch))
    Y = np.array([[float(r["x"]), float(r["y"])] for r in rows])
    seg = np.array([int(r["seg"]) for r in rows])
    kind = np.array([r["kind"] for r in rows])
    phase = np.array([r["phase"] for r in rows])
    tin = np.array([float(r["t_in_seg"]) for r in rows])
    ok_cls = ~np.isnan(F["cls"][:, 0])
    ok_wet = ~np.isnan(F["emb"][:, 0]) & ~F["closed"]
    base_open = np.nanmedian(F["open"][(phase == "calib") & ok_cls])
    open_ok = F["open"] >= 0.75 * base_open
    settled = tin >= SETTLE
    calib = (phase == "calib") & settled
    px_per_cm = W / cw
    dist_cm = float(np.nanmedian(F["fo"][:, 2]))
    print("face distance (WebEyeTrack estimate): %.0f cm, %.1f px/cm" % (dist_cm, px_per_cm))
    preds = {}

    # ---- classic ----
    m = calib & ok_cls & open_ok
    model = fit_groups(F["cls"][m], Y[m], seg[m], (W, H), base_open)
    P = np.full_like(Y, np.nan)
    P[ok_cls] = np.stack([model.predict(f) for f in F["cls"][ok_cls]])
    preds["classic"] = (P, ok_cls & open_ok)
    print("classic: features %s, degree %d" % (model.cols, model.degree))

    # ---- WebEyeTrack ----
    from gazekit.wet import GazeMLP, KalmanFilter2D, KerasAdam, compute_affine_transform
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = dict(np.load(os.path.join(root, "models", "blazegaze_mlp.npz")))
    Xw = np.concatenate([F["emb"], F["hv"], F["fo"]], 1).astype(np.float32)
    norm = lambda p: p / np.array([W, H]) - 0.5          # noqa: E731
    scr = np.array([cw, ch], np.float32)

    def wet_run(points_mask_fn):
        mlp = GazeMLP(base)
        # 適応前のモデルで、時系列順にカルマンフィルタをかけた予測 (元実装の較正と同じく、これの平均に近いフレームを選ぶ)
        sel_idx, targets = [], []
        for s in np.unique(seg[(phase == "calib") & (kind == "fix")]):
            if not points_mask_fn(Y[seg == s][0]):
                continue
            idx = np.where((seg == s) & ok_wet)[0]
            if len(idx) == 0:
                continue
            p, _ = mlp.forward(Xw[idx])
            k = idx[np.argmin(np.linalg.norm(p - p.mean(0), axis=1))]
            sel_idx.append(k)
            targets.append(norm(Y[k]))
        X, T = Xw[sel_idx], np.array(targets, np.float32)
        pred, _ = mlp.forward(X)
        A = compute_affine_transform(pred.astype(np.float64), T.astype(np.float64))
        opt = KerasAdam(1e-4)
        for _ in range(10):
            out, cache = mlp.forward(X)
            Af = A.astype(np.float32)
            p = out @ Af[:, :2].T + Af[:, 2]
            dd = (np.sign(p - T) * scr / (2 * len(T))) @ Af[:, :2]
            opt.apply(mlp.p, mlp.backward(cache, dd.astype(np.float32)))
        raw = np.full_like(Y, np.nan)
        o_all, _ = mlp.forward(Xw[ok_wet])
        raw[ok_wet] = ((o_all @ A[:, :2].T + A[:, 2]) + 0.5) * np.array([W, H])
        kf = KalmanFilter2D()
        P = np.full_like(Y, np.nan)
        for i in np.where(ok_wet)[0]:            # 録画順 = 時間順
            o, _ = mlp.forward(Xw[i:i + 1])
            n = kf.step(A @ np.append(o[0], 1.0))
            n = np.array([np.clip(n[0], -0.5, 0.5), np.clip(n[1], -0.45, 0.45)])
            P[i] = (n + 0.5) * np.array([W, H])
        return P, len(sel_idx), raw

    wet_pts = [(0.1 * W, 0.1 * H), (0.9 * W, 0.1 * H), (0.1 * W, 0.9 * H), (0.9 * W, 0.9 * H)]
    P, n4, _ = wet_run(lambda y: min(np.hypot(y[0] - a, y[1] - b) for a, b in wet_pts) < 2)
    preds["wet_4pt"] = (P, ok_wet)
    P, na, RAW = wet_run(lambda y: True)
    preds["wet_allpts"] = (P, ok_wet)
    # ---- stack (= アプリの hybrid エンジン): [WebEyeTrack の予測, 虹彩 u, v, 開眼度] -> 線形リッジ ----
    from gazekit.hybrid import StackModel, stack_features
    ok_s = ok_cls & ok_wet & open_ok
    ms = calib & ok_s
    sm = StackModel.fit(stack_features(RAW[ms], F["cls"][ms]), Y[ms], seg[ms])
    P = np.full_like(Y, np.nan)
    idx = np.where(ok_s)[0]
    P[idx] = np.stack([sm.predict(x) for x in stack_features(RAW[idx], F["cls"][idx])])
    preds["stack"] = (P, ok_s)
    print("wet_4pt: %d points, wet_allpts: %d points" % (n4, na))

    # ---- hybrid: classic 特徴 + CNN 埋め込み (PCA) + 頭部ベクトル + 顔位置 -> リッジ回帰 ----
    ok_h = ok_cls & ok_wet & open_ok
    mtr = calib & ok_h
    best = None
    for k in (0, 4, 8, 16, 32):
        E = F["emb"][mtr]
        mu = E.mean(0)
        U = np.linalg.svd(E - mu, full_matrices=False)[2][:k] if k else np.zeros((0, 512))
        def feats(idx, U=U, mu=mu):   # noqa: E306
            Z = (F["emb"][idx] - mu) @ U.T
            c = F["cls"][idx]
            return np.concatenate([(c[:, 0:1] + c[:, 2:3]) / 2, (c[:, 1:2] + c[:, 3:4]) / 2, c[:, 4:5],
                                   F["hv"][idx], F["fo"][idx], Z], 1)
        Xtr = feats(np.where(mtr)[0])
        mean, std = Xtr.mean(0), Xtr.std(0) + 1e-9
        G = seg[mtr]
        for deg in (1, 2):
            if deg == 2 and Xtr.shape[1] > 14:
                continue
            Xe = _expand((Xtr - mean) / std, deg)
            cnt = {g: (G == g).sum() for g in np.unique(G)}
            Wt = np.array([1.0 / cnt[g] for g in G]); Wt /= Wt.mean()
            for lam in (0.1, 1, 10, 100, 1000):
                errs = []
                ug = np.unique(G)
                for f in range(8):
                    te = np.isin(G, ug[f::8])
                    c_ = _ridge_fit(Xe[~te], Y[mtr][~te], lam, Wt[~te])
                    Pp = Xe[te] @ c_
                    for g in np.unique(G[te]):
                        mm = G[te] == g
                        errs.append(np.linalg.norm(Pp[mm].mean(0) - Y[mtr][te][mm][0]))
                e = float(np.sqrt(np.mean(np.square(errs))))
                if best is None or e < best[0]:
                    best = (e, k, deg, lam, feats, mean, std)
    e, k, deg, lam, feats, mean, std = best
    Xe = _expand((feats(np.where(mtr)[0]) - mean) / std, deg)
    G = seg[mtr]
    cnt = {g: (G == g).sum() for g in np.unique(G)}
    Wt = np.array([1.0 / cnt[g] for g in G]); Wt /= Wt.mean()
    coef = _ridge_fit(Xe, Y[mtr], lam, Wt)
    P = np.full_like(Y, np.nan)
    idx = np.where(ok_h)[0]
    P[idx] = _expand((feats(idx) - mean) / std, deg) @ coef
    preds["hybrid"] = (P, ok_h)
    print("hybrid: PCA %d dims, degree %d, lambda %g (CV %.0f px)" % (k, deg, lam, e))

    # ---- 結果 ----
    print()
    print("%-11s %-11s | %-26s | %-26s | frames/points" % ("method", "test set", "per-frame  px / cm / deg", "per-fixation px / cm / deg"))
    for name, (P, valid) in preds.items():
        for ph in ("test", "test_moved"):
            v = valid & (phase == ph) & settled & (kind == "fix") & ~np.isnan(P[:, 0])
            if v.sum() == 0:
                continue
            fr, fx, nf, npnt = errors(P, Y, seg, v, px_per_cm, dist_cm)
            print("%-11s %-11s | %5.0f / %4.1f / %4.2f        | %5.0f / %4.1f / %4.2f        | %d / %d" % (
                name, ph, fr[0], fr[1], fr[2], fx[0], fx[1], fx[2], nf, npnt))


if __name__ == "__main__":
    main(sys.argv[1])
