#!/bin/bash
# camera_watchdog.sh v1.1 — MindVision SUA133GC (VID f622) USB link watchdog.
# Orange Pi 5 Ultra (RK3588, kernel 5.10.209), runs as root via systemd.
#
# v1.1 changes:
#  - usbfs-holder awareness: while a streaming process (e.g. arv_grab) holds the
#    device node, probes are suspended (arv-tool bootstrap would fail with the
#    interface claimed by the holder -> false positive -> recovery would kill a
#    healthy stream). Stream liveness is the stream monitor's job.
#  - L4 hardened: after VBUS restore, poll up to 25s for re-enumeration (camera
#    needs ~9-13s from power-on to enumerate); force dwc3 rebind if still absent.
#
# Death mode: SS link silently dies (no xHCI/PHY errors in dmesg), control
# endpoint then returns EIO while device stays enumerated. VBUS power cycle
# (L4, DTB "gpio-leds vbus-recover") is the reliable revive; L1-L3 best effort.
# Cutting vbus-host also blips the other USB2 host ports (shared rail) — harmless.

ARV_TOOL=/home/USER/aravis/build/src/arv-tool-0.8
INTERVAL=15
LOG=/var/log/camera-watchdog.log
VID=f622
RECOVER_COOLDOWN=45
HEARTBEAT=900

log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG"; }

trim_log() {
    local size
    size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt 5242880 ]; then
        tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

find_devdir() {
    local f
    for f in /sys/bus/usb/devices/*/idVendor; do
        [ -r "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" = "$VID" ]; then
            dirname "$f"
            return 0
        fi
    done
    return 1
}

on_bus() { lsusb 2>/dev/null | grep -q "$VID"; }

# Sets HOLDERS to "pid(comm) ..." for processes holding the camera usbfs node.
find_holders() {
    local d bus dev
    d=$(find_devdir) || return 1
    bus=$(cat "$d/busnum" 2>/dev/null); dev=$(cat "$d/devnum" 2>/dev/null)
    [ -n "$bus" ] && [ -n "$dev" ] || return 1
    HOLDERS=$(python3 - "$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$dev")" <<'PY'
import os, glob, sys
t = sys.argv[1]
me = str(os.getpid())
dad = str(os.getppid())
out = []
for fd in glob.glob('/proc/[0-9]*/fd/*'):
    try:
        if os.readlink(fd) == t:
            pid = fd.split('/')[2]
            if pid not in (me, dad):
                try:
                    comm = open('/proc/%s/comm' % pid).read().strip()
                except OSError:
                    comm = '?'
                out.append('%s(%s)' % (pid, comm))
    except OSError:
        pass
print(' '.join(out))
PY
)
    [ -n "$HOLDERS" ]
}

HEALTH_NOTE=""
# 0 = healthy; 1 = on bus but control channel dead; 2 = not on bus
health() {
    local d
    d=$(find_devdir) || return 2
    # ROS camera node running? it owns link health + recovery; stay off its usbfs
    if pgrep -f 'aravis_camera_[n]ode' >/dev/null 2>&1; then
        HEALTH_NOTE="in-use by ros-node (probes suspended)"
        return 0
    fi
    if find_holders; then
        HEALTH_NOTE="in-use by $HOLDERS"
        return 0
    fi
    HEALTH_NOTE=""
    timeout 8 "$ARV_TOOL" control Width >/dev/null 2>&1 || return 1
    return 0
}

ctrl_for_dev() {
    readlink -f "$1" | sed -n 's#.*/platform/\(fc[0-9a-f]*\.usb\)/.*#\1#p'
}

# fc400000.usb (usbdrd3_1, u2phy1) -> vbus-host ; fc000000.usb (usbdrd3_0, u2phy0) -> vbus-otg
vbus_led_for_ctrl() {
    case "$1" in
        fc400000.usb) echo "vbus-host" ;;
        fc000000.usb) echo "vbus-otg"  ;;
        *)            echo ""          ;;
    esac
}

dwc3_rebind() {
    echo "$1" > /sys/bus/platform/drivers/dwc3/unbind 2>/dev/null || return 1
    sleep 3
    echo "$1" > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null || return 1
    sleep 4
}

usbfs_reset() {
    local b n dev
    b=$(cat "$1/busnum" 2>/dev/null) || return 1
    n=$(cat "$1/devnum" 2>/dev/null) || return 1
    dev=$(printf '/dev/bus/usb/%03d/%03d' "$b" "$n")
    [ -e "$dev" ] || return 1
    python3 - "$dev" <<'PY'
import fcntl, sys
try:
    fd = open(sys.argv[1], 'wb', buffering=0)
    fcntl.ioctl(fd, 21792, 0)  # USBDEVFS_RESET = _IO('U', 20)
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
}

wait_enum() {  # $1 = seconds to poll for the device to appear on the bus
    local i
    for i in $(seq 1 "$1"); do
        on_bus && return 0
        sleep 1
    done
    on_bus
}

recover() {
    local d ctl led
    d=$(find_devdir) || d=""
    log WARN "recovery ladder start (device $([ -n "$d" ] && echo present || echo GONE-from-bus)); any active stream will be interrupted"

    # L1: authorized toggle
    if [ -n "$d" ]; then
        echo 0 > "$d/authorized" 2>/dev/null; sleep 2
        echo 1 > "$d/authorized" 2>/dev/null; sleep 4
        health; [ $? -eq 0 ] && { log INFO "L1 authorized-toggle revived"; return 0; }
        log INFO "L1 failed"
    else
        log INFO "L1 skipped (device not on bus)"
    fi

    # L2: usbfs port reset
    d=$(find_devdir)
    if [ -n "$d" ]; then
        if usbfs_reset "$d"; then
            sleep 5
            health; [ $? -eq 0 ] && { log INFO "L2 usbfs-reset revived"; return 0; }
        fi
    fi
    log INFO "L2 failed"

    # L3: dwc3 controller unbind/rebind (full controller + link re-init)
    d=$(find_devdir)
    [ -n "$d" ] && ctl=$(ctrl_for_dev "$d")
    ctl=${ctl:-fc400000.usb}
    if [ -d /sys/bus/platform/drivers/dwc3 ]; then
        dwc3_rebind "$ctl"
        wait_enum 10
        health; [ $? -eq 0 ] && { log INFO "L3 dwc3-rebind ($ctl) revived"; return 0; }
        log INFO "L3 failed"
    fi

    # L4: VBUS power cycle (electrical replug — needs DTB vbus-recover)
    led=$(vbus_led_for_ctrl "$ctl")
    if [ -n "$led" ] && [ -e "/sys/class/leds/$led/brightness" ]; then
        log INFO "L4 VBUS power-cycle via /sys/class/leds/$led"
        echo 0   > "/sys/class/leds/$led/brightness" 2>/dev/null
        sleep 3
        echo 255 > "/sys/class/leds/$led/brightness" 2>/dev/null
        wait_enum 25   # camera needs ~9-13s from power-on to enumerate
        if ! on_bus; then
            log INFO "L4: no re-enum after VBUS restore — forcing dwc3 rebind"
            dwc3_rebind "$ctl"
            wait_enum 10
        fi
        sleep 3
        health; [ $? -eq 0 ] && { log INFO "L4 VBUS-cycle revived"; return 0; }
        log INFO "L4 failed"
    else
        log WARN "L4 unavailable (/sys/class/leds/$led missing — DTB vbus-recover not installed?)"
    fi

    log ERROR "all recovery levels failed — PHYSICAL REPLUG REQUIRED"
    return 1
}

fails=0
last_recover=0
hb=0
busy_prev=""
log INFO "watchdog v1.1 start (pid $$, interval ${INTERVAL}s)"
while :; do
    health
    h=$?
    # holder-transition logging
    case "$HEALTH_NOTE" in
        in-use*)
            [ -z "$busy_prev" ] && log INFO "camera in use ($HEALTH_NOTE) — probes suspended"
            busy_prev="$HEALTH_NOTE"
            ;;
        *)
            [ -n "$busy_prev" ] && log INFO "camera released ($busy_prev) — probes resumed"
            busy_prev=""
            ;;
    esac
    case $h in
        0)
            [ "$fails" -gt 0 ] && log INFO "camera healthy again (after $fails bad probes)"
            fails=0
            now=$(date +%s)
            if [ $((now - hb)) -ge $HEARTBEAT ]; then
                log INFO "heartbeat: camera OK"
                hb=$now
            fi
            ;;
        *)
            fails=$((fails + 1))
            now=$(date +%s)
            if [ $((now - last_recover)) -ge $RECOVER_COOLDOWN ]; then
                case $h in
                    1) log WARN "camera wedged: enumerated but control channel dead (probe x$fails)" ;;
                    2) log WARN "camera NOT on bus (probe x$fails)" ;;
                esac
                if recover; then
                    last_recover=0
                else
                    last_recover=$now
                fi
                fails=0
            fi
            ;;
    esac
    trim_log
    sleep "$INTERVAL"
done
