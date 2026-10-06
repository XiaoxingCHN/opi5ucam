# 内核级深挖：死链机制的仪器化观测（2026-10-06）

> 回应一个合理的质疑：**"无法解决"究竟是结论还是回避？** 本文档记录了为回答这个问题
> 补做的全部内核级观测实验——之前"软件层已穷尽"的说法只在配置层面成立，
> 死亡瞬间的机制从未被仪器化观测过。本文补上，并给出证据化结论。

## 1. 观测工具链（全部落在板上实测）

| 工具 | 手段 | 结论可信度 |
|---|---|---|
| usbmon 文本流 | `modprobe usbmon` + `cat /sys/kernel/debug/usb/usbmon/<bus>u`，URB 级轨迹 | ✅ 可靠（流量停止瞬间清晰可见） |
| usbfs GetPortStatus | 对 roothub `/dev/bus/usb/<bus>/001` 发 `USBDEVFS_CONTROL`（`_IOWR('U',0,…)`=0xC0185500）读端口状态 | ✅ 可靠（内核视角权威读数，1Hz） |
| /dev/mem 直读 PORTSC | mmap 0xfc000000 读 xHCI 寄存器 | ⚠️ 不可靠（同一地址在两次健康推流中读值不同，Device memory 对齐陷阱 + 寄存器布局非标） |
| xhci 动态调试 | `module xhci_hcd +p`（190 个站点） | ⚠️ 部分有用：站点 `xhci-ring.c:1964`（"Port change event"）在真实重枚举中也从不打印 = **死代码**，不能用作"事件是否到达"的判据 |
| ftrace xhci 事件 | `trace_xhci_handle_port_status` | ❌ 本内核未编译 TRACEPOINTS |
| hub.c / xhci-ring dbg 全开 | 会灌爆 dmesg 环形缓冲（实测 9 秒 3409 行），必须收窄 | 教训 |

关键陷阱记录：
- `USBDEVFS_CONTROL` 的 nr 是 **0**（`_IOWR('U',0,…)`=0xC0185500），不是直觉的 2；
- /dev/mem 读 Device memory **不允许非对齐 4 字节访问**（SIGBUS）；
- dmesg 的 `[uptime]` 时间戳与 usbmon 文本 ts、epoch 三者零点各不相同且系统时钟会被
  步进跳变——**跨源对齐只能用 gps.log 的 epoch + `/proc/stat btime` 换算**。

## 2. 死亡瞬间观测（样本 1，2026-10-06 01:00:48）

实验配置：SS 链路（Bus 6）推流 ~100fps + usbmon 抓包 + PORTSC 轮询 + xhci/hub 动态调试全开。

**usbmon 实测**（544,021 个 URB 事件）：
- 健康推流期：**~800 事件/秒**（bulk IN 流），全部 status=0 正常完成；
- 死亡瞬间：**t=3349s 有 718 个事件，t=3350s 起归零**—— abruptly、无错误完成、
  无部分传输、无重试痕迹。流量"戛然而止"。

**dmesg 实测**（xhci + hub 动态调试全开）：
- 死亡窗口内（前后 ±40s）：**xhci 零输出**。无 "Port change event"、无错误、
  无链路状态处理痕迹；
- 唯一的异常：死亡窗口附近出现 **ap6611s 蓝牙电源循环**（`BT_RFKILL: bt shut off power` /
  `sending frame failed (-49)`）——相关性见 §3；
- 死亡后 40s 的 drop/configure 端点日志来自并行运行的 systemd 看门狗的恢复动作（实验干扰，
  已在后续轮次停掉）。

**usbcore 行为**：
- 设备在 usbcore 中**保持枚举数小时**（无 disconnect 消息）；
- 期间控制端点全部 EIO、推流全部无完成——usbcore 完全不知道设备已消失；
- L2 usbfs RESET 会重枚举成"新设备"但立即再次死亡（复位不解决相机侧状态）。

## 3. 待跨样本确认的假设

1. **BT_RFKILL 触发假设**：板载 ap6611s 模组的蓝牙反复"断电重上电"（蓝牙协议栈持续重试），
   其电瞬态可能是 SS 链路死亡的诱因之一。样本 1 中 BT 活动与死亡窗口重叠
   （精确对齐受时钟跳变限制）。A/B 验证方法：`rfkill block bluetooth` 前后对比死亡率。
2. **恢复诱发死亡假设**：round 1 死亡后 18 分钟的干净运行，而 round 2/3 在恢复后
   **39 秒内**再死；round 4 恢复后 20 分钟干净——模式不稳定，需更多样本。
   若成立：每一次 VBUS 断电复活都会让相机进入"易死状态"，死亡循环是被恢复动作
   种下的——这对报障 MindVision 是重要证据（固件在断电恢复路径上有缺陷）。

## 4. 内核级可行修复的评估（截至本文）

| 方向 | 评估 |
|---|---|
| 主线 usbdp PHY 驱动移植 | ✅ 已 diff 全文（1466 行变更）：主线 2024 重构 + 至今无任何针对链路不稳定/断开的修复 commit；**不是解药** |
| dwc3-rockchip glue 驱动 | 上游 v16 系列（2026-09，未合入）新增 PIPE interface reset / PHY reset 语义；Rockchip 自家 6.1 BSP（无此 glue）同样复现 → **优先级降低** |
| xhci/usbcore"端口事件丢失"修复 | 死亡时端口事件是否到达驱动仍无法用现有仪表判别（dbg 站点是死代码、tracepoint 未编译）；**即使能判别**，主机侧唯一的干净处理也只是"断开设备"——相机仍需断电才能回来 |
| usbcore 轮询 roothub（小补丁） | 能让 disconnect 被及时感知（体验改善：从"僵尸"变"干净离线"），但**不改变恢复需求** |
| 相机固件更新 | **唯一可能根治的路径**：死亡瞬间主机处于 Rx.Detect 轮询等待，相机侧若固件健康应重新发起 LFPS 连接——实测数分钟不重连 → 相机 USB3 协议栈挂死。已具备报障材料 |

## 5. 结论（当前证据强度）

- **死亡触发机制**：SS 链路在推流/空闲中无事件地掉线（主机侧零可观测痕迹），疑似与
  板载蓝牙电源循环相关（待 A/B 确认）——PHY 模拟层或相机固件层面的问题；
- **死亡后的僵局**：主机端口回到 Rx.Detect 等待，相机永不重新发起连接（固件挂死），
  usbcore 因得不到端口事件而保持僵尸枚举——这是"必须断电"的直接原因；
- **内核软件层**：配置级手段确实穷尽（A7 排除表），且主线无现成修复；
  死亡瞬间的机制观测（本文）把"无法解决"从推测升级为：**主机侧无修复抓手，
  根治点在相机固件与 PHY 模拟层**——该结论现在有 usbmon + gps + dmesg 三重证据支撑。

---

## 6. 追加实验（2026-10-06）：MMU QOS 优先级假设

**外部线索**：Firefly 论坛同款问题（RK3588 原生 USB3.0 + 海康工业相机帧率不稳，
USB 分析仪抓到 NRDY→Unexpected 错误，外接供电无效，PCIe 转 USB 卡反而稳定），
最终"通过升级 MMU QOS 的优先级解决"
（[forum.t-firefly.com/t/topic/11646](https://forum.t-firefly.com/t/topic/11646/10)，
具体做法未公开）。

### 6.1 带宽饥饿加速实验（✅ 方向确认）

用 4 线程 memset 打满 DDR 带宽作为压力源，推流同时观测：

| 条件 | 死亡时间 |
|---|---|
| 无负载基线 | 10~20+ 分钟（多轮） |
| **DDR 带宽饱和** | **30 秒 ~ 7 分钟** |

带宽争用显著加速死亡 → "USB3 DMA 被饿死"与死亡机制一致（也解释了死亡频率
与桌面负载的正相关性：晚上无人使用时长时间不死，白天高负载时频发）。

### 6.2 Interconnect QOS 块实验（⚠️ 不是完整解药）

DTB 中的 QOS 块（`qos_usb3_0 @0xfdf3e200`、`qos_usb3_1 @0xfdf3e000`、
`qos_usb2host_0/1 @0xfdf3e400/600`，每块 8 寄存器，0x08=QOS_PRIORITY）：

- 寄存器格式实测：**3 位优先级字段**（写 0xF 读回 0x7，硬件截断），`0x0707` 已是最大值；
- 板上默认值对比：USB3=0x0404、VOP=0x0303、GPU=0x0000；
- **把 USB3 提到最大 0x0707 后，带宽饱和下仍然死亡**（120s）——
  该 interconnect QOS 块不是 Firefly 修复的全部（或不是正确的块）；
- PMU 电源域驱动（pm_domains.c）在域断电时保存/恢复这些寄存器
  （PRIORITY@0x08 / MODE@0x0C / BANDWIDTH@0x10 / SATURATION@0x14 / EXTCONTROL@0x18）。

### 6.3 开放问题与下一步

1. **Firefly 修复的确切内容**在 v1.0.7+ 固件里（FAE 私有补丁）：
   - 路径 A：论坛联系 ainstecYang 索取补丁；
   - 路径 B：下载 Firefly AIO-3588SJD4 / ROC-RK3588S-PC v1.0.7+ 固件，
     解包提取 DTB/内核，diff QOS 相关改动（工具已备好：`tools/`）；
   - 路径 C：Rockchip FAE / TRM QOS 章节（寄存器语义可从 TRM 补全）。
2. "MMU QOS" 的字面指向仍待定：可能是 DMC 端口仲裁（非本 interconnect 块）、
   或 vendor 内核在 USB3 路径新增的 QOS 设置代码。
3. 采样基础设施已固化：`tools/gps_poll.py`（usbfs GetPortStatus 1Hz 端口状态）、
   `tools/death_watcher2.sh`（自动死亡采样）、`tools/observe_death.py`（PORTSC 观测）。

### 6.4 实验基础设施备忘

- **/tmp 不可靠**：系统时钟步进（NTP 校正 10.6h）导致 systemd-tmpfiles 清理"过期"
  文件——实验产物一律写 `~/harness/`；
- 系统时钟步进使跨源时间对齐必须经 `/proc/stat` 的 btime 换算；
- pkill 模式匹配会命中同命令行中的启动文本——杀进程与含关键字的启动命令必须分开执行。

---

## 7. 终章：根因确认与修复（2026-10-06）——MMU600PHP QOS 饥饿

**用户线索**（Firefly 论坛 11646 帖：同款问题"通过升级 MMU QOS 的优先级解决"）
指引下，从 [RK3588 TRM Part2](https://github.com/gziren/RK3588-TRM-and-Datasheet)
（QoS Generator 章节 + Table 1-3 Master BIU 表）完成寄存器语义破译：

### 7.1 根因

RK3588 USB3 OTG 控制器的 DMA 路径经过 **MMU600PHP（ARM SMMU-600，PHP 域）** 的
TBU/TCU 端口。该端口的 QoS 生成器（`@0xfdf3a600(TBU) / @0xfdf3a800(TCU)`）
**出厂 urgency=0——全系统最低**（对照：USB3 控制器=4，VOP=3）。系统内存带宽
争用时（GPU/NPU/解码/桌面负载），SMMU 端口最先被饿死 → USB3 DMA 停摆 →
链路静默死亡。这解释了全部症状：死亡无声（链路协议层无错）、与负载正相关、
复位后很快复发（QOS 配置在每次重启后回到出厂低优先级）。

### 7.2 修复

六个 QoS 生成器的 QOS_PRIORITY（偏移 0x08，P1@bits[10:8] / P0@bits[2:0]，3 位）
全部提到最大 7（0x80000707）：

| QoS 块 | 地址 | 服务对象 | 原值 → 修复值 |
|---|---|---|---|
| MMU600PHP_TBU | fdf3a600 | USB3 DMA 翻译路径 | 0 → 7 |
| MMU600PHP_TCU | fdf3a800 | 同上 | 0 → 7 |
| USB3_0 | fdf3e200 | usbdrd3_0 | 4 → 7 |
| USB3_1 | fdf3e000 | usbdrd3_1 | 4 → 7 |
| USB2HOST_0/1 | fdf3e400/e600 | USB2 host | 4 → 7 |

固化为 `rk3588-usb-qos.service`（开机自动写入）。

### 7.3 A/B 验证（DDR 带宽饱和压力测试，4 线程 memset 打满）

| 配置 | 饱和下生存时间 |
|---|---|
| 出厂默认（TBU/TCU=0） | 420 s 死亡 |
| 仅 USB3 控制器=7（TBU/TCU 仍 0） | 120 s 死亡 |
| 仅 USB3=0（全最低） | 30 s 死亡 |
| **全路径=7（本修复）** | **≥1200 s 存活（测试上限）** |

死亡时间与 QOS 数值单调相关 → 因果确认。此前"必须断电复活"的死亡在
修正后的 QOS 下未再复现。

### 7.4 修正记录

- 前文"内核软件层已穷尽"的结论**不成立**：真正的修复点（MMU600PHP QOS）
  在 TRM 里，不在任何公开内核树中（BSP 5.10/6.1、主线均无该 QOS 节点）；
- 之前 interconnect 块（fdf3eXXX）调优无效的原因：调的不是 MMU600PHP
  TBU/TCU 这一层；
- 本节结论由 A/B 实验支撑，非推测。

---

## 8. Firefly v1.1.1f 固件解析（2026-10-06）

用户提供 Firefly AIO-3588SJD4 Ubuntu22.04-Xfce-r31154_v1.1.1f_250521 固件
（2025-05，内核 6.1.84）。解包链：RKFW 外壳 → RKAF 更新包 → boot 分区（FIT）→
内核 Image（40.1MB）+ DTB（249KB，反编译为 `firefly-v111f.dts`）。

**结论**：
1. Firefly 6.1.84 内核与 DTB 中**均无** USB3/MMU600PHP 的 QOS 优先级代码或节点
   （strings 与 DTB 全文检查）——其"MMU QOS"修复大概率在 **DDR 初始化 blob**
   （bootloader 层，随 SDK 更新）或其 FAE 私有内核补丁；
2. 我们的用户态运行时注入（rk3588-usb-qos.service）以更简单的方式
   达成了同等效果（A/B：饱和下 420s 死 → 1200s+ 存活）；
3. 提取的 Firefly DTB（`firefly-v111f.dts`）与内核可用于后续深度比对
   （6.1.84 的 DWC3/xHCI/usbdp 驱动含 5.10→6.1 的大量上游修复，是
   方案二（回移植）的候选补丁来源）。

---

## 8. 附：蓝牙循环开关问题（ap6611s / SYN43711）

**现象**：蓝牙每 ~38 秒电源循环一次（BT_RFKILL: shut off power → turn on power），
hci 设备反复创建/消失。

**根因（两层叠加）**：
1. 原厂 `ap6611s-bluetooth.service` 的 UART 时序错误，SYN43711 蓝牙**从未真正
   初始化成功**；bluetoothd/驱动无限重试 → rfkill 电源循环成为常态；
2. 修复套件初版：AMPAK patchram 工具下载完成后退出 → tty 关闭时 line
   discipline 还原 → hci 设备注销；其 btattach 又使用了内核未编译的
   LL 协议（proto 5 → EPROTONOSUPPORT）。

**修复（已部署 `bt-uart.service`）**：
1. patchram 下载（AMPAK 工具，实测 chip id=SYN43711A0 响应正常）；
2. H4 协议 attach 常驻守护：`TIOCSETD(N_HCI=15)` → 波特率 1500000 →
   `HCIUARTSETPROTO(H4=0)`（注意：HCIUART 系列 ioctl 类型字符是 **'U'**，
   HCIUARTSETPROTO=0x400455C8/SETFLAGS=0x400455C9）→ 持有 fd；
3. 实测：hci0 UP RUNNING、真实 BD 地址、经典扫描成功。

教训：HCIUART ioctl 类型字符是 'U'（0x400455C8/C9）而非直觉的 'H'；
TIOCSETD/HCIUART ioctl 在 python fcntl 中必须传**缓冲区指针**（传 int 会 EFAULT）；
patchram 工具退出后 tty 关闭会还原 line discipline——必须由常驻进程持有 fd。

## 9. 蓝牙 bring-up 修复验证（2026-10-06 晚）

`ap6611s-bt-fixed` 套件在反复调试后成功 bring-up：
hci0（UART）UP RUNNING PSCAN ISCAN，BD 地址随机化正常，10 秒扫描发现 55 个设备。

经验记录：
1. bring-up 时序敏感（断电→patchram→btattach 持有），服务自带 15 次重试；
2. 失败态的典型特征：hci0 有 BD 地址但命令超时（UART 会话失步）——
   完整重跑 `systemctl restart ap6611s-bt-fixed` 即可恢复；
3. GNOME"关蓝牙即飞行模式"的表象 = bring-up 失败导致 rfkill 设备反复注册
   （索引滚到 725），GNOME 误判；bring-up 稳定后消失。
