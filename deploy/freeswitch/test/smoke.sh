#!/usr/bin/env bash
# 测试 1：FS 冒烟检查
# ① compose 核心服务全部 healthy ② ESL 可达（fs_cli status）
# ③ sofia internal profile RUNNING 且监听 5060 ④ 无残留通道 ⑤ och-api ESL 状态 fs_config.status=0
set -uo pipefail
SCRIPT_NAME="smoke"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

log "① compose 核心服务健康状态"
ps_out="$(docker compose ps --format '{{.Name}} {{.Health}}')"
for svc in och-mysql och-redis och-freeswitch och-api; do
  line="$(echo "$ps_out" | grep "^$svc " || echo "$svc (missing)")"
  assert_contains "服务 $svc healthy" "$line" "healthy"
done

log "② ESL 可达（fs_cli status）"
status="$(fs_cli "status")"
assert_contains "fs_cli status 返回 uptime" "$status" "UP"

log "③ sofia internal profile（RUNNING 字样在总览输出里，profile 明细输出没有）"
sofia="$(fs_cli "sofia status")"
internal_line="$(echo "$sofia" | awk '$1=="internal" && $2=="profile"' | head -1)"
assert_contains "internal profile RUNNING" "$internal_line" "RUNNING"
assert_contains "监听 5060" "$internal_line" "5060"

log "④ 无残留通道"
count="$(fs_cli "show channels count")"
assert_contains "show channels count = 0" "$count" "0 total"

log "⑤ och-api ESL 连接状态（fs_config.status 应全为 0=在线）"
offline="$(mysql_q "SELECT count(*) FROM openCallHub.fs_config WHERE status<>0;")"
assert_eq "fs_config 无下线记录" "0" "$offline"

finish
