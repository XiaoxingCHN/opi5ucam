# DTB 手术：VBUS 软件可控化

## 背景见
[../docs/troubleshooting.md](../docs/troubleshooting.md) A2（regulator/gpio 三重权限墙）
与 [../docs/architecture.md](../docs/architecture.md) §1（L1 电气层手柄）。

## 脚本用法

```bash
# 0) 前置：板上装有 dtc（device-tree-compiler），从当前运行 DTB 反编译
dtc -I dtb -O dts /lib/firmware/5.10.209/device-tree/rockchip/rk3588-orangepi-5-ultra.dtb \
    -o /tmp/opi5u.dts
# 1) 手术
python3 dtb_edit.py     # → /tmp/dts-base.dts（SS）+ /tmp/dts-hs.dts（强制高速模式）
# 2) 编译 + 安装 + 备份 + 重启，完整步骤见 ../docs/deployment.md B 节
```

## 手术内容（对反编译 dts 的三处修改）

1. `vcc5v0-host`（gpio3_D5，usbdrd3_1 口 VBUS）与 `vcc5v0-otg`（gpio4_B1=PB1，
   usbdrd3_0 口 VBUS）两个 fixed-regulator：**摘除** `gpio` / `enable-active-high` /
   `pinctrl-*` 属性 → 变成无引脚的虚拟常供轨（u2phy 消费者无感知）；
2. 新增根节点 `vbus-recover`（`compatible = "gpio-leds"`）接管两个引脚：
   ```dts
   vbus-recover {
       compatible = "gpio-leds";
       vbus-host { gpios = <&gpio3 29 GPIO_ACTIVE_HIGH>; default-state = "on"; };
       vbus-otg  { gpios = <&gpio4 9  GPIO_ACTIVE_HIGH>; default-state = "on"; };
   };
   ```
3. HS 变体：另在两个 `usb@fc000000 / usb@fc400000`（dwc3）节点加
   `maximum-speed = "high-speed";` —— 彻底绕开有缺陷的 SS 链路（帧率上限 ~30fps）。

## 效果

VBUS 开关成为标准 LED sysfs（root）：

```bash
echo 0   > /sys/class/leds/vbus-host/brightness   # 断电（等效拔出相机）
echo 255 > /sys/class/leds/vbus-host/brightness   # 上电（9~13s 后重枚举）
```

这是全方案自愈能力的物理基础：链路死亡后由看门狗/ROS 节点自动断电重上电。

## 风险与回滚

- `default-state="on"` 保持开机行为与原厂一致；断电会连带 u2phy2/3 的 USB2 host 口
  （键鼠闪断重连，无害）；
- 修改前备份原 DTB（`~/dtb-backup/*.orig`），extlinux 保留原厂内核救援启动项；
  启动失败时 u-boot 选单选 `old` 救援。
