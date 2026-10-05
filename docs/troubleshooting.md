# 故障排查手册：全部问题 → 根因 → 修复 → 验证

> 本手册收录本项目在 Orange Pi 5 Ultra + MindVision SUA133GC 上遇到的**所有**问题，
> 按层次组织。每条给出：现象、排查过程、根因、修复、验证方法。
> 配套方法论见 [architecture.md](architecture.md)，代码见对应目录。

---

## 目录

- [A. 平台 / 链路层](#a-平台--链路层)
  - [A1. SuperSpeed 链路静默死亡（核心缺陷）](#a1-superspeed-链路静默死亡核心缺陷)
  - [A2. VBUS 无法软件控制（regulator/gpio 三重权限墙）](#a2-vbus-无法软件控制regulatorgpio-三重权限墙)
  - [A3. "僵尸流"模式：控制通道活着，流全丢](#a3-僵尸流模式控制通道活着流全丢)
  - [A4. usbfs 独占：多应用争抢相机](#a4-usbfs-独占多应用争抢相机)
  - [A5. SS 训练失败回落 HighSpeed（帧率骤降）](#a5-ss-训练失败回落-highspeed帧率骤降)
  - [A6. 相机断电后重枚举需要 9~13 秒](#a6-相机断电后重枚举需要-913-秒)
  - [A7. 已排除项记录（runtime PM / USB3 LPM / DTS quirks …）](#a7-已排除项记录)
- [B. 相机 / 图像层](#b-相机--图像层)
  - [B1. MindVision 官方 SDK 枚举失败（-16）](#b1-mindvision-官方-sdk-枚举失败-16)
  - [B2. Aravis 设备名 ≠ USB 产品名（假死误判）](#b2-aravis-设备名--usb-产品名假死误判)
  - [B3. 普通用户枚举不到相机（usbfs 权限）](#b3-普通用户枚举不到相机usbfs-权限)
  - [B4. 严重绿偏（R/G=0.60）且随时间/重连漂移](#b4-严重绿偏rg0660且随时间重连漂移)
  - [B5. 红蓝对调：物理 CFA 是 BGGR 而寄存器叫 RGGB](#b5-红蓝对调物理-cfa-是-bggr-而寄存器叫-rggb)
  - [B6. 帧率由曝光间接决定](#b6-帧率由曝光间接决定)
- [C. ROS / 软件工程层](#c-ros--软件工程层)
  - [C1. image_transport 忽略 sub-node 命名空间](#c1-image_transport-忽略-sub-node-命名空间)
  - [C2. image_transport (Humble) 无法自定义 QoS](#c2-image_transport-humble-无法自定义-qos)
  - [C3. package.xml email 校验失败](#c3-packagexml-email-校验失败)
  - [C4. ros2 CLI 图缓存过期 / topic hz 输出被管道吞掉](#c4-ros2-cli-图缓存过期--topic-hz-输出被管道吞掉)
  - [C5. GTK 应用吞掉 SIGTERM](#c5-gtk-应用吞掉-sigterm)
  - [C6. pkill -f 自匹配自杀（反复踩坑）](#c6-pkill--f-自匹配自杀反复踩坑)
  - [C7. 后台子 shell 包装导致杀错 PID（孤儿进程握死相机）](#c7-后台子-shell-包装导致杀错-pid孤儿进程握死相机)
  - [C8. After=multi-user.target 永久排队（板级服务缺陷）](#c8-aftermulti-usertarget-永久排队板级服务缺陷)
- [D. 内核 / 构建层](#d-内核--构建层)
  - [D1. 内核构建三铁律](#d1-内核构建三铁律)
  - [D2. WSL 构建环境注意事项](#d2-wsl-构建环境注意事项)

---

## A. 平台 / 链路层

### A1. SuperSpeed 链路静默死亡（核心缺陷）

**现象**：相机随机性地"消失"或假死：
- dmesg 中**没有任何** xHCI/PHY 错误事件，链路死亡完全静默；
- 设备有时仍枚举在总线上，但控制端点所有请求返回 `LIBUSB_ERROR_IO`；
- 跨 **2 颗相机**、**2 路独立 usbdp PHY**（fc000000+phy0 / fc400000+phy1）复现；
- 空闲、仅控制、推流三种状态均复现；
- 唯一可靠的恢复手段是**物理拔插**（断电重启相机 MCU）；
- 曾观察到枚举期 `-71`（device not accepting address）与
  `can't restore configuration #1 (error=-110)`。

**排查过程**（详见 [architecture.md](architecture.md)）：
1. 怀疑 DTS quirks → 与原厂 6.1 BSP 逐项比对，一致，排除；
2. 怀疑 xHCI 等时传输实现 → 与主线 v6.6 对齐，排除；
3. 怀疑 naneng combphy / dwc3 glue → 本树无 dwc3-rockchip.c（走 of-simple），排除；
4. 怀疑自编内核 4 补丁 → 应用后仍复现，排除；
5. 怀疑内核版本 → 原厂 5.10.0-1012-rockchip 与 6.1 BSP 同样复现，排除；
6. 软件层穷尽后定性：**usbdp PHY 链路训练/模拟层 或 相机固件的互操作缺陷**。

**修复（绕开）**：无法根治，改为"检测 + 自动恢复"：
- 常驻看门狗（`system/camera_watchdog.sh`）15s 探测 Aravis 控制引导；
- 恢复梯 L1 authorized 翻转 → L2 usbfs RESET → L3 DWC3 unbind/rebind →
  **L4 VBUS 断电重上电（等效物理拔插，100% 复活）**；
- 实测自愈耗时 14~40s。证据日志：`docs/evidence/camera-watchdog.log`。

**验证**：人为触发链路死亡（或等待自然死亡），观察看门狗日志出现
`L4 VBUS-cycle revived`，dmesg 出现断开→重枚举序列，无人工干预。

---

### A2. VBUS 无法软件控制（regulator/gpio 三重权限墙）

**现象**：链路死后想用软件模拟拔插（断 VBUS），三条常规路径全部被堵：
1. regulator sysfs：`echo 0 > /sys/class/regulator/regulator.N/state` → root 也
   `Permission denied`（该属性在 status 不可变时是 0444 只读；`regulator-always-on`
   约束的 `vcc5v0_host` 更是根本不可 disable）；
2. legacy sysfs gpio：`echo 125 > /sys/class/gpio/export` → `Device or resource busy`
   （引脚被 regulator 驱动以 chardev 方式占用）；
3. libgpiod `gpioset`：同样 EBUSY（内核消费者持有）。

**根因**：相机口 VBUS 由 fixed-regulator `vcc5v0_host`（GPIO3_D5，使能脚高有效）供电，
驱动 probe 后永久持有该引脚；`vcc5v0_otg`（GPIO4_B1 = PB1，Type-C 口）同理。

**修复（DTB 手术）**：让 GPIO "换个主人"——
- 从两个 regulator 节点摘除 `gpio`/`enable-active-high`/`pinctrl` 属性
  （regulator 变成虚拟常供轨，u2phy 消费者无感知）；
- 新增 `vbus-recover`（compatible = "gpio-leds"）节点接管同一对引脚，
  `default-state = "on"`（开机即供电，与原行为一致）；
- 此后 VBUS 开关就是标准 LED sysfs：
  `echo 0|255 > /sys/class/leds/vbus-host/brightness`（root，无任何权限限制）。

**验证**：重启后 `ls /sys/class/leds/ | grep vbus` 出现两项；断电 3s→回电，
dmesg 出现 `usb 8-1: USB disconnect` → 9~13s 后重枚举；恢复后首帧颜色正常
（见 `docs/evidence/camera-watchdog.log` 20:41/20:56/20:58 三次实测）。

**注意**：`vbus-host` 轨同时供 u2phy2/3 的 USB2 host 口，断电时键鼠会闪断重连（无害）。

**工具**：`dtb/dtb_edit.py`（从运行中 DTB 反编译 → 手术 → 重编译，含 HS 变体）。

---

### A3. "僵尸流"模式：控制通道活着，流全丢

**现象**：一种比 A1 更隐蔽的死亡模式：
- `arv-tool control` 引导**成功**（控制通道正常）；
- 但推流 buffer 全部 `MISSING_PACKETS`，或新进程报 `NO_STREAM` / `NO_CAMERA`；
- 看门狗的探测完全测不出来（控制引导通过），L3 DWC3 重绑后也常直接进入此状态。

**根因**：链路重训练后相机内部流引擎状态残留/劣化；L3 复活只重建了主机侧链路。

**修复**：必须 **VBUS 断电**（A2 的 L4）。实现为两处：
- `system/camera_soak.sh` 的 `hard_recover()`：帧停滞检出 → 杀段 → VBUS 断电 3s →
  回电轮询枚举 25s → 必要时补 DWC3 重绑；
- ROS 节点恢复状态机：REOPEN 连续失败 2 次 → 执行 `/usr/local/sbin/usb_recover.sh`。

**验证**：`docs/evidence/camera-soak.log` 20:45~20:52 段：僵尸流 → arv-tool 依旧绿 →
VBUS 电子拔插 → 恢复后首段即 80fps 全 SUCCESS（当时 SS 链路）。

---

### A4. usbfs 独占：多应用争抢相机

**现象**：两个进程同时打开相机时，后者引导失败（`NO_CAMERA`），且可能干扰前者的流。

**根因**：usbfs/libusb 语义下相机接口被独占（USB3 Vision 控制接口不支持多客户端并发引导）。

**修复**：三层协同——
1. **应用互斥约定**：预览窗 / soak / ROS 节点同一时刻只跑一个（各脚本/文档明示启停命令）；
2. **持有者保护**（`system/usb_recover.sh`）：恢复脚本扫描 `/proc/*/fd` 是否有人持有
   相机 usbfs 节点，有则**拒绝断电**（退出码 3），绝不把相机从正在运行的应用手里抢走；
   扫描本身失败也拒绝（fail-safe）；
3. **看门狗让位**（`system/camera_watchdog.sh`）：检测到预览/soak/ROS 节点持有 usbfs
   或 ROS 节点存活时自动暂停探测——探测用的 arv-tool 引导会短暂持有设备，与恢复动作冲突。

**验证**：预览推流中启动 ROS 节点 → 节点持续 `REOPEN failed`（预期），
恢复脚本日志出现 `refusing: device held by …`，预览不受任何影响。

---

### A5. SS 训练失败回落 HighSpeed（帧率骤降）

**现象**：某次断电恢复后相机枚举在 480M（USB2 HighSpeed）而非 5000M，
帧率从 ~40+ 掉到 ~30fps 封顶。

**根因**：USB3 规范允许设备在 SS 训练失败后回落 HS——A1 缺陷的另一种表现形式。

**修复**：无需修复，但要**知情**：
- 监视窗口显示当前链路速率（SuperSpeed/HighSpeed），一眼可辨；
- 恢复脚本/看门狗按设备实际 sysfs 路径动态定位控制器，回落不影响自愈逻辑；
- 如需强制稳定优先，`kernel/` 提供了 `maximum-speed="high-speed"` 的 HS 变体 DTB
  （extlinux 启动项 `l0hs`），彻底绕开 SS 链路（帧率上限 ~30fps）。

**验证**：`lsusb -t` 看速率；`/sys/bus/usb/devices/*/speed` 读数值。

---

### A6. 相机断电后重枚举需要 9~13 秒

**现象**：VBUS 回电后设备不是立刻回来，`lsusb` 空窗最长 ~13s。

**根因**：相机 MCU 上电自检 + USB3 链路训练所需时间。

**修复**：所有恢复逻辑用**轮询等待**（25s 上限）而非固定睡眠；不足此等待会误判
"复活失败"而触发多余动作。

---

### A7. 已排除项记录

以下嫌疑项均**有对照实验排除**，避免后来者重复排查：

| 嫌疑项 | 排除依据 |
|---|---|
| DTS quirks 与原厂不一致 | 与 6.1 BSP 逐项一致仍复现 |
| xHCI 等时传输实现 | 与主线 v6.6 对齐仍复现 |
| naneng combphy | 相机走 usbdp PHY，不经过 combphy |
| dwc3-rockchip glue | 本树无此文件（走 of-simple） |
| 自编 4 补丁 | 应用后仍复现 |
| 内核版本 | 原厂 5.10 + 6.1 BSP 均复现；社区 issue #1081 佐证 |
| runtime PM | 两个 usbdp dwc3 均 `active/on`（未挂起） |
| USB3 LPM（U1/U2） | dwc3 已带 `snps,dis-u1-entry-quirk/dis-u2-entry-quirk`，dmesg 亦报 LPM disabled |
| MindVision SDK 版本 | V2.1.0.49 在 x86/ARM 均枚举失败（见 B1），与链路死亡无关 |

---

## B. 相机 / 图像层

### B1. MindVision 官方 SDK 枚举失败（-16）

**现象**：MindVision Linux SDK V2.1.0.49（arm64）`MvcamGetString`/枚举返回 -16
（无设备），`strace` 证实其打开了 usbfs 节点后**拒绝认领**自己的相机。

**修复**：放弃 SDK，改用 **Aravis 0.8.31**（源码编译到 /usr/local）——
USB3 Vision 协议通用实现，枚举/控制/GenICam XML/采流全部正常。

**教训**：拿到"官方 SDK 不认自家设备"这种反直觉现象时，用 strace 看
`open/ioctl(UI dev)` 序列比反复调参数更快定位是 SDK 侧问题。

---

### B2. Aravis 设备名 ≠ USB 产品名（假死误判）

**现象**：`arv-tool -n SUA133GC control Width` 报 "Device 'SUA133GC' not found"，
被误判为相机假死。

**根因**：Aravis 的设备名是 GenCP 的 DeviceID：`MindVision-<SN>-<SN>`
（如 `MindVision-042090420305-042090420305`），不是 USB 产品名字符串。

**修复/规避**：单相机环境直接省略 `-n`（自动选择唯一设备）；多相机用完整 Aravis 名。

---

### B3. 普通用户枚举不到相机（usbfs 权限）

**现象**：root 下 arv-tool 一切正常；普通用户 `arv-tool control` 报 "No device found"——
**ROS 节点以普通用户运行时因此完全无法工作**，且症状与链路假死一模一样，极易误判。

**根因**：`/dev/bus/usb/00X/00Y` 默认 `root:root 0644`，普通用户无法读写 usbfs。

**修复**：udev 规则（`system/99-mindvision.rules`，精确匹配 VID:PID 不放大权限面）：

```
SUBSYSTEM=="usb", ATTRS{idVendor}=="f622", ATTRS{idProduct}=="d132", MODE="0666"
```

安装：拷入 `/etc/udev/rules.d/` → `udevadm control --reload-rules && udevadm trigger`。

**验证**：`ls -l /dev/bus/usb/005/003` → `crw-rw-rw-`；普通用户 arv-tool 正常。

---

### B4. 严重绿偏（R/G=0.60）且随时间/重连漂移

**现象**：raw Bayer 流直接去马赛克后严重偏绿；颜色还会"随时间变化"。

**排查**（实验工具 `tools/wb_probe.c`，量化各设置下的通道均值）：
1. 基线（增益 100/100/166）：R=141 G=235 B=169 → **R/G=0.60**，固有绿偏；
2. `ColorTemperatureAutoSel=on`（相机自动色温）：校正**不完整**（B 持续偏低），
   且**不写回增益寄存器**——不可观测、不可控，即"漂移"来源之一；
3. `WBOnce`（相机一键白平衡）：增益自动设为 156/100/167，通道均值立刻平衡
   （R/G 0.60 → 0.97）；
4. **关键机制**：每次链路死亡 → VBUS 断电恢复 = 相机 MCU 重新上电 = **WB 状态丢失
   回出厂自适应**——这就是"随时间（实为随重连）漂移"。

**修复**（ROS 节点 `wb_mode` 参数，**每次 openCamera 都重新执行**，含恢复路径）：
- `once`（默认）：`ColorTemperatureAutoSel=false` → 执行 `WBOnce` 命令 → 睡 2.5s 等收敛
  → 增益锁定；
- `manual`：直接写 `RGain/GGain/BGain`（0~400，100=中性）；
- `off`：不碰。

**验证**：订阅话题实测 75s：R/G=0.981、B/G=1.093，三个 20s 窗口内比值稳定在
小数点第三位（零漂移）。截图 `docs/images/rviz_wb_verified.png`。

---

### B5. 红蓝对调：物理 CFA 是 BGGR 而寄存器叫 RGGB

**现象**：白平衡修好后颜色仍不对——用户目视确认红蓝互换。

**排查（增益锚点法）**：用相机自己的增益寄存器当"真值锚点"
（`tools/cfa_test.c`）：单独拉高 RGain → 只有**奇行奇列**均值跳变（×2.04）；
单独拉高 BGain → 只有**偶行偶列**跳变（×2.2）。故物理 CFA：
B@(0,0)、G@(0,1)/(1,0)、R@(1,1) = **BGGR**，与 PixelFormat 寄存器名 `BAYER_RG_8` 矛盾
——寄存器名是元数据不是物理事实。

**修复**：零开销方案——BGGR 流按 RGGB 站点逻辑去马赛克后，每像素字节天然是
[B,G,R] 顺序，直接以标准 **`bgr8`** 编码发布（OpenCV 原生格式，cv_bridge/rviz 全兼容）；
raw 透传模式标签改为 `bayer_bggr8`。参数 `bayer_pattern`（bggr/rggb）可切换。
预览工具 `tools/arv_grab.c` 的输出字节序同步修正。

**验证**：`ros2 topic echo --field encoding` → `bgr8`；正确语义下 R/G=1.015、B/G=0.957；
rviz 目视确认（木色桌面、白色灯带，见 `docs/images/rviz_bggr_verified.png`）。

**教训**：**不要相信格式寄存器的名字**。CFA 排布这类"物理事实"要用可观测的因果实验
（增益→哪个像素相位跳变）来钉死。

---

### B6. 帧率由曝光间接决定

**现象**：XML 里没有 `AcquisitionFrameRate`/`AcquisitionFrameRateAbs` 特性，
读帧率特性报 Not found。

**根因**：该相机帧率 = 1/(曝光时间 + 读出)，由曝光间接决定。

**修复**：想锁 30fps 就把 `exposure_time` 设 33000（µs）。实测：
曝光 10ms 时 SuperSpeed 链路 ~35-44fps（标称上限 77fps），HighSpeed 回落模式 ~30-34fps
（USB2 带宽上限 1280×1024×8bit ≈ 39MB/s）。

---

## C. ROS / 软件工程层

### C1. image_transport 忽略 sub-node 命名空间

**现象**：`create_sub_node("mv_camera")` + `advertiseCamera("image_raw")` →
话题落在 `/image_raw` 而非 `/mv_camera/image_raw`。

**根因**：Humble 的 image_transport 内部解析话题名时绕过了 sub-node 的命名空间。

**修复**：不依赖 sub-node 解析，直接用显式绝对路径
`advertiseCamera("/" + camera_name_ + "/image_raw", 10)`。

---

### C2. image_transport (Humble) 无法自定义 QoS

**现象**：`advertiseCamera(topic, rmw_qos_profile_t)` 编译失败——Humble 的该重载
只收 `uint32_t queue_size`；`use_sensor_data_qos`（BestEffort）无法表达。

**修复**：双分支——默认走 image_transport（附带 compressed 话题）；需要 SensorDataQoS
时直接 `create_publisher<Image>/<CameraInfo>`（rclcpp 原生，同样落到
`/<camera_name>/image_raw`）。文档提醒 rviz 端 QoS 必须匹配。

---

### C3. package.xml email 校验失败

**现象**：colcon 构建报 `Invalid email "xiaoxingchn@local"`——catkin_pkg 对
maintainer email 做格式校验（无需 TLD 但必须有合法域名形制）。

**修复**：`email="xiaoxingchn@example.com"`。

---

### C4. ros2 CLI 图缓存过期 / topic hz 输出被管道吞掉

**现象**：`ros2 topic list` 看不到活跃话题；`ros2 topic hz | tail` 无任何输出。

**根因**：CLI daemon 缓存的计算图过期；hz 的 python stdout 经管道是块缓冲，
`timeout` SIGTERM 杀进程时缓冲丢失。

**修复**：`ros2 daemon stop` 重建；或 `--no-daemon`；hz 用
`timeout 12 stdbuf -oL ros2 topic hz … > 文件` 或直接 python rclpy 探针
（探针还顺带能读 encoding/尺寸，比 hz 信息多）。

---

### C5. GTK 应用吞掉 SIGTERM

**现象**：监视窗口 `kill` 不退（TERM 无效），只能 `kill -9`。

**根因**：python 的信号处理器只在主线程字节码间执行，而主线程阻塞在 C 层
`Gtk.main()` 里永不返回 → TERM 处理器被无限期搁置。

**修复**：信号必须挂到 GLib 主循环：
`GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit, None)`。

---

### C6. pkill -f 自匹配自杀（反复踩坑）

**现象**：`pkill -f 'camera.launch.py'` 把自己的 shell 一起杀了（命令行里含该字符串），
复合命令莫名中断且无输出；还有一次 `pgrep | head` 的管道退出码骗过了存活检查
（head 永远成功）。

**修复**：
- 模式加括号正则防自匹配：`pkill -f 'camera.launch.[p]y'`；
- 注意**同一命令里后续文本**也会参与匹配（启动参数含字面串时依然自杀）——
  杀进程与含该串的启动命令必须分成两条命令执行；
- 可靠的存活判定用 `pgrep -c` 的退出码而不是管道。

---

### C7. 后台子 shell 包装导致杀错 PID（孤儿进程握死相机）

**现象**：`(cd dir && arv_grab … >> log) &` 后 kill 其 `$!`，只杀了包装 subshell，
arv_grab 变孤儿继续死握 usbfs → 后续所有段 `NO_CAMERA`、看门狗被"持有者检测"吊住。

**修复**：`(cd dir && exec arv_grab …) &`——`exec` 让段 PID 就是 arv_grab 本体；
启动前再 `pkill -KILL -x arv_grab` 防御性清场。

---

### C8. After=multi-user.target 永久排队（板级服务缺陷）

**现象**：`systemctl enable --now` 新服务卡死数分钟不返回；`systemctl list-jobs` 显示
`multi-user.target start waiting`，元凶是 `ap6611s-bluetooth.service`（4G 模组蓝牙）
开机即卡在 `running`，导致 multi-user.target 从开机起永远到不了 active。

**修复**：自研服务**去掉 `After=multi-user.target`**（`WantedBy=` 不受影响，开机自启正常）；
顺带提示：这块板想加速启动可以 `systemctl mask ap6611s-bluetooth`。

---

## D. 内核 / 构建层

### D1. 内核构建三铁律

在 x86 交叉编译 RK3588 内核（Joshua-Riek/linux-rockchip 5.10.209 基线）时：
1. **配置必须用出厂配置**（镜像内 `/boot/config-5.10.0-1012-rockchip`）+
   `make O=build olddefconfig`——`rockchip_linux_defconfig` 缺 2858 项会黑屏；
2. **必须装 pahole**（`apt install dwarves`），否则 `CONFIG_DEBUG_INFO_BTF=y` 编译失败；
3. **不用 initramfs**（关键驱动全内建），extlinux 用 `root=PARTUUID=…` 直挂根——
   x86 上产的 initramfs 是 x86 二进制，板子上会 `No working init found` panic。

构建：`make O=build -j32 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image dtbs modules`
；注入镜像的步骤（模块 strip、DTB 安装到 `/lib/firmware/<ver>/device-tree/rockchip/`、
extlinux 重写）见 [deployment.md](deployment.md)。

### D2. WSL 构建环境注意事项

- WSL 的 `/tmp` 在会话间清空——中间文件放 `/root/work/` 或挂载盘；
- `wsl.exe bash -c` 多层引号必翻车——复杂命令写成脚本文件用 `bash -s <` 执行；
- 本项目的 4 个内核补丁以 **git commit** 形式保存在内核工作分支
  `rk3588-usb-isoc-fixes`（获取方式见 [kernel/README.md](kernel/README.md)）。

---

## 附：开发中产生的实用工具

| 工具 | 用途 |
|---|---|
| `tools/wb_probe.c` | 量化各相机设置下的 R/G/B 通道均值（白平衡实验） |
| `tools/cfa_test.c` | 增益锚点法测定物理 CFA 排布 |
| `tools/arv_grab.c` | 采集 + NN 去马赛克 + stdout 原始帧（预览/soak 的基础） |
| `system/post_reboot_verify.sh` | DTB 手术后的一次性全套验证（含强制 VBUS 断电测试） |
| `dtb/dtb_edit.py` | DTB 反编译→手术→重编译的自动化脚本 |
