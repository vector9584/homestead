#!/usr/bin/env bash
# nginx-site —— 站点 nginx 的专用运维入口
#
# 为什么需要它：当机器上同时跑着系统面板的 nginx 和自己站点的 nginx 时，
# 两者若共用 /run/nginx.pid，`systemctl reload nginx` 会按那个文件里的 pid 发信号，
# 极可能发给错的那个进程。表现是：配置改完，nginx -t 也通过，就是永远不生效。
#
# 这个脚本不猜 pid —— 它从站点自己的 nginx.conf 里读 `pid` 指令指向的文件。
# 前提：站点 nginx 的 pid 指令已经指向独立文件（不与系统面板共用）。
#
# 用法：nginx-site {test|reload|status|restart}

set -euo pipefail

NGINX_BIN="${NGINX_BIN:-$(command -v nginx)}"
CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"

die() { echo "错误: $*" >&2; exit 1; }

# 从 nginx.conf 读 pid 路径（去掉行尾分号），默认 /run/nginx.pid
pid_file() {
    local p
    p="$(grep -E '^[[:space:]]*pid[[:space:]]' "$CONF" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]*pid[[:space:]]+//; s/;.*$//; s/[[:space:]]+$//')"
    echo "${p:-/run/nginx.pid}"
}

master_pid() {
    local f; f="$(pid_file)"
    [[ -r "$f" ]] || return 1
    head -1 "$f" 2>/dev/null
}

case "${1:-}" in
  test)
    "$NGINX_BIN" -t -c "$CONF"
    ;;

  status)
    site_pid="$(master_pid)" || die "pid 文件不可读: $(pid_file)"
    echo "配置文件: $CONF"
    echo "pid 文件: $(pid_file)"
    echo "master  : ${site_pid}"
    if kill -0 "$site_pid" 2>/dev/null; then
        echo "状态    : running"
        ps -o pid,etime,cmd -p "$site_pid" --no-headers || true
        echo "Worker  : $(pgrep -P "$site_pid" | wc -l) 个"
    else
        echo "状态    : 进程不存在（pid 文件是残留）" >&2
        exit 1
    fi
    ;;

  reload)
    pid="$(master_pid)" || die "读不到 pid 文件: $(pid_file)"
    kill -0 "$pid" 2>/dev/null || die "master $pid 不存在"
    "$NGINX_BIN" -t -c "$CONF"
    # 验证方式：reload 前后 worker PID 必须全变。没变 = 信号发给了别人。
    before="$(pgrep -P "$pid" | sort | tr '\n' ' ')"
    kill -HUP "$pid"
    sleep 1
    after="$(pgrep -P "$pid" | sort | tr '\n' ' ')"
    if [[ "$before" == "$after" ]]; then
        die "worker 未更换，HUP 可能没送到（before=after=$before）"
    fi
    echo "reload 完成，worker 已换代"
    ;;

  restart)
    pid="$(master_pid)" || die "读不到 pid 文件: $(pid_file)"
    "$NGINX_BIN" -t -c "$CONF"
    # 用 QUIT 让老 master 处理完存量连接再退出，再拉新的
    kill -QUIT "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
    kill -0 "$pid" 2>/dev/null && die "老 master $pid 未退出，先查 ss -ltnp"
    "$NGINX_BIN" -c "$CONF"
    echo "restart 完成，新 master: $(master_pid)"
    ;;

  *)
    echo "用法: $(basename "$0") {test|reload|status|restart}" >&2
    exit 2
    ;;
esac
