#!/usr/bin/env python3
"""gps_poll.py — 通过 usbfs GetPortStatus 轮询相机所在 roothub 端口状态（root）。
这是内核视角的权威端口状态（usbcore 自己就是这么读的）。
输出 /tmp/gps.log:  epoch  CCS  PLS  PP  RAW
"""
import ctypes, fcntl, glob, os, struct, sys, time

VID, PID = 'f622', 'd132'

def find_camera():
    for f in glob.glob('/sys/bus/usb/devices/*/idVendor'):
        try:
            if open(f).read().strip() != VID: continue
        except OSError: continue
        d = os.path.dirname(f)
        try:
            if open(os.path.join(d, 'idProduct')).read().strip() != PID: continue
        except OSError: continue
        bus = open(os.path.join(d, 'busnum')).read().strip()
        # roothub 设备节点: /dev/bus/usb/<bus>/001
        return int(bus), d
    return None, None

USBDEVFS_CONTROL = 0xC0185500   # _IOWR('U', 2, struct usbdevfs_ctrltransfer)

class ctrltransfer(ctypes.Structure):
    _fields_ = [('bmRequestType', ctypes.c_uint8),
                ('bRequest', ctypes.c_uint8),
                ('wValue', ctypes.c_uint16),
                ('wIndex', ctypes.c_uint16),
                ('wLength', ctypes.c_uint16),
                ('timeout', ctypes.c_uint32),
                ('data', ctypes.POINTER(ctypes.c_char))]

def get_port_status(fd, port):
    buf = ctypes.create_string_buffer(4)
    ct = ctrltransfer()
    ct.bmRequestType = 0xA3      # device-to-host, class, other
    ct.bRequest = 0x00           # GET_STATUS
    ct.wValue = 0
    ct.wIndex = port
    ct.wLength = 4
    ct.timeout = 1000
    ct.data = ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))
    r = fcntl.ioctl(fd, USBDEVFS_CONTROL, ct, 1)
    return struct.unpack('<I', buf.raw[:r if r > 0 else 0])[0] if r == 4 else None

def main():
    log = open('/tmp/gps.log', 'a', buffering=1)
    while True:
        bus, devdir = find_camera()
        if not bus:
            log.write(f'{time.time():.3f} NO_CAMERA\n')
            time.sleep(2)
            continue
        path = f'/dev/bus/usb/{bus:03d}/001'
        if not os.path.exists(path):
            log.write(f'{time.time():.3f} NO_ROOTHUB_NODE {path}\n')
            time.sleep(2)
            continue
        try:
            fd = os.open(path, os.O_RDWR)
        except OSError as e:
            log.write(f'{time.time():.3f} OPEN_FAIL {e}\n')
            time.sleep(2)
            continue
        port = 1
        try:
            while True:
                try:
                    v = get_port_status(fd, port)
                except OSError as e:
                    log.write(f'{time.time():.3f} IOCTL_ERR {e}\n')
                    break
                if v is None:
                    log.write(f'{time.time():.3f} READ_ERR\n')
                    break
                pls = (v >> 5) & 0xF
                names = {0:'U0',4:'SS.Disabled',5:'Rx.Detect',6:'SS.Inactive',
                         7:'Polling',8:'Recovery',10:'Compliance'}
                log.write(f'{time.time():.3f} CCS={v&1} PLS={pls}({names.get(pls,"?")}) '
                          f'PP={(v>>9)&1} RAW={v:08x}\n')
                time.sleep(1)
        finally:
            os.close(fd)

if __name__ == '__main__':
    main()
