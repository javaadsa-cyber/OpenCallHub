#!/usr/bin/env bash
# 测试 2：dialplan + xml_curl 链路
# 运行时向 fs_dialplan 插入临时路由 ^9990$（xml_curl 按呼叫实时拉取，立即生效，无需 reload），
# originate loopback/9990/default 验证路由命中，测后清理 DB 行与通道。
# 失败时打印 och-api 日志尾部（xml_curl 报错会落在那里）。
set -uo pipefail
SCRIPT_NAME="loopback-dialplan"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

TEST_NAME="zz-auto-test-loopback"
DEST=9990
UUID=""

cleanup() {
  [ -n "$UUID" ] && fs_cli "uuid_kill $UUID" >/dev/null 2>&1 || true
  mysql_q "DELETE FROM openCallHub.fs_dialplan WHERE name='$TEST_NAME';" >/dev/null 2>&1 || true
  fs_cli "hupall" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "① 幂等预清理（消化上次异常退出的残留）"
cleanup
UUID=""
sleep 1

log "② 插入测试路由 ^$DEST\$ → answer + sleep(60s) + hangup"
insert_sql=$(cat <<'SQL'
INSERT INTO openCallHub.fs_dialplan
(`group_id`,`name`,`type`,`expression`,`context_name`,`content`,`describe`,`create_by`,`create_time`,`del_flag`)
VALUES (1,'zz-auto-test-loopback','xml','^9990$','default',
'<extension><condition field="destination_number" expression="^9990$"><action application="answer"/><action application="sleep" data="60000"/><action application="hangup"/></condition></extension>',
'自动化测试-临时路由(run-all自动清理)',1,NOW(),0);
SQL
)
mysql_q "$insert_sql"
rows="$(mysql_q "SELECT count(*) FROM openCallHub.fs_dialplan WHERE name='$TEST_NAME';")"
assert_eq "fs_dialplan 已插入 1 行" "1" "$rows"

log "③ originate loopback/$DEST/default（xml_curl 将实时拉取上面的路由）"
out="$(fs_cli "originate {loopback_bowout=false}loopback/$DEST/default &park()")"
if [[ "$out" != *"+OK"* ]]; then
  fail "originate 未返回 +OK：$out"
  log "--- och-api 日志尾部（xml_curl/dialplan/错误）---"
  docker compose logs --tail 40 och-api 2>&1 | grep -iE "xmlCurl|dialplan|ERROR" | tail -20 || true
  finish
fi
pass "originate 返回 +OK"
UUID="$(echo "$out" | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}' | head -1 || true)"
log "A 腿 uuid=$UUID"

log "④ 轮询通道出现 dest=$DEST（≤10s）"
found=""
if wait_for 10 1 "dest=$DEST 通道出现" bash -c "
    docker compose exec -T freeswitch fs_cli -p $FS_PASSWORD -x 'show channels as csv' | grep -q ',$DEST,'
  "; then
  found="yes"
fi
assert_eq "通道 dest=$DEST 已建立" "yes" "$found"

log "⑤ 清理并复验"
fs_cli "uuid_kill $UUID" >/dev/null 2>&1
UUID=""
sleep 1
count="$(fs_cli "show channels count")"
assert_contains "通道数回到 0" "$count" "0 total"
mysql_q "DELETE FROM openCallHub.fs_dialplan WHERE name='$TEST_NAME';"
rows="$(mysql_q "SELECT count(*) FROM openCallHub.fs_dialplan WHERE name='$TEST_NAME';")"
assert_eq "测试路由已从 fs_dialplan 删除" "0" "$rows"

finish
