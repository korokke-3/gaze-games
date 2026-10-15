from __future__ import annotations

from typing import Optional, Tuple

import numpy as np


def zoom_region(center, screen: Tuple[int, int], factor: float = 4.0) -> Tuple[int, int, int, int]:
    """center を中心に、画面を factor 倍に拡大したときに表示される領域 (x0, y0, w, h)。画面端でクランプ。"""
    w, h = int(screen[0] / factor), int(screen[1] / factor)
    x0 = int(min(max(center[0] - w / 2, 0), screen[0] - w))
    y0 = int(min(max(center[1] - h / 2, 0), screen[1] - h))
    return x0, y0, w, h


def zoom_to_screen(p, region, canvas: Tuple[int, int]) -> np.ndarray:
    """拡大表示(canvas全面)上の座標 p を実画面座標に戻す。"""
    x0, y0, w, h = region
    return np.array([x0 + p[0] / canvas[0] * w, y0 + p[1] / canvas[1] * h])


class CursorFilter:
    """カーソルのガタつき防止: 視線が dead zone 内なら動かさず、外に出たら追従する。"""

    def __init__(self, dead_px: float = 35.0, follow: float = 0.35):
        self.dead, self.k = dead_px, follow
        self.pos: Optional[np.ndarray] = None

    def update(self, target) -> np.ndarray:
        target = np.asarray(target, dtype=np.float64)
        if self.pos is None:
            self.pos = target.copy()
        elif np.linalg.norm(target - self.pos) > self.dead:
            self.pos += self.k * (target - self.pos)
        return self.pos.copy()


class OSMouse:
    """X11 (python-xlib) でカーソル移動/クリック。Ubuntu 20.04 標準の X11 セッション向け。"""

    backend = "X11 (XTest)"

    def __init__(self):
        from Xlib import X, display
        from Xlib.ext import xtest
        self._X, self._xtest = X, xtest
        self.d = display.Display()
        self.root = self.d.screen().root
        g = self.root.get_geometry()
        self.size = (g.width, g.height)

    def move(self, x: float, y: float):
        x = int(min(max(x, 0), self.size[0] - 1))
        y = int(min(max(y, 0), self.size[1] - 1))
        self.root.warp_pointer(x, y)
        self.d.sync()

    def position(self) -> Tuple[int, int]:
        q = self.root.query_pointer()
        return q.root_x, q.root_y

    def click(self, button: int = 1):
        self._xtest.fake_input(self.d, self._X.ButtonPress, button)
        self._xtest.fake_input(self.d, self._X.ButtonRelease, button)
        self.d.sync()

    def close(self):
        self.d.close()


def _grab_portal(timeout: float = 8.0) -> Optional[np.ndarray]:
    """XDG Desktop Portal の Screenshot (Wayland/GNOME で利用可)。jeepney (純Python D-Bus) を使う。
    ポータルは ~/Pictures にファイルを書くので、読み込んだ後に削除する。"""
    try:
        import os
        import time
        from urllib.parse import unquote, urlparse

        import cv2
        from jeepney import DBusAddress, new_method_call
        from jeepney.bus_messages import MatchRule, message_bus
        from jeepney.io.blocking import Proxy, open_dbus_connection
        conn = open_dbus_connection(bus="SESSION")
        try:
            sender = conn.unique_name[1:].replace(".", "_")
            token = "gazekit%d" % int(time.time() * 1000)
            req = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
            rule = MatchRule(type="signal", interface="org.freedesktop.portal.Request",
                             member="Response", path=req)
            Proxy(message_bus, conn).AddMatch(rule)
            addr = DBusAddress("/org/freedesktop/portal/desktop", bus_name="org.freedesktop.portal.Desktop",
                               interface="org.freedesktop.portal.Screenshot")
            msg = new_method_call(addr, "Screenshot", "sa{sv}",
                                  ("", {"interactive": ("b", False), "handle_token": ("s", token)}))
            conn.send_and_get_reply(msg, timeout=5)
            with conn.filter(rule) as q:
                m = conn.recv_until_filtered(q, timeout=timeout)
            code, res = m.body
            if code != 0 or "uri" not in res:
                return None
            path = unquote(urlparse(res["uri"][1]).path)
            img = cv2.imread(path)
            try:
                os.remove(path)
            except OSError:
                pass
            return img
        finally:
            conn.close()
    except Exception:
        return None


def grab_screen() -> Optional[np.ndarray]:
    """全画面のスクリーンショット (BGR)。X11 は mss、Wayland は ポータル。失敗時 None。"""
    try:
        import mss
        with mss.mss() as s:
            m = s.monitors[0]
            img = np.ascontiguousarray(np.array(s.grab(m))[:, :, :3])
        if img.mean() > 2.0:      # Wayland では XWayland 経由で真っ黒になる
            return img
    except Exception:
        pass
    return _grab_portal()


class KeyHold:
    """X11 のキー状態(XQueryKeymap)を直接読み、キーが「押されている間」だけ True を返す。
    OpenCV の waitKey は離した事象を返さないため。X11/XWayland 以外では available=False。"""

    def __init__(self):
        self.available = False
        try:
            from Xlib import XK, display
            self.d = display.Display()
            self._codes = {}
            self._XK = XK
            self.available = True
        except Exception:
            self.d = None

    def is_down(self, keysym_name: str = "space") -> bool:
        if not self.available:
            return False
        try:
            code = self._codes.get(keysym_name)
            if code is None:
                code = self.d.keysym_to_keycode(self._XK.string_to_keysym(keysym_name))
                self._codes[keysym_name] = code
            km = self.d.query_keymap()
            return bool(km[code // 8] & (1 << (code % 8)))
        except Exception:
            return False


class UInputMouse:
    """/dev/uinput に仮想の絶対座標ポインタを作る (外部ライブラリ不要)。
    カーネルレベルの入力なので X11 でも Wayland でも動く。/dev/uinput への書き込み権限が必要
    (enable_uinput.sh で付与)。"""

    backend = "uinput (works on Wayland/X11)"
    # linux/uinput.h, linux/input-event-codes.h
    UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
    UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
    EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
    BTN_LEFT, BTN_RIGHT = 0x110, 0x111
    ABS_X, ABS_Y = 0, 1

    @staticmethod
    def _dev_struct(name: bytes, w: int, h: int) -> bytes:
        import struct
        absmax = [0] * 64
        absmax[UInputMouse.ABS_X], absmax[UInputMouse.ABS_Y] = w - 1, h - 1
        return (struct.pack("80sHHHHI", name, 0x03, 0x1234, 0x5678, 1, 0)
                + struct.pack("64i", *absmax) + struct.pack("64i", *([0] * 64))
                + struct.pack("64i", *([0] * 64)) + struct.pack("64i", *([0] * 64)))

    @staticmethod
    def _event(etype: int, code: int, value: int) -> bytes:
        import struct
        return struct.pack("llHHi", 0, 0, etype, code, value)

    def __init__(self, size):
        import fcntl
        import os
        import time
        self._fcntl = fcntl
        self.size = (int(size[0]), int(size[1]))
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (self.EV_KEY, self.EV_ABS, self.EV_SYN):
            fcntl.ioctl(self.fd, self.UI_SET_EVBIT, ev)
        for k in (self.BTN_LEFT, self.BTN_RIGHT):
            fcntl.ioctl(self.fd, self.UI_SET_KEYBIT, k)
        for a in (self.ABS_X, self.ABS_Y):
            fcntl.ioctl(self.fd, self.UI_SET_ABSBIT, a)
        os.write(self.fd, self._dev_struct(b"gazekit virtual pointer", *self.size))
        fcntl.ioctl(self.fd, self.UI_DEV_CREATE)
        time.sleep(0.6)          # コンポジタがデバイスを認識するまで待つ
        self._pos = (0, 0)

    def _write(self, *events):
        import os
        os.write(self.fd, b"".join(self._event(*e) for e in events) + self._event(self.EV_SYN, 0, 0))

    def move(self, x: float, y: float):
        x = int(min(max(x, 0), self.size[0] - 1))
        y = int(min(max(y, 0), self.size[1] - 1))
        self._pos = (x, y)
        self._write((self.EV_ABS, self.ABS_X, x), (self.EV_ABS, self.ABS_Y, y))

    def position(self):
        return self._pos

    def click(self, button: int = 1):
        code = self.BTN_LEFT if button == 1 else self.BTN_RIGHT
        self._write((self.EV_KEY, code, 1))
        self._write((self.EV_KEY, code, 0))

    def close(self):
        import os
        try:
            self._fcntl.ioctl(self.fd, self.UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


def make_mouse(screen):
    """使えるバックエンドを選ぶ。戻り値: (mouse or None, 失敗理由)。
    優先: uinput (Wayland対応) -> X11 XTest (Xorgセッションのみ)。"""
    import os
    reasons = []
    try:
        return UInputMouse(screen), ""
    except PermissionError:
        reasons.append("/dev/uinput: permission denied -> run ./enable_uinput.sh")
    except Exception as e:
        reasons.append("uinput: %s" % e)
    if os.environ.get("XDG_SESSION_TYPE", "").lower() != "wayland":
        try:
            return OSMouse(), ""
        except Exception as e:
            reasons.append("X11: %s" % e)
    else:
        reasons.append("Wayland session: X11 backend cannot move the real pointer")
    return None, "; ".join(reasons)
