#!/usr/bin/env python3
"""camera_monitor.py — SUA133GC 相机状态/帧率监视窗口 (GTK3)。

只读监视，绝不直接访问相机（不争抢 usbfs，与预览/soak/ROS 节点共存）：
  - 订阅 /mv_camera/image_raw：实时 fps（2s 滑窗）+ 迷你曲线 + 分辨率/编码
  - sysfs：设备是否在总线、链路速率（SuperSpeed / HighSpeed）、Bus/Dev
  - 进程：ROS 节点是否在运行
  - 日志：节点 [RECOVER]/白平衡事件 + 看门狗 L3/L4 恢复事件（最近几条）

运行（桌面会话或带 WAYLAND/DISPLAY 环境）：
  source /opt/ros/humble/setup.bash
  python3 ~/ros2_ws/src/sua_aravis_camera/scripts/camera_monitor.py
"""
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Pango
import cairo
import glob
import os
import re
import subprocess
import threading
import time

try:
    import rclpy
    from rclpy.node import Node
    from sensor_msgs.msg import Image
    HAVE_ROS = True
except ImportError:
    HAVE_ROS = False

TOPIC = '/mv_camera/image_raw'
NODE_LOG = '/tmp/ros_node.log'
WATCHDOG_LOG = '/var/log/camera-watchdog.log'

state = {
    'lock': threading.Lock(),
    'times': [],           # message arrival times (monotonic)
    'w': 0, 'h': 0, 'enc': '',
    'last_msg': 0.0,
}


class Feed(threading.Thread):
    """rclpy spinner: tracks message arrivals from the image topic."""

    def __init__(self):
        super().__init__(daemon=True)

    def run(self):
        rclpy.init()
        node = Node('camera_monitor_feed')

        def on_img(m):
            now = time.monotonic()
            with state['lock']:
                state['times'].append(now)
                if len(state['times']) > 4000:
                    del state['times'][:2000]
                state['w'], state['h'], state['enc'] = m.width, m.height, m.encoding
                state['last_msg'] = now

        node.create_subscription(Image, TOPIC, on_img, 5)
        try:
            rclpy.spin(node)
        except Exception:
            pass


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=3).stdout.strip()
    except Exception:
        return ''


def camera_sysfs():
    """Return (devdir, speed, bus, dev) for the camera, or None."""
    for f in glob.glob('/sys/bus/usb/devices/*/idVendor'):
        try:
            if open(f).read().strip() == 'f622':
                d = os.path.dirname(f)
                speed = open(os.path.join(d, 'speed')).read().strip()
                bus = open(os.path.join(d, 'busnum')).read().strip()
                dev = open(os.path.join(d, 'devnum')).read().strip()
                return d, speed, bus, dev
        except OSError:
            continue
    return None


def tail_events(path, patterns, n=4):
    """Last matching lines (oldest→newest) of a log file."""
    try:
        with open(path, 'rb') as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 65536))
            lines = fh.read().decode('utf-8', 'replace').splitlines()
        out = [l for l in lines if any(p in l for p in patterns)]
        return out[-n:]
    except OSError:
        return []


class Monitor(Gtk.Window):
    def __init__(self):
        super().__init__(title='SUA133GC 相机监视器')
        self.set_default_size(620, 520)
        self.connect('destroy', Gtk.main_quit)

        css = Gtk.CssProvider()
        css.load_from_data(b"""
            .big  { font-size: 24px; font-weight: bold; }
            .mid  { font-size: 15px; }
            .mono { font-family: monospace; font-size: 11px; color: #555; }
        """)
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        v.set_margin_top(12)
        v.set_margin_bottom(10)
        v.set_margin_start(14)
        v.set_margin_end(14)
        self.add(v)

        self.status_lbl = Gtk.Label(xalign=0)
        self.status_lbl.get_style_context().add_class('big')
        v.pack_start(self.status_lbl, False, False, 0)

        self.fps_lbl = Gtk.Label(xalign=0)
        self.fps_lbl.get_style_context().add_class('mid')
        v.pack_start(self.fps_lbl, False, False, 0)

        self.spark = Gtk.DrawingArea()
        self.spark.set_size_request(-1, 64)
        self.spark.connect('draw', self.on_draw)
        v.pack_start(self.spark, False, False, 0)
        self.fps_hist = []

        grid = Gtk.Grid(column_spacing=14, row_spacing=4)
        v.pack_start(grid, False, False, 4)
        self.info = {}
        for i, (key, name) in enumerate([
                ('res', '分辨率'), ('enc', '编码'), ('link', '链路速率'),
                ('dev', '设备'), ('pid', '节点进程'), ('wb', '白平衡')]):
            nl = Gtk.Label(xalign=1)
            nl.set_markup(f'<b>{name}</b>')
            vl = Gtk.Label(xalign=0)
            vl.set_width_chars(46)
            vl.set_ellipsize(Pango.EllipsizeMode.END)
            grid.attach(nl, 0, i, 1, 1)
            grid.attach(vl, 1, i, 1, 1)
            self.info[key] = vl

        ev_head = Gtk.Label(xalign=0)
        ev_head.set_markup('<b>最近事件</b>')
        v.pack_start(ev_head, False, False, 6)
        self.ev_lbl = Gtk.Label(xalign=0)
        self.ev_lbl.get_style_context().add_class('mono')
        self.ev_lbl.set_halign(Gtk.Align.START)
        v.pack_start(self.ev_lbl, True, True, 0)

        self.wb_line = '—'
        self._ev_n = 0
        self.fps = 0.0
        GLib.timeout_add(500, self.tick)

    def tick(self):
        now = time.monotonic()
        with state['lock']:
            times = [t for t in state['times'] if t > now - 10]
            state['times'] = times
            w, h, enc, last = state['w'], state['h'], state['enc'], state['last_msg']

        self.fps = sum(1 for t in times if t > now - 2.0) / 2.0
        self.fps_hist.append(self.fps)
        if len(self.fps_hist) > 240:
            del self.fps_hist[0]

        pid = sh("pgrep -f 'aravis_camera_[n]ode' | head -1")
        cam = camera_sysfs()

        if last and now - last < 2.0 and self.fps > 1:
            st, col = '● 正在推流', '#2e9e4f'
        elif pid and (not last or now - last > 2.0):
            st, col = '● 数据停滞（节点在，无帧）', '#d98a00'
        elif cam and not pid:
            st, col = '● 相机在总线，节点未运行', '#888888'
        elif not cam:
            st, col = '● 相机不在总线（恢复中或已拔出）', '#cc3333'
        else:
            st, col = '● 无数据', '#cc3333'
        note = '' if HAVE_ROS else '（未检测到 rclpy：无帧率数据）'
        self.status_lbl.set_markup(
            f'<span foreground="{col}">{st}</span>'
            f'  <span size="small" foreground="#888">{TOPIC} {note}</span>')
        self.fps_lbl.set_markup(f'<span size="x-large">{self.fps:5.1f}</span>  fps')

        self.info['res'].set_text(f'{w}×{h}' if w else '—')
        self.info['enc'].set_text(enc or '—')
        if cam:
            d, speed, bus, dev = cam
            mode = {'5000': 'SuperSpeed', '480': 'HighSpeed'}.get(speed, speed + ' Mbps')
            self.info['link'].set_text(f'{speed} Mbps（{mode}）')
            self.info['dev'].set_text(f'Bus {bus} Dev {dev}')
        else:
            self.info['link'].set_text('—')
            self.info['dev'].set_text('—')
        self.info['pid'].set_text(f'PID {pid}' if pid else '未运行')
        self.info['wb'].set_text(self.wb_line)

        self._ev_n += 1
        if self._ev_n % 4 == 0:
            wb = tail_events(NODE_LOG, ['white balance'], 1)
            if wb:
                self.wb_line = (wb[0].split(']:')[-1].strip() or self.wb_line)[:60]
            evs = []
            for l in tail_events(NODE_LOG, ['[RECOVER]', 'white balance', 'PHYSICAL'], 5):
                text = l.split(']:')[-1].strip() if ']:' in l else l
                evs.append('节点   ' + text[:100])
            for l in tail_events(WATCHDOG_LOG, ['L4 ', 'L3 ', 'revived', 'PHYSICAL', 'VBUS'], 3):
                evs.append('看门狗 ' + l[:100])
            self.ev_lbl.set_text('\n'.join(evs[-9:]) or '（暂无）')

        self.spark.queue_draw()
        return True

    def on_draw(self, w, cr):
        a = self.fps_hist
        alloc = self.spark.get_allocation()
        wd, ht = alloc.width, alloc.height
        cr.set_source_rgb(0.94, 0.94, 0.94)
        cr.paint()
        cr.set_font_size(10)
        if len(a) < 2:
            cr.set_source_rgb(0.4, 0.4, 0.4)
            cr.move_to(4, ht / 2)
            cr.show_text('fps 曲线（最近 2 分钟）')
            return False
        mx = max(max(a), 5.0)
        step = wd / 239.0
        x0 = wd - (len(a) - 1) * step
        cr.set_source_rgb(0.18, 0.55, 0.86)
        cr.set_line_width(1.6)
        cr.move_to(x0, ht - 3 - a[0] / mx * (ht - 10))
        for i, v in enumerate(a[1:], 1):
            cr.line_to(x0 + i * step, ht - 3 - v / mx * (ht - 10))
        cr.stroke()
        cr.set_source_rgb(0.4, 0.4, 0.4)
        cr.move_to(4, 12)
        cr.show_text(f'最近 2 分钟 · 峰值 {max(a):.0f} fps')
        return False


def main():
    if HAVE_ROS:
        Feed().start()
    else:
        print('警告: rclpy 不可用（先 source /opt/ros/humble/setup.bash），仅显示系统状态')
    # SIGTERM/SIGINT must be handled on the GLib main loop: the python-level
    # default handler never runs while the main thread is inside Gtk.main().
    import signal
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit, None)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, Gtk.main_quit, None)
    w = Monitor()
    w.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
