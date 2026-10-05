#!/usr/bin/env python3
"""observe_death.py — 死链瞬间观测器（root）。
用法: observe_death.py <feeder_pid>
持续 100ms 轮询相机所在 xHCI 控制器的 PORTSC（PLS 链路状态/连接位），
记录所有迁移；同时监测 feeder(arv_grab) 的 wchar 以判定死亡时刻。
输出: /tmp/portsc.log
判读:
  死亡时 PLS 仍=0(U0)  → 链路"活着"但对端不响应（设备/PHY 模拟层挂死）
  死亡时 PLS≠0(如5/6/7) → 链路已掉但主机未收到端口事件（主机侧可修!）
"""
import glob, mmap, os, re, struct, sys, time

CAM_VID = 'f622'

def find_cam():
    for f in glob.glob('/sys/bus/usb/devices/*/idVendor'):
        try:
            if open(f).read().strip() != CAM_VID:
                continue
        except OSError:
            continue
        d = os.path.dirname(f)
        real = os.path.realpath(d)
        m = re.search(r'(fc[0-9a-f]+)\.usb', real)
        if m:
            return m.group(1)
    return None

ctrl = find_cam()
if not ctrl:
    print('camera not on bus'); sys.exit(1)
phys = int(ctrl, 16)
print(f'controller {ctrl} @ phys 0x{phys:x}')

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 0x10000, offset=phys)
def rd32(off):
    return struct.unpack_from('<I', mm, off)[0]

caplen = rd32(0) & 0xFF
oper = caplen
maxp = (rd32(oper + 0x04) >> 24) & 0xFF
print(f'CAPLENGTH=0x{caplen:x} oper=0x{oper:x} MaxPorts={maxp}')

PLS_NAMES = {0:'U0',1:'U1',2:'U2',3:'Suspended',4:'SS.Disabled',5:'Rx.Detect',
             6:'SS.Inactive',7:'Polling',8:'Recovery',9:'HotReset',10:'Compliance',
             11:'Loopback',12:'Resume'}

log = open('/tmp/portsc.log', 'a', buffering=1)
def w(s):
    log.write(f'{time.time():.3f} {s}\n')

w(f'=== harness start ctrl={ctrl} maxp={maxp}')
prev = {}
feeder = int(sys.argv[1])
last_w = -1
stall_t = None
zones = sorted(glob.glob('/sys/class/thermal/thermal_zone*/temp'))
last_thermal = 0.0

try:
    while True:
        now = time.time()
        for p in range(1, maxp + 1):
            try:
                v = rd32(oper + 0x400 + 4 * (p - 1))
            except Exception as e:
                w(f'PORT{p} read error {e}'); raise
            pls, ccs = (v >> 5) & 0xF, v & 1
            csc, pec, plc = (v >> 17) & 1, (v >> 18) & 1, (v >> 22) & 1
            key = (pls, ccs, csc, pec, plc)
            if prev.get(p) != key:
                w(f'PORT{p} PLS={pls}({PLS_NAMES.get(pls,"?")}) CCS={ccs} CSC={csc} PEC={pec} PLC={plc} RAW={v:08x}')
                prev[p] = key
        # feeder stall detection via wchar
        try:
            wv = [l for l in open(f'/proc/{feeder}/io') if l.startswith('wchar')][0]
            cur = int(wv.split()[1])
        except Exception:
            cur = last_w
        if last_w >= 0 and cur == last_w:
            if stall_t is None:
                stall_t = now
                w(f'STALL_START (wchar frozen at {cur})')
        else:
            if stall_t is not None:
                w(f'STALL_END dur={now - stall_t:.1f}s')
                stall_t = None
        last_w = cur
        if now - last_thermal > 5:
            try:
                temps = ' '.join(str(int(open(z).read()) // 1000) for z in zones)
                w(f'THERMAL {temps} C')
            except OSError:
                pass
            last_thermal = now
        time.sleep(0.1)
except KeyboardInterrupt:
    pass
finally:
    w('=== harness stop')
