#!/system/bin/sh
# ==============================================================
#  口袋防误触 v1.7 - 调试工具
#  用法（root 终端）：
#    sh /data/adb/modules/pocket_wake_blocker/prox_test.sh
#  用途：查看屏幕状态、接近传感器最近事件、判定结果、
#        常驻采样守护状态、模块运行状态与日志。
# ==============================================================

echo "============================================"
echo "  口袋防误触 v1.7 - 调试工具"
echo "============================================"

echo
echo "---- 1. 屏幕状态 ----"
dumpsys display 2>/dev/null | grep -m1 "mScreenState=" | sed 's/^/     /'
dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | sed 's/^/     /'

echo
echo "---- 2. 最近唤醒原因 ----"
dumpsys power 2>/dev/null | grep -iE "wake.?reason" | head -1 | sed 's/^/     /' || echo "     (无)"

echo
echo "---- 3. 常驻采样守护进程（sensor_keepalive，仅息屏时运行） ----"
DAEMON_BIN="/data/adb/modules/pocket_wake_blocker/sensor_keepalive"
DAEMON_PIDFILE="/data/local/tmp/sensor_keepalive.pid"
if [ -x "$DAEMON_BIN" ] && [ -f "$DAEMON_PIDFILE" ]; then
    pid=$(cat "$DAEMON_PIDFILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        echo "     运行中 (pid $pid)"
        ps -A 2>/dev/null | grep "sensor_keepalive" | head -1 | sed 's/^/     /'
    else
        echo "     进程已退出（pid $pid 不存在）"
    fi
elif [ -x "$DAEMON_BIN" ]; then
    echo "     未运行（屏幕亮着时正常，息屏后模块会自动启动）"
else
    echo "     未运行（二进制缺失）"
fi

echo
echo "---- 4. 电源键监听（power key bypass） ----"
PWR_DEV_FILE="/data/local/tmp/power_key_dev"
PWR_TS_FILE="/data/local/tmp/power_key_ts"
PWR_LAST_FILE="/data/local/tmp/power_key_last"
dev=$(cat $PWR_DEV_FILE 2>/dev/null || true)
if [ -n "$dev" ]; then
    name=$(getevent -lp 2>/dev/null | awk -v d="$dev" '
        /add device/ { found=($0 ~ d); next }
        found && /name: *"/ { sub(/^ *name: *"/, "", $0); sub(/".*$/, "", $0); print; exit }
    ')
    echo "     设备: $dev${name:+ ($name)}"
else
    echo "     设备: （无）"
fi
if [ -f "$PWR_DEV_FILE" ]; then
    if pgrep -f "geteven[t] -l $dev" >/dev/null 2>&1; then
        echo "     监听进程: 运行中"
    else
        echo "     监听进程: 已退出（模块每 10 秒会自动重启）"
    fi
else
    echo "     监听进程: 未启动"
fi
echo "     最近电源键时间戳: $(cat $PWR_TS_FILE 2>/dev/null || echo '（无）')"
echo "     最近电源键事件:   $(cat $PWR_LAST_FILE 2>/dev/null || echo '（无，按一下电源键后应有内容）')"
echo "     （应选 pmic_pwrkey 类电源键设备，而非 goodix_ts 触屏）"

echo
echo "---- 5. 接近传感器（stk_stk3a7x）最近事件 ----"
dumpsys sensorservice 2>/dev/null | grep -m1 -A20 "stk_stk3a7x Proximity Sensor Wakeup: last" | sed 's/^/     /'

echo
echo "---- 6. 当前接近值判定（锚定 stk，awk 精确取块） ----"
line=$(dumpsys sensorservice 2>/dev/null | awk '
    /stk_stk3a7x Proximity Sensor Wakeup: last/ { inc=1; next }
    inc && /: last [0-9]+ events/     { exit }
    inc && /\(ts=/                    { last=$0 }
    END { if (last != "") print last }
')
if [ -z "$line" ]; then
    echo "     （读不到接近事件 → 常驻守护开启后应始终可读）"
else
    val=$(echo "$line" | sed 's/.*) //' | cut -d',' -f1 | tr -d ' ')
    echo "     最近事件: $line"
    case "$val" in
        0|0.0|0.00|0.000|0.0000) echo "     判定: NEAR（近，会拦截亮屏）" ;;
        5|5.0|5.00|5.000)        echo "     判定: FAR（远，正常亮屏）" ;;
        *)                       echo "     判定: RAW:$val（异常/残留值，说明取块窗口可能越界）" ;;
    esac
fi

echo
echo "---- 7. 模块运行状态 ----"
ps -A 2>/dev/null | grep -c "service.sh" | sed 's/^/     service.sh 进程数: /'
tail -n 12 /data/local/tmp/pocket_wake_blocker.log 2>/dev/null | sed 's/^/     /' || echo "     （暂无日志）"

echo
echo "---- 提示 ----"
echo "     v1.7 功耗优化：传感器守护只在息屏时运行（亮屏自动停止，"
echo "       息屏自动启动），且主循环已节流，CPU 占用应极低。"
echo "       验证：息屏后第 3 节应显示运行中；亮屏后应显示未运行。"
echo "     息屏守护开启后，捂住传感器 → 最近事件应变 0.00（NEAR），"
echo "       松开 → 5.00（FAR）。"
echo "     电源键放行验证：按一下电源键亮屏，然后看第 4 节的"
echo "       '最近电源键事件' 是否有内容、时间戳是否更新。"
echo "     若误触未被拦截，请查看 /data/local/tmp/pocket_wake_blocker.log"
echo "============================================"
