#!/usr/bin/env bash
# 测试 3：SIP 注册 + 分机互呼 + RTP 媒体
# 编排：sipp 容器注册 1000/1001 → UAS(1001) 后台待叫 → UAC(1000) 呼叫 1001
#       → FS 经种子 dialplan bridge user/1001 → UAS 接听 → UAC rtp_stream 放 440Hz 音调
#       → 宿主机侧 uuid_record 录音 → 断言「文件大小 + 采样方差」（方差证明 RTP 真实到达，
#          排除 soft timer 静音帧造成的假阳性）
set -uo pipefail
SCRIPT_NAME="sipp-call"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

WAV_LOCAL=/tmp/och-test-call.wav
WAV_FS=/tmp/och-test-call.wav
FS_IP=""

cleanup() {
  # 杀掉容器内残留 sipp（UAS 收不到 INVITE 时会无限等待，占住端口导致下轮注册失败）
  docker exec och-sipp pkill -f sipp >/dev/null 2>&1 || true
  fs_cli "hupall" >/dev/null 2>&1 || true
  fs_cli "sofia profile internal flush_inbound_reg" >/dev/null 2>&1 || true
  rm -f "$WAV_LOCAL"
}
trap cleanup EXIT

log "① 预清理 + 启动 sipp 容器（profiles: test）"
cleanup
if [ ! -d "$TEST_DIR/src/sipp" ]; then
  log "未发现 sipp 源码，先运行 fetch-sipp-sources.sh（github 不通时自动回退 gitcode 镜像）"
  bash "$TEST_DIR/fetch-sipp-sources.sh" || { fail "sipp 源码抓取失败"; finish; }
fi
# 注意：必须 build/up 分开且只针对 sipp——`up --build sipp` 会连带 bake 依赖的
# freeswitch，重建的镜像 ID 变化会触发 FS 容器 recreate，打断整个核心栈
if ! docker compose --profile test build sipp >/dev/null 2>&1; then
  fail "sipp 镜像构建失败（查看 docker compose --profile test build sipp 输出）"
  finish
fi
if ! docker compose --profile test up -d --no-build sipp >/dev/null 2>&1; then
  fail "sipp 容器启动失败"
  finish
fi
pass "sipp 容器已就绪"

log "② 解析 FS 容器 IP"
FS_IP="$(docker exec och-sipp getent hosts freeswitch | awk '{print $1; exit}')"
assert_contains "freeswitch 解析出 IP" "$FS_IP" "."
log "FS_IP=$FS_IP"

# 直接用容器名驱动（compose exec 对 profiles 服务的行为各版本不一）
sipp_exec() { # 在 sipp 容器内前台执行
  docker exec och-sipp bash -c "$1"
}
sipp_bg() { # 在 sipp 容器内后台执行
  docker exec -d och-sipp bash -c "$1"
}

log "③ SIPp 注册 1000 / 1001"
if ! sipp_exec "sipp -sf /opt/och-test/scenarios/register_1000.xml -p 5061 -i \$(hostname -i) -m 1 $FS_IP:5060 >/tmp/reg1000.log 2>&1"; then
  fail "注册 1000 失败"; sipp_exec "tail -20 /tmp/reg1000.log" || true; finish
fi
pass "注册 1000 成功"
if ! sipp_exec "sipp -sf /opt/och-test/scenarios/register_1001.xml -p 5060 -i \$(hostname -i) -m 1 $FS_IP:5060 >/tmp/reg1001.log 2>&1"; then
  fail "注册 1001 失败"; sipp_exec "tail -20 /tmp/reg1001.log" || true; finish
fi
pass "注册 1001 成功"

log "④ 等待 FS 注册表出现 1001"
if ! wait_for 15 1 "1001 出现在注册表" bash -c "
    docker compose exec -T freeswitch fs_cli -p $FS_PASSWORD -x 'sofia status profile internal reg' | grep -q 1001
  "; then
  fail "FS 注册表未出现 1001"
  fs_cli "sofia status profile internal reg" || true
  finish
fi
pass "1001 已注册到 FS"

log "⑤ UAS(1001) 后台待叫 → UAC(1000) 发起呼叫"
sipp_bg "cd /tmp && sipp -sf /opt/och-test/scenarios/uas_1001.xml -p 5060 -i \$(hostname -i) -m 1 -trace_msg -trace_err > /tmp/uas.log 2>&1; echo \$? > /tmp/uas.exit"
sleep 1   # 等 UAS 起监听
sipp_bg "sipp -sf /opt/och-test/scenarios/uac_1000_call_1001.xml -p 5061 -i \$(hostname -i) -m 1 $FS_IP:5060 > /tmp/uac.log 2>&1; echo \$? > /tmp/uac.exit"

log "⑥ 等待通话建立（dest=1001 的 inbound 通道）"
if ! wait_for 10 1 "通话建立" bash -c "
    docker compose exec -T freeswitch fs_cli -p $FS_PASSWORD -x 'show channels as csv' | awk -F',' 'NR==1{for(i=1;i<=NF;i++){if(\$i==\"uuid\")u=i;if(\$i==\"dest\")d=i;if(\$i==\"direction\")dir=i}} NR>1&&\$d==\"1001\"&&\$dir==\"inbound\"{print \$u;exit}' | grep -q .
  "; then
  fail "通话未建立（10s 内无 dest=1001 的 inbound 通道）"
  fs_cli "show channels" || true
  sipp_exec "tail -20 /tmp/uac.log" || true
  finish
fi
pass "通话已建立"
CALL_UUID="$(fs_cli "show channels as csv" | awk -F',' 'NR==1{for(i=1;i<=NF;i++){if($i=="uuid")u=i;if($i=="dest")d=i;if($i=="direction")dir=i}} NR>1&&$d=="1001"&&$dir=="inbound"{print $u;exit}')"
log "呼叫通道 uuid=$CALL_UUID"

log "⑦ 录音 3 秒（UAC 正在放 440Hz 音调，UAC 场景内 pause 15s 保证窗口充足）"
# 注意参数顺序：uuid_record <uuid> start|stop <path>（动词在路径前）
rec_out="$(fs_cli "uuid_record $CALL_UUID start $WAV_FS")"
assert_contains "uuid_record start" "$rec_out" "+OK"
sleep 3
fs_cli "uuid_record $CALL_UUID stop $WAV_FS" >/dev/null 2>&1

log "⑧ 等待呼叫自然结束（UAC pause 结束后 BYE）并校验 sipp 退出码"
if ! wait_for 25 1 "呼叫结束（通道清零）" bash -c "
    docker compose exec -T freeswitch fs_cli -p $FS_PASSWORD -x 'show channels count' | grep -q '0 total'
  "; then
  fail "呼叫未在预期时间内结束"
  fs_cli "show channels" || true
fi
uac_exit="$(sipp_exec "cat /tmp/uac.exit 2>/dev/null || echo missing")"
uas_exit="$(sipp_exec "cat /tmp/uas.exit 2>/dev/null || echo missing")"
assert_eq "UAC sipp 退出码 0" "0" "$uac_exit"
assert_eq "UAS sipp 退出码 0" "0" "$uas_exit"
if [ "$uac_exit" != "0" ] || [ "$uas_exit" != "0" ]; then
  sipp_exec "tail -20 /tmp/uac.log" || true
  sipp_exec "tail -20 /tmp/uas.log" || true
fi

log "⑨ 媒体断言：文件大小 + 采样方差（防 soft timer 静音帧假阳性）"
docker cp "och-freeswitch:$WAV_FS" "$WAV_LOCAL" >/dev/null 2>&1
if [ ! -s "$WAV_LOCAL" ]; then
  fail "录音文件未生成"
  finish
fi
docker cp "$WAV_LOCAL" och-sipp:/tmp/och-test-call.wav >/dev/null 2>&1
if sipp_exec "python3 /opt/och-test/check_wav.py /tmp/och-test-call.wav"; then
  pass "录音含真实 RTP 音频（大小与方差均达标）"
else
  fail "录音断言未通过（无 RTP 或全静音）"
fi

finish
