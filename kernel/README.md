# 内核补丁（4 commits）

基线：[Joshua-Riek/linux-rockchip](https://github.com/Joshua-Riek/linux-rockchip)
分支 `jammy`（5.10.209，commit `a2d0e7d7e`）。
工作分支 **`rk3588-usb-isoc-fixes`**，补丁以 git commit 形式保存：

| Commit | 主题 | 内容 |
|---|---|---|
| `3ef817a02` | usbdp PHY 主线化对齐 | 将 Rockchip 5.10 BSP 的 usbdp PHY 驱动与主线 v6.x 实现对齐（训练参数/时钟处理） |
| `7e58f1756` | DWC3 REFCLKPER/GFLADJ 回填 | 从设备树 ref-clock 频率正确回填 REFCLKPER/GFLADJ 寄存器（BSP 缺失导致 SS 时序参数漂移） |
| `16b6819fd` | DTS ref-clock | 为两个 usbdp/usbdrd 节点补充 ref-clock 属性 |
| `df1637036` | rk3588-orangepi-5-ultra.dts | 新增 Ultra 专用 DTS：禁用 HDMI0（修幻影屏）、OTG 使能脚 PB1（vbus-gpios）、LED 极性、风扇 PWM |

## 获取方式

```bash
git clone -b jammy https://github.com/Joshua-Riek/linux-rockchip
cd linux-rockchip
git checkout -b rk3588-usb-isoc-fixes a2d0e7d7e
git cherry-pick 3ef817a02 7e58f1756 16b6819fd df1637036
# 或 git format-patch a2d0e7d7e..rk3588-usb-isoc-fixes 导出
```

> 以上 commit 哈希对应本项目的内部工作分支；若仓库未公开，可按主题说明
> 在你的 5.10.209 BSP 树上自行实现——其中 **7e58f1756 + 16b6819fd**（ref-clock
> 时序回填）与 USB3 链路质量最相关，建议优先移植。

## 构建纪律（违反 = 黑屏/坏镜像）

1. 配置用**出厂配置**（`/boot/config-5.10.0-1012-rockchip`）+ `make O=build olddefconfig`；
   `rockchip_linux_defconfig` 缺 2858 项，会黑屏；
2. 装 `dwarves`（pahole），否则 `CONFIG_DEBUG_INFO_BTF=y` 编译失败；
3. **不用 initramfs**（关键驱动全内建），extlinux `root=PARTUUID=…` 直挂根
   （x86 交叉编译产的 initramfs 是 x86 二进制 → 板上 `No working init found` panic）。

```bash
make O=build -j32 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image dtbs modules
```

## 关于链路死亡缺陷

上述补丁**不能**根治 SUA133GC 的 SS 链路静默死亡（对照实验：原厂 6.1 BSP 同样复现），
但 ref-clock 修正对链路质量有普遍意义。根治需相机固件或 Rockchip PHY 深层修正
（已具备完整报障材料，见 [../docs/troubleshooting.md](../docs/troubleshooting.md) A1）。
本项目通过自愈栈（看门狗 + VBUS 电子拔插）绕开该缺陷。
