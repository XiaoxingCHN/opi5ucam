# SUA133GC 相机 ROS2 使用文档（Humble / aarch64）

> 适用环境：Orange Pi 5 Ultra（RK3588）+ Ubuntu 22.04 + ROS2 Humble
> 包名：`sua_aravis_camera`　工作区：`~/ros2_ws`
> 本文档随包维护：`~/ros2_ws/src/sua_aravis_camera/doc/ROS2_使用文档.md`
> 底层相机链路稳定性方案见 `~/camera-stabilize/README.md`

---

## 1. 总览

```
MindVision SUA133GC (USB3 Vision, f622:d132)
        │  Aravis 0.8.31 (usbfs)
        ▼
aravis_camera_node ──恢复状态机: STREAMING→REOPEN→USB_RECOVER→WAIT_DEVICE→COOLDOWN
        │
        ├─ /mv_camera/image_raw      sensor_msgs/Image  (rgb8, 默认)
        ├─ /mv_camera/camera_info    sensor_msgs/CameraInfo
        └─ /mv_camera/image_raw/compressed*  (image_transport 自动附加)
        ▼
   rviz2 (Image 显示) / 你的下游节点
```

- 节点内置与全链路同款的**自恢复状态机**：5 秒无帧 → REOPEN（重建 Aravis 相机/流）→
  连续失败 2 次 → 调 `/usr/local/sbin/usb_recover.sh`（VBUS 电子拔插）→ 等设备回总线 → 再开流。
  恢复动作带指数退避（1s→30s 封顶）。
- `usb_recover.sh` 有**持有者保护**：若相机被别的进程占用则拒绝断电（退出码 3），不会误伤其他程序。

---

## 2. 快速开始

```bash
# 终端 1：启动相机节点（默认参数）
source /opt/ros/humble/setup.bash
source ~/ros2_ws/install/setup.bash
ros2 launch sua_aravis_camera camera.launch.py

# 终端 2：rviz 查看画面（自动加载示例配置）
source /opt/ros/humble/setup.bash
rviz2 -d ~/ros2_ws/src/sua_aravis_camera/config/view_camera.rviz
```

一条命令连 rviz 一起起：

```bash
ros2 launch sua_aravis_camera camera.launch.py rviz:=true
```

### 状态/帧率监视窗口

```bash
ros2 launch sua_aravis_camera camera.launch.py monitor:=true
# 或独立运行：
~/camera-stabilize/launch_monitor.sh
```

GTK3 窗口（`scripts/camera_monitor.py`）：推流状态灯（推流/停滞/不在总线）、实时 fps
大数字 + 最近 2 分钟曲线、分辨率/编码/链路速率（SuperSpeed/HighSpeed）/Bus/Dev/
节点 PID/白平衡增益，以及节点与看门狗的最近恢复事件。
监视器**只读**（订阅话题 + sysfs/日志），不访问相机，可与任何应用常驻共存。

![监视窗口](doc/monitor_verified.png)

已验证的实机效果（本包 `doc/rviz_verified.png`）：
rviz Image 面板实时出图，rviz 渲染循环 31fps（USB2 高速链路模式）。

![rviz 实机验证](doc/rviz_verified.png)

---

## 3. 话题与参数

### 话题

| 话题 | 类型 | 说明 |
|---|---|---|
| `/mv_camera/image_raw` | sensor_msgs/Image | 图像流。默认编码 `rgb8`（节点内 NN 去马赛克）；参数改 `bayer_rggb8` 时为原生 raw |
| `/mv_camera/camera_info` | sensor_msgs/CameraInfo | 未标定时为默认值（width/height 正确，畸变为空） |
| `/mv_camera/image_raw/compressed` 等 | image_transport 附加 | compressed/jpeg/theora 按需 |

> 注意：`ros2 topic hz` 输出经管道时会被缓冲截断，重定向文件或用 python 探针验证：
> `timeout 12 stdbuf -oL ros2 topic hz /mv_camera/image_raw --window 30`。

### 参数（config/default.yaml）

| 参数 | 默认 | 说明 |
|---|---|---|
| `camera_name` | `mv_camera` | 话题命名空间：`/<camera_name>/image_raw` |
| `camera_optical_frame` | `camera_optical_frame` | 图像消息 frame_id |
| `camera_info_url` | `""` | 标定文件 file:// 路径（见 §7） |
| `exposure_time` | `10000.0`（µs） | **帧率由曝光间接决定**：10ms≈77fps（SS 链路）/≈30fps（HS 链路带宽上限），想要 30fps 设 `33000` |
| `use_sensor_data_qos` | `false` | `true`=BestEffort（SensorDataQoS），适合丢包容忍场景 |
| `output_encoding` | `rgb8` | `rgb8`（节点内去马赛克）或 `bayer_rggb8`（原生 raw，rviz 无法直接显示） |
| `stream_stall_seconds` | `5.0` | 连续 N 秒无帧进入恢复 |
| `usb_recover_script` | `/usr/local/sbin/usb_recover.sh` | 恢复脚本路径 |
| `wb_mode` | `once` | 白平衡策略（见 §3.1） |
| `wb_rgain/wb_ggain/wb_bgain` | `100` | `wb_mode=manual` 时的通道增益（0~400，100=中性） |
| `bayer_pattern` | `bggr` | 物理CFA排布。实测为 **BGGR**（增益锚点法，工具 `~/aravis/cfa_test.c`），尽管相机 PixelFormat 寄存器叫 BAYER_RG_8。`bggr` → 彩色模式发布 **bgr8**（OpenCV 原生格式）；`rggb` → rgb8；raw 模式标签为 `bayer_bggr8` |

### 3.1 白平衡与偏色（重要）

实测：该相机原始 Bayer 流**严重绿偏**（R/G≈0.60），且相机自带的 `ColorTemperatureAutoSel`
（自动色温）校正不完整、也不反映在增益寄存器里——这就是"偏色且随时间变化"的根源。
另外**链路每次断电恢复 = 相机 MCU 重新上电 = 白平衡状态丢失**。

节点策略（`wb_mode`，**每次开流包括恢复后都会自动重做**）：

- `once`（默认）：关闭自动色温 → 执行相机一键白平衡 `WBOnce` → 增益锁定。
  实测 R/G=0.98、B/G=1.09，60 秒零漂移（修复前 R/G=0.60）。
- `manual`：使用 `wb_rgain/wb_ggain/wb_bgain` 固定增益（适合固定光源产线）。
- `off`：完全不动相机（配合自己下游做颜色处理时用）。

参考实验工具：`~/aravis/wb_probe.c`（量化各设置下的 R/G/B 通道均值）。

### 3.2 Bayer 排布（CFA）与 R/B 对调问题

相机的 PixelFormat 寄存器名为 BAYER_RG_8，但**物理 CFA 实测是 BGGR**——直接按 RGGB
去马赛克会把红蓝对调（偏色的另一来源）。判定方法（增益锚点法，`~/aravis/cfa_test.c`）：
单独拉高 RGain 只有奇行奇列均值跳变、拉高 BGain 只有偶行偶列跳变，故 B 在 (0,0)、R 在 (1,1)。

节点按 `bayer_pattern` 参数处理：`bggr`（默认）时彩色输出使用标准 `bgr8` 编码
（字节序天然正确，cv_bridge/OpenCV 直接可用）；下游若写死假设 rgb8，请改用
`cv2.cvtColor(..., cv2.COLOR_BGR2RGB)` 或把参数设为验证过的其他值。
`output_encoding=bayer_rggb8`（raw 透传）时编码标签相应为 `bayer_bggr8`。

命令行覆盖示例：

```bash
ros2 run sua_aravis_camera aravis_camera_node --ros-args \
  -p camera_name:=cam0 -p exposure_time:=33000.0
```

---

## 4. rviz 使用详解

**方式 A（推荐）**：`rviz2 -d .../config/view_camera.rviz`——已预置 Image 显示项（话题
`/mv_camera/image_raw`，Reliable QoS）+ Grid。

**方式 B（手动添加）**：空白 rviz2 里 `Add → By topic → /mv_camera/image_raw → Image`。

**Global Status 显示 Warn？** 正常且无害：Image 显示不依赖 TF，但 rviz 需要 Fixed Frame。
`camera_optical_frame` 没有人发布 TF 时状态为 Warn，图像照常显示。要消除它：
- 简单：把 Fixed Frame 改成任何已存在的 frame；
- 规范：由你的下游发布 `camera_optical_frame` 的 static TF（如机械臂标定后）。

**无线/远程查看**：跨网络订阅建议先 `ros2 run image_transport republish raw in:=/mv_camera/image_raw compressed out:=/mv_camera/image_raw/compressed`，客户端订阅 compressed，减少带宽。

**QoS 匹配**：默认发布 Reliable → rviz 配置里 Reliability Policy 要是 `Reliable`；
若节点开了 `use_sensor_data_qos:=true`，rviz 订阅端必须改成 `Best Effort`，否则无图。

---

## 5. 与相机其他应用的共存规则（重要）

相机 usbfs **同一时刻只允许一个拥有者**。三套应用互斥，切换前先停掉前者：

| 应用 | 启动 | 停止 |
|---|---|---|
| ROS 节点 | `ros2 launch sua_aravis_camera camera.launch.py` | Ctrl-C / `pkill -f 'camera.launch.[p]y'` |
| 彩色预览窗 | `sudo setsid bash ~/camera-stabilize/preview_live.sh &` | `touch /tmp/preview.stop`（或直接关窗） |
| 稳定性 soak | `sudo systemctl start camera-soak` | `sudo systemctl stop camera-soak` |

- `camera-watchdog.service`（系统常驻）在 ROS 节点运行期间**自动暂停探测**，不会抢相机；
  节点停掉后它继续值守空闲期。
- 若节点发现相机被别的进程占用：日志提示 `REOPEN failed`，恢复脚本返回 3 拒绝断电，
  节点持续退避重试——属正常协同，不是故障。

---

## 6. 自恢复机制与日志

状态机：`STREAMING →(5s 无帧)→ REOPEN →(2 次失败)→ USB_RECOVER(VBUS 电子拔插) → WAIT_DEVICE → REOPEN …`

- 节点日志：launch 终端输出，带 `[RECOVER]` 前缀的为恢复事件。
- 恢复脚本日志：`journalctl -t usb_recover`。
- 看门狗日志：`/var/log/camera-watchdog.log`。

恢复机制依赖（**已装好**，重装系统时需重做）：
1. DTB `vbus-recover` gpio-leds 节点（`/sys/class/leds/vbus-host|vbus-otg` 控 VBUS）；
2. `/usr/local/sbin/usb_recover.sh`（源：`~/camera-stabilize/usb_recover.sh`）；
3. `/etc/sudoers.d/usb-recover`（`xiaoxingchn` 对该脚本 NOPASSWD）；
4. udev 规则 `/etc/udev/rules.d/99-mindvision.rules`（usbfs 0666，**普通用户才能开相机**）。

---

## 7. 下游编程示例

### Python（rclpy）订阅

```python
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image, CameraInfo
import numpy as np


class Listener(Node):
    def __init__(self):
        super().__init__('listener')
        self.create_subscription(Image, '/mv_camera/image_raw', self.on_img, 10)
        self.create_subscription(CameraInfo, '/mv_camera/camera_info', self.on_ci, 10)

    def on_img(self, m):
        # rgb8: HxWx3 直接 reshape
        frame = np.frombuffer(m.data, dtype=np.uint8).reshape(m.height, m.width, 3)
        # ... 你的处理 ...

    def on_ci(self, m):
        self.K = np.array(m.k).reshape(3, 3)  # 内参


rclpy.init()
rclpy.spin(Listener())
```

### C++（rclcpp）订阅

```cpp
auto sub = node->create_subscription<sensor_msgs::msg::Image>(
    "/mv_camera/image_raw", 10,
    [](const sensor_msgs::msg::Image::SharedPtr m) {
      // m->encoding == "rgb8"; 行跨度 m->step
    });
```

### 时间戳与同步

图像时间戳为到达节点的 `now()`（相机本体无 PTP）。与其它传感器融合请用
`message_filters::TimeSynchronizer` 按 header.stamp 对齐，或以本机时钟为准。

---

## 8. 标定

1. `sudo apt install ros-humble-camera-calibration-parsers`（已装）
2. 用 `camera_calibration` 包跑棋盘格标定，把结果存为
   `~/.ros/camera_info/mv_camera.yaml`
3. 节点重启后自动加载（默认 URL 即该路径），`camera_info` 随帧发布。

---

## 9. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `open failed: No supported device found` | 相机被其他进程占用 / 已死链 | 查 `lsusb`；停掉占用者；等节点自恢复；`journalctl -t usb_recover` 看断电记录 |
| rviz 有 topic 但黑图 | QoS 不匹配（BestEffort 发布 + Reliable 订阅） | rviz 里把 Reliability 改 Best Effort |
| `ros2 topic list` 空 | ros2 CLI daemon 缓存过期 | `ros2 daemon stop` 后重试 |
| 话题频率只有 ~30fps | 当前枚举在 USB2 高速链路（SS 训练失败回落）或曝光 33ms | 正常；SS 链路下曝光 10ms 可达 70+fps |
| 画面颜色怪异 | 用了 `bayer_rggb8` 原生模式 | `output_encoding: rgb8` |
| 恢复全失败 | VBUS 断电也救不回 | 物理拔插一次；查 `journalctl -t usb_recover` |

---

## 10. 构建与文件清单

```bash
# 依赖（已装）：ros-humble-ros-base rviz2 image-transport camera-info-manager
#               colcon；Aravis 0.8.31(/usr/local, pkgconfig 可达)；udev 规则
cd ~/ros2_ws
colcon build --packages-select sua_aravis_camera
```

```
sua_aravis_camera/
├── src/aravis_camera_node.cpp     # 节点（采集+去马赛克+恢复状态机）
├── scripts/camera_monitor.py      # GTK3 状态/帧率监视窗口（只读）
├── launch/camera.launch.py        # 参数文件 + rviz:=true / monitor:=true 联动
├── config/default.yaml            # 参数默认值
├── config/view_camera.rviz        # rviz 示例配置
├── udev/99-mindvision.rules       # usbfs 权限规则（装到 /etc/udev/rules.d/）
└── doc/ROS2_使用文档.md           # 本文档
```
