from __future__ import annotations

import math
from collections import deque

import numpy as np


class OneEuroFilter:
    """One Euro Filter (Casiez+ 2012). 静止時は強く平滑化し、速い動きでは遅延を減らす。"""

    def __init__(self, min_cutoff=0.8, beta=0.006, d_cutoff=1.0):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self.reset()

    def reset(self):
        self._x = None
        self._dx = None
        self._t = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x, t):
        x = np.asarray(x, dtype=np.float64)
        if self._x is None or t <= self._t:
            self._x, self._dx, self._t = x.copy(), np.zeros_like(x), t
            return x.copy()
        dt = t - self._t
        a_d = self._alpha(self.d_cutoff, dt)
        dx = (x - self._x) / dt
        self._dx = a_d * dx + (1 - a_d) * self._dx
        speed = float(np.linalg.norm(self._dx))
        a = self._alpha(self.min_cutoff + self.beta * speed, dt)
        self._x = a * x + (1 - a) * self._x
        self._t = t
        return self._x.copy()


class GazeSmoother:
    """3点メディアン(外れ値除去) -> One Euro。瞬き中などは hold() で値を凍結する。"""

    def __init__(self, **kw):
        self._buf = deque(maxlen=3)
        self._f = OneEuroFilter(**kw)
        self.value = None

    def update(self, p, t):
        self._buf.append(np.asarray(p, dtype=np.float64))
        med = np.median(np.stack(self._buf), axis=0)
        self.value = self._f(med, t)
        return self.value

    def reset(self):
        self._buf.clear()
        self._f.reset()
        self.value = None
