/*
 * sensor_keepalive —— 接近传感器常驻采样守护进程（口袋防误触模块组件）
 *
 * 作用：持续保持接近传感器（stk_stk3a7x）处于"激活采样"状态。
 *      该传感器是 on-change 型：只要被某个客户端启用，遮挡/移开就会
 *      实时上报 0.00(近)/5.00(远)，dumpsys sensorservice 的"最近事件"
 *      始终反映当前遮挡状态，模块在任何时刻都能读到新鲜值。
 *
 * 编译（NDK r28，aarch64）：
 *   aarch64-linux-android35-clang -O2 -Wall -o sensor_keepalive \
 *       sensor_keepalive.c -landroid -llog -static-libgcc
 *
 * 运行：sensor_keepalive [采样间隔微秒，默认 5000000=0.2Hz]
 *       SIGTERM/SIGINT/SIGHUP 退出；退出时删除 pidfile。
 *
 * 功耗优化（v1.7）：
 *  - 主循环强制节流：无论事件是否到达，每轮至少间隔 200ms，
 *    避免事件风暴导致 pollOnce 立即返回、死循环空转吃满 CPU。
 *  - 采样率请求降到 0.2Hz：on-change 传感器的 rate 只是"最大上报频率"，
 *    遮挡/移开时值变化仍实时上报，不影响检测及时性；若 HAL 是周期
 *    上报型，事件流直接降 5 倍，进一步降低传感器侧负载。
 */
#include <android/sensor.h>
#include <android/looper.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#define PIDFILE "/data/local/tmp/sensor_keepalive.pid"

static volatile sig_atomic_t g_running = 1;

static void on_signal(int sig) {
    (void)sig;
    g_running = 0;
}

/* 事件回调：返回 1 保持事件队列活跃；事件内容无需处理 */
static int on_sensor_event(int fd, int events, void* data) {
    (void)fd;
    (void)events;
    (void)data;
    return 1;
}

static void write_pidfile(void) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    FILE* f = fopen(PIDFILE, "w");
    if (f) {
        fwrite(buf, 1, (size_t)(len > 0 ? (size_t)len : 0), f);
        fclose(f);
    }
}

int main(int argc, char** argv) {
    ASensorManager* mgr = NULL;
    ALooper* looper = NULL;
    ASensorEventQueue* queue = NULL;
    const ASensor* prox = NULL;
    int64_t rate_us = 5000000L;   /* 默认 0.2Hz（5 秒一次） */
    const char* sname = "?";

    if (argc > 1) {
        rate_us = atoll(argv[1]);
        if (rate_us < 500000L) rate_us = 500000L;   /* 不小于 0.5s */
    }

    mgr = ASensorManager_getInstanceForPackage("pocket_wake_blocker");
    if (!mgr) return 1;

    prox = ASensorManager_getDefaultSensor(mgr, ASENSOR_TYPE_PROXIMITY);
    if (!prox) return 2;

    if (ASensor_getName(prox)) sname = ASensor_getName(prox);

    looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
    if (!looper) return 3;

    queue = ASensorManager_createEventQueue(mgr, looper,
                                            ALOOPER_POLL_CALLBACK,
                                            on_sensor_event, NULL);
    if (!queue) return 4;

    if (ASensorEventQueue_enableSensor(queue, prox) < 0) return 5;
    ASensorEventQueue_setEventRate(queue, prox, rate_us);

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    write_pidfile();

    fprintf(stderr, "sensor_keepalive: enabled '%s' @%lldus\n",
            sname, (long long)rate_us);

    while (g_running) {
        ALooper_pollOnce(1000, NULL, NULL, NULL);
        /* 节流：无论事件是否到达，每轮至少间隔 200ms。
         * 否则传感器持续产生事件时 pollOnce 会立即返回、循环空转，
         * 导致进程吃满一个 CPU 核（曾实测 106% CPU）。我们并不依赖
         * 消费事件工作（模块通过 dumpsys 读最近值），积压由系统环形
         * 缓冲自动覆盖，节流零功能损失。 */
        usleep(200000);
    }

    ASensorEventQueue_disableSensor(queue, prox);
    ASensorManager_destroyEventQueue(mgr, queue);
    unlink(PIDFILE);
    return 0;
}
