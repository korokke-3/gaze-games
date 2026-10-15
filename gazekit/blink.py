from __future__ import annotations

from typing import Optional


class BlinkDetector:
    """目の開き具合(openness)から通常の瞬きと意図的な長い瞬きを区別する。

    - openness は個人ごとの「開眼時の値」(baseline) に対する比で判定する (ヒステリシス付き)。
    - 閉眼が SHORT_MIN 未満はノイズ、LONG_PROGRESS_START まではただの瞬きとして無視、
      LONG_DURATION に達した時点で confirmed=True を1回だけ出す (閉じたまま達した時に発火)。
    """

    CLOSE_RATIO = 0.55    # baseline * 0.55 未満で「閉じた」
    OPEN_RATIO = 0.70     # baseline * 0.70 以上で「開いた」
    SHORT_MIN = 0.05      # [s] これ未満はノイズ
    LONG_DURATION = 0.55  # [s] 既定。これ以上閉じ続けたら決定 (set_long で変更可)
    PROGRESS_FRAC = 0.5   # 決定時間のこの割合を過ぎたらリング表示 (通常の瞬きでチラつかない)
    REFRACTORY = 0.5      # [s] 決定後の再発火禁止

    def __init__(self, baseline: float = 0.25):
        self.baseline = baseline
        self.closed = False
        self._t_close = 0.0
        self._fired = False
        self._lock_until = 0.0
        self.progress = 0.0       # 0..1 長い瞬きの進行度 (UI用)
        self.last_blink_duration = 0.0
        self.long_duration = self.LONG_DURATION
        self.natural = []         # 通常の瞬きの継続時間の履歴 [s]

    def set_long(self, seconds: float):
        self.long_duration = float(min(max(seconds, 0.3), 1.2))

    def auto_long(self, margin: float = 1.5, lo: float = 0.4, hi: float = 0.8):
        """この人の通常の瞬きの最長(外れ値除去後)の margin 倍を決定時間にする。"""
        d = [x for x in self.natural if 0.05 <= x <= 0.6]
        if len(d) >= 4:
            self.set_long(min(max(margin * max(d), lo), hi))

    def set_baseline(self, v: float):
        if v > 1e-3:
            self.baseline = v

    def openness_ratio(self, openness: float) -> float:
        return openness / max(self.baseline, 1e-6)

    def is_open(self, openness: Optional[float]) -> bool:
        """視線推定に使ってよい(目がしっかり開いている)か。"""
        return openness is not None and not self.closed and self.openness_ratio(openness) >= self.OPEN_RATIO

    def reset(self):
        self.closed = False
        self._fired = False
        self.progress = 0.0

    def update(self, openness: Optional[float], t: float) -> str:
        """戻り値: 'none' | 'blink' (通常の瞬きが終わった) | 'long_blink' (決定)"""
        if openness is None:  # 顔ロスト: 状態をリセットして誤発火を避ける
            self.reset()
            return "none"
        r = self.openness_ratio(openness)
        event = "none"
        if not self.closed:
            if r < self.CLOSE_RATIO:
                self.closed = True
                self._t_close = t
                self._fired = False
            else:
                # 開眼中だけ baseline をゆっくり追従 (照明/姿勢変化)
                self.baseline += 0.002 * (openness - self.baseline)
        else:
            dur = t - self._t_close
            start = self.PROGRESS_FRAC * self.long_duration
            if dur >= start:
                self.progress = min(1.0, (dur - start) / (self.long_duration - start))
            if not self._fired and dur >= self.long_duration and t >= self._lock_until:
                self._fired = True
                event = "long_blink"
            if r >= self.OPEN_RATIO:
                self.closed = False
                self.progress = 0.0
                self.last_blink_duration = dur
                if self._fired:
                    self._lock_until = t + self.REFRACTORY
                elif dur >= self.SHORT_MIN:
                    event = "blink"
                    self.natural.append(dur)
                    self.natural = self.natural[-40:]
        return event
