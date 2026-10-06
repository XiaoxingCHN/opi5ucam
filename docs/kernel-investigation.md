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
