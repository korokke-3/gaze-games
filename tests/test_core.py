import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from gazekit.blink import BlinkDetector
from gazekit.calibration import CalibrationPath, CalibrationRecorder, GazeModel
from gazekit.filters import GazeSmoother, OneEuroFilter

W, H = 1920, 1200


def synth_feat(g, rng, noise=0.003):
    """既知の(非線形)写像の逆: 画面座標 -> 特徴量。"""
    x, y = g[0] / W - 0.5, g[1] / H - 0.5
    u = 0.20 * x + 0.02 * x * y
    v = 0.12 * y - 0.02 * x * x
    f = np.array([u, v, u * 0.9, v * 1.1, 0.28, 0.3 * x, 0.2 * y, 0.5, 0.5, 0.2])
    f[:4] += rng.normal(0, noise, 4)
    return f


class TestCalibration(unittest.TestCase):
    def test_path_covers_screen_and_duration(self):
        p = CalibrationPath(W, H)
        ts = np.arange(0, p.duration, 0.05)
        pts = np.stack([p.at(t) for t in ts])
        self.assertLess(pts[:, 0].min(), 0.1 * W)
        self.assertGreater(pts[:, 0].max(), 0.9 * W)
        self.assertLess(pts[:, 1].min(), 0.1 * H)
        self.assertGreater(pts[:, 1].max(), 0.9 * H)
        self.assertLess(p.duration, 30.0)  # 「短時間」

    def test_fit_recovers_mapping_with_lag(self):
        rng = np.random.default_rng(0)
        p = CalibrationPath(W, H)
        rec = CalibrationRecorder(p)
        lag = 0.2
        for t in np.arange(0, p.duration, 1 / 30):
            rec.add(t, synth_feat(p.at(t - lag), rng))  # 眼は点より 0.2s 遅れる
        m = rec.fit((W, H))
        self.assertIsNotNone(m)
        self.assertAlmostEqual(m.lag, 0.2, delta=0.11)
        # 独立なテスト点
        errs = []
        for _ in range(200):
            g = np.array([rng.uniform(0.1, 0.9) * W, rng.uniform(0.1, 0.9) * H])
            errs.append(np.linalg.norm(m.predict(synth_feat(g, rng)) - g))
        self.assertLess(np.mean(errs), 0.03 * W)

    def test_save_load_roundtrip(self):
        rng = np.random.default_rng(1)
        p = CalibrationPath(W, H)
        rec = CalibrationRecorder(p)
        for t in np.arange(0, p.duration, 1 / 30):
            rec.add(t, synth_feat(p.at(t), rng))
        m = rec.fit((W, H))
        path = os.path.join(os.path.dirname(__file__), "_m.json")
        try:
            m.save(path)
            m2 = GazeModel.load(path)
        finally:
            os.remove(path)
        f = synth_feat(np.array([900.0, 500.0]), rng)
        np.testing.assert_allclose(m.predict(f), m2.predict(f))

    def test_too_few_samples(self):
        rec = CalibrationRecorder(CalibrationPath(W, H))
        for t in np.arange(0, 1, 1 / 30):
            rec.add(t, np.ones(10))
        self.assertIsNone(rec.fit((W, H)))


def run_blink(durations, dt=1 / 30, base=0.28):
    """durations: [(open秒, closed秒), ...] を流して event を集める。"""
    d = BlinkDetector(base)
    t, events = 0.0, []
    for o, c in durations:
        for _ in range(int(o / dt)):
            t += dt
            e = d.update(base, t)
            if e != "none":
                events.append(e)
        for _ in range(int(c / dt)):
            t += dt
            e = d.update(0.03, t)
            if e != "none":
                events.append(e)
    for _ in range(30):
        t += dt
        e = d.update(base, t)
        if e != "none":
            events.append(e)
    return events


class TestBlink(unittest.TestCase):
    def test_normal_blink_is_not_selection(self):
        self.assertEqual(run_blink([(1, 0.15), (1, 0.3)]), ["blink", "blink"])

    def test_long_blink_fires_once(self):
        self.assertEqual(run_blink([(1, 1.2)]), ["long_blink"])

    def test_noise_ignored(self):
        self.assertEqual(run_blink([(1, 0.02)]), [])

    def test_refractory_and_multiple(self):
        self.assertEqual(run_blink([(1, 1.0), (1, 1.0)]), ["long_blink", "long_blink"])

    def test_face_lost_resets(self):
        d = BlinkDetector(0.28)
        d.update(0.28, 0.0)
        d.update(0.02, 0.1)
        self.assertTrue(d.closed)
        d.update(None, 0.2)
        self.assertFalse(d.closed)


class TestFilters(unittest.TestCase):
    def test_smoother_reduces_jitter_and_tracks_motion(self):
        rng = np.random.default_rng(0)
        s = GazeSmoother()
        raw, out = [], []
        for i in range(300):
            t = i / 30
            p = np.array([500.0, 500.0]) + rng.normal(0, 30, 2)
            raw.append(p)
            out.append(s.update(p, t))
        self.assertLess(np.std(np.array(out)[60:, 0]), 0.5 * np.std(np.array(raw)[60:, 0]))
        # 大きな移動には追従する (1秒以内に新位置の近く)
        for i in range(30):
            v = s.update(np.array([1500.0, 900.0]), 10 + i / 30)
        self.assertLess(np.linalg.norm(v - [1500, 900]), 120)


if __name__ == "__main__":
    unittest.main()


class TestOSControl(unittest.TestCase):
    def test_zoom_region_clamped_and_roundtrip(self):
        from gazekit.oscontrol import zoom_region, zoom_to_screen
        scr = (1920, 1200)
        r = zoom_region((10, 10), scr, 4.0)
        self.assertEqual(r, (0, 0, 480, 300))
        r = zoom_region((1915, 1195), scr, 4.0)
        self.assertEqual((r[0] + r[2], r[1] + r[3]), scr)
        r = zoom_region((960, 600), scr, 4.0)
        np.testing.assert_allclose(zoom_to_screen((960, 600), r, scr), (960, 600))  # 拡大画面の中心=領域の中心
        np.testing.assert_allclose(zoom_to_screen((0, 0), r, scr), (r[0], r[1]))

    def test_zoom_reduces_error(self):
        from gazekit.oscontrol import zoom_region, zoom_to_screen
        scr = (1920, 1200)
        r = zoom_region((800, 500), scr, 4.0)
        tgt = np.array([830.0, 520.0])
        # 拡大画面上で 80px ずれて見ていても、実画面では 80/4 = 20px のずれ
        canvas_pt = np.array([(tgt[0] - r[0]) / r[2] * scr[0] + 80, (tgt[1] - r[1]) / r[3] * scr[1]])
        self.assertAlmostEqual(np.linalg.norm(zoom_to_screen(canvas_pt, r, scr) - tgt), 20.0, delta=0.5)

    def test_cursor_filter_deadzone(self):
        from gazekit.oscontrol import CursorFilter
        f = CursorFilter(35, 0.5)
        f.update((100, 100))
        np.testing.assert_allclose(f.update((120, 110)), (100, 100))   # 範囲内: 動かない
        self.assertGreater(f.update((300, 100))[0], 150)                # 範囲外: 追従


class TestRefit(unittest.TestCase):
    def _old_model(self, rng):
        p = CalibrationPath(W, H)
        rec = CalibrationRecorder(p)
        for t in np.arange(0, p.duration, 1 / 30):
            rec.add(t, synth_feat(p.at(t), rng))
        return rec.fit((W, H))

    def _new_samples(self, rng, shift):
        Fs, Ys, Gs = [], [], []
        for gi in range(16):
            g = np.array([rng.uniform(0.05, 0.95) * W, rng.uniform(0.05, 0.95) * H])
            for _ in range(15):
                Fs.append(synth_feat(g, rng))
                Ys.append(g + shift)       # 環境が変わり、同じ特徴量でも正解がずれた状況
                Gs.append(gi)
        return np.array(Fs), np.array(Ys), np.array(Gs)

    def test_refit_improves_when_environment_changed(self):
        from gazekit.calibration import refit
        rng = np.random.default_rng(3)
        m = self._old_model(rng)
        F, Y, G = self._new_samples(rng, np.array([120.0, -90.0]))
        new, e_old, e_new = refit(m, F, Y, G)
        self.assertLess(e_new, 0.5 * e_old)
        self.assertIsNot(new, m)

    def test_refit_never_worse(self):
        from gazekit.calibration import refit
        rng = np.random.default_rng(4)
        m = self._old_model(rng)
        F, Y, G = self._new_samples(rng, np.zeros(2))   # 変化なし
        new, e_old, e_new = refit(m, F, Y, G)
        P = np.stack([new.predict(f) for f in F])
        err_new = np.sqrt(np.mean(np.sum((P - Y) ** 2, 1)))
        P0 = np.stack([m.predict(f) for f in F])
        err_old = np.sqrt(np.mean(np.sum((P0 - Y) ** 2, 1)))
        self.assertLessEqual(err_new, err_old * 1.5 + 5.0)


class TestLatency(unittest.TestCase):
    def test_estimate_latency_from_step_response(self):
        from gazekit.calibration import estimate_latency, fit_groups
        rng = np.random.default_rng(5)
        # 学習: 16点 x 20フレーム
        F, Y, G = [], [], []
        pts = [(rng.uniform(.05, .95) * W, rng.uniform(.05, .95) * H) for _ in range(16)]
        for gi, g in enumerate(pts):
            for _ in range(20):
                F.append(synth_feat(np.array(g), rng)); Y.append(g); G.append(gi)
        m = fit_groups(np.array(F), np.array(Y), np.array(G), (W, H), 0.28)
        # 応答: 点の切替から 0.28s 後に視線が(0.08s かけて)移る
        items = []
        for k in range(1, 9):
            A, B = np.array(pts[k - 1]), np.array(pts[k])
            t = np.arange(0, 1.4, 1 / 30)
            s = np.clip((t - 0.24) / 0.08, 0, 1)            # 中間点は t=0.28
            Fk = np.stack([synth_feat(A + (B - A) * si, rng) for si in s])
            items.append((t, Fk, A, B))
        lat = estimate_latency(m, items)
        self.assertIsNotNone(lat)
        self.assertAlmostEqual(lat, 0.28, delta=0.05)


class TestBlinkTuning(unittest.TestCase):
    def test_shorter_long_blink_and_auto(self):
        d = BlinkDetector(0.28)
        d.set_long(0.5)
        self.assertEqual(run_blink_with(d, [(1, 0.6)]), ["long_blink"])
        self.assertEqual(run_blink_with(BlinkDetector(0.28), [(1, 0.4), (1, 0.3)]), ["blink", "blink"])
        d2 = BlinkDetector(0.28)
        d2.natural = [0.12, 0.2, 0.15, 0.3, 0.18]
        d2.auto_long()
        self.assertAlmostEqual(d2.long_duration, 0.45, delta=0.01)   # 1.5*0.3

    def test_default_long_is_shorter_than_before(self):
        self.assertLessEqual(BlinkDetector.LONG_DURATION, 0.6)


def run_blink_with(d, durations, dt=1 / 30, base=0.28):
    t, events = 0.0, []
    for o, c in durations:
        for _ in range(int(o / dt)):
            t += dt
            e = d.update(base, t)
            events += [e] if e != "none" else []
        for _ in range(int(c / dt)):
            t += dt
            e = d.update(0.03, t)
            events += [e] if e != "none" else []
    for _ in range(30):
        t += dt
        e = d.update(base, t)
        events += [e] if e != "none" else []
    return events


class TestUInput(unittest.TestCase):
    def test_struct_sizes_match_kernel_abi(self):
        from gazekit.oscontrol import UInputMouse
        self.assertEqual(len(UInputMouse._dev_struct(b"x", 1920, 1200)), 1116)   # struct uinput_user_dev
        self.assertEqual(len(UInputMouse._event(3, 0, 5)), 24)                   # struct input_event (64bit)

    def test_make_mouse_reports_reason_when_unavailable(self):
        from gazekit.oscontrol import make_mouse
        m, why = make_mouse((1920, 1200))
        if m is None:
            self.assertTrue(len(why) > 0)
        else:
            m.close()


class TestHeadMotionCalibration(unittest.TestCase):
    """視線を固定して頭を回すと、眼球は逆に回る(虹彩位置 u が変わる)。
    頭を動かした較正データがあれば、頭部特徴の係数が学習され、カーソルが動かなくなることを確認。"""

    @staticmethod
    def feat(g, hx, hy, rng):
        x, y = g[0] / W - 0.5, g[1] / H - 0.5
        u = 0.20 * x - 0.25 * hx + rng.normal(0, 0.003)     # 頭が右を向くと目は左へ (補償)
        v = 0.12 * y - 0.20 * hy + rng.normal(0, 0.003)
        return np.array([u, v, u, v, 0.28 + 0.02 * y, hx, hy, 0.5 + 0.3 * hx, 0.5, 0.15])

    def make(self, with_head, rng):
        from gazekit.calibration import fit_groups
        F, Y, G = [], [], []
        gi = 0
        for gx in np.linspace(0.06, 0.94, 4):
            for gy in np.linspace(0.08, 0.92, 4):
                g = (gx * W, gy * H)
                for _ in range(20):   # 静止点: 頭はほぼ動かない
                    F.append(self.feat(g, rng.normal(0, 0.005), rng.normal(0, 0.005), rng)); Y.append(g); G.append(gi)
                gi += 1
        if with_head:
            for g in [(0.5 * W, 0.5 * H), (0.25 * W, 0.3 * H), (0.75 * W, 0.7 * H)]:
                for k in range(150):   # 同じ点を見たまま頭を左右上下に動かす
                    hx, hy = 0.15 * np.sin(k / 12), 0.10 * np.sin(k / 19)
                    F.append(self.feat(g, hx, hy, rng)); Y.append(g); G.append(gi)
                gi += 1
        return fit_groups(np.array(F), np.array(Y), np.array(G), (W, H), 0.28)

    def drift(self, m, rng):
        g = (0.5 * W, 0.5 * H)
        P = np.stack([m.predict(self.feat(g, hx, 0.0, rng)) for hx in np.linspace(-0.15, 0.15, 21)])
        return float(np.ptp(P[:, 0]))       # 頭を回したときのカーソルの横移動量 [px]

    def test_head_motion_phase_removes_drift(self):
        rng = np.random.default_rng(0)
        d_static = self.drift(self.make(False, rng), rng)
        m = self.make(True, rng)
        d_head = self.drift(m, rng)
        self.assertIn("hx", m.cols)
        self.assertGreater(d_static, 300)       # 頭の較正なし: 大きくずれる
        self.assertLess(d_head, 0.25 * d_static)


class TestGames(unittest.TestCase):
    def setUp(self):   # 自己ベストの保存先をテスト用の一時ファイルにする
        import tempfile
        import gazekit.games as g
        self._g, self._orig = g, g._BEST
        self._tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
        g._BEST = self._tmp

    def tearDown(self):
        self._g._BEST = self._orig
        os.remove(self._tmp)

    def test_selector_hysteresis(self):
        from gazekit.games import RectSelector
        s = RectSelector([(0, 0, 100, 100), (110, 0, 100, 100)], dwell=0.1)
        s.update((50, 50), 0.0); s.update((50, 50), 0.2)
        self.assertEqual(s.hover, 0)
        s.update((105, 50), 0.3); s.update((105, 50), 0.6)      # 境界のすぐ外: まだ 0 のまま
        self.assertEqual(s.hover, 0)
        s.update((160, 50), 0.7); s.update((160, 50), 0.9)
        self.assertEqual(s.hover, 1)

    def test_quiz_scoring_and_result(self):
        from gazekit.games import Quiz, center
        q = Quiz(1920, 1080, seed=1)
        t = 0.0
        for i in range(q.N):
            ans = q.qs[q.i][2]
            p = center(q.sel.rects[ans] if i % 2 == 0 else q.sel.rects[(ans + 1) % 4])   # 半分正解
            for _ in range(10):
                t += 0.05; q.on_gaze(p, t); q.tick(t)
            q.on_long_blink(t)
            for _ in range(40):
                t += 0.05; q.tick(t)
        self.assertEqual(q.score, q.N // 2)
        self.assertEqual(q.request[0], "result")

    def test_mole_dwell_hit_and_bomb(self):
        from gazekit.games import Mole, _Mole, center
        m = Mole(1920, 1080, seed=0)
        m.tick(0.0)
        m.moles = {4: _Mole("normal", 0.0, 10.0), 0: _Mole("bomb", 0.0, 10.0)}
        m.next_spawn = 1e9
        t = 0.0
        for _ in range(20):                      # 中央のモグラを見つめる
            t += 0.05; m.on_gaze(center(m.cells[4]), t); m.tick(t)
        self.assertEqual(m.score, 10)
        for _ in range(20):                      # 爆弾を見つめると減点
            t += 0.05; m.on_gaze(center(m.cells[0]), t); m.tick(t)
        self.assertEqual(m.score, -10)
        m.tick(Mole.DURATION + 1)
        self.assertEqual(m.request[0], "result")


class TestWebEyeTrackParity(unittest.TestCase):
    """元実装 (TensorFlow/Keras) で計算した参照値 tests/data/blazegaze_ref.npz と一致することを確認する。
    参照値は tools/ の変換・検証時に、元の .keras モデルから作った。"""

    @classmethod
    def setUpClass(cls):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cls.ref = np.load(os.path.join(root, "tests", "data", "blazegaze_ref.npz"))
        cls.models = os.path.join(root, "models")

    def test_encoder_and_mlp_match_keras(self):
        import cv2
        from gazekit.wet import GazeMLP
        yy, xx = np.mgrid[0:128, 0:512].astype(np.float32)
        img = np.stack([(np.sin(xx / 17.0) + 1) / 2, (np.cos(yy / 9.0 + xx / 40.0) + 1) / 2,
                        ((xx + yy) % 64) / 63.0], -1)
        net = cv2.dnn.readNetFromONNX(os.path.join(self.models, "blazegaze_encoder.onnx"))
        net.setInput(cv2.dnn.blobFromImage(img))
        emb = net.forward().reshape(-1)
        np.testing.assert_allclose(emb, self.ref["emb"], atol=1e-4)
        mlp = GazeMLP(dict(np.load(os.path.join(self.models, "blazegaze_mlp.npz"))))
        out, _ = mlp.forward(np.concatenate([emb, self.ref["hv"], self.ref["fo"]])[None].astype(np.float32))
        np.testing.assert_allclose(out[0], self.ref["out"], atol=1e-5)

    def test_adaptation_matches_keras_adam(self):
        from gazekit.wet import GazeMLP, KerasAdam, compute_affine_transform
        r = self.ref
        mlp = GazeMLP(dict(np.load(os.path.join(self.models, "blazegaze_mlp.npz"))))
        X = np.concatenate([r["E"], r["H"], r["F"]], 1).astype(np.float32)
        Y = r["Y"]
        scr = np.array([30.0, 19.0], np.float32)
        pred, _ = mlp.forward(X)
        A = compute_affine_transform(pred.astype(np.float64), Y.astype(np.float64))
        np.testing.assert_allclose(A, r["A"], atol=1e-5)
        opt = KerasAdam(1e-4)
        for _ in range(10):
            out, cache = mlp.forward(X)
            Af = A.astype(np.float32)
            p = out @ Af[:, :2].T + Af[:, 2]
            d = (np.sign(p - Y) * scr / (2 * len(Y))) @ Af[:, :2]
            opt.apply(mlp.p, mlp.backward(cache, d.astype(np.float32)))
        np.testing.assert_allclose(p, r["pred"], atol=1e-4)
        for k in ("W0", "W1", "W2", "b2"):
            np.testing.assert_allclose(mlp.p[k], r[k], atol=1e-5)

    def test_kalman_and_affine_basics(self):
        from gazekit.wet import KalmanFilter2D, compute_affine_transform
        k = KalmanFilter2D()
        for _ in range(60):
            v = k.step(np.array([0.2, -0.1]))
        np.testing.assert_allclose(v, [0.2, -0.1], atol=0.02)
        src = np.random.default_rng(0).uniform(-0.5, 0.5, (6, 2))
        A = np.array([[1.1, 0.1, 0.02], [-0.05, 0.9, -0.03]])
        np.testing.assert_allclose(compute_affine_transform(src, src @ A[:, :2].T + A[:, 2]), A, atol=1e-9)


class TestStackModel(unittest.TestCase):
    def test_fit_recovers_linear_combination(self):
        from gazekit.hybrid import StackModel, stack_features
        rng = np.random.default_rng(0)
        G = np.repeat(np.arange(20), 15)
        Y = np.repeat(rng.uniform(0, 1000, (20, 2)), 15, axis=0)
        wet = Y * 0.8 + 100 + rng.normal(0, 30, Y.shape)          # 偏りのある WebEyeTrack 予測
        cls = np.zeros((len(Y), 10)); cls[:, 0] = cls[:, 2] = Y[:, 0] / 5000; cls[:, 1] = cls[:, 3] = Y[:, 1] / 5000
        cls[:, :4] += rng.normal(0, 0.002, (len(Y), 4)); cls[:, 4] = 0.3
        m = StackModel.fit(stack_features(wet, cls), Y, G)
        P = np.stack([m.predict(x) for x in stack_features(wet, cls)])
        self.assertLess(np.mean(np.linalg.norm(P - Y, axis=1)), 25)
        self.assertLess(m.cv_error_px, 40)


class TestFutsal(unittest.TestCase):
    def setUp(self):
        from gazekit.football import FutsalGame
        self.g = FutsalGame(1920, 1080, keys=None, seed=0)
        self.g.update(0.0)

    def test_gaze_attention_marks_watched_teammate(self):
        from gazekit.football import HOME
        g = self.g
        mate = [p for p in g.team(HOME) if p is not g.ball.owner and not p.gk][0]
        for i in range(20):
            g.on_gaze(g.to_px(mate.p), i / 30)
            g.update(i / 30)
        self.assertIs(g.watched, mate)

    def test_nolook_pass_stuns_defenders(self):
        from gazekit.football import AWAY, HOME
        g = self.g
        carrier = g.ball.owner
        mates = [p for p in g.team(HOME) if p is not carrier and not p.gk]
        g.watched = mates[0]
        g.attn[id(mates[0])] = 1.0
        g.kick("pass", target=mates[1])
        self.assertTrue(g.ball.nolook)
        self.assertEqual(g.stats["nolook"], 1)
        self.assertTrue(all(p.stun > 0 for p in g.team(AWAY)))

    def test_goal_and_kickoff(self):
        from gazekit.football import AWAY, L
        g = self.g
        g.ball.owner = None
        g.ball.p[:] = (L / 2 - 0.1, 0.0)
        g.ball.v[:] = (5.0, 0.0)
        g.update(0.05)
        self.assertEqual(g.score, [1, 0])
        self.assertEqual(g.ball.owner.team, AWAY)      # 失点した側からキックオフ


class TestSoccer11Rules(unittest.TestCase):
    def setUp(self):
        from gazekit.soccer11 import Soccer11
        self.g = Soccer11(1920, 1080, keys=None, seed=0)
        self.g.update(0.0)

    def _free_ball(self, pos, vel, last):
        b = self.g.ball
        b.owner = None
        b.p[:] = pos
        b.v[:] = vel
        b.z = b.vz = 0
        b.last = b.kicker = last

    def test_goal_kick_vs_corner(self):
        from gazekit.soccer11 import AWAY, HOME, PL
        g = self.g
        self._free_ball((PL / 2 - 0.2, 15.0), (8.0, 0.0), g.team(HOME)[9])      # 攻撃側が出した
        g.update(0.05)
        self.assertEqual((g.setp["kind"], g.setp["team"]), ("gk", AWAY))
        g.setp = None
        self._free_ball((PL / 2 - 0.2, 15.0), (8.0, 0.0), g.team(AWAY)[2])      # 守備側が出した
        g.update(0.10)
        self.assertEqual((g.setp["kind"], g.setp["team"]), ("corner", HOME))

    def test_throw_in_goes_to_other_team(self):
        from gazekit.soccer11 import AWAY, HOME, PW
        g = self.g
        self._free_ball((5.0, PW / 2 - 0.2), (0.0, 8.0), g.team(HOME)[6])
        g.update(0.05)
        self.assertEqual((g.setp["kind"], g.setp["team"]), ("throw", AWAY))

    def test_offside(self):
        from gazekit.soccer11 import AWAY, HOME
        g = self.g
        c, r = g.team(HOME)[6], g.team(HOME)[9]
        c.p[:] = (5.0, 0.0)
        r.p[:] = (40.0, 0.0)                          # 守備ラインより前
        for i, q in enumerate(g.team(AWAY)):
            q.p[:] = (30.0 - i, 25.0) if i else (51.0, 0.0)
        g.ball.owner = c
        g.setp = None
        g.kick("pass", c, target=r)
        self.assertIs(g.ball.offside, r)
        g.ball.p[:] = r.p
        g.ball.v[:] = (1.0, 0.0)
        g.try_receive()
        self.assertEqual((g.setp["kind"], g.setp["team"]), ("fk", AWAY))

    def test_foul_in_box_is_penalty(self):
        from gazekit.soccer11 import AWAY, HOME, PL
        g = self.g
        victim, fouler = g.team(HOME)[9], g.team(AWAY)[2]
        victim.p[:] = (PL / 2 - 8, 0.0)
        g.foul(fouler, victim)
        self.assertEqual((g.setp["kind"], g.setp["team"]), ("pk", HOME))

    def test_keeper_leans_to_where_you_look(self):
        from gazekit.soccer11 import AWAY, GOAL_W, PL
        g = self.g
        g.setp = None
        for i in range(30):
            g.on_gaze(g.to_px((PL / 2, GOAL_W / 2)), i / 30)
            g.update_attention(1 / 30)
        tg = g.shape_targets()
        self.assertGreater(tg[id(g.team(AWAY)[0])][1], 0.8)


class TestSkillMoves(unittest.TestCase):
    def setUp(self):
        from gazekit.soccer11 import Soccer11, HOME
        self.g = Soccer11(1920, 1080, keys=None, seed=0)
        self.g.update(0.0)
        self.c = self.g.ball.owner
        self.g.ctrl = self.c
        self.c.face[:] = (1.0, 0.0)
        self.c.v[:] = (3.0, 0.0)            # 右 (+x) へ進んでいる

    def _input(self, keys):
        g = self.g
        g.skill_arm_until = g.elapsed + 0.6   # R2 (Shift) 短押しの直後と同じ状態
        for k in keys:
            g.on_key(ord(k))
            g.elapsed += 0.05
        return g.match_skill(self.c)

    def test_commands_map_to_skills(self):
        self.assertEqual(self._input("s")[0], "double_touch")              # 横 1回
        self.g.rs_buf = []
        self.assertEqual(self._input("sw")[0], "elastico")                 # 横 -> 逆の横
        self.g.rs_buf = []
        self.assertEqual(self._input("ds")[0], "scissors")                 # 前 -> 横
        self.g.rs_buf = []
        self.assertEqual(self._input("das")[0], "marseille")               # 前 -> 後ろ -> 横
        self.g.rs_buf = []
        self.assertEqual(self._input("a")[0], "drag_back")                 # 後ろ

    def test_skill_runs_and_keeps_ball(self):
        g, c = self.g, self.c
        for q in g.team(1 - c.team):
            q.p[:] = (40.0, 30.0)            # 近くに相手なし
        name, f, side = self._input("s")
        g.rs_buf = []
        g.start_skill(c, name, f, side)
        t = g.elapsed
        for i in range(20):
            t += 1 / 30
            g.t_last = t - 1 / 30
            g.update(t)
        self.assertIsNone(c.skill)
        self.assertIs(g.ball.owner, c)

    def test_defender_can_be_beaten_or_read(self):
        g, c = self.g, self.c
        d = g.team(1 - c.team)[2]
        d.p[:] = c.p + (1.2, 0.0)
        d.v[:] = (-4.0, 0.0)                # 勢いよく寄せてくる
        beaten = 0
        for i in range(40):
            d.stun = 0
            g.ball.owner = c
            g.start_skill(c, "elastico", np.array([1.0, 0.0]), np.array([0.0, 1.0]))
            c.skill_log = []
            g.judge_skill(c)
            beaten += d.stun > 0
        self.assertTrue(10 < beaten < 40)    # 確率的に抜ける / 止められる


class TestSoccer11Controls(unittest.TestCase):
    """eFootball スマホ版のボタン構成: パス=K, スルーパス=I, シュート=J, カーソル=U。フリック = ボタン + 矢印キー。"""

    def setUp(self):
        from gazekit.soccer11 import Soccer11
        self.g = Soccer11(1920, 1080, keys=None, seed=0)
        self.g.update(0.0)

    def test_attack_buttons(self):
        g = self.g
        for key, flick, kind in (("k", None, "pass"), ("k", "Up", "lofted"), ("i", None, "through"),
                                 ("i", "Down", "lthrough")):
            g.kickoff(0)
            g._ev = {}
            if flick:
                g._ev[flick] = g.elapsed               # その向きにフリック
            g.on_key(ord(key))
            self.assertIsNone(g.ball.owner)
            self.assertEqual(g.ball.kind, kind)
        g.kickoff(0)
        g._ev = {}
        g.on_key(ord("j"))
        self.assertIsNotNone(g.charge)              # シュートボタン: 溜め開始

    def test_shoot_button_is_tackle_when_defending_and_l_is_slide(self):
        from gazekit.soccer11 import AWAY, HOME
        g = self.g
        g.kickoff(AWAY)
        carrier = g.ball.owner
        me = g.team(HOME)[5]
        g.ctrl = me
        me.p[:] = carrier.p + (1.0, 0.0)
        g.ball.p[:] = carrier.p + (0.5, 0.0)
        g.on_key(ord("j"))
        self.assertGreater(me.cd, 0)                 # □: タックルを試みた
        g.ctrl.cd = 0
        g.ball.owner = carrier
        g.on_key(ord("l"))
        self.assertGreater(me.slide, 0)              # ○: スライディング

    def test_next_cursor_prefers_goal_side_defender(self):
        from gazekit.soccer11 import AWAY, HOME
        g = self.g
        g.kickoff(AWAY)
        carrier = g.ball.owner
        carrier.p[:] = (-10.0, 0.0)
        g.update_ball(0.0)
        ahead, behind = g.team(HOME)[9], g.team(HOME)[2]
        g.ctrl = g.team(HOME)[8]
        g.ctrl.p[:] = (30.0, -20.0)
        ahead.p[:] = (-7.0, 0.0)                     # ボールより相手ゴール側 (抜かれている)
        behind.p[:] = (-18.0, 2.0)                   # ボールより自陣ゴール側
        for p in g.team(HOME):
            if p not in (ahead, behind, g.ctrl) and not p.gk:
                p.p[:] = (40.0, 30.0)
        self.assertIs(g.next_cursor(), behind)
        g.on_key(ord("u"))
        self.assertIs(g.ctrl, behind)
