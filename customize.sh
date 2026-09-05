#!/system/bin/sh
# ==============================================================
#  口袋防误触（双击亮屏保护）v1.7 - 安装脚本
#  逻辑：监听屏幕点亮瞬间，结合“息屏阶段缓存 + 新鲜读”判定接近传感器，
#        若为“近”则立即强制息屏，取消口袋内的双击误触。
#  内置 sensor_keepalive 守护进程保持接近传感器常驻采样，
#        遮挡/移开实时上报，模块随时可读到新鲜遮挡状态。
# ==============================================================
SKIPUNZIP=0

CONF_FILE="/data/adb/pocket_wake_blocker.conf"
LOG_FILE="/data/local/tmp/pocket_wake_blocker_install.log"

log_msg() {
    echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

ui_print "========================================"
ui_print "  口袋防误触（双击亮屏保护）v1.7"
ui_print "========================================"
ui_print " "
ui_print "  · 双击亮屏点亮瞬间检查接近传感器"
ui_print "  · 传感器为“近”（如手机在口袋）→ 立即息屏"
ui_print "  · 传感器为“远” → 正常亮屏"
ui_print "  · 常驻采样守护，传感器实时检测遮挡"
ui_print "  · 现场采样为准，手移开即放行"
ui_print "  · 电源键亮屏不检测"
ui_print " "
ui_print "  作者：酷安@HelllC"
ui_print " "


log_msg "customize.sh started, MODPATH=$MODPATH"

# 确保日志目录存在
mkdir -p /data/local/tmp 2>/dev/null || true

# 部署默认配置：不存在则创建，已存在则保留用户修改
if [ ! -f "$CONF_FILE" ]; then
    cp -f "$MODPATH/default.conf" "$CONF_FILE" 2>/dev/null || true
    chmod 0644 "$CONF_FILE" 2>/dev/null || true
    log_msg "created default config: $CONF_FILE"
    ui_print "  · 已生成默认配置 /data/adb/pocket_wake_blocker.conf"
else
    log_msg "config exists, keep user config"
    ui_print "  · 检测到已有配置，保留用户修改"
fi

# 设置模块文件权限（目录 0755，脚本 0755）
set_perm_recursive "$MODPATH" 0 0 0755 0755 2>/dev/null || true

# 确保常驻采样守护进程可执行（zip 打包可能丢失执行位）
chmod 0755 "$MODPATH/sensor_keepalive" 2>/dev/null || true
log_msg "permissions set (sensor_keepalive chmod 755)"

log_msg "customize.sh finished"
ui_print " "
ui_print "  安装完成，请重启设备后生效"
ui_print "========================================"
