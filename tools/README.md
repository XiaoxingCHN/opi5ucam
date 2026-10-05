# 工具源码

| 文件 | 用途 | 构建 |
|---|---|---|
| `arv_grab.c` | 采集 + BGGR NN 去马赛克 → stdout RGB 流（预览/soak 基础程序）。参数：`秒数 [dump]`，每分钟打印 `frames=/dropped=/MISSING=` 统计行 | `gcc -O2 -o arv_grab arv_grab.c $(pkg-config --cflags --libs aravis-0.8)` |
| `wb_probe.c` | 白平衡实验：量化 baseline / AutoSel=off / WBOnce / RGain 拉高 / 20s 漂移 各状态下的 R/G/B 通道均值与增益读数 | 同上 → `sudo ./wb_probe` |
| `cfa_test.c` | **CFA 排布判别**（增益锚点法）：单独拉高 RGain / BGain，报告 Bayer 四个像素相位哪个响应 → 确定 S00/S11 是 B 还是 R | 同上 → `sudo ./cfa_test` |

依赖：Aravis 0.8.31（`PKG_CONFIG_PATH=/usr/local/lib/aarch64-linux-gnu/pkgconfig`），
root 运行（usbfs 权限，见 `../system/99-mindvision.rules`）。

三个工具都体现了同一套实验方法：**用可观测的因果杠杆（寄存器增益、受控开关）代替
猜测**——详见 [../docs/architecture.md](../docs/architecture.md) §2"锚点实验"。
