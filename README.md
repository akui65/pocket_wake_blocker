# 口袋防误触（双击亮屏保护）

HyperOS3 / Android16 息屏防误触 KernelSU 模块。

手机在口袋中时，双击亮屏 / 拿起亮屏等误触会被自动拦截并立即息屏；电源键亮屏、手移开后均正常亮屏，无迟滞感。

## 功能特性

- **双击亮屏拦截**：点亮瞬间检测接近传感器，若为"近"（手机在口袋）则立即强制息屏
- **电源键豁免**：电源键亮屏不检测距离传感器，直接放行
- **现场采样优先**：唤醒瞬间连续读取接近传感器，手移开即放行，无迟滞感
- **常驻采样守护**：内置 `sensor_keepalive` 守护进程持续启用接近传感器（on-change 型），遮挡/移开实时上报 0=近/5=远，息屏后立即盖住也能即时拦截
- **按状态启停**：守护进程仅在息屏（OFF/DOZE）时运行，亮屏即停，零额外开销
- **极低功耗**：守护主循环强制节流（200ms/轮）+ 0.2Hz 低频采样，CPU 占用 <1%
- **轻量探测**：屏幕状态优先读 `dumpsys power`（比 `dumpsys display` 轻一个数量级）
- **降级保护**：守护离线时自动降级为新鲜度判定，避免传感器休眠时陈旧读数误熄屏

## 适配环境

- **系统**：HyperOS3 / Android16
- **接近传感器**：昇佳 stk_stk3a7x（on-change 型，0.00=近，5.00=远）
- **触摸屏**：Goodix（双击亮屏为 framework 层实现）
- **电源键**：pmic_pwrkey 设备（/dev/input/event3）
- **框架**：KernelSU（需 root）

## 工作原理

1. 双击亮屏为 framework 层实现，无法在"点亮前"禁用 → 采用"点亮后立即强制息屏"兜底方案
2. 接近传感器 stk_stk3a7x 无 sysfs 节点，通过 `dumpsys sensorservice` 读取"最近事件"最后一条
3. 传感器平时休眠，只有被系统激活采样时才上报 → 内置 `sensor_keepalive` 守护进程持续启用该传感器
4. 守护进程仅在息屏时运行，亮屏即停（防误触只发生在息屏阶段）
5. 唤醒瞬间：电源键触发 → 放行；现场读为远 → 放行；现场持续近 → 强制息屏

## 安装

1. 下载模块 zip 包
2. 在 KernelSU 管理器中安装模块
3. 重启设备
4. （可选）编辑配置文件 `/data/adb/pocket_wake_blocker.conf`

> **注意**：升级模块时，已存在的配置文件会被保留（不会被默认配置覆盖）。若新版本新增了配置项，需手动添加或删除旧配置文件后重装。

## 配置说明

配置文件：`/data/adb/pocket_wake_blocker.conf`

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `POLL_INTERVAL` | `1.0` | 息屏/DOZE 状态轮询间隔（秒），双击拦截响应粒度 |
| `POLL_INTERVAL_ON` | `2` | 亮屏状态轮询间隔（秒），只需捕捉 ON→OFF 边缘 |
| `PROX_POLL_EVERY` | `12` | 息屏时每 N 轮缓存一次接近值（约 12 秒一次，低频兜底） |
| `CONFIRM_DELAY` | `0.2` | 检测到"近"后二次确认延迟（秒），避免单次误判 |
| `FRESH_AGE` | `2` | 守护离线时，接近事件新鲜度阈值（秒），超过则视为无遮挡 |
| `POWER_KEY_WINDOW` | `2` | 电源键按下后该秒数内的亮屏直接放行 |
| `DEBUG` | `0` | 调试开关，1 输出更详细日志 |

## 调试

运行调试脚本（root 终端）：

```sh
sh /data/adb/modules/pocket_wake_blocker/prox_test.sh
```

查看运行日志：

```sh
cat /data/local/tmp/pocket_wake_blocker.log
```

## 编译 sensor_keepalive

仓库中不包含编译好的二进制，需自行编译：

```sh
# NDK r28, aarch64
aarch64-linux-android35-clang -O2 -Wall -o sensor_keepalive \
    sensor_keepalive.c -landroid -llog -static-libgcc
```

编译后将 `sensor_keepalive` 放入模块目录，确保可执行权限（`chmod 755`）。

## 文件结构

```
pocket_wake_blocker/
├── module.prop          # 模块元信息
├── customize.sh         # 安装脚本（部署配置、设置权限）
├── service.sh           # 常驻服务（主循环、传感器判定、强制息屏）
├── default.conf         # 默认配置文件
├── prox_test.sh         # 调试工具脚本
├── sensor_keepalive.c   # 接近传感器常驻采样守护进程源码
└── README.md
```

## 版本历史

### v1.7
- **功耗优化**：守护进程主循环强制节流（200ms/轮），修复事件风暴导致 106% CPU 的问题
- **采样率降至 0.2Hz**：on-change 传感器遮挡/移开仍实时上报，周期上报型 HAL 事件流降 5 倍
- **守护按屏幕状态启停**：仅息屏时运行，亮屏即停，零额外开销
- **轮询降频**：息屏轮询 0.4s→1s，亮屏轮询 2s，缓存读取降至每 12 轮一次
- **轻量屏幕探测**：优先读 `dumpsys power`（比 `dumpsys display` 轻一个数量级）

### v1.6.2
- 修复电源键监听设备选择：优先 pmic_pwrkey 类电源键专用设备，避免误选触摸屏
- 修复 awk `exit` 后 `END` 仍执行的 bug

### v1.6.1
- 电源键监听进程自愈检查 + 启动失败验证
- 新增电源键最近事件诊断文件

### v1.6
- 新增 `sensor_keepalive` 常驻采样守护进程，解决息屏后立即盖住传感器不上报的问题
- 守护在线时读到"近"即拦截，离线时降级为新鲜度判定

### v1.5
- 新增电源键亮屏豁免（getevent 监听 + 2s 窗口放行）
- 新增 FRESH_AGE 新鲜度判定兜底，解决无遮挡却自动熄屏的问题

### v1.4
- 修复"捂住→快速移开→双击仍熄屏"迟滞感，改为唤醒瞬间现场连续采样

### v1.3
- 作者署名更新，描述重写

### v1.2
- 息屏阶段缓存接近值 + 唤醒瞬间"缓存+新鲜读"双路判定
- 用 awk 精确取块，修复窗口越界误读相邻传感器值

## 作者

酷安@HelllC

## 许可证

MIT License
