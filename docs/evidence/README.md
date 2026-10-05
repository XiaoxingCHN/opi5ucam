# 实测证据日志

全部为本项目开发过程中（2026-10-05）在板上实机采集的日志快照，用于支撑
[troubleshooting.md](../troubleshooting.md) 各案例的结论。

| 文件 | 内容 | 关键看点 |
|---|---|---|
| `camera-watchdog.log` | 看门狗全量日志（检测→恢复梯） | 20:41 `L3 dwc3-rebind revived`（14s 自愈）；20:45 起僵尸流形态（控制绿、流死）；20:52 L4 VBUS 复活 |
| `camera-soak.log` | 推流压测段汇总 | 20:56~20:58 三次 `DEATH → hard-recover → 复活 → 续段` 闭环；恢复后 80fps 全 SUCCESS 的段记录 |
| `ros-node-sample.log` | ROS 节点日志样本 | `white balance: mode=once, gains …`（WB 策略生效）；`out=bgr8 pattern=bggr` 启动参数 |

说明：
- 日志中时间戳为板载本地时间；`[ INFO]/[WARN]/[ERROR]` 为等级；
- 更早的 bus6/bus8 原始总线监视日志（cam-history*.log）位于 /tmp，因一次重启
  （DTB 手术生效所需）丢失；丢失前后的行为差异已由上表的看门狗/soak 日志完整覆盖；
- 日志不含任何凭据；主机名等本机标识请在上传公开仓库前自行斟酌是否脱敏。
