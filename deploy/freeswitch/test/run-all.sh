#!/usr/bin/env bash
# FreeSWITCH 无软电话自动化测试套件入口
# 依次执行：① smoke（冒烟）② loopback-dialplan（dialplan+xml_curl 链路）③ sipp-call（SIP+RTP）
# 用法：bash deploy/freeswitch/test/run-all.sh
# 前置：docker compose up -d 且核心服务 healthy（smoke 会检查）
set -uo pipefail
cd "$(dirname "$0")"

results=()
rc_total=0
for t in smoke.sh loopback-dialplan.sh sipp-call.sh; do
  echo
  echo "================ $t ================"
  if bash "$t"; then
    results+=("PASS  $t")
  else
    results+=("FAIL  $t")
    rc_total=1
  fi
done

echo
echo "================ 汇总 ================"
printf '%s\n' "${results[@]}"
exit $rc_total
