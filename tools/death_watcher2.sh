#!/bin/bash
# death_watcher2.sh — 长时采样，时间戳样本名（root）
OUT=/home/xiaoxingchn/harness
cd /home/xiaoxingchn/aravis
ensure_healthy() {
    timeout 8 ./build/src/arv-tool-0.8 control Width >/dev/null 2>&1 && return 0
    LED=/sys/class/leds/vbus-otg/brightness
    [ -f /sys/class/leds/vbus-host/brightness ] && LED=/sys/class/leds/vbus-host/brightness
    echo 0 > $LED 2>/dev/null; sleep 3; echo 255 > $LED 2>/dev/null
    for i in $(seq 1 25); do lsusb | grep -q f622 && break; sleep 1; done
    lsusb | grep -q f622
}
for round in 1 2 3 4 5 6; do
    TS=$(date +%H%M%S)
    ensure_healthy || { echo "$(date +%T) r$round camera gone" >> $OUT/watch2.log; sleep 30; continue; }
    pkill -f "usbmon/6u" 2>/dev/null; sleep 1; rm -f /tmp/usbmon.cap
    timeout 1500 cat /sys/kernel/debug/usb/usbmon/6u > /tmp/usbmon.cap 2>/dev/null &
    setsid nohup bash -c "exec ./arv_grab 1200" > /tmp/death_grab.log 2>&1 < /dev/null &
    echo "$(date +%T) r$round feeder started" >> $OUT/watch2.log
    while :; do
        sleep 15
        pgrep -x arv_grab >/dev/null || { echo "$(date +%T) r$round feeder exited" >> $OUT/watch2.log; break; }
        S1=$(stat -c%s /tmp/usbmon.cap 2>/dev/null || echo 0); sleep 12
        S2=$(stat -c%s /tmp/usbmon.cap 2>/dev/null || echo 0)
        if [ "$S1" = "$S2" ]; then sleep 12; S3=$(stat -c%s /tmp/usbmon.cap 2>/dev/null || echo 0)
            [ "$S2" = "$S3" ] && { echo "$(date +%T) r$round DEATH usbmon stalled" >> $OUT/watch2.log; break; }
        fi
    done
    sleep 8
    dmesg > $OUT/dmesg-r$round-$TS.log
    cp /tmp/portsc2.log $OUT/portsc-r$round-$TS.log 2>/dev/null
    cp /tmp/gps.log $OUT/gps-r$round-$TS.log 2>/dev/null
    cp /tmp/usbmon.cap $OUT/usbmon-r$round-$TS.cap 2>/dev/null
    cp /tmp/death_grab.log $OUT/grab-r$round-$TS.log 2>/dev/null
    : > /tmp/portsc2.log; : > /tmp/gps.log
    echo "$(date +%T) r$round sample saved ($TS)" >> $OUT/watch2.log
    pkill -9 -x arv_grab 2>/dev/null
done
echo "$(date +%T) watcher2 done" >> $OUT/watch2.log
