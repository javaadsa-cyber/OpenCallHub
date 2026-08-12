#!/usr/bin/env bash
# FreeSWITCH 自动化测试套件公共函数
# 供 smoke.sh / loopback-dialplan.sh / sipp-call.sh / run-all.sh source 使用

# 目录定位：test 目录位于 deploy/freeswitch/test
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

# MySQL root 密码：优先环境变量，其次 .env，缺省 123456（与 docker-compose.yml 缺省一致）
if [ -z "${MYSQL_ROOT_PASSWORD:-}" ] && [ -f .env ]; then
  MYSQL_ROOT_PASSWORD="$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' .env | tr -d '"' || true)"
fi
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-123456}"

# FS ESL 密码（deploy/freeswitch/autoload_configs/event_socket.conf.xml）
FS_PASSWORD="ClueCon"

FAIL_COUNT=0
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# assert_eq <描述> <期望值> <实际值>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1（期望 [$2] 实际 [$3]）"; fi
}

# assert_contains <描述> <全文> <子串>
assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1（未找到 [$3]）" ;;
  esac
}

# fs_cli 一次性命令：fs_cli "<ESL命令>" → 打印 FS 输出
fs_cli() {
  docker compose exec -T freeswitch fs_cli -p "$FS_PASSWORD" -x "$1" 2>&1
}

# MySQL 无表头查询：mysql_q "<SQL>"（密码走 MYSQL_PWD 环境变量，避免命令行密码告警）
mysql_q() {
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -e "$1"
}

# wait_for <超时秒> <间隔秒> <描述> <命令...>
# 命令在超时内返回 0 则成功；用于轮询等待异步状态（注册出现、通道建立等）
wait_for() {
  local timeout=$1 interval=$2 desc=$3 waited=0
  shift 3
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  log "等待超时：$desc（${timeout}s）"
  return 1
}

# 测试脚本收尾：按 FAIL_COUNT 决定退出码，打印小结
finish() {
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\033[31m==> %s：%d 项断言失败\033[0m\n' "$SCRIPT_NAME" "$FAIL_COUNT"
    exit 1
  fi
  printf '\033[32m==> %s：全部断言通过\033[0m\n' "$SCRIPT_NAME"
  exit 0
}
