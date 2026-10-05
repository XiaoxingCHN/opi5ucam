# Orange Pi 5 Ultra / RK3588 USB3 等时传输修复内核 — 烧写与验证手册

## 一、产物清单

| 文件 | 说明 |
|---|---|
| `artifacts/Image` | 新内核（release = 5.10.209，含 3 个补丁） |
| `artifacts/rk3588-orangepi-5-max.dtb` | 新设备树（含 `snps,ref-clock-period-ns = <41>`） |
| `artifacts/System.map` / `config-5.10.209` | 符号表与配置 |
| `artifacts/modules-5.10.209.tar.zst` | /lib/modules/5.10.209（已 depmod） |
| `images/ubuntu-22.04-...-orangepi-5-max-usbfix.img` | 官方 v2.4.0 镜像 + 注入新内核，可直接烧写 |
| `patches/0001..0003.patch` | 三个源码补丁（git format-patch） |

## 二、烧写

推荐直接烧 `images/*.img`（已在官方镜像基础上注入）：

```bash
# Windows 下用 Rufus / balenaEtcher；Linux 下：
xz -d 无需（产物已是 .img）
sudo dd if=ubuntu-22.04-preinstalled-desktop-arm64-orangepi-5-max-usbfix.img of=/dev/sdX bs=4M status=progress oflag=direct sync=direct
```

如果只想在现有系统上替换内核（不重刷）：把 `artifacts/` 传到板上后

```bash
sudo cp Image /boot/vmlinuz-5.10.209
sudo cp rk3588-orangepi-5-max.dtb /boot/dtb-5.10.209/rockchip/   # 布局按现有 /boot 探测
sudo tar -C / -xf modules-5.10.209.tar.zst
sudo depmod -a 5.10.209
# 修改 /boot/extlinux/extlinux.conf（或 /boot/firmware/extlinux/extlinux.conf）
#   linux /boot/vmlinuz-5.10.209
#   fdtdir /boot/dtb-5.10.209/rockchip/
sudo update-initramfs -c -k 5.10.209    # 如引导需要 initrd
```

确认版本：`uname -a` → `Linux ... 5.10.209 ...`

> **引导说明（v5 镜像起）**：新内核条目**不使用 initramfs**（全部引导关键驱动内建，内核经 PARTUUID 直挂根）。首次启动 systemd 会通过 `x-systemd.growfs` 自动把根文件系统扩展到整张卡，属正常现象。如后续需要 initramfs（例如换根设备），在板上执行 `sudo update-initramfs -c -k 5.10.209` 生成 arm64 initrd，并在 extlinux 对应条目加回 `initrd /boot/initrd.img-5.10.209` 一行。

## 三、验证协议（对应任务书步骤 5，共 30+ 分钟）

```bash
# 终端 1：全量日志
sudo dmesg -wT | tee /tmp/usbfixed-dmesg.log | grep -iE 'xhci|dwc3|usb|eproto|reset|cdr|lcpll'
```

```bash
# 终端 2：确认控制器与 PHY 挂载
lsusb -t                    # 相机应挂在 5000M 总线上
ls /sys/bus/platform/drivers/dwc3-of-simple/
cat /sys/kernel/debug/usb/devices | grep -A3 -B1 'SuperSpeed'
v4l2-ctl --list-formats-ext -d /dev/video0   # 确认 SuperSpeed 模式的格式表
```

```bash
# 终端 3：持续采集 ≥30 分钟（以 ffmpeg 为例，yuv4mpeg 落盘或丢到 null）
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=YUYV
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 -i /dev/video0 \
       -c copy -f null -timeout 36000000 -
```

### 判定标准

| 观察点 | 通过 | 失败 |
|---|---|---|
| 30 分钟连续采集 | 无 `Non-zero status (-71)` | 出现 -71 / EPROTO |
| `reset SuperSpeed USB device` | 0 次 | ≥1 次 |
| usbdp PHY 日志 | 无 `lcpll lock timeout` / `cdr lock timeout` | 出现则记录时间点 |
| 掉线后恢复 | 拔插后恢复，或不再需要拔插 | 需要断电 |
| 采集静默阻塞（无报错） | 不出现 | ffmpeg/v4l2 无输出且无 dmesg 报错（RK3588 USB3 相机故障的另一种发作形态，参考 Neardi 论坛 #199：`Failed to query (GET_DEF) UVC control 3 ... -32` + 采集阻塞） |

> 注意：`Failed to query (GET_DEF) ... -32 (EPIPE)` 单独出现**不一定致命**——很多工业相机固件不实现某 XU 控制的 GET_DEF，x86 上也会打这条；但若伴随采集阻塞/端点停摆，则与本问题的 -71 风暴同属链路层失败谱系，都应记录。

### 三个补丁各自的验证信号

1. **usbdp 主线化对齐（0001）**
   - 若 CDR 失锁被拦截：`dmesg` 出现 `disable u3 port because udphy not ready`（这是新逻辑生效的证据；出现它说明链路训练本身有问题，需要下一层排查）。
   - 若 LCPLL 检测通过且无 timeout：说明新的 `{0x00D4,...}` 初始化顺序工作正常。
2. **DWC3 REFCLKPER/GFLADJ（0002+0003）**
   - 板上验证寄存器：
     ```bash
     # usbdrd_dwc3_1（Type-A USB3 所在控制器）基址 0xfc400000
     sudo devmem 0xfc40c12c      # GUCTL: 期望 bit[31:22]=41 (0x0A400000 附近)
     sudo devmem 0xfc40c630      # GFLADJ: 期望 bit[21:8]=fladj 修正值
     ```
   - `snps,ref-clock-period-ns` 是否被解析：`dmesg` 无 "Unknown property" 报错；或在 `drivers/usb/dwc3/core.c` 的 `dwc3_ref_clk_period` 里临时加 `dev_info` 重编验证。
3. **基线对照**：先烧原版 v2.4.0 镜像跑同样 30 分钟并留存 dmesg，再烧修复版对比（复现时间窗口 10–276 秒内的话，30 分钟即可给出明确结论）。

## 四、如果仍然复现

若三个补丁上板后 30 分钟内仍出现 -71 风暴与 `reset SuperSpeed`：
1. 源码证据显示：DTS quirks（=原厂 6.1）、xHCI 等时路径（≈主线 6.6）、combphy（5.10/6.1 无差异）、glue（of-simple）全部排除；Rockchip 自己的 6.1 BSP 从未修改过这些文件中的等时相关代码。
2. 此时软件层剩余可查的只有 usbdp PHY 的模拟参数细节与 LCPLL/CDR 状态机，再往下就是 RX 信号完整性/LFPS 互操作（FX3 相机在 NVIDIA Orin 等 DWC3 平台也有同类报告）。
3. 建议抓取：`usbmon`（CONFIG_USB_MON）在 SS 总线上抓包看最后一帧的方向与错误类型，以及用示波器/眼图确认硬件层。
