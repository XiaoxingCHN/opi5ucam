# MERGE_NOTES —— 合并建议与说明（写给后续 AI / 维护者）

> 生成：2026-10-06。本文件是**新增文件**，未修改仓库任何已有内容。
> 来源：另一个 AI 会话（内核/系统/BT 层排查与修复）的完整交付快照，存放于
> `ai-handoff-20261005/`（本仓库顶层新增子目录）。

## 一、`ai-handoff-20261005/` 里有什么

| 子目录 | 内容 | 与本仓库的关系 |
|---|---|---|
| `kernel-patches/` | 4 个内核补丁：①usbdp PHY 主线化对齐 ②DWC3 REFCLKPER/GFLADJ ③rk3588 USB3 DTS ref-clock ④新增 rk3588-orangepi-5-ultra.dts（幻影屏修复+OTG GPIO PB1） | **本仓库没有的内核层内容**。仓库聚焦用户态/ROS；这 4 个补丁是让相机 USB3 链路与 Ultra 板级显示/USB 正确工作的前置条件 |
| `kernel-build/` | Image、System.map、config（=出厂配置+补丁）、modules、dtb(max+ultra) | 已在测试机验证可启动、可采流的构建产物 |
| `image/` | 完整可烧写镜像（官方 v2.4.0 + 上述内核，7.6G） | 应急恢复用 |
| `board-fixes/` | 蓝牙（AP6611S/SYN43711）bring-up 全套：bt-start.sh（重试+断电时序）、btattach（补 HCIUARTSETPROTO ioctl 的守护式挂载器）、systemd 服务、btsdio 黑名单；以及 apply-to-installed.sh | **全新能力**：原厂 ap6611s-bluetooth.service 用 UART 方式且时序错误，蓝牙从未工作过；本套件实测扫描到周边设备 |
| `kernel-source-modified/` | 被补丁修改的 4 个源文件（ultra.dts / dwc3 core.c+core.h / usbdp.c） | 供 code review，不必整体替换 |
| `docs/` | HANDOFF.md（AI 交接文档，含避坑清单 10 条）、方案总结.md（排查矩阵+证据链）、TESTING.md、camera-evidence.log（掉线时间线） | 参考与报障材料 |

## 二、关键技术事实（后续 AI 容易踩错的点）

1. **SUA133GC 是 USB3 Vision 相机（非 UVC）**。任何 v4l2/uvcvideo/MindVision-SDK 路线对它无效：
   MindVision 官方 SDK V2.1.0.49 枚举返回 -16（strace 证实打开 usbfs 节点后拒绝认领）。
   正确协议栈 = **Aravis**（仓库 ros2/sua_aravis_camera 已选对）。
2. **内核必须用出厂配置**（镜像内 config-5.10.0-1012-rockchip）+ olddefconfig 构建；
   `rockchip_linux_defconfig` 缺 2858 项（cgroups/BPF/DRM 面板等）→ 黑屏。
   构建需 pahole（dwarves）。**不要做 initramfs**（x86 交叉产出的 initramfs 会 panic；
   关键驱动全内建，extlinux 直挂根即可）。
3. **SYN43711 蓝牙**：下载必须"rfkill 断电→上电→立即 patchram"的时序（否则卡 proc_reset）；
   下载完成后挂载必须走 `TIOCSETD(N_HCI)+HCIUARTSETPROTO(BCM)` 且**挂载进程须常驻持有 fd**
   （退出=注销 hci）。老版 AMPAK patchram 不会发 SETPROTO，必须配合 btattach。
4. **USB3 链路随机静默死亡是平台/固件级缺陷**（2 相机×2 PHY×空闲/推流全复现，
   掉线瞬间内核零报错，死后控制端点 EIO 须拔插）——内核软件层已穷尽（补丁应用后仍复现）。
   上层方案=快速恢复（仓库 system/usb_recover.sh 的 VBUS 断电思路正确），根治=报障厂商。

## 三、合并建议（与仓库现有内容）

1. **`tools/arv_grab.c`**：仓库版（91 行，BGGR 去马赛克）与快照版（RGGB）并存。
   两版 Bayer 顺序不同——**以实拍颜色验证为准**（谁的出图颜色正用谁；快照版当时未验证颜色正确性）。
   快照版多出的能力：格式能力打印、按状态分类的错误计数。建议人工 diff 后择一。
2. **`ros2/sua_aravis_camera`**：恢复状态机按 `ai-handoff-20261005/docs/HANDOFF.md` §5 的
   L1(重开)→L2(usb_recover)→L3(等设备) 设计实现；**不要引入 MindVision SDK**（见 II-1，
   mvsdk 目录保留仅作历史参考）。
3. **`system/usb_recover.sh`**（仓库版）比快照版 HANDOFF §5 的 L2 描述更完善（VBUS 电气级
   断电 + usbfs 持有者感知）——**以仓库版为准**，快照版无需合并。
4. **`docs/evidence/`** 与快照版 `docs/camera-evidence.log` 可按时间戳合并成一条完整
   故障时间线（快照版覆盖 4464~12362s 段，含 `can't restore configuration -110`）。
5. **蓝牙件**：建议将 `board-fixes/` 内容合入仓库 `system/`（或独立 `bluetooth/` 目录），
   并把 `ap6611s-bt-fixed.service` 纳入部署文档；原厂 `ap6611s-bluetooth.service`
   （UART-only、时序错误）应继续 disabled。
6. **内核补丁**：建议单独维护（它们作用于另一棵源码树 linux-rockchip jammy，不作用于本仓库）。
   打包内的 Image/modules/dtb 已验证可直接用于现役镜像（见 `kernel-build/`）。

## 四、边界声明

- 本次添加**仅限** `ai-handoff-20261005/` 子目录与顶层 `MERGE_NOTES.md`（两个名字在添加前
  已确认不存在）；仓库已有文件（含 .git、LICENSE、README、docs/*、system/*、tools/*、ros2/*）
  一个字节都没有改动。
- 快照内文件在该会话中全部实测过：补丁已编译上板、镜像已烧写启动、BT 已扫描到周边设备。
