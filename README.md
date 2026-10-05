# opi5ucam — Orange Pi 5 Ultra (RK3588) × MindVision SUA133GC USB3 Vision 相机全栈方案

> **English**: A complete, production-hardened stack for running a MindVision SUA133GC
> USB3 Vision camera on the Orange Pi 5 Ultra (RK3588): a custom 5.10.209 kernel with
> USB/PDT fixes, a DTB surgery that turns the camera port's VBUS into a software-switchable
> rail, a self-healing watchdog (detection → authorized toggle → usbfs reset → DWC3 rebind
> → VBUS power cycle = "electrical replug"), and a ROS 2 Humble node (`sua_aravis_camera`)
> built on Aravis with built-in recovery, correct BGGR debayering, one-shot white balance,
> and a GTK status/monitor window. Full failure analysis, bottom-up debugging methodology,
> API reference and deployment guide are in `docs/`. Licensed under MIT.

本项目记录并交付了一整套在 **Orange Pi 5 Ultra（RK3588）** 上稳定运行 **MindVision SUA133GC
USB3 Vision 工业相机** 的方案：从自编译内核、设备树手术、系统服务，到 ROS2 Humble 驱动节点、
彩色去马赛克、白平衡修正与 GUI 监视器。

**核心价值：这块平台 + 这颗相机的组合存在多层真实的坑（SS 链路静默死亡、原始流严重绿偏、
CFA 实际为 BGGR 而寄存器声称 RGGB、白平衡随断电恢复丢失……），本项目把每一层的问题、
根因、修复与验证全部做成了可复现的工程资产。**

## 特性一览

- 🔧 **自编译内核 5.10.209**（4 个 USB/PHY 相关补丁，见 `kernel/`）
- ⚡ **DTB 手术**：把相机 USB 口的 VBUS 变成软件可控电源轨（gpio-leds 方案，绕开 regulator 权限墙）
- 🩹 **四级自愈看门狗**：authorized 翻转 → usbfs 复位 → DWC3 控制器重绑 → **VBUS 断电重上电（电子拔插）**，
  链路死亡从"必须人工拔插"变为 **约 14-40 秒全自动恢复**
- 🎨 **图像修正**：物理 CFA 实测为 BGGR（修正红蓝对调）、一键白平衡 + 锁定（修正严重绿偏且不随恢复漂移）
- 📦 **ROS2 Humble 节点** `sua_aravis_camera`：`/mv_camera/image_raw`（bgr8）+ `camera_info`，
  内置同款恢复状态机，参数化（曝光/白平衡/编码/QoS）
- 🖥️ **GTK 监视窗口**：状态灯、实时 fps 曲线、链路速率、恢复事件流（只读，不占相机）
- 📚 **完整文档**：故障排查手册（每个问题→根因→修复→验证）、从电气层到应用层的排障方法论、
  API 参考、部署教程、实测证据日志

## 快速开始（已部署系统的日常使用）

```bash
# 1. 启动相机 ROS 节点（可加 rviz:=true monitor:=true 联动图形界面）
source /opt/ros/humble/setup.bash
source ~/ros2_ws/install/setup.bash
ros2 launch sua_aravis_camera camera.launch.py rviz:=true monitor:=true

# 2. 验证帧率
timeout 12 stdbuf -oL ros2 topic hz /mv_camera/image_raw --window 30
```

从零部署（新镜像/新板子）：见 **[docs/deployment.md](docs/deployment.md)**。

## 文档地图

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | **分层架构与排障方法论**：电气 → 总线 → 协议 → 驱动 → 用户态 → 应用 → 集成，每层的可信数据源与判别实验 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | **故障排查手册**：本项目遇到的全部问题 → 根因 → 修复 → 验证（含代码/命令级细节） |
| [docs/api-reference.md](docs/api-reference.md) | **接口参考**：ROS 话题/参数、sysfs 接口、脚本退出码、Aravis C API 调用点 |
| [docs/deployment.md](docs/deployment.md) | **部署教程**：从镜像烧写、内核构建、DTB 手术到 ROS 全栈的完整步骤 |
| [docs/evidence/](docs/evidence/) | 实测证据日志（看门狗/soak：死亡→自愈全过程带时间戳） |

## 目录结构

```
opi5ucam/
├── ros2/sua_aravis_camera/   # ROS2 Humble 包（节点/监视器/launch/配置/udev）
├── system/                   # 看门狗、soak、恢复脚本、systemd 单元、udev 规则
├── dtb/                      # DTB 手术脚本（VBUS 软件可控化）
├── kernel/                   # 内核补丁说明（4 个 commit）
├── tools/                    # 采集/实验工具源码（arv_grab、wb_probe、cfa_test）
└── docs/                     # 文档 + 截图 + 证据日志
```

## 实测性能

| 指标 | 数值 |
|---|---|
| 帧率（SuperSpeed，曝光 10ms） | 35~44 fps 实测（相机标称上限 ~77 fps） |
| 帧率（HighSpeed 回落模式） | ~30-34 fps（USB2 带宽上限） |
| 链路死亡自愈耗时 | 14~40 s（全自动，无需人工） |
| 颜色 | R/G≈1.02、B/G≈0.96（白平衡锁定后 60s 零漂移） |
| 恢复可靠性 | VBUS 电子拔插与物理拔插等效（多次实测 100% 复活） |

## 已知平台缺陷（本项目绕开而非解决的）

RK3588 usbdp PHY × 这颗相机固件的组合存在 **SuperSpeed 链路静默死亡** 缺陷
（跨 2 颗相机、2 路 PHY、空闲/推流全复现，dmesg 零错误事件，详见
[troubleshooting §1](docs/troubleshooting.md)）。根治需要厂商固件/PHY 修正；
本项目的自愈栈把它对上层的影响降到了几十秒的自动中断。

## 许可

MIT（见 [LICENSE](LICENSE)）。内核补丁遵循上游 GPL-2.0。
