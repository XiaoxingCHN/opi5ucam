#!/bin/bash
# post_reboot_verify.sh — run after reboot into the vbus-recover DTB.
# Verifies: vbus leds present, camera healthy, VBUS power-cycle revive works,
# watchdog active. Safe to re-run.
set -u
echo "== 1. vbus leds"
ls -l /sys/class/leds/ | grep -i vbus || { echo "FAIL: vbus leds missing (old DTB booted?)"; }

echo "== 2. wait for camera enumeration"
for i in $(seq 1 30); do
    lsusb | grep -q f622 && break
    sleep 2
done
lsusb | grep f622 || echo "WARN: camera not on bus (plug in if unplugged)"

echo "== 3. Aravis control channel (must run as root)"
cd /home/USER/aravis
timeout 10 ./build/src/arv-tool-0.8 control Width Height 2>&1 | head -4

echo "== 4. FORCED VBUS power-cycle test (electrical replug)"
B=$(ls /sys/class/leds | grep -m1 vbus-host)
[ -z "$B" ] && B=$(ls /sys/class/leds | grep -m1 vbus)
echo "toggling /sys/class/leds/$B"
dmesg | grep -c 'usb 8-1' > /tmp/vbus-test-before.txt
echo 0   > "/sys/class/leds/$B/brightness"
sleep 3
echo 255 > "/sys/class/leds/$B/brightness"
sleep 7
dmesg | grep 'usb 8-1' | tail -8
timeout 10 ./build/src/arv-tool-0.8 control Width 2>&1 | head -2

echo "== 5. watchdog"
systemctl is-active camera-watchdog.service
tail -5 /var/log/camera-watchdog.log
echo "== done"
