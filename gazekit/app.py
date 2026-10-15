from __future__ import annotations

import argparse
import os
import re
import subprocess
import threading
import time
from collections import deque
from typing import Optional, Tuple

import cv2
import numpy as np

from .blink import BlinkDetector
from .calibration import (CalibrationPath, CalibrationRecorder, GazeModel, clean_group,
                          estimate_latency, fit_groups, refit)
from .face import FaceObs, FaceTracker
from .filters import GazeSmoother
from .oscontrol import CursorFilter, KeyHold, grab_screen, make_mouse, zoom_region, zoom_to_screen
from .football import FutsalGame
from .soccer11 import Soccer11
from .games import Menu, Mole, Quiz, Result, inside
from .jtext import JT
from .hybrid import StackModel, stack_features
from .record import SessionRecorder
from .wet import WebEyeTrackEngine, screen_size_cm
from .viz import BG, Heatmap, Keypad, Trail, draw_gaze_cursor, put_text

WIN = "gaze"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Camera:
    """最新フレームだけを保持するキャプチャスレッド (バッファ遅延を避ける)。"""

    def __init__(self, src, width, height, fps):
        if isinstance(src, int) or str(src).isdigit():
            self.cap = cv2.VideoCapture(int(src), cv2.CAP_V4L2)
            self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            self.cap.set(cv2.CAP_PROP_FPS, fps)
            self.live = True
        else:
            self.cap = cv2.VideoCapture(src)
            self.live = False
        if not self.cap.isOpened():
            raise RuntimeError("camera open failed: %s" % (src,))
        self.frame = None
        self.stamp = 0.0
        self.seq = 0
        self._lock = threading.Lock()
        self._run = True
        self._th = threading.Thread(target=self._loop, daemon=True)
        self._th.start()

    def _loop(self):
        while self._run:
            ok, f = self.cap.read()
            if not ok:
                if not self.live:
                    self._run = False
                time.sleep(0.005)
                continue
            with self._lock:
                self.frame, self.stamp, self.seq = f, time.perf_counter(), self.seq + 1

    def read(self, last_seq):
        with self._lock:
            if self.frame is None or self.seq == last_seq:
                return None
            return self.frame, self.stamp, self.seq

    def release(self):
        self._run = False
        self._th.join(timeout=1)
        self.cap.release()


class PreprocessWorker:
    """WebEyeTrack の前処理 (顔の点の検出・目の画像・顔の3D復元) を別スレッドで行う。
    メインスレッドは BlazeGaze の推論・アプリ処理・描画を並行して行えるので、計算は同じまま FPS が上がる。"""

    def __init__(self, cam: "Camera", engine, with_facemesh: bool = False):
        self.cam, self.engine = cam, engine
        self.with_facemesh = with_facemesh
        self.ft: Optional[FaceTracker] = None
        self.out = None
        self.seq = 0
        self._lock = threading.Lock()
        self._run = True
        self._th = threading.Thread(target=self._loop, daemon=True)
        self._th.start()

    def _loop(self):
        last = -1
        while self._run:
            r = self.cam.read(last)
            if r is None:
                time.sleep(0.002)
                continue
            frame, t, last = r
            obs = self.engine.process(frame)
            if obs is not None and obs.eye_patch is not None:
                obs.X = self.engine.inputs_one(obs)       # BlazeGaze の CNN もこのスレッドで
            if self.with_facemesh and obs is not None:
                # hybrid: 虹彩位置は FaceMesh (虹彩専用の精密化モデル付き) の方が精度が良かったのでそちらを使う
                if self.ft is None:
                    self.ft = FaceTracker(frame.shape[1], frame.shape[0])
                fo = self.ft.process(frame)
                obs.features = None if fo is None else fo.features
                if fo is not None:
                    obs.openness = fo.openness
            with self._lock:
                self.out, self.seq = (frame, t, obs), self.seq + 1

    def read(self, last_seq):
        with self._lock:
            if self.out is None or self.seq == last_seq:
                return None
            return self.out + (self.seq,)

    def stop(self):
        self._run = False
        self._th.join(timeout=2)


def detect_screen_size() -> Tuple[int, int]:
    try:
        out = subprocess.run(["xrandr"], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r"current (\d+) x (\d+)", out)
        if m:
            return int(m.group(1)), int(m.group(2))
    except Exception:
        pass
    return 1920, 1080


class App:
    def __init__(self, a):
        self.a = a
        self.W, self.H = a.screen or ((1280, 720) if a.windowed else detect_screen_size())
        self.cam = Camera(a.camera, a.width, a.height, 30)
        self.tracker: Optional[FaceTracker] = None
        self.blink = BlinkDetector()
        self.smoother = GazeSmoother()
        self.heat = Heatmap(self.W, self.H)
        self.trail = Trail()
        self.keypad = Keypad(self.W, self.H)
        self.pins = []   # 長い瞬きで「決定」した位置 (トラッキング画面用)
        self.model: Optional[GazeModel] = None
        self.profile = os.path.join(ROOT, "profiles", a.profile + ".json")
        # --- WebEyeTrack エンジン (既定) ---
        self.wet = a.engine in ("webeyetrack", "hybrid")     # どちらも WebEyeTrack エンジンを使う
        self.hyb = a.engine == "hybrid"
        self.stack: Optional[StackModel] = None
        self.stack_path = os.path.join(ROOT, "profiles", a.profile + ".stack.json")
        self.hcal = None
        self.engine: Optional[WebEyeTrackEngine] = None
        self.wet_profile = os.path.join(ROOT, "profiles", a.profile + ".wet.npz")
        self.wcal = None                  # 較正の進行状態
        self.wcal_report = None
        self._last_click_calib = None
        self.recorder: Optional[SessionRecorder] = None
        self.state = "intro"
        self.view = "track"
        self.show_heat = True
        self.show_trail = True
        self.show_cam = False
        self.msg = ""
        self.msg_until = 0.0
        self.path = CalibrationPath(self.W, self.H)
        self.rec: Optional[CalibrationRecorder] = None
        self.t0 = 0.0
        self.obs: Optional[FaceObs] = None
        self.gaze: Optional[np.ndarray] = None
        self.frame = None
        self.fps = 0.0
        self._last_t = None
        self._shot_n = 0
        # --- 実PC操作 (control / zoom 状態) ---
        self.mouse: Optional[OSMouse] = None
        self.cursor_f = CursorFilter()
        self.cursor = None            # OS座標 (実画面ピクセル)
        self.zoom_click = True        # 長い瞬き -> 拡大 -> もう一度長い瞬きでクリック
        self.paused = False
        self.zoom_img = None
        self.zoom_reg = None
        self.zoom_t0 = 0.0
        self.last_click = None
        self.CTRL_SIZE = (480, 300)
        # --- 描画モード (視線でお絵かき/文字) ---
        self.keys = KeyHold()
        self.strokes = []              # [{"color","width","pts"}]
        self.cur_stroke = None
        self.paint = None
        self.pen_toggle = False        # 長い瞬きでペンを上げ下げ
        self.pen_color = (255, 255, 255)
        self.pen_w = 8
        self.lazy = CursorFilter(dead_px=22, follow=0.30)   # 「遅れてついてくる筆」で線を滑らかに
        self.pen_pos = None
        self._space_t = -1.0
        self.blink.set_long(a.long_blink)
        self.scene = None               # メニュー / ゲーム (games.py)
        self.MENU_BTN = (10, 40, 250, 70)   # トラッキング/おえかき画面左上の「メニュー」ボタン
        # --- 追加学習 (refine): 画面上の点を見ながらマウスでクリック ---
        self.fbuf = deque(maxlen=300)     # 直近の (時刻, 特徴量) 約10秒分
        self._click = None                # マウスコールバックからの通知
        self.ref_pts = []
        self.ref_i = 0
        self.ref_F, self.ref_Y, self.ref_G = [], [], []
        self.ref_report = None
        self.ref_flash = 0.0
        self.pt_mode = "calib"
        self._pending = None
        self._dot_t0 = None
        self.dot_series = []

    # ----------------------------------------------------------- 入出力 --
    def load_profile(self):
        if self.wet:
            if not os.path.exists(self.wet_profile):
                return False
            if self.engine is None:
                self.engine = WebEyeTrackEngine((self.W, self.H), screen_size_cm())
            ok = self.engine.load(self.wet_profile)
            if ok and self.hyb:
                self.stack = StackModel.load(self.stack_path)
                ok = self.stack is not None
                if ok and self.stack.baseline_open:
                    self.blink.set_baseline(self.stack.baseline_open)
                    if self.stack.long_blink:
                        self.blink.set_long(self.stack.long_blink)
            if not ok:
                self.msg = "保存済みの較正は別の画面サイズのものです。再較正してください"
            return ok
        if os.path.exists(self.profile):
            try:
                m = GazeModel.load(self.profile)
                if tuple(m.screen) == (self.W, self.H):
                    self.model = m
                    self.blink.set_baseline(m.baseline_open)
                    return True
                self.msg = "Saved profile has another screen size: recalibrate"
            except Exception as e:  # 壊れたプロファイル
                self.msg = "Profile load failed: %s" % e
        return False

    def start_calibration_auto(self):
        if self.hyb:
            self.start_hcal()
        elif self.wet:
            self.start_wet_calib()
        else:
            self.start_points("calib")

    def start_calibration(self):
        self.rec = CalibrationRecorder(self.path)
        self.state = "countdown"
        self.t0 = time.perf_counter()
        self.msg = ""

    # ----------------------------------------------------------- 毎フレーム --
    def process(self, frame, t, obs=None, pre=False):
        """pre=True のときは obs (前処理済み) をそのまま使う。"""
        if self.wet:
            if self.engine is None:
                self.engine = WebEyeTrackEngine((self.W, self.H), screen_size_cm())
            self.tracker = self.engine
        elif self.tracker is None:
            self.tracker = FaceTracker(frame.shape[1], frame.shape[0])
        self.frame = frame
        self.obs = obs if pre else self.tracker.process(frame)
        o = self.obs
        ev = self.blink.update(o.openness if o else None, t)
        if not self.wet and o is not None and o.openness >= 0.75 * self.blink.baseline and not self.blink.closed:
            self.fbuf.append((t, o.features))
        if self._last_t is not None:
            self.fps = 0.9 * self.fps + 0.1 / max(t - self._last_t, 1e-3)
        dt = 0.0 if self._last_t is None else t - self._last_t
        self._last_t = t

        if self.state == "calib":
            self.rec.add(t - self.t0 - 1.5, o.features if (o and not self.blink.closed) else None)
        elif self.state == "wetcalib":
            self.wetcalib_frame(o, t)
        elif self.state == "hcal":
            self.hcal_frame(o, t)
        elif self.state == "record":
            self.recorder.update(frame, t)
            if self.recorder.done:
                self.state = "recorded"
        elif self.state in ("track", "control", "zoom", "draw", "scene") and (self.wet or self.model is not None):
            updated = False
            if self.hyb and self.stack is not None:
                p = self.hybrid_px(o, t)
                if p is not None and self.blink.is_open(o.openness):
                    updated = True
                    self.gaze = p
            elif self.wet:
                # 元実装と同じく、目が開いている全フレームで推論しカルマンフィルタを更新する
                p = self.engine.predict_px(o) if o is not None else None
                if p is not None and self.blink.is_open(o.openness):
                    updated = True
                    self.gaze = p
            elif o is not None and self.blink.is_open(o.openness):
                updated = True
                self.gaze = self.smoother.update(self.model.predict(o.features), t)
            if updated:
                if self.state == "track":
                    if self.view == "track":
                        self.heat.add(self.gaze, dt)
                        self.trail.add(t, self.gaze)
                    else:
                        self.keypad.update_gaze(self.gaze, t)
                elif self.state == "control" and not self.paused:
                    self.cursor = self.cursor_f.update(self._to_os(self.gaze))
                    if self.mouse:
                        self.mouse.move(*self.cursor)
                elif self.state == "draw":
                    self.update_pen(t)
                elif self.state == "scene":
                    self.scene.on_gaze(self.gaze, t)
            if self.state == "draw" and not updated:
                self.cur_stroke = None          # 目を閉じている間/顔ロスト時は線を切る
            if ev == "long_blink":
                self.on_long_blink(t)
            if self.state == "scene":
                self.scene.tick(t)
                self.handle_scene_request()
            if self.state == "zoom" and t - self.zoom_t0 > 8.0:   # 放置したらキャンセル
                self.exit_zoom()

    def _to_os(self, p):
        """較正時の画面座標 -> 実OS座標 (サイズが違う場合のみ拡縮)。"""
        sx, sy = self.model.screen if self.model is not None else (self.W, self.H)
        ox, oy = self.mouse.size if self.mouse else (sx, sy)
        return np.array([p[0] * ox / sx, p[1] * oy / sy])

    def on_long_blink(self, t):
        if self.state in ("track", "draw") and self.gaze is not None and inside(self.gaze, self.MENU_BTN, 0.15):
            self.open_scene("menu")          # 左上のメニューボタンを見て長い瞬き
            return
        if self.state == "scene":
            self.scene.on_long_blink(t)
            self.handle_scene_request()
            return
        if self.state == "track":
            if self.view == "keypad":
                self.keypad.press(t)
            elif self.gaze is not None:
                self.pins.append((int(self.gaze[0]), int(self.gaze[1]), t))
                self.pins = self.pins[-20:]
        elif self.state == "control":
            if self.cursor is None:
                return
            if self.cursor[0] < 120 and self.cursor[1] < 120:   # 左上隅 + 長い瞬き = 一時停止/再開
                self.paused = not self.paused
                return
            if self.paused:
                return
            if self.zoom_click:
                self.enter_zoom(t)
            else:
                self.do_click(self.cursor)
        elif self.state == "draw":
            self.pen_toggle = not self.pen_toggle
            self.cur_stroke = None
        elif self.state == "zoom" and self.gaze is not None:
            target = zoom_to_screen(self.gaze, self.zoom_reg, (self.W, self.H))
            self.exit_zoom()
            self.do_click(target)

    def do_click(self, pos):
        if self.mouse:
            self.mouse.move(*pos)
            self.mouse.click(1)
        self.last_click = (np.asarray(pos).copy(), time.perf_counter())

    # --- hybrid エンジン ---
    def _hyb_ok(self, o) -> bool:
        return (o is not None and o.eye_patch is not None and not o.closed
                and getattr(o, "features", None) is not None)

    def hybrid_px(self, o, t):
        if not self._hyb_ok(o):
            return None
        wp = self.engine.raw_px(self.engine.inputs_one(o))[0]
        p = self.stack.predict(stack_features(wp[None], o.features[None]))
        p = self.smoother.update(p, t)
        return np.array([min(max(p[0], 0), self.W - 1), min(max(p[1], 0), self.H - 1)])

    HCAL_DOT, HCAL_SETTLE, HCAL_HEAD = 1.6, 0.6, 6.0

    def start_hcal(self, refine: bool = False):
        """hybrid の較正: 静止点24 (5x4 + WebEyeTrack の4点) + 頭を動かす3点。録画評価と同じ手順。
        refine=True (追加学習) のときは、前回までの較正データに今回の分を足して学習し直す。"""
        rng = np.random.default_rng()
        pts = [(0.06 + 0.88 * c / 4, 0.08 + 0.84 * r / 3) for r in range(4) for c in range(5)]
        pts += [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)]
        segs = [("pause", None, 3.0)]
        segs += [("fix", (pts[i][0] * self.W, pts[i][1] * self.H), self.HCAL_DOT) for i in rng.permutation(len(pts))]
        segs += [("pause", None, 3.0)]
        segs += [("head", (hx * self.W, hy * self.H), self.HCAL_HEAD) for hx, hy in [(0.5, 0.5), (0.22, 0.28), (0.78, 0.72)]]
        if not refine:
            self.engine.reset()
        self.hcal = {"segs": segs, "i": 0, "t": None, "rows": [], "refine": refine}
        self.state = "hcal"
        self.msg = ""

    def hcal_frame(self, o, t):
        h = self.hcal
        if h["t"] is None:
            h["t"] = t
        kind, xy, show = h["segs"][h["i"]]
        el = t - h["t"]
        if kind != "pause" and el <= show and self._hyb_ok(o):
            h["rows"].append((h["i"], kind, xy, el, self.engine.inputs_one(o), o.features.copy(), o.openness))
        if el >= show:
            h["i"] += 1
            h["t"] = t
            if h["i"] >= len(h["segs"]):
                self.finish_hcal()

    def finish_hcal(self):
        rows = self.hcal["rows"]
        if len(rows) < 100:
            self.state, self.msg = "intro", "較正に失敗しました (顔が十分に検出できませんでした)。もう一度 SPACE"
            return
        seg = np.array([r[0] for r in rows])
        kind = np.array([r[1] for r in rows])
        Y = np.array([r[2] for r in rows], dtype=np.float64)
        tin = np.array([r[3] for r in rows])
        X = np.stack([r[4] for r in rows]).astype(np.float32)
        C = np.stack([r[5] for r in rows])
        op = np.array([r[6] for r in rows])
        # 1) WebEyeTrack の個人適応: 静止点ごとに、適応前の予測の平均に最も近い1フレーム (元実装と同じ選び方)
        sel, tgt = [], []
        for s_ in np.unique(seg[kind == "fix"]):
            idx = np.where(seg == s_)[0]
            p, _ = self.engine.mlp.forward(X[idx])
            sel.append(idx[np.argmin(np.linalg.norm(p - p.mean(0), axis=1))])
            tgt.append(Y[sel[-1]] / np.array([self.W, self.H]) - 0.5)
        self.engine.adapt_X(X[sel], np.array(tgt), steps_inner=10, inner_lr=1e-4, affine_transform=True,
                            pt_type="calib_dot")
        # 2) 組み合わせ回帰: 視線が落ち着いた後 (0.6s〜) の、目がしっかり開いたフレーム
        base = float(np.median(op))
        m = (tin >= self.HCAL_SETTLE) & (op >= 0.75 * base)
        Xs, Cs, Ys, Gs = X[m], C[m], Y[m], seg[m]
        rows_path = self.stack_path.replace(".stack.json", ".hcal.npz")
        if self.hcal.get("refine") and os.path.exists(rows_path):
            old = np.load(rows_path)                      # 前回までの較正データに足す
            off = int(old["G"].max()) + 1
            Xs, Cs = np.concatenate([old["X"], Xs]), np.concatenate([old["C"], Cs])
            Ys, Gs = np.concatenate([old["Y"], Ys]), np.concatenate([old["G"], Gs + off])
            if len(Ys) > 8000:                            # 古いものから捨てる
                Xs, Cs, Ys, Gs = Xs[-8000:], Cs[-8000:], Ys[-8000:], Gs[-8000:]
        Z = stack_features(self.engine.raw_px(Xs), Cs)
        self.stack = StackModel.fit(Z, Ys, Gs)
        self.blink.set_baseline(base)
        self.blink.auto_long()
        self.stack.baseline_open, self.stack.long_blink = base, self.blink.long_duration
        self.stack.n_points = len(np.unique(Gs))
        os.makedirs(os.path.dirname(rows_path), exist_ok=True)
        np.savez(rows_path, X=Xs.astype(np.float32), C=Cs, Y=Ys, G=Gs)
        dist = float(np.median(X[:, 517]))          # 顔までの距離 [cm] (WebEyeTrack の3D復元)
        os.makedirs(os.path.dirname(self.wet_profile), exist_ok=True)
        self.engine.save(self.wet_profile)
        self.stack.save(self.stack_path)
        cm = self.stack.cv_error_px / (self.W / screen_size_cm()[0])
        self.hcal_report = (self.stack.cv_error_px, cm, float(np.degrees(np.arctan(cm / max(dist, 1.0)))), dist,
                            int(len(Ys)), self.stack.n_points)
        self.smoother.reset()
        self.state = "hresult"

    def render_hcal(self, t):
        c = self.blank_canvas()
        cx, cy = self.W // 2, self.H // 2
        h = self.hcal
        kind, xy, show = h["segs"][h["i"]]
        el = 0.0 if h["t"] is None else max(0.0, t - h["t"])
        cv2.rectangle(c, (0, self.H - 8), (int(self.W * h["i"] / len(h["segs"])), self.H), (0, 200, 120), -1)
        if kind == "pause":
            msg = ("点が出たら、その中心を見つめてください (クリック不要・頭は動かさない)" if h["i"] == 0
                   else "次は、点を見たまま頭をゆっくり 左右・上下 に動かしてください")
            JT.draw(c, msg, (cx, cy - 20), 34, (255, 255, 255))
            JT.draw(c, "あと %d 秒" % int(np.ceil(show - el)), (cx, cy + 40), 30, (0, 230, 255))
        else:
            x, y = int(xy[0]), int(xy[1])
            cv2.circle(c, (x, y), int(30 - 20 * min(1.0, el / self.HCAL_SETTLE)), (255, 255, 255), 2, cv2.LINE_AA)
            cv2.circle(c, (x, y), 7, (0, 0, 255), -1, cv2.LINE_AA)
            if kind == "head":
                step = ["左へ", "右へ", "上へ", "下へ", "ぐるっと回す"][min(4, int(el / 1.2))]
                JT.draw(c, "点を見たまま、顔の向きを → " + step,
                        (min(max(x, 400), self.W - 400), y + 90 if y < self.H / 2 else y - 90), 32, (0, 230, 255))
        if self.obs is None:
            JT.draw(c, "顔が見えません", (cx, 40), 30, (80, 80, 255))
        return c

    def render_hresult(self):
        c = self.blank_canvas()
        cx, cy = self.W // 2, self.H // 2
        px, cm, deg, dist, n, k = self.hcal_report
        JT.draw(c, "較正完了 (hybrid: WebEyeTrack + 虹彩位置)", (cx, cy - 110), 50, (255, 255, 255))
        JT.draw(c, "見ていない点への誤差 (1点抜き交差検証): %d px / %.1f cm / %.1f°" % (px, cm, deg), (cx, cy - 35), 32,
                (210, 210, 210))
        JT.draw(c, "顔までの距離 約 %.0f cm   学習データ: 累計 %d フレーム / %d 点 (毎回自動で読み込みます)" % (dist, n, k),
                (cx, cy + 15), 24, (170, 170, 170))
        JT.draw(c, "SPACE: メニューへ   C: やり直す", (cx, cy + 80), 32, (255, 255, 255))
        self.hud(c)
        return c

    # --- WebEyeTrack 方式の較正 (元実装 demo/calibration_widget.py, main.py と同じ手順) ---
    WCAL_POINTS = [(-0.4, -0.4), (0.4, -0.4), (-0.4, 0.4), (0.4, 0.4)]   # 正規化座標 (画面中心が0)
    WCAL_INSTR = 5.0       # 説明表示 [s]
    WCAL_DOT = 2.05        # 1点あたり: 赤->白の色変化 50ms x 41 step

    def start_wet_calib(self):
        self.wcal = {"t0": time.perf_counter(), "i": -1, "frames": [[] for _ in self.WCAL_POINTS]}
        self.state = "wetcalib"
        self.msg = ""

    def _wcal_index(self, t):
        el = t - self.wcal["t0"] - self.WCAL_INSTR
        if el < 0:
            return -1
        i = int(el / self.WCAL_DOT)
        return i if i < len(self.WCAL_POINTS) else len(self.WCAL_POINTS)

    def wetcalib_frame(self, o, t):
        i = self._wcal_index(t)
        if 0 <= i < len(self.WCAL_POINTS) and o is not None and o.eye_patch is not None:
            # 元実装: 較正中は各フレームの推定結果 (目を閉じたフレームは norm_pog=(0,0)) を点ごとに保存
            n = self.engine.predict_norm(o)
            self.wcal["frames"][i].append((o, np.zeros(2) if n is None else n))
        if i >= len(self.WCAL_POINTS):
            self.finish_wet_calib()

    def finish_wet_calib(self):
        obs, targets = [], []
        for pt, fr in zip(self.WCAL_POINTS, self.wcal["frames"]):
            if not fr:
                continue
            pogs = np.array([n for _, n in fr])
            k = int(np.argmin(np.linalg.norm(pogs - pogs.mean(axis=0), axis=1)))   # 平均に最も近い1フレーム
            obs.append(fr[k][0])
            targets.append(pt)
        if len(obs) < 3:
            self.state = "intro"
            self.msg = "較正に失敗しました (顔が検出できませんでした)。もう一度 SPACE"
            return
        preds = self.engine.adapt(obs, np.array(targets), steps_inner=10, inner_lr=1e-4,
                                  affine_transform=True, pt_type="calib_dot")
        T = np.array(targets)
        P = preds[:len(T)]
        self.wcal_report = (T, P, self.engine.mae_cm(P, T, self.engine.screen_cm),
                            float(np.mean(np.linalg.norm((P - T) * np.array([self.W, self.H]), axis=1))))
        os.makedirs(os.path.dirname(self.wet_profile), exist_ok=True)
        self.engine.save(self.wet_profile)
        self.state = "wetresult"

    def click_calibrate(self, x, y):
        """元実装 demo の handle_mouse_click: クリック位置を見ていたとして1サンプルで適応 (1秒/0.05以内は無視)。"""
        if not self.wet or self.hyb or self.engine is None or self.obs is None or self.obs.eye_patch is None:
            return   # hybrid では、較正後に MLP を変えると組み合わせ回帰と食い違うのでクリック較正はしない
        n = np.array([x / self.W - 0.5, y / self.H - 0.5])
        now = time.time()
        lc = self._last_click_calib
        if lc is not None and (now - lc["t"] < 1.0 or np.linalg.norm(lc["n"] - n) < 0.05):
            lc["t"], lc["n"] = now, n
            return
        self.engine.adapt([self.obs], n[None, :], steps_inner=10, inner_lr=1e-4, affine_transform=True,
                          pt_type="click")
        self.engine.save(self.wet_profile)
        self._last_click_calib = {"t": now, "n": n}
        self.msg, self.msg_until = "クリック位置で較正しました (%d)" % self.engine.n_adapt, time.perf_counter() + 1.5

    def render_wetcalib(self, c, t):
        cx, cy = self.W // 2, self.H // 2
        i = self._wcal_index(t)
        # 元実装と同じく 10x10 の補助線と中心線を描く
        for gx in range(0, self.W, max(1, self.W // 10)):
            cv2.line(c, (gx, 0), (gx, self.H), (70, 70, 70), 1)
        for gy in range(0, self.H, max(1, self.H // 10)):
            cv2.line(c, (0, gy), (self.W, gy), (70, 70, 70), 1)
        cv2.line(c, (cx, 0), (cx, self.H), (140, 140, 140), 2)
        cv2.line(c, (0, cy), (self.W, cy), (140, 140, 140), 2)
        if i < 0:
            rem = self.WCAL_INSTR - (t - self.wcal["t0"])
            JT.draw(c, "較正 (WebEyeTrack 方式)", (cx, cy - 120), 56, (255, 255, 255))
            JT.draw(c, "4つの点が順に表示されます。点が赤から白に変わるまで、点を見つめてください。", (cx, cy - 40), 30,
                    (220, 220, 220))
            JT.draw(c, "開始まで %d 秒" % int(np.ceil(rem)), (cx, cy + 40), 40, (0, 230, 255))
        elif i < len(self.WCAL_POINTS):
            el = t - self.wcal["t0"] - self.WCAL_INSTR - i * self.WCAL_DOT
            r = min(1.0, el / 2.0)
            col = (int(255 * r), int(255 * r), 255)          # 赤 -> 白 (BGR)
            nx, ny = self.WCAL_POINTS[i]
            p = (int((nx + 0.5) * self.W), int((ny + 0.5) * self.H))
            cv2.circle(c, p, 20, col, -1, cv2.LINE_AA)
            JT.draw(c, "%d / %d" % (i + 1, len(self.WCAL_POINTS)), (cx, cy + 60), 28, (170, 170, 170))
        if self.obs is None:
            JT.draw(c, "顔が見えません", (cx, cy + 110), 30, (80, 80, 255))

    def render_wetresult(self, c):
        cx, cy = self.W // 2, self.H // 2
        T, P, mae_cm, err_px = self.wcal_report
        for (tx, ty), (px_, py_) in zip(T, P):
            a = (int((tx + 0.5) * self.W), int((ty + 0.5) * self.H))
            b = (int((px_ + 0.5) * self.W), int((py_ + 0.5) * self.H))
            cv2.line(c, a, b, (200, 200, 200), 2, cv2.LINE_AA)
            cv2.circle(c, a, 14, (90, 220, 90), -1, cv2.LINE_AA)
            cv2.circle(c, b, 10, (60, 60, 255), -1, cv2.LINE_AA)
        JT.draw(c, "較正完了 (BlazeGaze を4点で個人適応)", (cx, cy - 90), 48, (255, 255, 255))
        JT.draw(c, "較正点での誤差: 平均 %.1f cm / %d px   (緑: 点, 赤: 適応後の推定)" % (mae_cm, err_px), (cx, cy - 25),
                28, (210, 210, 210))
        JT.draw(c, "SPACE: メニューへ   C: やり直す   (使用中にマウスでクリックすると、その位置で追加較正)",
                (cx, cy + 40), 26, (255, 255, 255))

    def render_record(self, t):
        c = self.blank_canvas()
        cx, cy = self.W // 2, self.H // 2
        r = self.recorder
        if self.state == "recorded":
            JT.draw(c, "録画が終わりました (%d フレーム)" % r.n, (cx, cy - 60), 48, (255, 255, 255))
            JT.draw(c, "保存先: " + os.path.relpath(r.dir, ROOT), (cx, cy + 10), 28, (210, 210, 210))
            JT.draw(c, "Q で終了してください。このフォルダ名を教えてください", (cx, cy + 70), 28, (0, 230, 255))
            return c
        seg = r.current()
        el = 0.0 if r.t_seg is None else max(0.0, t - r.t_seg)
        i, n = r.progress()
        cv2.rectangle(c, (0, self.H - 8), (int(self.W * i / n), self.H), (0, 200, 120), -1)
        if seg is None:
            return c
        if seg.kind == "pause":
            JT.draw(c, seg.note, (cx, cy - 20), 34, (255, 255, 255))
            JT.draw(c, "あと %d 秒" % int(np.ceil(seg.show - el)), (cx, cy + 40), 30, (0, 230, 255))
        else:
            x, y = int(seg.xy[0]), int(seg.xy[1])
            rr = int(30 - 20 * min(1.0, el / 0.6))
            cv2.circle(c, (x, y), rr, (255, 255, 255), 2, cv2.LINE_AA)
            cv2.circle(c, (x, y), 7, (0, 0, 255), -1, cv2.LINE_AA)
            if seg.kind == "head":
                step = ["左へ", "右へ", "上へ", "下へ", "ぐるっと回す"][min(4, int(el / 1.2))]
                ty = y + 90 if y < self.H / 2 else y - 90
                JT.draw(c, "点を見たまま、顔の向きを → " + step, (min(max(x, 400), self.W - 400), ty), 32, (0, 230, 255))
        if self.obs is None:
            JT.draw(c, "顔が見えません", (cx, 40), 30, (80, 80, 255))
        return c

    # --- メニュー / ゲーム ---
    def open_scene(self, name, arg=None):
        self.msg = ""
        if name == "menu":
            self.scene, self.state = Menu(self.W, self.H), "scene"
        elif name == "quiz":
            self.scene, self.state = Quiz(self.W, self.H), "scene"
        elif name == "mole":
            self.scene, self.state = Mole(self.W, self.H), "scene"
        elif name == "football":
            self.scene, self.state = FutsalGame(self.W, self.H, keys=self.keys), "scene"
        elif name == "soccer11":
            self.scene, self.state = Soccer11(self.W, self.H, keys=self.keys), "scene"
        elif name == "result":
            game, lines = arg
            self.scene, self.state = Result(self.W, self.H, game, lines), "scene"
        elif name == "draw":
            self.enter_draw()
        elif name == "heat":
            self.state, self.view = "track", "track"
        elif name == "refine" and self.hyb:
            self.start_hcal(refine=True)                  # 前回までのデータに追加して学習し直す
        elif name == "calib" and self.hyb:
            self.start_hcal()
        elif name == "refine":
            self.start_wet_calib() if self.wet else self.start_refine()   # WebEyeTrack は較正を重ねて蓄積する
        elif name == "calib":
            if self.wet:
                self.engine.reset()                 # 事前学習の重みに戻してやり直す
                self.start_wet_calib()
            else:
                self.start_points("calib")
        self.smoother.reset()

    def handle_scene_request(self):
        if self.scene is not None and self.scene.request is not None:
            name, arg = self.scene.request
            self.scene.request = None
            self.open_scene(name, arg)

    def draw_menu_button(self, c):
        x, y, w, h = self.MENU_BTN
        hot = self.gaze is not None and inside(self.gaze, self.MENU_BTN, 0.15)
        cv2.rectangle(c, (x, y), (x + w, y + h), (110, 80, 30) if hot else (55, 55, 55), -1)
        cv2.rectangle(c, (x, y), (x + w, y + h), (0, 220, 255) if hot else (110, 110, 110), 2)
        JT.draw(c, "◀ メニュー", (x + w // 2, y + h // 2), 28, (255, 255, 255))
        if hot and self.blink.progress > 0:
            cv2.rectangle(c, (x, y + h - 8), (x + int(w * self.blink.progress), y + h), (0, 255, 120), -1)

    # --- 描画 ---
    def pen_down(self, now) -> bool:
        if self.keys.available:
            held = self.keys.is_down("space")
        else:   # X11 が使えない場合のフォールバック: キーリピートの間隔で「押している」とみなす
            held = now - self._space_t < 0.15
        return held or self.pen_toggle

    def update_pen(self, t):
        pos = self.lazy.update(self.gaze)
        self.pen_pos = pos
        if self.paint is None:
            self.paint = self.blank_canvas()
        if not self.pen_down(time.perf_counter()):
            self.cur_stroke = None
            return
        if self.cur_stroke is None:
            self.cur_stroke = {"color": self.pen_color, "width": self.pen_w, "pts": [tuple(pos)]}
            self.strokes.append(self.cur_stroke)
            cv2.circle(self.paint, (int(pos[0]), int(pos[1])), max(1, self.pen_w // 2),
                       self.pen_color, -1, cv2.LINE_AA)
            return
        prev = self.cur_stroke["pts"][-1]
        if np.hypot(pos[0] - prev[0], pos[1] - prev[1]) >= 2.0:
            cv2.line(self.paint, (int(prev[0]), int(prev[1])), (int(pos[0]), int(pos[1])),
                     self.cur_stroke["color"], self.cur_stroke["width"], cv2.LINE_AA)
            self.cur_stroke["pts"].append(tuple(pos))

    def redraw(self):
        self.paint = self.blank_canvas()
        for st in self.strokes:
            pts = st["pts"]
            if len(pts) == 1:
                cv2.circle(self.paint, (int(pts[0][0]), int(pts[0][1])), max(1, st["width"] // 2),
                           st["color"], -1, cv2.LINE_AA)
            for a, b in zip(pts[:-1], pts[1:]):
                cv2.line(self.paint, (int(a[0]), int(a[1])), (int(b[0]), int(b[1])), st["color"],
                         st["width"], cv2.LINE_AA)

    def enter_draw(self):
        self.state = "draw"
        self.cur_stroke = None
        self.pen_toggle = False
        self.lazy = CursorFilter(dead_px=22, follow=0.30)
        self.smoother.reset()
        if self.paint is None:
            self.paint = self.blank_canvas()

    def render_draw(self, t):
        c = self.paint.copy() if self.paint is not None else self.blank_canvas()
        drawing = self.pen_down(time.perf_counter())
        if self.pen_pos is not None:
            p = (int(self.pen_pos[0]), int(self.pen_pos[1]))
            if drawing:
                cv2.circle(c, p, self.pen_w // 2 + 6, (0, 255, 120), 2, cv2.LINE_AA)
            else:
                cv2.circle(c, p, 14, (200, 200, 200), 2, cv2.LINE_AA)
                cv2.circle(c, p, 3, (200, 200, 200), -1, cv2.LINE_AA)
            if self.blink.progress > 0:
                cv2.ellipse(c, p, (34, 34), -90, 0, 360 * self.blink.progress, (0, 255, 255), 5, cv2.LINE_AA)
        state = "DRAWING" if drawing else "pen up"
        put_text(c, "%s | %s | width %d" % (state, "toggle ON" if self.pen_toggle else "hold SPACE / long blink = pen",
                                          self.pen_w), (270, 64), 0.6,
                 (90, 255, 140) if drawing else (200, 200, 200))
        cv2.rectangle(c, (270, 76), (310, 100), self.pen_color, -1)
        cv2.rectangle(c, (270, 76), (310, 100), (200, 200, 200), 1)
        put_text(c, "[SPACE hold] pen  [long blink] pen toggle  [R G B Y W K] color (K=eraser)  [+/-] width  "
                    "[U] undo  [X] clear  [S] save  [Esc/5] back", (12, self.H - 14), 0.5, (150, 150, 150))
        return c

    # --- 追加学習 ---
    def _on_mouse(self, event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            self._click = (x, y, time.perf_counter())

    def start_points(self, mode: str):
        """静止した点を見つめる方式の較正 (mode='calib') / 追加学習 (mode='refine')。
        最後に「点を見たまま頭を動かす」点を加え、頭部姿勢の係数を学習できるようにする。"""
        rng = np.random.default_rng()
        if mode == "calib":
            cols, rows, jit = 4, 4, 0.0
            head = [(0.5, 0.5), (0.22, 0.28), (0.78, 0.72)]
        else:
            cols, rows, jit = 4, 3, 0.15
            head = [(rng.uniform(0.3, 0.7), rng.uniform(0.3, 0.7))]
        pts = []
        for r in range(rows):
            for c in range(cols):
                fx = 0.06 + 0.88 * (c + rng.uniform(-jit, jit)) / (cols - 1)
                fy = 0.08 + 0.84 * (r + rng.uniform(-jit, jit)) / (rows - 1)
                pts.append((min(max(fx, 0.04), 0.96) * self.W, min(max(fy, 0.05), 0.95) * self.H))
        rng.shuffle(pts)
        self.ref_kind = ["fix"] * len(pts) + ["head"] * len(head)
        pts += [(hx * self.W, hy * self.H) for hx, hy in head]
        self.pt_mode = mode
        self.ref_pts, self.ref_i = pts, 0
        self.ref_F, self.ref_Y, self.ref_G = [], [], []
        self.state = "refine"
        self.msg = ""
        self.fbuf.clear()
        self._click = None
        self._pending = None
        self._dot_t0 = None
        self.dot_series = []

    def start_refine(self):
        self.start_points("refine")

    DOT_SHOW = 1.4      # 1点あたりの表示時間 [s]
    DOT_SETTLE = 0.6    # 点が出てから視線が落ち着くまで捨てる時間 [s]
    HEAD_SHOW = 6.0     # 頭を動かす点の表示時間 [s]
    HEAD_SETTLE = 0.8

    def _dot_timing(self):
        if self.ref_kind[self.ref_i] == "head":
            return self.HEAD_SHOW, self.HEAD_SETTLE
        return self.DOT_SHOW, self.DOT_SETTLE

    def handle_refine_click(self):
        """点を見つめている後半 (SETTLE〜SHOW) のフレームだけをその点の正解データにする。クリック不要。"""
        now = time.perf_counter()
        self._click = None
        if self.ref_i >= len(self.ref_pts):
            return
        if self._dot_t0 is None:
            self._dot_t0 = now
            self.fbuf.clear()
            return
        show, settle = self._dot_timing()
        if now - self._dot_t0 < show:
            return
        t0 = self._dot_t0
        tx, ty = self.ref_pts[self.ref_i]
        kind = self.ref_kind[self.ref_i]
        series = [(t - t0, f) for (t, f) in self.fbuf if t0 <= t <= t0 + show]
        fr = np.array([f for (t, f) in self.fbuf if t0 + settle <= t <= t0 + show])
        if kind == "fix" and len(fr):
            fr = clean_group(fr)   # 頭を動かす点では虹彩位置が大きく変わるのが正常なので除去しない
        self._dot_t0 = now
        self.fbuf.clear()
        if len(fr) < 8:
            self.msg = "Face not tracked - the same dot is shown again"
            return
        self.msg = ""
        if kind == "fix" and self.ref_i > 0 and len(series) >= 8:   # 応答遅延の推定用の時系列
            self.dot_series.append((np.array([a for a, _ in series]), np.array([b for _, b in series]),
                                    self.ref_pts[self.ref_i - 1], (tx, ty)))
        for f in fr:
            self.ref_F.append(f)
            self.ref_Y.append((tx, ty))
            self.ref_G.append(self.ref_i)
        self.ref_i += 1
        self._dot_t0 = now
        if self.ref_i >= len(self.ref_pts):
            self.finish_points()

    def finish_points(self):
        F, Y, G = np.array(self.ref_F), np.array(self.ref_Y), np.array(self.ref_G)
        if self.pt_mode == "calib":
            m = fit_groups(F, Y, G, (self.W, self.H), float(np.median(F[:, 4])))
            lat = estimate_latency(m, self.dot_series)
            if lat is not None:
                m.lag = lat                       # 応答遅延 [s]
                # 次回以降の追加学習では、遅延 + 余裕 の分だけ捨てる
            self.model = m
            self.blink.set_baseline(m.baseline_open)
            os.makedirs(os.path.dirname(self.profile), exist_ok=True)
            m.save(self.profile)
            self.smoother.reset()
            self.blink.auto_long()             # 較正中に観測した通常の瞬きから決定時間を自動調整
            self.state = "result"
            return
        new, e_old, e_new = refit(self.model, F, Y, G)
        adopted = new is not self.model
        if adopted:
            self.model = new
            self.model.save(self.profile)
            self.smoother.reset()
        self.ref_report = (e_old, e_new, adopted, len(self.ref_F))
        self.state = "refine_done"

    # --- ウィンドウ切替 / ズーム ---
    def _win_small(self):
        if self.a.windowed:
            return
        cv2.setWindowProperty(WIN, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(WIN, *self.CTRL_SIZE)
        cv2.moveWindow(WIN, max(self.W - self.CTRL_SIZE[0] - 20, 0), 40)
        try:
            cv2.setWindowProperty(WIN, cv2.WND_PROP_TOPMOST, 1)
        except cv2.error:
            pass

    def _win_full(self):
        if self.a.windowed:
            return
        try:
            cv2.setWindowProperty(WIN, cv2.WND_PROP_TOPMOST, 0)
        except cv2.error:
            pass
        cv2.setWindowProperty(WIN, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)

    def enter_control(self):
        if self.mouse is None:
            self.mouse, why = make_mouse((self.W, self.H))
            if self.mouse is None:
                self.msg = "PC control unavailable: " + why
                self.msg_until = time.perf_counter() + 12.0
                return
        self.state = "control"
        self.cursor = None
        self.cursor_f = CursorFilter()
        self.smoother.reset()
        self._win_small()

    def exit_control(self):
        self.state = "track"
        self._win_full()

    def enter_zoom(self, t):
        shot = grab_screen()
        os_w, os_h = self.mouse.size
        if shot is None or shot.mean() < 2.0:   # Wayland 等で取得できない場合は格子で代替
            shot = np.full((os_h, os_w, 3), 50, np.uint8)
            for gx in range(0, os_w, 40):
                cv2.line(shot, (gx, 0), (gx, os_h), (90, 90, 90), 1)
            for gy in range(0, os_h, 40):
                cv2.line(shot, (0, gy), (os_w, gy), (90, 90, 90), 1)
            self.msg = "screen capture unavailable (use an X11 session)"
        shot = cv2.resize(shot, (os_w, os_h))
        self.zoom_reg = zoom_region(self.cursor, (os_w, os_h), 4.0)
        x0, y0, w, h = self.zoom_reg
        self.zoom_img = cv2.resize(shot[y0:y0 + h, x0:x0 + w], (self.W, self.H), interpolation=cv2.INTER_CUBIC)
        self.zoom_t0 = t
        self.state = "zoom"
        self.smoother.reset()
        self._win_full()

    def exit_zoom(self):
        self.state = "control"
        self.cursor_f = CursorFilter()
        self.smoother.reset()
        self._win_small()

    # ----------------------------------------------------------- 描画 --
    def preview(self, canvas):
        if self.frame is None:
            return
        h, w = self.frame.shape[:2]
        pw = 320
        ph = int(pw * h / w)
        small = cv2.resize(self.frame, (pw, ph))
        if self.obs is not None:
            sc = pw / w
            for i in (468, 473, 33, 133, 362, 263):
                x, y = self.obs.landmarks_px[i] * sc
                cv2.circle(small, (int(x), int(y)), 2, (0, 255, 0), -1)
        small = cv2.flip(small, 1)
        y0 = self.H - ph - 40
        canvas[y0:y0 + ph, 10:10 + pw] = small
        cv2.rectangle(canvas, (10, y0), (10 + pw, y0 + ph), (120, 120, 120), 1)

    def hud(self, canvas):
        s = "FPS %.0f | %s | open %.2f" % (self.fps, "face OK" if self.obs else "NO FACE",
                                             (self.obs.openness / self.blink.baseline) if self.obs else 0)
        s += " | long blink %.2fs" % self.blink.long_duration
        put_text(canvas, s, (12, 24), 0.55, (170, 170, 170))
        if self.state == "track":
            put_text(canvas, "[M/Esc] menu  [1] heat  [2] keypad  [3] PC  [4] learn  [5] draw  [,/.] blink  [H] heatmap  [T] trail  [V] camera  [R] reset  [C] recalibrate  [Q] quit",
                     (12, self.H - 14), 0.55, (150, 150, 150))
        if self.msg:
            if self.msg_until and time.perf_counter() > self.msg_until:
                self.msg, self.msg_until = "", 0.0
            else:
                put_text(canvas, self.msg, (self.W // 2, self.H - 50), 0.7, (80, 160, 255), 2, "c")

    def render_control(self, t):
        cw, ch = self.CTRL_SIZE
        c = np.full((ch, cw, 3), BG, np.uint8)
        if self.frame is not None:
            h, w = self.frame.shape[:2]
            ph = int(cw * 0.5 * h / w)
            c[40:40 + ph, 0:cw // 2] = cv2.flip(cv2.resize(self.frame, (cw // 2, ph)), 1)
        col = (0, 200, 255) if self.paused else (90, 220, 90)
        put_text(c, "PAUSED" if self.paused else "CONTROL", (cw // 2 + 12, 70), 0.9, col, 2)
        put_text(c, "zoom-click: %s" % ("ON" if self.zoom_click else "OFF"), (cw // 2 + 12, 105), 0.5)
        put_text(c, "blink: %.0f%%" % (100 * self.blink.progress), (cw // 2 + 12, 130), 0.5)
        put_text(c, "FPS %.0f %s" % (self.fps, "" if self.obs else "NO FACE"), (8, 20), 0.5, (170, 170, 170))
        cv2.rectangle(c, (0, ch - 12), (int(cw * self.blink.progress), ch), (0, 255, 120), -1)
        lines = ["1) Look at a target: the mouse pointer follows.",
                 "2) Long blink -> screen zooms 4x.",
                 "3) Look at the exact spot, long blink -> click.",
                 "Top-left corner + long blink = pause.",
                 "Z zoom on/off | P pause | 3 or Esc back"]
        for i, ln in enumerate(lines):
            put_text(c, ln, (8, 185 + i * 22), 0.45, (200, 200, 200))
        if self.mouse:
            put_text(c, "backend: %s" % self.mouse.backend, (8, ch - 20), 0.45, (150, 150, 150))
        return c

    def render_zoom(self, t):
        c = self.zoom_img.copy()
        if self.gaze is not None:
            draw_gaze_cursor(c, self.gaze, self.blink.progress)
        put_text(c, "ZOOM 4x: look at the exact target, then long blink to click", (self.W // 2, 40),
                 0.9, (0, 255, 255), 2, "c")
        return c

    def blank_canvas(self, fill: bool = True) -> np.ndarray:
        """毎フレーム使い回すキャンバス。単色の塗りつぶしは遅い (全画面で約8ms) ので、作り置きからコピーする。"""
        if getattr(self, "_canvas", None) is None or self._canvas.shape[:2] != (self.H, self.W):
            self._canvas = np.empty((self.H, self.W, 3), np.uint8)
            self._blank = np.empty((self.H, self.W, 3), np.uint8)
            self._blank[:, :] = BG
        if fill:
            np.copyto(self._canvas, self._blank)
        return self._canvas

    def render(self, t):
        if self.state == "control":
            return self.render_control(t)
        if self.state == "zoom":
            return self.render_zoom(t)
        if self.state == "draw":
            c = self.render_draw(t)
            self.draw_menu_button(c)
            return c
        if self.state in ("record", "recorded"):
            return self.render_record(t)
        if self.state == "hcal":
            return self.render_hcal(t)
        if self.state == "hresult":
            return self.render_hresult()
        if self.state == "wetcalib":
            c = np.full((self.H, self.W, 3), (0, 0, 0), np.uint8)
            self.render_wetcalib(c, t)
            return c
        if self.state == "wetresult":
            c = self.blank_canvas()
            self.render_wetresult(c)
            self.hud(c)
            return c
        if self.state == "scene":
            c = self.blank_canvas(fill=not getattr(self.scene, "full_frame", False))
            self.scene.render(c, t, self.blink.progress)
            if self.scene.cursor and self.gaze is not None:
                draw_gaze_cursor(c, self.gaze, 0.0)
            put_text(c, "FPS %.0f%s" % (self.fps, "" if self.obs else "  NO FACE"), (12, 22), 0.5, (150, 150, 150))
            return c
        c = self.blank_canvas()
        cx, cy = self.W // 2, self.H // 2
        st = self.state
        if st == "intro":
            put_text(c, "Webcam Gaze Tracker", (cx, cy - 160), 1.8, (255, 255, 255), 3, "c")
            for i, s in enumerate(["Sit ~50-70 cm from the screen, face the camera, keep your face well lit.",
                                   "Calibration: just look at each dot until it moves (16 dots, ~25 s).",
                                   "Keep your head fairly still, but small natural movements are fine.",
                                   "Look at the center of the dot; no mouse clicking is needed."]):
                put_text(c, s, (cx, cy - 70 + i * 40), 0.8, (210, 210, 210), 1, "c")
            ok = self.obs is not None
            put_text(c, "Face detected" if ok else "No face detected", (cx, cy + 130), 0.9,
                     (90, 220, 90) if ok else (80, 80, 255), 2, "c")
            put_text(c, "Press SPACE to start calibration" + ("   (L: load saved profile)" if os.path.exists(self.wet_profile if self.wet else self.profile) else "")
                     + ("   [engine: %s]" % self.a.engine),
                     (cx, cy + 190), 0.9, (255, 255, 255), 2, "c")
        elif st in ("countdown", "calib"):
            el = t - self.t0
            if st == "countdown":
                p = self.path.at(0)
                n = int(np.ceil(1.5 - el)) if el < 1.5 else 0
                put_text(c, "Look at the dot and follow it", (cx, cy), 1.0, (210, 210, 210), 2, "c")
                r = 14 + int(10 * (1.5 - min(el, 1.5)))
                cv2.circle(c, (int(p[0]), int(p[1])), r, (255, 255, 255), 2, cv2.LINE_AA)
                cv2.circle(c, (int(p[0]), int(p[1])), 6, (0, 0, 255), -1, cv2.LINE_AA)
            else:
                te = el - 1.5
                p = self.path.at(te)
                cv2.circle(c, (int(p[0]), int(p[1])), 20, (255, 255, 255), 2, cv2.LINE_AA)
                cv2.circle(c, (int(p[0]), int(p[1])), 7, (0, 0, 255), -1, cv2.LINE_AA)
                frac = min(1.0, te / self.path.duration)
                cv2.rectangle(c, (self.W // 4, 40), (self.W // 4 + int(self.W / 2 * frac), 52), (0, 200, 120), -1)
                cv2.rectangle(c, (self.W // 4, 40), (3 * self.W // 4, 52), (150, 150, 150), 1)
                if self.obs is None:
                    put_text(c, "FACE LOST - stay in view of the camera", (cx, 100), 0.9, (80, 80, 255), 2, "c")
            self.preview(c)
        elif st == "result":
            m = self.model
            put_text(c, "Calibration done", (cx, cy - 100), 1.6, (255, 255, 255), 3, "c")
            put_text(c, "leave-one-dot-out error: %d px (%.1f%% of screen width)" % (m.cv_error_px, 100 * m.cv_error_px / self.W),
                     (cx, cy - 30), 0.9, (210, 210, 210), 1, "c")
            lat = "response latency ~%d ms" % (m.lag * 1000) if m.lag > 0 else "latency: n/a"
            put_text(c, "samples %d | model %s | %s" % (m.n_samples, "poly2" if m.degree == 2 else "linear", lat),
                     (cx, cy + 10), 0.7, (170, 170, 170), 1, "c")
            put_text(c, "SPACE: menu     C: redo calibration     (error = leave-one-dot-out)", (cx, cy + 100), 0.9, (255, 255, 255), 2, "c")
        elif st == "refine":
            n = len(self.ref_pts)
            for j, (px, py) in enumerate(self.ref_pts):
                if j < self.ref_i:
                    cv2.circle(c, (int(px), int(py)), 6, (70, 120, 70), -1, cv2.LINE_AA)
            if self.ref_i < n:
                px, py = self.ref_pts[self.ref_i]
                show, settle = self._dot_timing()
                el = 0.0 if self._dot_t0 is None else max(0.0, t - self._dot_t0)
                r = int(34 - 22 * min(1.0, el / settle))   # 点に向かって縮む輪: 視線を誘導
                cv2.circle(c, (int(px), int(py)), r, (255, 255, 255), 2, cv2.LINE_AA)
                cv2.circle(c, (int(px), int(py)), 7, (0, 0, 255), -1, cv2.LINE_AA)
                if el >= settle:    # 収集中
                    cv2.ellipse(c, (int(px), int(py)), (16, 16), -90, 0,
                                360 * min(1.0, (el - settle) / (show - settle)), (0, 255, 120), 3, cv2.LINE_AA)
            title = "較正" if self.pt_mode == "calib" else "追加学習"
            if self.ref_i < n:
                # 案内文は他の点と重ならないよう、今の点のすぐ上/下に出す
                px, py = self.ref_pts[self.ref_i]
                ty = py + 95 if py < self.H / 2 else py - 95
                tx = min(max(px, 420), self.W - 420)
                if self.ref_kind[self.ref_i] == "head":
                    el = 0.0 if self._dot_t0 is None else max(0.0, t - self._dot_t0)
                    step = ["左へ", "右へ", "上へ", "下へ", "ぐるっと回す"][min(4, int(el / 1.2))]
                    JT.draw(c, "点を見たまま、顔の向きを → " + step, (int(tx), int(ty)), 34, (0, 230, 255))
                    JT.draw(c, "%s %d / %d" % (title, self.ref_i + 1, n), (int(tx), int(ty) + (40 if py < self.H / 2 else -40)),
                            22, (170, 170, 170))
                elif self.ref_i < 2:
                    JT.draw(c, "赤い点を見つめてください(クリック不要・頭は動かさない)", (int(tx), int(ty)), 26,
                            (255, 255, 255))
                    JT.draw(c, "%s %d / %d    Esc: 中止" % (title, self.ref_i + 1, n),
                            (int(tx), int(ty) + (36 if py < self.H / 2 else -36)), 20, (170, 170, 170))
            if self.obs is None:
                JT.draw(c, "顔が見えません。カメラに顔を向けてください", (cx, int(self.H * 0.22)), 30, (80, 80, 255))
        elif st == "refine_done":
            e_old, e_new, ok, n = self.ref_report
            put_text(c, "Additional learning done", (cx, cy - 100), 1.5, (255, 255, 255), 3, "c")
            if np.isnan(e_old):
                put_text(c, "not enough data", (cx, cy - 30), 0.9, (200, 200, 200), 1, "c")
            else:
                put_text(c, "held-out error: before %d px  ->  after %d px" % (e_old, e_new),
                         (cx, cy - 30), 0.9, (210, 210, 210), 1, "c")
                put_text(c, "new model adopted" if ok else "no improvement: kept the previous model",
                         (cx, cy + 15), 0.8, (90, 220, 90) if ok else (80, 160, 255), 2, "c")
            put_text(c, "SPACE: back to tracking     4: learn more", (cx, cy + 100), 0.9, (255, 255, 255), 2, "c")
        elif st == "track":
            if self.view == "track":
                if self.show_heat:
                    self.heat.draw(c)
                if self.show_trail:
                    self.trail.draw(c, t)
                for x, y, tp in self.pins:
                    cv2.drawMarker(c, (x, y), (0, 255, 120), cv2.MARKER_TILTED_CROSS, 30, 3)
                    if t - tp < 0.8:
                        put_text(c, "SELECTED", (x, y - 28), 0.7, (0, 255, 120), 2, "c")
            else:
                self.keypad.draw(c, t, self.blink.progress)
            self.draw_menu_button(c)
            if self.gaze is not None:
                draw_gaze_cursor(c, self.gaze, self.blink.progress)
            if self.blink.closed:
                put_text(c, "eyes closed", (cx, 30), 0.7, (200, 200, 120), 1, "c")
            if self.show_cam:
                self.preview(c)
        self.hud(c)
        return c

    # ----------------------------------------------------------- キー --
    def on_key(self, k: int) -> bool:
        if k == ord("q") or (k == 27 and self.state not in ("control", "zoom", "refine", "draw", "scene", "track", "wetcalib", "record", "hcal")):
            return False
        ch = chr(k).lower() if 0 <= k < 256 else ""
        if self.state == "intro":
            if ch == " " and self.obs is not None and self.a.record:
                self.recorder = SessionRecorder(os.path.join(ROOT, "profiles", "sessions"), self.W, self.H,
                                                screen_size_cm())
                self.state = "record"
            elif ch == " " and self.obs is not None:
                self.start_calibration_auto()
            elif ch == "m" and self.obs is not None:
                self.start_calibration()   # 旧方式: 動く点を追従
            elif ch == "l" and self.load_profile():
                self.open_scene("menu")
        elif self.state == "result" and ch == " ":
            self.open_scene("menu")
        elif self.state == "refine_done":
            if ch == " ":
                self.state = "track"
            elif ch == "4":
                self.start_refine()
            return True
        elif self.state == "refine":
            if k == 27:
                self.state = "track"
            return True
        if self.state == "scene":
            if k == 27:
                if isinstance(self.scene, Menu):
                    self.state, self.view = "track", "track"
                else:
                    self.open_scene("menu")
            elif isinstance(self.scene, Menu) and ch in "12345678" and ch != "":
                self.scene.choose(int(ch) - 1)
                self.handle_scene_request()
            elif ch in (",", ".") and not isinstance(self.scene, (FutsalGame, Soccer11)):
                self.blink.set_long(self.blink.long_duration + (0.05 if ch == "." else -0.05))
            else:
                self.scene.on_key(k)
                self.handle_scene_request()
            return True
        if self.state == "draw":
            if ch == " ":
                self._space_t = time.perf_counter()
            elif k == 27 or ch == "5":
                self.open_scene("menu")
            elif ch in "rgbywk" and ch != "":
                self.pen_color = {"r": (60, 60, 255), "g": (80, 220, 80), "b": (255, 140, 60),
                                  "y": (0, 230, 255), "w": (255, 255, 255), "k": BG}[ch]
            elif ch in ("+", "="):
                self.pen_w = min(self.pen_w + 2, 40)
            elif ch == "-":
                self.pen_w = max(self.pen_w - 2, 2)
            elif ch == "u":
                if self.strokes:
                    self.strokes.pop()
                    self.cur_stroke = None
                    self.redraw()
            elif ch == "x":
                self.strokes.clear()
                self.cur_stroke = None
                self.redraw()
            elif ch == "s":
                path = os.path.join(ROOT, "drawing_%d.png" % int(time.time()))
                cv2.imwrite(path, self.paint)
                self.msg = "saved %s" % os.path.basename(path)
            elif ch in (",", "."):
                self.blink.set_long(self.blink.long_duration + (0.05 if ch == "." else -0.05))
            return True
        if self.state in ("control", "zoom"):
            if ch == "3" or k == 27:
                self.state = "control"
                self.exit_control()
            elif ch == "z":
                self.zoom_click = not self.zoom_click
            elif ch == "p":
                self.paused = not self.paused
            return True
        if self.state == "record":
            if k == 27:
                self.recorder.finish()
                self.state = "recorded"
            return True
        if self.state == "recorded":
            if ch == " ":
                self.state = "intro"
            return True
        if self.state == "hresult":
            if ch == " ":
                self.open_scene("menu")
            elif ch == "c":
                self.start_hcal()
            return True
        if self.state == "hcal":
            if k == 27:
                self.state = "intro"
            return True
        if self.state == "wetresult":
            if ch == " ":
                self.open_scene("menu")
            elif ch == "c":
                self.start_wet_calib()
            return True
        if self.state == "wetcalib":
            if k == 27:
                self.state = "intro"
            return True
        if ch == "c" and self.state in ("track", "result"):
            self.start_calibration_auto()
        elif self.state == "track":
            if ch == "1":
                self.view = "track"
            elif ch == "2":
                self.view = "keypad"
            elif ch == "h":
                self.show_heat = not self.show_heat
            elif ch == "t":
                self.show_trail = not self.show_trail
            elif ch == "v":
                self.show_cam = not self.show_cam
            elif ch == "3":
                self.enter_control()
            elif ch == "4":
                self.open_scene("refine")
            elif ch == "5":
                self.enter_draw()
            elif ch in ("6", "m") or k == 27:
                self.open_scene("menu")
            elif ch in (",", "."):
                self.blink.set_long(self.blink.long_duration + (0.05 if ch == "." else -0.05))
                self.msg = "long blink = %.2f s" % self.blink.long_duration
            elif ch == "r":
                self.heat.reset()
                self.trail.reset()
                self.pins.clear()
                self.keypad.text = ""
            elif ch == "s":
                self._shot_n += 1
        return True

    def finish_calibration(self):
        m = self.rec.fit((self.W, self.H))
        if m is None:
            self.state = "intro"
            self.msg = "Calibration failed (face not tracked enough). Try again."
            return
        self.model = m
        self.blink.set_baseline(m.baseline_open)
        os.makedirs(os.path.dirname(self.profile), exist_ok=True)
        m.save(self.profile)
        self.state = "result"
        self.msg = ""
        self.smoother.reset()

    # ----------------------------------------------------------- main --
    def run(self):
        if not self.a.windowed:
            cv2.namedWindow(WIN, cv2.WINDOW_NORMAL)
            cv2.setWindowProperty(WIN, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)
        else:
            cv2.namedWindow(WIN, cv2.WINDOW_AUTOSIZE)
        cv2.setMouseCallback(WIN, self._on_mouse)
        if not self.a.recalibrate and self.load_profile():
            self.open_scene("menu")             # 保存済みの (あなた用に学習した) モデルで、較正を飛ばして始める
            self.msg, self.msg_until = "保存済みの較正を読み込みました (やり直しは C / 追加学習はメニュー)", time.perf_counter() + 5
        seq = -1
        auto = self.a.autotest
        t_start = time.perf_counter()
        shots = set()
        worker = None
        if self.wet:
            if self.engine is None:
                self.engine = WebEyeTrackEngine((self.W, self.H), screen_size_cm())
            worker = PreprocessWorker(self.cam, self.engine, with_facemesh=self.hyb)
        try:
            while True:
                if worker is not None:
                    r = worker.read(seq)
                    if r is not None:
                        frame, t, obs, seq = r
                        self.process(frame, t, obs, pre=True)
                    else:
                        time.sleep(0.001)
                else:
                    r = self.cam.read(seq)
                    if r is not None:
                        frame, t, seq = r
                        self.process(frame, t)
                if r is not None:
                    if self.state == "countdown" and t - self.t0 >= 1.5:
                        self.state = "calib"
                    elif self.state == "calib" and t - self.t0 - 1.5 >= self.path.duration:
                        self.finish_calibration()
                now = time.perf_counter()
                # 描画は最大 40fps。余った時間は前処理スレッド (視線推定) に回す
                wait = 1.0 / 40 - (now - getattr(self, "_last_draw", 0.0))
                if wait > 0:
                    time.sleep(wait)
                    now = time.perf_counter()
                self._last_draw = now
                canvas = self.render(now)
                cv2.imshow(WIN, canvas)
                k = cv2.waitKey(1)
                if self.state == "refine":
                    self.handle_refine_click()
                elif self.wet and self._click is not None and self.state in ("track", "scene", "draw"):
                    x, y, _ = self._click
                    self._click = None
                    self.click_calibrate(x, y)
                if auto:  # 自動テスト: 状態遷移を自動で進め、スクリーンショットを保存
                    el = now - t_start
                    if self.state == "intro" and el > 2.5 and k == -1:
                        k = ord(" ") if self.obs else -1
                    if self.state == "result":
                        k = ord(" ")
                    if self.state == "track":
                        if "t1" not in shots:
                            shots.add("t1"); self._t_track = now
                        e2 = now - self._t_track
                        if e2 > 4 and "s1" not in shots:
                            shots.add("s1"); cv2.imwrite(os.path.join(auto, "track.png"), canvas); self.view = "keypad"
                        if e2 > 8:
                            cv2.imwrite(os.path.join(auto, "keypad.png"), canvas)
                            self.enter_control(); self._ctl_t = now; print("control:", self.state, self.msg)
                    if self.state == "control" and getattr(self, "_ctl_t", None):
                        e3 = now - self._ctl_t
                        if e3 > 3 and "z1" not in shots:
                            shots.add("z1")
                            cv2.imwrite(os.path.join(auto, "control.png"), canvas)
                            print("cursor", self.cursor, "os pointer", self.mouse.position() if self.mouse else None)
                            self.on_long_blink(now); print("after blink:", self.state)
                    if self.state == "zoom":
                        self._zt = getattr(self, "_zt", now)
                        if now - self._zt > 2:
                            cv2.imwrite(os.path.join(auto, "zoom.png"), canvas)
                            self.on_long_blink(now); print("after 2nd blink:", self.state, "click", self.last_click)
                            break
                    if self.state in ("calib",) and "c1" not in shots and now - self.t0 > 8:
                        shots.add("c1"); cv2.imwrite(os.path.join(auto, "calib.png"), canvas)
                    if el > 90:
                        break
                    if self.state == "intro" and "i1" not in shots and el > 2:
                        shots.add("i1"); cv2.imwrite(os.path.join(auto, "intro.png"), canvas)
                if k != -1:
                    if not self.on_key(k):
                        break
                    if self._shot_n:
                        cv2.imwrite(os.path.join(ROOT, "screenshot_%d.png" % int(time.time())), canvas)
                        self._shot_n = 0
        finally:
            if worker is not None:
                worker.stop()
            self.cam.release()
            cv2.destroyAllWindows()
            if self.tracker:
                self.tracker.close()
            if auto and self.model:
                print("fps %.1f cv_error_px %.1f lag %.2f deg %d n %d" % (
                    self.fps, self.model.cv_error_px, self.model.lag, self.model.degree, self.model.n_samples))


def main():
    ap = argparse.ArgumentParser(description="Webcam real-time gaze tracker (MediaPipe + OpenCV)")
    ap.add_argument("--camera", default="0", help="camera index or video file")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--screen", type=lambda s: tuple(int(v) for v in s.lower().split("x")),
                    help="screen size WxH (default: auto-detect via xrandr)")
    ap.add_argument("--windowed", action="store_true", help="1280x720 window instead of fullscreen")
    ap.add_argument("--profile", default="default", help="calibration profile name (profiles/<name>.json)")
    ap.add_argument("--engine", choices=["hybrid", "webeyetrack", "classic"], default="hybrid",
                    help="hybrid: WebEyeTrack の予測 + FaceMesh の虹彩位置の個人回帰 (評価で最も良かった構成) / "
                         "webeyetrack: WebEyeTrack(2025)と同じ構成 / classic: 虹彩ランドマーク + リッジ回帰")
    ap.add_argument("--record", action="store_true",
                    help="評価用データを録画する (SPACE で開始、約2分)。tools/benchmark.py で方式を比較できる")
    ap.add_argument("--long-blink", type=float, default=0.55,
                    help="seconds of eye closure that counts as a confirm (default 0.55; ,/. keys adjust)")
    ap.add_argument("--load", action="store_true", help=argparse.SUPPRESS)   # 互換用 (今は既定で読み込む)
    ap.add_argument("--recalibrate", action="store_true", help="保存済みの較正を使わず、最初から較正する")
    ap.add_argument("--autotest", metavar="DIR", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if a.autotest:
        os.makedirs(a.autotest, exist_ok=True)
    App(a).run()
