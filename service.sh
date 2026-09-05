#!/system/bin/sh
# ==============================================================
#  口袋防误触（双击亮屏保护）v1.7 - 常驻服务
#
#  本机适配（HyperOS3 / Android16 / Goodix 触摸屏 / 昇佳 stk_stk3a7x）：
#  · 双击亮屏为 framework 层实现（Goodix double_en 节点无效），
#    无法在“点亮前”禁用 → 采用“点亮后立即强制息屏”兜底方案。
#  · 接近传感器 stk_stk3a7x 无 sysfs 节点，通过 dumpsys sensorservice
#    读取“最近事件”最后一条：0.00=近，5.00=远。
#
#  关键处理逻辑：
#   · 传感器常驻采样守护（sensor_keepalive）：持续启用 stk_stk3a7x
#    （on-change 型，启用后遮挡/移开实时上报 0/5）。v1.7 起：
#      - 守护进程主循环强制节流（200ms/轮）+ 采样率 0.2Hz，
#        修复事件风暴导致 106% CPU 的功耗问题；
#      - 守护只在息屏（OFF/DOZE）时运行，亮屏即停——防误触只发生在
#        息屏阶段，亮屏时传感器交还系统，零额外开销。
#   · 电源键亮屏豁免：getevent 监听电源键设备（优先 pmic_pwrkey 类
#    电源键专用设备，避免误选触摸屏），唤醒瞬间若电源键在 2s 内按下
#    → 直接放行，不检测距离传感器。
#   · 现场采样优先：唤醒瞬间连续读接近传感器——
#     现场读到 远 → 放行（手已移开/不在口袋）；
#     现场持续 近 → 强制息屏（仍在口袋）；
#     现场读不到干净值 → 回退息屏缓存。
#   · 守护进程离线时的降级保护：要求“近”事件足够新鲜（≤FRESH_AGE 秒）
#    才拦截，避免传感器休眠时陈旧读数误熄屏。
#   · 功耗优化（v1.7）：屏幕状态优先读 dumpsys power（比 dumpsys display
#    轻一个数量级）；息屏轮询 1s、亮屏轮询 2s；缓存读取降至每 12 轮一次。
#
#  工作逻辑：
#    监听屏幕 OFF/DOZE → ON 的唤醒瞬间 →
#      电源键触发 → 正常亮屏（不检测）
#      现场读为 远 → 正常亮屏
#      现场读为 近 → 强制息屏
#      现场无干净值 → 回退新鲜缓存判定
# ==============================================================

MODDIR=${0%/*}
CONF_FILE="/data/adb/pocket_wake_blocker.conf"
LOG_FILE="/data/local/tmp/pocket_wake_blocker.log"
PIDFILE="/data/local/tmp/pocket_wake_blocker.pid"

log_msg() {
    echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_msg "===== pocket_wake_blocker v1.7 service start ====="

# ---------- 防重复运行 / 清理旧实例 ----------
# 注意：pidfile 位于 /data 上，跨重启保留；重启后旧 pid 可能被其它进程复用，
# 因此必须核对 /proc/<pid>/cmdline 是否为我们的 service.sh，而不能只看 pid 是否存活。
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$old_pid" ]; then
        if tr '\0' '\n' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -q "pocket_wake_blocker/service.sh"; then
            log_msg "old instance running (pid $old_pid), kill & restart"
            kill "$old_pid" 2>/dev/null
            sleep 1
        else
            log_msg "stale pidfile ignored (pid $old_pid)"
        fi
    fi
fi
echo $$ > "$PIDFILE" 2>/dev/null || true
log_msg "service pid $$"

# ---------- 等待系统启动完成 ----------
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 1
done
log_msg "boot completed"

# ---------- 加载配置（先默认值，再覆盖） ----------
POLL_INTERVAL=1.0     # 息屏/DOZE 轮询间隔（秒），双击拦截响应粒度
POLL_INTERVAL_ON=2    # 亮屏轮询间隔（秒），只需捕捉 ON→OFF 边缘，可更慢
CONFIRM_DELAY=0.2
PROX_POLL_EVERY=12    # 息屏时每 N 轮缓存一次接近值（≈12 秒一次，低频省电）
FRESH_AGE=2        # 守护离线时：接近事件超过该秒数无新事件 → 视为"当前无遮挡"
POWER_KEY_WINDOW=2 # 电源键按下后该秒数内的亮屏 → 直接放行，不检测
DEBUG=0

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE" 2>/dev/null || true
    log_msg "config loaded: $CONF_FILE"
else
    log_msg "config not found, use defaults"
fi

# 校验配置值（防御脏数据；间隔类支持小数，用 grep 校验）
echo "$POLL_INTERVAL" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || POLL_INTERVAL=1.0
echo "$POLL_INTERVAL_ON" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || POLL_INTERVAL_ON=2
echo "$CONFIRM_DELAY" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || CONFIRM_DELAY=0.2
[ "$PROX_POLL_EVERY" -ge 1 ] 2>/dev/null || PROX_POLL_EVERY=12
echo "$FRESH_AGE" | grep -Eq '^[0-9]+$' || FRESH_AGE=2
echo "$POWER_KEY_WINDOW" | grep -Eq '^[0-9]+$' || POWER_KEY_WINDOW=2

# ---------- 获取屏幕状态（ON / OFF / DOZE / UNKNOWN） ----------
get_screen_state() {
    local v
    # 优先 dumpsys power（输出比 dumpsys display 小一个数量级，省电）
    v=$(dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | sed 's/.*mWakefulness=\([A-Za-z]*\).*/\1/')
    case "$v" in
        Awake)  echo "ON";   return ;;
        Asleep) echo "OFF";  return ;;
        Dozing) echo "DOZE"; return ;;
    esac
    # fallback：dumpsys display
    v=$(dumpsys display 2>/dev/null | grep -m1 "mScreenState=" | sed 's/.*mScreenState=\([A-Z]*\).*/\1/')
    if [ -n "$v" ]; then
        echo "$v"
        return
    fi
    echo "UNKNOWN"
}

# ---------- 读取唤醒原因（诊断用，Android16 字段名可能不同，放宽匹配） ----------
get_wake_reason() {
    dumpsys power 2>/dev/null | grep -iE "wake.?reason" | head -1 | sed 's/.*[:=] *//' | tr -d ' \r'
}

# ---------- 事件新鲜度：wall=HH:MM:SS.mmm 距今秒数（处理跨天） ----------
# 注意：事件 wall 为本地时间，必须用本地 date 换算秒数（不可用 UTC epoch % 86400）
event_age() {
    local wall h m s rest nh nm ns nrest now_local now_sod ev_sod age
    wall=$1
    h=${wall%%:*}
    rest=${wall#*:}
    m=${rest%%:*}
    rest=${rest#*:}
    s=${rest%%.*}
    now_local=$(date +%H:%M:%S)
    nh=${now_local%%:*}
    nrest=${now_local#*:}
    nm=${nrest%%:*}
    ns=${nrest#*:}
    h=$(echo "$h" | sed 's/^0*//'); [ -z "$h" ] && h=0
    m=$(echo "$m" | sed 's/^0*//'); [ -z "$m" ] && m=0
    s=$(echo "$s" | sed 's/^0*//'); [ -z "$s" ] && s=0
    nh=$(echo "$nh" | sed 's/^0*//'); [ -z "$nh" ] && nh=0
    nm=$(echo "$nm" | sed 's/^0*//'); [ -z "$nm" ] && nm=0
    ns=$(echo "$ns" | sed 's/^0*//'); [ -z "$ns" ] && ns=0
    ev_sod=$(( h*3600 + m*60 + s ))
    now_sod=$(( nh*3600 + nm*60 + ns ))
    age=$(( now_sod - ev_sod ))
    [ "$age" -lt 0 ] && age=$(( age + 86400 ))
    echo "$age"
}

# ---------- 读取接近传感器（锚定 stk_stk3a7x，读最近事件最后一条） ----------
# 返回 "状态|事件年龄秒数"，如 NEAR|0、FAR|5、RAW:46.71|120、UNKNOWN|999
# 注意：必须用 awk 在“下一个 last N events 块”处截断，否则 -A 窗口会
# 延伸到相邻传感器块（如加速度计），误读到 14.51/15.59 这类非接近值。
read_prox() {
    local last_line val wall age
    last_line=$(dumpsys sensorservice 2>/dev/null | awk '
        /stk_stk3a7x Proximity Sensor Wakeup: last/ { inc=1; next }
        inc && /: last [0-9]+ events/     { exit }
        inc && /\(ts=/                    { last=$0 }
        END { if (last != "") print last }
    ')
    if [ -z "$last_line" ]; then
        [ "$DEBUG" = "1" ] && log_msg "prox read failed (no event)"
        echo "UNKNOWN|999"
        return
    fi
    # 事件行示例：  3 (ts=..., wall=...) 5.00, 0.00, 0.00,
    val=$(echo "$last_line" | sed 's/.*) //' | cut -d',' -f1 | tr -d ' ')
    wall=$(echo "$last_line" | sed -n 's/.*wall=\([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9.]*\).*/\1/p')
    if [ -z "$wall" ]; then
        age=999
    else
        age=$(event_age "$wall")
    fi
    case "$val" in
        0|0.0|0.00|0.000|0.0000) echo "NEAR|$age" ;;
        5|5.0|5.00|5.000)        echo "FAR|$age" ;;
        *)                       echo "RAW:$val|$age" ;;   # 残留/异常值，便于调试
    esac
}

# ---------- 电源键监听（识别电源键亮屏，直接放行不检测） ----------
PWR_TS_FILE="/data/local/tmp/power_key_ts"
PWR_DEV_FILE="/data/local/tmp/power_key_dev"
PWR_LAST_FILE="/data/local/tmp/power_key_last"   # 最近一次电源键事件原文（诊断用）

start_power_key_listener() {
    local pwr_dev
    # 优先选"电源键专用设备"（pmic_pwrkey / gpio-keys 等），找不到再回退到
    # 任意声明 KEY_POWER 能力的设备。
    # 注意：触摸屏（goodix_ts）也声明了 KEY_POWER，但物理电源键事件来自
    # pmic_pwrkey；若按"第一个 KEY_POWER 设备"选会选错（触屏），导致监听
    # 不到电源键。因此按设备名优先选择。
    pwr_dev=$(getevent -lp 2>/dev/null | awk '
        /add device/ { dev=$0; sub(/^.*add device [0-9]+: /, "", dev); name="" }
        /name: *"/  { name=$0; sub(/^.*name: *"/, "", name); sub(/".*$/, "", name) }
        /KEY_POWER/ {
            if (name ~ /pwrkey|power|gpio-keys|button/) { print dev; done=1; exit }
            if (fallback == "") fallback = dev
        }
        END { if (!done && fallback != "") print fallback }
    ')
    if [ -z "$pwr_dev" ]; then
        log_msg "power key device not found, will retry later"
        return 1
    fi
    # 清理旧监听进程（正则用 [t] 避免 pkill 匹配到自身命令行）
    pkill -f "geteven[t] -l $pwr_dev" 2>/dev/null
    rm -f "$PWR_TS_FILE"
    echo "$pwr_dev" > "$PWR_DEV_FILE" 2>/dev/null
    # 后台监听：电源键 DOWN 时记录当前秒级时间戳 + 最近事件原文（诊断用）
    ( getevent -l "$pwr_dev" 2>/dev/null | while read -r line; do
        case "$line" in
            *KEY_POWER*"DOWN"*)
                date +%s > "$PWR_TS_FILE" 2>/dev/null || true
                echo "$line" > "$PWR_LAST_FILE" 2>/dev/null || true
                ;;
        esac
    done ) &
    sleep 0.5
    if power_key_listener_alive; then
        log_msg "power key listener started on $pwr_dev"
        return 0
    fi
    log_msg "power key listener START FAILED on $pwr_dev (will retry)"
    return 1
}

# 电源键监听进程是否存活（主循环周期性检查，死了自动重启）
power_key_listener_alive() {
    local dev
    [ -f "$PWR_DEV_FILE" ] || return 1
    dev=$(cat "$PWR_DEV_FILE" 2>/dev/null || true)
    [ -n "$dev" ] || return 1
    pgrep -f "geteven[t] -l $dev" >/dev/null 2>&1
}

power_pressed_recently() {
    local ts now
    [ -f "$PWR_TS_FILE" ] || return 1
    ts=$(cat "$PWR_TS_FILE" 2>/dev/null || echo 0)
    echo "$ts" | grep -Eq '^[0-9]+$' || return 1
    now=$(date +%s)
    [ $(( now - ts )) -le "$POWER_KEY_WINDOW" ] 2>/dev/null
}

# ---------- 接近传感器常驻采样守护进程（v1.7：按屏幕状态启停） ----------
# stk_stk3a7x 是 on-change 型接近传感器：传感器平时休眠，只有被系统激活
# 采样时才上报。若息屏后立刻盖住，doze 还没激活传感器 → 盖住不上报 → 模块
# 读到旧"远"值误放行。因此内置 sensor_keepalive 守护进程持续启用该传感器，
# 使遮挡/移开实时上报 0/5，模块随时能读到新鲜值。
# v1.7 功耗优化：守护只在息屏（OFF/DOZE）时运行，亮屏即停（防误触只发生在
# 息屏阶段；亮屏时传感器交还系统，零额外开销）。
DAEMON_BIN="$MODDIR/sensor_keepalive"
DAEMON_PIDFILE="/data/local/tmp/sensor_keepalive.pid"

sensor_daemon_alive() {
    [ -f "$DAEMON_PIDFILE" ] || return 1
    local pid
    pid=$(cat "$DAEMON_PIDFILE" 2>/dev/null || echo 0)
    echo "$pid" | grep -Eq '^[0-9]+$' || return 1
    kill -0 "$pid" 2>/dev/null
}

start_sensor_daemon() {
    if [ ! -x "$DAEMON_BIN" ]; then
        log_msg "sensor_keepalive binary missing, keepalive daemon disabled"
        return 1
    fi
    # 清理残留实例（[v] 避免 pkill 匹配到自身）
    pkill -f "sensor_keepali[v]e" 2>/dev/null
    rm -f "$DAEMON_PIDFILE"
    nohup "$DAEMON_BIN" >/dev/null 2>&1 &
    sleep 0.5
    if sensor_daemon_alive; then
        log_msg "sensor keepalive daemon started (pid $(cat $DAEMON_PIDFILE))"
        return 0
    fi
    log_msg "sensor keepalive daemon FAILED to start"
    return 1
}

# 亮屏时停止守护（息屏防误触不再需要，省电）
stop_sensor_daemon() {
    if sensor_daemon_alive; then
        pkill -f "sensor_keepali[v]e" 2>/dev/null
        rm -f "$DAEMON_PIDFILE"
        log_msg "sensor keepalive daemon stopped (screen ON)"
    fi
}

# ---------- 唤醒瞬间判定（守护在线信任实时值 + 离线时新鲜度降级） ----------
# 返回 NEAR / FAR
#  - 现场读到 远            → 放行（手已移开/不在口袋）
#  - 现场读到 近            → 守护在线：传感器实时，NEAR 可信，延迟重读确认
#                             守护离线：要求事件新鲜才信任，避免陈旧"近"误熄屏
#  - 现场无干净值（RAW/UNKNOWN）→ 回退息屏缓存（守护离线时缓存也要求新鲜）
judge_on_wake() {
    local s1 s2 v1 a1 v2 a2 cv ca alive
    alive=0
    sensor_daemon_alive && alive=1
    s1=$(read_prox); v1=${s1%%|*}; a1=${s1##*|}
    if [ "$v1" = "FAR" ]; then
        log_msg "  judge: s1=FAR(age=$a1) → 现场即远，放行"
        echo "FAR"
        return
    fi
    if [ "$v1" = "NEAR" ]; then
        if [ "$alive" = "1" ] || [ "$a1" -le "$FRESH_AGE" ]; then
            sleep "$CONFIRM_DELAY" 2>/dev/null || sleep 1
            s2=$(read_prox); v2=${s2%%|*}; a2=${s2##*|}
            if [ "$v2" = "FAR" ]; then
                log_msg "  judge: s1=NEAR s2=FAR(age=$a2) → 手已移开，放行"
                echo "FAR"; return
            fi
            if [ "$v2" = "NEAR" ]; then
                log_msg "  judge: s1/s2=NEAR(守护在线=$alive age=$a1/$a2) → 持续遮挡，拦截"
                echo "NEAR"; return
            fi
            log_msg "  judge: s1=NEAR s2=$v2(age=$a2) → 保守拦截"
            echo "NEAR"; return
        fi
        log_msg "  judge: s1=NEAR(age=$a1 过期,守护离线) → 无新鲜证据，放行"
        echo "FAR"; return
    fi
    # 现场无干净值 → 回退息屏缓存
    cv=${PROX_CACHE%%|*}; ca=${PROX_CACHE##*|}
    if [ "$cv" = "NEAR" ]; then
        if [ "$alive" = "1" ] || [ "$ca" -le "$FRESH_AGE" ]; then
            log_msg "  judge: 现场无干净值(v1=$v1)，缓存近(守护在线=$alive cache=$PROX_CACHE) → 拦截"
            echo "NEAR"; return
        fi
    fi
    log_msg "  judge: 现场无干净近证据(v1=$v1 age=$a1 cache=$PROX_CACHE) → 放行"
    echo "FAR"
}

# ---------- 强制息屏（取消误亮屏） ----------
force_sleep() {
    input keyevent KEYCODE_SLEEP 2>/dev/null || input keyevent 223 2>/dev/null || true
    log_msg ">>> 已强制息屏（口袋防误触触发）"
}

# ---------- 主循环（脚本自身常驻，不使用内联子shell） ----------
WAS_OFF=0              # 上一次是否处于熄屏状态（1=是）
PROX_CACHE="UNKNOWN|999" # 息屏期间缓存的接近状态（状态|事件年龄）
OFF_CYCLE=0            # 息屏轮询计数（用于周期性读接近值）

# 启动电源键监听（后台 getevent）
start_power_key_listener || true

# 接近传感器守护进程由主循环按屏幕状态启停（息屏跑/亮屏停），
# 启动后首个循环即按当前屏幕状态接管，无需在此预启动。

log_msg "service entering main loop (off_interval=${POLL_INTERVAL}s, on_interval=${POLL_INTERVAL_ON}s, prox_every=${PROX_POLL_EVERY})"

PWR_CYCLE=0   # 电源键监听检查计数

while true; do
    state=$(get_screen_state)

    # 周期性守护电源键监听（异常退出时自动重启；接近传感器守护已按状态启停）
    PWR_CYCLE=$((PWR_CYCLE+1))
    if [ $((PWR_CYCLE % 20)) -eq 0 ]; then
        power_key_listener_alive || start_power_key_listener || true
    fi

    case "$state" in
        ON)
            # 屏幕刚被点亮（之前为熄灭/息屏显示）→ 判定是否误触
            if [ "$WAS_OFF" = "1" ]; then
                reason=$(get_wake_reason)
                if power_pressed_recently; then
                    # 电源键亮屏：直接放行，不检测距离传感器
                    log_msg "wake by power key (within ${POWER_KEY_WINDOW}s) → 正常亮屏，不检测"
                else
                    decision=$(judge_on_wake)
                    if [ "$decision" = "NEAR" ]; then
                        log_msg "wake+NEAR (cache=$PROX_CACHE reason='$reason') → 拦截"
                        force_sleep
                    else
                        log_msg "wake+FAR (cache=$PROX_CACHE reason='$reason') → 正常亮屏"
                    fi
                fi
                WAS_OFF=0
            fi
            OFF_CYCLE=0
            # 亮屏：停掉传感器守护（防误触只在息屏时需要，省电）
            stop_sensor_daemon
            sleep "$POLL_INTERVAL_ON" 2>/dev/null || sleep 2
            ;;
        OFF|DOZE)
            # 屏幕熄灭：确保传感器守护在跑（遮挡/移开实时可读）
            WAS_OFF=1
            sensor_daemon_alive || start_sensor_daemon || true
            # 周期性缓存接近值（低频兜底，守护在线时几乎用不上）
            OFF_CYCLE=$((OFF_CYCLE+1))
            if [ $((OFF_CYCLE % PROX_POLL_EVERY)) -eq 0 ]; then
                PROX_CACHE=$(read_prox)
            fi
            sleep "$POLL_INTERVAL" 2>/dev/null || sleep 1
            ;;
        UNKNOWN)
            # 读取失败时保持上一次的 WAS_OFF，避免误判
            :
            sleep "$POLL_INTERVAL" 2>/dev/null || sleep 1
            ;;
    esac
done
