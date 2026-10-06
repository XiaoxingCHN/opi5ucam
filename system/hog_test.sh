#!/bin/bash
# hog_test.sh — QOS 提升后的带宽饥饿死亡率测试（root）
OUT=/home/xiaoxingchn/harness
cd /home/xiaoxingchn/aravis
# 1) 相机健康（必要时 VBUS 恢复）
timeout 8 ./build/src/arv-tool-0.8 control Width >/dev/null 2>&1 || {
  for LED in /sys/class/leds/vbus-host/brightness /sys/class/leds/vbus-otg/brightness; do
    [ -f $LED ] || continue
    echo 0 > $LED; sleep 3; echo 255 > $LED
    for i in $(seq 1 25); do lsusb | grep -q f622 && break; sleep 1; done
    timeout 8 ./build/src/arv-tool-0.8 control Width >/dev/null 2>&1 && break
  done
}
lsusb | grep -q f622 || { echo "$(date +%T) camera gone" > $OUT/hog_test.result; exit 1; }
# 2) QOS 状态记录（确认提升仍在）
python3 $OUT/qos_read.py usb3_0 0xfdf3e200 > $OUT/hog_test.qos 2>&1
python3 $OUT/qos_read.py usb3_1 0xfdf3e000 >> $OUT/hog_test.qos 2>&1
# 3) usbmon + feeder
rm -f /tmp/usbmon.cap /tmp/death_grab.log
timeout 1200 cat /sys/kernel/debug/usb/usbmon/6u > /tmp/usbmon.cap 2>/dev/null &
setsid nohup bash -c "exec ./arv_grab 1800" > /tmp/death_grab.log 2>&1 < /dev/null &
sleep 4
FEEDER=$(pgrep -x arv_grab | head -1)
echo "$(date +%T) feeder=$FEEDER hog test start (QOS raised)" > $OUT/hog_test.result
# 4) 启动带宽饥饿器
/tmp/hog &
HOG=$!
echo "$(date +%T) hog=$HOG started" >> $OUT/hog_test.result
# 5) 死亡观测循环（最长 20 分钟）
for i in $(seq 1 80); do
  sleep 15
  pgrep -x arv_grab >/dev/null || { echo "$(date +%T) DEATH at t≈$((i*15))s under hog" >> $OUT/hog_test.result; kill $HOG 2>/dev/null; exit 0; }
done
echo "$(date +%T) SURVIVED 1200s under hog (QOS raised)" >> $OUT/hog_test.result
kill $HOG 2>/dev/null
