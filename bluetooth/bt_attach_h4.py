#!/usr/bin/env python3
import fcntl, os, struct, termios, time
TTY = '/dev/ttyS7'
fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY)
buf = bytearray(struct.pack('<i', 15))
fcntl.ioctl(fd, 0x5423, buf, 1)   # TIOCSETD(N_HCI)
print('ldisc set', flush=True)
attr = termios.tcgetattr(fd)
try:
    attr[4] = attr[5] = termios.B1500000
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    print('baud 1500000', flush=True)
except Exception as e:
    print('baud set fail:', e, flush=True)
fcntl.ioctl(fd, 0x400455C8, 0)    # HCIUARTSETPROTO(H4=0)
print('proto H4 attached — holding', flush=True)
while True:
    time.sleep(3600)
