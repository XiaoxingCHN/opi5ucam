# 部署教程：从零到全栈

> 目标：在一台全新的 Orange Pi 5 Ultra（eMMC/SD 卡 Ubuntu 22.04）上部署本项目的
> 完整相机栈。全程可在 SSH 下完成（除烧写镜像外）；预计耗时 1~2 小时（内核编译占大头，
> 可跳过 D 步骤直接使用已注入内核的镜像）。

---

## 0. 硬件与前提

| 项 | 说明 |
|---|---|
| 板 | Orange Pi 5 Ultra（RK3588），≥16GB SD/eMMC |
| 相机 | MindVision SUA133GC（USB3 Vision，VID:PID `f622:d132`），接 **USB3.0 Type-A 口** |
| OS | Ubuntu 22.04 arm64（Joshua-Riek preinstalled desktop v2.4.0 基线） |
| 交叉构建机（可选） | x86 Linux/WSL2，装 `gcc-aarch64-linux-gnu dwarves flex bison libssl-dev` |
| 串口/SSH | `ssh <user>@<board-ip>`（桌面 GNOME 会话用于 rviz/监视窗） |

---

## A. 内核（含 4 个 USB/PHY 补丁）

> 已有现成镜像的可跳过。补丁以 git commit 形式维护，见 [kernel/README.md](../kernel/README.md)。

1. 克隆基线并建工作分支：
   ```bash
   git clone -b jammy https://github.com/Joshua-Riek/linux-rockchip
   cd linux-rockchip && git checkout -b rk3588-usb-isoc-fixes a2d0e7d7e
   ```
2. cherry-pick 4 个补丁 commit（内容见 [kernel/README.md](../kernel/README.md)）：
   `3ef817a02`（usbdp PHY 主线化对齐）· `7e58f1756`（DWC3 REFCLKPER/GFLADJ 回填）·
   `16b6819fd`（DTS ref-clock）· `df1637036`（rk3588-orangepi-5-ultra.dts：禁 HDMI0
   修幻影屏、OTG 使能脚 PB1、LED 极性、风扇 PWM）。
3. 构建（**三铁律**：出厂 config + olddefconfig；装 pahole；不用 initramfs）：
   ```bash
   cp /boot/config-5.10.0-1012-rockchip build/.config 2>/dev/null || true
   make O=build olddefconfig ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
   make O=build -j32 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image dtbs modules
   ```
4. 注入镜像/系统：
   - `Image` → `/boot/vmlinuz-5.10.209`；模块 `make modules_install`（strip 调试段）；
   - DTB → `/lib/firmware/5.10.209/device-tree/rockchip/`；
   - extlinux 默认项指向新内核（`root=PARTUUID=…` 直挂根，无 initrd）；
   - **保留原厂内核启动项**作救援（`label old`）。

---

## B. DTB 手术：VBUS 软件可控化（本方案的关键一步）

目的：把相机 USB 口的 VBUS 从"固话的 always-on regulator"变成软件开关，
为链路死亡的自动恢复（电子拔插）铺路。原理与细节见
[architecture.md](architecture.md) §1、[troubleshooting A2](troubleshooting.md)。

```bash
# 1) 反编译当前 DTB（板上有 dtc）
dtc -I dtb -O dts /lib/firmware/5.10.209/device-tree/rockchip/rk3588-orangepi-5-ultra.dtb \
    -o /tmp/opi5u.dts
# 2) 手术（自动脚本：摘 regulator 的 gpio，加 gpio-leds vbus-recover 节点）
python3 dtb/dtb_edit.py          # 产出 /tmp/dts-base.dts 与 /tmp/dts-hs.dts
# 3) 编译
dtc -I dts -O dtb -o /tmp/ultra-vbus.dtb /tmp/dts-base.dts
dtc -I dts -O dtb -o /tmp/ultra-hs.dtb  /tmp/dts-hs.dts
# 4) 备份 + 安装
sudo cp /lib/firmware/5.10.209/device-tree/rockchip/rk3588-orangepi-5-ultra.dtb \
        ~/dtb-backup/rk3588-orangepi-5-ultra.dtb.orig
sudo cp /tmp/ultra-vbus.dtb /lib/firmware/5.10.209/device-tree/rockchip/rk3588-orangepi-5-ultra.dtb
sudo cp /tmp/ultra-hs.dtb   /lib/firmware/5.10.209/device-tree/rockchip/rk3588-orangepi-5-ultra-hs.dtb
# 5) extlinux 增加 l0hs 启动项（可选，见 dtb/README.md），默认项保持 SS
sudo reboot
```

重启后验证：
```bash
ls /sys/class/leds/ | grep vbus          # → vbus-host、vbus-otg
echo 0 | sudo tee /sys/class/leds/vbus-host/brightness; sleep 3
echo 255 | sudo tee /sys/class/leds/vbus-host/brightness
sudo dmesg | tail                        # 应看到 disconnect → 重枚举
```

> 若启动失败：u-boot 选单选 `old`（原厂内核 + 原厂 DTB）救援，回滚
> `~/dtb-backup/*.orig`。

---

## C. 系统配置

```bash
# 0) 路径适配：脚本中的 /home/USER 占位符替换为实际用户目录
cd <本仓库路径>
grep -rl '/home/USER' system/ | xargs sed -i "s|/home/USER|$HOME|g"

# 1) udev：普通用户可访问相机（ROS 节点必须）
sudo cp system/99-mindvision.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger

# 2) 恢复脚本 + 免密（节点 L2 恢复用；$USER 为当前用户名）
sudo install -m 755 system/usb_recover.sh /usr/local/sbin/
echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/usb_recover.sh" \
  | sudo tee /etc/sudoers.d/usb-recover && sudo chmod 440 /etc/sudoers.d/usb-recover
sudo visudo -c          # 必须 parsed OK

# 3) 看门狗 + soak 服务（按需）
sudo install -m 755 system/camera_watchdog.sh system/camera_soak.sh /usr/local/sbin/
sudo install -m 644 system/camera-watchdog.service system/camera-soak.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now camera-watchdog
# soak 会长期占用相机，只在积累稳定性数据时开启：
sudo systemctl enable --now camera-soak && sudo systemctl stop camera-soak

# 4) Aravis 0.8.31（源码）
sudo apt install -y meson ninja-build libglib2.0-dev libxml2-dev libusb-1.0-0-dev
git clone -b v0.8.31 https://github.com/AravisProject/aravis ~/aravis-src
cd ~/aravis-src && meson setup build --prefix=/usr/local && ninja -C build && sudo ninja -C build install
export PKG_CONFIG_PATH=/usr/local/lib/aarch64-linux-gnu/pkgconfig
arv-tool-0.8 --version

# 5) 采集/实验工具
gcc -O2 -o ~/aravis/arv_grab  tools/arv_grab.c  $(pkg-config --cflags --libs aravis-0.8)
gcc -O2 -o ~/wb_probe tools/wb_probe.c $(pkg-config --cflags --libs aravis-0.8)
gcc -O2 -o ~/cfa_test tools/cfa_test.c $(pkg-config --cflags --libs aravis-0.8)
```

> `usb_recover.sh` / 看门狗脚本里如需改动，重装后 `systemctl restart` 对应服务。

---

## D. ROS 2 Humble 与相机节点

```bash
# 1) ROS2（arm64 Jammy）
sudo add-apt-repository universe
sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
     -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" \
  | sudo tee /etc/apt/sources.list.d/ros2.list
sudo apt update && sudo apt install -y ros-humble-ros-base ros-humble-rviz2 \
  ros-humble-image-transport ros-humble-camera-info-manager python3-colcon-common-extensions

# 2) 工作区构建
mkdir -p ~/ros2_ws/src && cp -r ros2/sua_aravis_camera ~/ros2_ws/src/
source /opt/ros/humble/setup.bash
cd ~/ros2_ws && colcon build --packages-select sua_aravis_camera

# 3) 启动
source ~/ros2_ws/install/setup.bash
ros2 launch sua_aravis_camera camera.launch.py rviz:=true monitor:=true
```

> 国内网络可将 ROS 源替换为清华/中科大镜像（本机实际使用 `mirrors.ustc.edu.cn`）。

---

## E. 验证清单（每步期望输出）

| # | 命令 | 期望 |
|---|---|---|
| 1 | `lsusb \| grep f622` | `ID f622:d132 MindVision SUA133GC` |
| 2 | `cat /sys/bus/usb/devices/*/speed` | 某口 `5000`（SS）或 `480`（HS 回落） |
| 3 | `sudo arv-tool-0.8 control Width` | `Width = 1280 …`（控制通道健康） |
| 4 | `ls /sys/class/leds \| grep vbus` | `vbus-host`、`vbus-otg` |
| 5 | 节点日志 | `white balance: mode=once, gains R=… G=… B=…` + `camera open: 1280x1024 … streaming` |
| 6 | `ros2 topic echo /mv_camera/image_raw --field encoding --once` | `bgr8` |
| 7 | `timeout 12 stdbuf -oL ros2 topic hz /mv_camera/image_raw --window 30` | ~30-44 fps |
| 8 | `ros2 topic echo /mv_camera/camera_info --once` | 1280×1024 CameraInfo |
| 9 | 监视窗口 | 绿灯"正在推流" + fps 曲线 |
| 10 | （可选）`sudo bash system/post_reboot_verify.sh` | 强制 VBUS 断电→自动复活全流程 |

---

## F. 故障对照

部署中遇到的任何异常，先查 **[troubleshooting.md](troubleshooting.md)**
（22 个已知问题均有根因与修法），再查 [architecture.md](architecture.md) 的五步法。

## G. 卸载

```bash
sudo systemctl disable --now camera-soak camera-watchdog
sudo rm /etc/systemd/system/camera-{soak,watchdog}.service /usr/local/sbin/camera_{soak,watchdog}.sh
sudo rm /usr/local/sbin/usb_recover.sh /etc/sudoers.d/usb-recover /etc/udev/rules.d/99-mindvision.rules
sudo udevadm control --reload-rules
# 回滚 DTB：用 ~/dtb-backup/*.orig 覆盖并重启
```
