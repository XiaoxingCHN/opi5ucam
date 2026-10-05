# API / 接口参考

> 本文列出本项目的全部对外接口：ROS 话题与参数、launch 参数、sysfs 控制面、
> 脚本与服务接口、Aravis C API 调用点。约定使用文档见
> [ros2/sua_aravis_camera/doc/ROS2_使用文档.md](../ros2/sua_aravis_camera/doc/ROS2_使用文档.md)。

---

## 1. ROS 2 接口（sua_aravis_camera）

### 1.1 话题

| 话题 | 类型 | QoS | 说明 |
|---|---|---|---|
| `/mv_camera/image_raw` | `sensor_msgs/msg/Image` | Reliable, KeepLast(10) | 彩色流。编码由 `bayer_pattern` 决定：`bggr`（实测物理 CFA）→ **`bgr8`**；`rggb` → `rgb8` |
| `/mv_camera/camera_info` | `sensor_msgs/msg/CameraInfo` | 同上 | 未标定时 width/height 正确、畸变空；标定文件经 `camera_info_url` 加载 |
| `/mv_camera/image_raw/compressed*` | image_transport 附加 | — | compressed/jpeg/theora，按需自动出现 |

`use_sensor_data_qos:=true` 时改用 `SensorDataQoS`（BestEffort），且不走
image_transport（Humble 限制），订阅端 QoS 必须匹配。

### 1.2 参数（`config/default.yaml`）

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `camera_name` | string | `mv_camera` | 话题命名空间 `/<camera_name>/…` |
| `camera_optical_frame` | string | `camera_optical_frame` | 图像 header.frame_id |
| `camera_info_url` | string | `""` | 标定文件 `file://…`；空则用 `~/.ros/camera_info/<name>.yaml` 默认路径 |
| `exposure_time` | double | `10000.0` | 曝光 µs。**帧率由曝光间接决定**：10ms≈标称 77fps（SS）；33ms≈30fps |
| `use_sensor_data_qos` | bool | `false` | BestEffort 模式开关 |
| `output_encoding` | string | `rgb8` | `rgb8`=节点内 NN 去马赛克（实际编码受 bayer_pattern 影响）；`bayer_rggb8`=raw 透传（实际标签 `bayer_bggr8`） |
| `stream_stall_seconds` | double | `5.0` | 连续无帧阈值 → 进入恢复状态机 |
| `usb_recover_script` | string | `/usr/local/sbin/usb_recover.sh` | L2 恢复脚本路径 |
| `wb_mode` | string | `once` | `once`=AutoSel off + WBOnce（推荐）/ `manual`=用下三参数 / `off` |
| `wb_rgain` `wb_ggain` `wb_bgain` | int | `100` | manual 模式通道增益（0~400，100=中性） |
| `bayer_pattern` | string | `bggr` | 物理 CFA（增益锚点法实测）；bggr→bgr8，rggb→rgb8 |

### 1.3 launch 参数（`ros2 launch sua_aravis_camera camera.launch.py`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `rviz` | `false` | 联动 rviz2（加载 `config/view_camera.rviz`） |
| `monitor` | `false` | 联动 GTK 监视窗口（自动设 `GDK_BACKEND=x11`） |
| `params` | 包内 default.yaml | 参数文件路径覆盖 |

### 1.4 恢复状态机（节点内部）

```
STREAMING ──(stream_stall_seconds 无帧)──▶ REOPEN
REOPEN ──openCamera 成功──────────────▶ STREAMING
REOPEN ──连续失败 2 次────────────────▶ USB_RECOVER
USB_RECOVER ──执行 usb_recover.sh─────▶ WAIT_DEVICE（退出码 0/1）
              └─退出码 3（他人持有）──▶ COOLDOWN（退避 1s→30s）→ USB_RECOVER
WAIT_DEVICE ──lsusb 见 f622───────────▶ REOPEN
```

状态迁移均以 `[RECOVER]` 前缀写入节点日志；openCamera 每次执行都会重设曝光并重跑
白平衡策略（相机 MCU 在 VBUS 断电后丢失 WB 状态）。

---

## 2. 系统接口（sysfs / udev）

### 2.1 VBUS 电源开关（DTB 手术后）

```
/sys/class/leds/vbus-host/brightness     # usbdrd3_1（Bus8 系）口 VBUS，GPIO3_D5
/sys/class/leds/vbus-otg/brightness      # usbdrd3_0（Bus6 系）口 VBUS，GPIO4_B1=PB1
  echo 0   → 断电（等效拔出）
  echo 255 → 上电（9~13s 后重枚举）
```

注意：`vbus-host` 同时供 u2phy2/3 的 USB2 host 口（键鼠闪断重连，无害）。

### 2.2 设备状态读取

```
/sys/bus/usb/devices/*/idVendor   # =f622 即相机；dirname 为设备 sysfs 路径
…/speed      # 5000 (SuperSpeed) / 480 (HighSpeed 回落)
…/busnum …/devnum   # → /dev/bus/usb/%03d/%03d（usbfs 节点，udev 规则已 0666）
```

### 2.3 udev 规则（`system/99-mindvision.rules`）

```
SUBSYSTEM=="usb", ATTRS{idVendor}=="f622", ATTRS{idProduct}=="d132", MODE="0666"
```

### 2.4 控制器重绑（L3 恢复的底层动作）

```
echo fc400000.usb > /sys/bus/platform/drivers/dwc3/unbind   # Bus8 系控制器
echo fc400000.usb > /sys/bus/platform/drivers/dwc3/bind
# fc000000.usb 同理；总线上设备将全部重枚举
```

---

## 3. 脚本与服务接口

### 3.1 `system/usb_recover.sh`（恢复脚本，节点经 `sudo -n` 调用）

| 退出码 | 含义 |
|---|---|
| 0 | 设备在总线（已恢复或本就健康） |
| 1 | 设备不在总线（等物理插回） |
| 2 | 内部错误 / 持有者扫描失败（fail-safe 拒绝动作） |
| 3 | **相机被其他进程持有**——拒绝断电（`HELD_BY: pid(comm)…`） |

动作序列：持有者扫描 → VBUS 断电 3s → 回电 → 轮询枚举 25s → 必要时 DWC3 重绑。
日志：`journalctl -t usb_recover`。

### 3.2 `system/camera_watchdog.sh`（systemd: `camera-watchdog.service`）

- 探测周期 15s；心跳 15min；日志 `/var/log/camera-watchdog.log`（>5MB 自动截断）；
- 恢复梯 L1 authorized → L2 usbfs RESET → L3 DWC3 → L4 VBUS（详见 architecture.md §3）；
- 检测到 usbfs 持有者或 ROS 节点存活时自动暂停探测（日志 `probes suspended`）。

### 3.3 `system/camera_soak.sh`（systemd: `camera-soak.service`）

- 10 分钟段连续推流（arv_grab，BayerRG8@10ms）；帧停滞（2×30s 计数不变）/早退 →
  杀段 → `hard_recover`（VBUS 断电）→ 健康后自动续段；
- 日志：`/var/log/camera-soak.log`（汇总）、`/var/log/soak-seg.log`（当前段）。

### 3.4 `system/preview_live.sh`（自愈预览窗）

ffplay 窗口常驻（FIFO 保活，feeder 死亡不关窗）+ VBUS 自愈；关窗或
`touch /tmp/preview.stop` 退出并自动恢复 camera-soak。

### 3.5 `scripts/camera_monitor.py`（GTK 监视窗口）

只读：话题时间戳 → fps；sysfs → 设备/速率；进程表 → 节点 PID；日志 tail → 事件。
启动：`ros2 launch … monitor:=true` 或 `system/launch_monitor.sh`。

### 3.6 systemd 单元

```bash
systemctl enable --now camera-watchdog      # 常驻看门狗（root）
systemctl enable --now camera-soak          # 推流压测（root）
systemctl restart camera-watchdog           # 改脚本后重启
```

依赖关系：两单元均 **不写** `After=multi-user.target`（本板 ap6611s-bluetooth 卡死该
target，见 troubleshooting C8）。

---

## 4. Aravis C API 调用点（节点/工具中的实际用法）

```c
ArvCamera *cam = arv_camera_new(NULL, &err);                    // 枚举+打开（单相机传 NULL）
arv_camera_set_pixel_format(cam, ARV_PIXEL_FORMAT_BAYER_RG_8, &err);
arv_camera_get_region(cam, &x0, &y0, &w, &h, &err);             // 分辨率
arv_camera_set_exposure_time_auto(cam, ARV_AUTO_OFF, &err);
arv_camera_set_exposure_time(cam, 10000.0, &err);               // µs；帧率由此决定
size_t payload = arv_camera_get_payload(cam, &err);
ArvStream *st = arv_camera_create_stream(cam, NULL, NULL, &err);
arv_stream_push_buffer(st, arv_buffer_new(payload, NULL));      // 队列 8 个
arv_camera_start_acquisition(cam, &err);
ArvBuffer *b = arv_stream_timeout_pop_buffer(st, 200000);       // 200ms（µs）
arv_buffer_get_status(b); arv_buffer_get_data(b, &sz);
arv_stream_push_buffer(st, b);                                  // 归还复用

/* 白平衡（设备层 API；camera 层无这些辅助函数） */
ArvDevice *dev = arv_camera_get_device(cam);
arv_device_set_boolean_feature_value(dev, "ColorTemperatureAutoSel", FALSE, &err);
arv_device_execute_command(dev, "WBOnce", &err);                // 一键白平衡
arv_device_get_integer_feature_value(dev, "RGain", &err);       // 0~400
arv_device_set_integer_feature_value(dev, "RGain", 156, &err);
```

已知特性缺失（无害忽略）：`DeviceVendorName`、`AcquisitionFrameRate(Abs)`。

## 5. usbfs 底层（无 Aravis 场景）

```c
/* USBDEVFS_RESET — 看门狗 L2 */
#include <fcntl.h>
int fd = open("/dev/bus/usb/008/002", O_WRONLY);
ioctl(fd, 21792, 0);          /* USBDEVFS_RESET = _IO('U', 20) */
```

## 6. 实验工具

| 工具 | 用法 | 输出 |
|---|---|---|
| `tools/wb_probe.c` | `sudo ./wb_probe` | 各 WB 设置下四相均值 + 增益读数 + 20s 漂移 |
| `tools/cfa_test.c` | `sudo ./cfa_test` | RGain/BGain 分别拉高时四相响应 → 物理 CFA |
| `tools/arv_grab.c` | `sudo ./arv_grab 秒数 [dump]` | NN 去马赛克 RGB 流到 stdout（分钟统计行） |
| `dtb/dtb_edit.py` | `python3 dtb_edit.py`（先 `dtc -I dtb -O dts` 反编译到 /tmp/opi5u.dts） | base/HS 两份手术 dts |
