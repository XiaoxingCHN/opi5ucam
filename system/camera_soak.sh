#!/bin/bash
# camera_soak.sh v1.1 — continuous streaming soak test for the SUA133GC.
# Runs as root via systemd. Works with camera-watchdog.service:
#  - streams in segments and detects frame stalls (silent link death = arv_grab
#    alive but frames= stopped advancing) and early exits (NO_CAMERA/NO_STREAM)
#  - on death: kills the segment, then performs HARD RECOVERY itself (VBUS power
#    cycle + dwc3 rebind). This is needed because the post-L3 "zombie mode"
#    (control channel alive, stream all-MISSING/no-stream) never trips the
#    watchdog, whose probe stays green.
# Aggregate log: /var/log/camera-soak.log   Segment log: /var/log/soak-seg.log
#
# v1.1: launch via exec (segment pid IS arv_grab — v1.0 killed the wrapper
# subshell and orphaned arv_grab, wedging the usbfs node); hard recovery on
# death; defensive pkill of leftover arv_grab before each segment.

ARV_GRAB_DIR=/home/USER/aravis
ARV_GRAB=$ARV_GRAB_DIR/arv_grab
ARV_TOOL=$ARV_GRAB_DIR/build/src/arv-tool-0.8
SEG_DUR=600          # seconds of streaming per segment
POLL=30              # segment monitor poll interval
SLOG=/var/log/camera-soak.log
SEGLOG=/var/log/soak-seg.log
VID=f622

slog() { echo "$(date '+%F %T') $*" >> "$SLOG"; }
on_bus() { lsusb 2>/dev/null | grep -q "$VID"; }

healthy() { timeout 8 "$ARV_TOOL" control Width >/dev/null 2>&1; }

wait_healthy() {  # polls every 10s for up to $1 seconds
    local i
    for i in $(seq 1 $(( $1 / 10 ))); do
        healthy && return 0
        sleep 10
    done
    healthy
}

wait_enum() {
    local i
    for i in $(seq 1 "$1"); do
        on_bus && return 0
        sleep 1
    done
    on_bus
}

# Hard recovery: VBUS power cycle (= electrical replug), then dwc3 rebind if
# the camera doesn't re-appear. Only a VBUS cycle reliably exits zombie mode.
hard_recover() {
    pkill -KILL -x arv_grab 2>/dev/null
    sleep 2
    local ctl=fc400000.usb led=vbus-host d
    d=$(ls /sys/bus/usb/devices/*/idVendor 2>/dev/null | while read -r f; do
           [ "$(cat "$f" 2>/dev/null)" = "$VID" ] && dirname "$f" && break
       done)
    if [ -n "$d" ]; then
        ctl=$(readlink -f "$d" | sed -n 's#.*/platform/\(fc[0-9a-f]*\.usb\)/.*#\1#p')
        [ -n "$ctl" ] || ctl=fc400000.usb
        case "$ctl" in
            fc400000.usb) led=vbus-host ;;
            fc000000.usb) led=vbus-otg  ;;
        esac
    fi
    if [ -e "/sys/class/leds/$led/brightness" ]; then
        slog "hard-recover: VBUS cycle on $led"
        echo 0   > "/sys/class/leds/$led/brightness" 2>/dev/null
        sleep 3
        echo 255 > "/sys/class/leds/$led/brightness" 2>/dev/null
        wait_enum 25
    fi
    if ! on_bus && [ -d /sys/bus/platform/drivers/dwc3 ]; then
        slog "hard-recover: dwc3 rebind $ctl"
        echo "$ctl" > /sys/bus/platform/drivers/dwc3/unbind 2>/dev/null
        sleep 3
        echo "$ctl" > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null
        wait_enum 10
    fi
    sleep 5
    wait_healthy 90 && slog "hard-recover: camera healthy again" || slog "WARN hard-recover: camera still unhealthy"
}

last_frames() {  # frames counter from newest minute-line, or -1
    grep -o 'frames=[0-9]*' "$SEGLOG" 2>/dev/null | tail -1 | cut -d= -f2 | grep -x '[0-9]*' || echo -1
}

seg=0
deaths=0
slog "soak v1.1 start (pid $$, segment=${SEG_DUR}s)"
while :; do
    if ! wait_healthy 300; then
        slog "WARN camera not healthy for 300s — watchdog should be recovering; waiting more"
        continue
    fi
    sleep 5   # settle after recovery / re-enumeration

    pkill -KILL -x arv_grab 2>/dev/null   # defensive: no leftovers may hold usbfs

    seg=$((seg + 1))
    : > "$SEGLOG"
    seg_start=$(date +%s)
    (cd "$ARV_GRAB_DIR" && exec "$ARV_GRAB" "$SEG_DUR" >> "$SEGLOG" 2>&1) &
    spid=$!
    slog "seg#$seg start (pid $spid)"

    last=-2
    stall=0
    death=0
    while kill -0 "$spid" 2>/dev/null; do
        sleep "$POLL"
        kill -0 "$spid" 2>/dev/null || break
        elapsed=$(( $(date +%s) - seg_start ))
        f=$(last_frames)
        if [ "$f" = "-1" ] && [ "$elapsed" -gt 120 ]; then
            stall=$((stall + 1))    # no minute line ever — stream never really started
        elif [ "$f" = "$last" ]; then
            stall=$((stall + 1))
        else
            stall=0
        fi
        last=$f
        if [ "$stall" -ge 2 ]; then
            death=1
            slog "DEATH: seg#$seg frames stalled (elapsed ${elapsed}s, frames=$f) — killing + hard recovery"
            break
        fi
    done
    kill -TERM "$spid" 2>/dev/null
    sleep 3
    kill -KILL "$spid" 2>/dev/null
    wait "$spid" 2>/dev/null
    rc=$?
    seg_elapsed=$(( $(date +%s) - seg_start ))
    result=$(grep '^RESULT' "$SEGLOG" | tail -1)

    if [ "$death" -eq 1 ] || [ "$seg_elapsed" -lt $((SEG_DUR - 60)) ] || [ "$rc" -ne 0 ]; then
        deaths=$((deaths + 1))
        slog "seg#$seg BAD after ${seg_elapsed}s rc=$rc — $result"
        hard_recover
    else
        fps=$( [ -n "$result" ] && echo "$result" | grep -o 'frames=[0-9]*' | cut -d= -f2 | awk -v d="$SEG_DUR" '{printf "%.1f", $1/d}' || echo "?" )
        slog "seg#$seg OK ${seg_elapsed}s fps=$fps deaths_so_far=$deaths — $result"
    fi
done
