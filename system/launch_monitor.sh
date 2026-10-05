#!/bin/bash
# launch_monitor.sh — 在桌面会话中启动 SUA133GC 监视窗口（X11 后端，便于窗口管理）
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000
export DISPLAY=:0
export GDK_BACKEND=x11
source /opt/ros/humble/setup.bash
exec python3 /home/USER/ros2_ws/src/sua_aravis_camera/scripts/camera_monitor.py
