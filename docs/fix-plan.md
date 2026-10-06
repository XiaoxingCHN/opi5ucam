# 修复可行性方案：RK3588 USB3 链路死亡（结合 Rockchip 新驱动）

> 2026-10-06。目标：不依赖人工拔插，在内核/系统层根治或大幅缓解
> SUA133GC USB3 链路静默死亡。前置事实见 [kernel-investigation.md](kernel-investigation.md)。

---

## 0. 已确证的机制链条（方案的事实基础）

1. **死亡形态**：bulk 流量戛然而止（usbmon：800 事件/s → 0，无错误事件），
   usbcore 保持僵尸枚举数小时，控制端点 EIO，只有 VBUS 断电能复活——
   相机固件挂死后**从不重新发起 LFPS 连接**；
2. **带宽饥饿加速**：DDR 带宽饱和下死亡从 10-20 分钟缩短到 30 秒~7 分钟
   （4 线程 memset hog 实测）→ 与 Firefly 论坛"MMU QOS 优先级升级"修复的
   同款症状（海康相机 NRDY→Unexpected 错误、帧率不稳）机制吻合；
3. **已排除**：interconnect QOS 块（fdf3e000/200/400/600，3 位优先级字段）
   调到最大无效；主线 usbdp PHY 驱动无相关修复；BSP 5.10 全树无
   USB3 MMU/QOS 节点；dwc3-rockchip glue（v16）动机是 Type-C gadget 重连；
4. **Firefly 修复**存在于其 v1.0.7+ SDK（FAE 私有补丁，公开渠道无细节）；
5. **主机侧能做的极限**：即使内核完美感知死亡，相机固件不重连 → 仍需断电复位；
   所以"内核级修复"的现实目标 = **让链路不死**（QOS 类）或**不死+自动复位 PHY**（新驱动类）。

---

## 方案一：USBDP/USB3 QOS 优先级注入（最可能复现 Firefly 修复）

**思路**：Firefly 修复的"MMU QOS 优先级"极可能是 Rockchip 新 SDK 里
USB3 主控 DMA 端口的 QOS 优先级（DRM/DDRC 仲裁层面），而非我调过的
interconnect QOS 块（那块调满无效已实测）。

**步骤**：
1. 取 RK3588 TRM Part1（公开 PDF），查 QOS 块寄存器语义——确认
   fdf3e000/200 块的 PRIORITY 编码（3 位字段已实测：写 0xF 读回 0x7）
   以及是否存在 DWC3 DMA 专用端口的 QOS 寄存器（0xfdf5 区域）；
2. 依 TRM 写"引导注入服务"（systemd oneshot，/dev/mem 或 regmap），
   将 USB3 DMA 端口优先级提到与 VOP/ISP 同级；
3. `hog_test.sh` A/B：饱和带宽下生存时间 ≥1200s ×3 轮 = 修复确认。

**成本**：TRM 检索 1-2h + 实现 2h + 验证 1h（工具全备）。
**风险**：低（写错值最坏 USB 挂 → 重启恢复）；若 TRM 显示 fdf3e 块即全部 → 转方案二。
**判据**：饱和下不再死亡 = 成功；死亡时间不变 = 该块非根因，转方案二。

---

## 方案二：移植上游 dwc3-rockchip glue 驱动 v16（结合"新驱动"的正统路线）

**思路**：Sebastian Reichel/Collabora 的 v16 系列（2026-09，6 补丁，未合入）
为 RK3588 引入真正的 dwc3 glue：**PHY 复位通知**（patch 4/6）+
post-PHY-registration hook（3/6）+ phy core notifier 基础设施（1/6）。
组合效果：**链路死亡事件可以触发 USBDP PHY 复位** → 链路重训练 →
不依赖相机断电的恢复路径（主机侧内建自愈）。

**步骤**：
1. 从 lore.kernel.org 取 v16 mbox（6 补丁，公开）；
2. 回移植到 5.10.209： phy core notifier（小，独立）、
   dwc3 core post-PHY hook（注意 BSP 的 dwc3/core.c 已被 Rockchip 改过——
   改动文件快照在 `ai-handoff-20261005/kernel-source-modified/` 可对照）、
   glue 驱动本体（新文件）、USBDP PHY 驱动的 notifier 对接（BSP usbdp.c 需小改）；
3. DTS：usbdrd3_0/1 节点挂 glue compatible + PHY reset 引用；
4. 板上重编译内核（config 现成，约 1-2h）+ 部署 + hog A/B
   （饱和下死亡 → 观察 glue 是否触发 PHY 复位 → 链路自愈？）。

**成本**：回移植 0.5-1 天 + 验证 0.5 天。
**风险**：中（6.x→5.10 回移植的 API 差异；glue 的 host 模式 PHY 复位行为需读补丁确认——
其动机偏 Type-C/gadget）；**收益**：即使不解决触发因素，也把"断电恢复"升级为
"PHY 复位恢复"（秒级、系统内完成）——比现行 VBUS 方案优雅一个量级。

---

## 方案三：获取 Firefly 修复固件做 diff（拿"标准答案"）

Firefly v1.0.7+ 固件的 DTB/内核里就写着他们改了什么：
1. 用户从 [Firefly 社区](https://community.t-firefly.com) 下载
   AIO-3588SJD4 v1.0.7+/v2.x 固件（百度盘/360）拷到板上（~2GB）；
2. 解包 update.img（rkImageMaker 格式，python 可解）→ boot 分区 →
   resource.img → DTB + 内核；
3. DTB diff：QOS 节点/USB 节点/DMC 节点逐一比对；
   内核 diff：strings/symbols 搜 qos/优先级相关新符号；
4. 命中的修复按方案一/二落地。

**成本**：下载 + 解包 + diff ≈ 半天。**风险**：无。**收益**：直接看到标准答案。

---

## 方案四：向 ainstecYang 索要补丁（社交路径，零成本）

在 [论坛 11646 帖](https://forum.t-firefly.com/t/topic/11646/13) 回帖追问
（13 楼 2025-04 已有人问过未获回复）——同时附上我们的分析仪级证据
（NRDY→Unexpected + 死亡时间线），大概率能换到 FAE 补丁或方向确认。

---

## 方案五：运行时缓解（保底，已部署）

- usb_recover.sh VBUS 断电自愈（30-60s 恢复）✓
- gpspoll/监视窗观测 ✓
- 建议：采流期间避免重度桌面负载（带宽争用是触发器）

---

## 推荐执行顺序与决策点

```
方案一（今天，2-5h，工具全备）
  ├─ 成功 → 固化为引导服务 + 修正文档结论 → 完结
  └─ 无效 → 方案三（要固件，半天）→ 拿到标准答案 → 回到方案一落地
                └─ 拿不到 → 方案二（glue 回移植，1-2 天）→ 即使不根治
                   也把恢复升级为 PHY 级秒级自愈
方案五贯穿全程保底。
```

**我的建议**：方案一现在就开始（TRM 检索 + 注入 + A/B）；同时请用户从
Firefly 社区下载 v1.0.7+ 固件（方案三的输入）。两者互补：方案一快，
方案三给标准答案。
