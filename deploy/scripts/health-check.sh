#!/bin/bash
# ============================================================
# openCallHub 全链路健康检查脚本
# 检查: MySQL / Redis / FreeSWITCH / och-api / och-mrcp
# 用法: ./health-check.sh
#
# 基于 docker-deploy 的 smoke.sh 探测逻辑重写；不依赖 Spring Actuator。
# 退出码: 0 = 全部 UP, 1 = 至少一个 DOWN
# ============================================================

set -uo pipefail

# 切换到仓库根目录（脚本可能在 deploy/scripts/ 下被调用）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."

PASS=0
FAIL=0
CHECKS=()

check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✅ $name : UP"
        PASS=$((PASS + 1))
        CHECKS+=("✅ $name")
    else
        echo "  ❌ $name : DOWN"
        FAIL=$((FAIL + 1))
        CHECKS+=("❌ $name")
    fi
}

echo "============================================="
echo " openCallHub 健康检查"
echo " $(date)"
echo "============================================="

# ─── MySQL ───
check "MySQL" \
    docker compose exec -T mysql sh -c \
        'mysqladmin ping -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASSWORD:-123456}"'

# ─── Redis ───
check "Redis" \
    docker compose exec -T redis redis-cli -a 123456 ping

# ─── FreeSWITCH ───
check "FreeSWITCH" \
    docker compose exec -T freeswitch fs_cli -p ClueCon -x status

# ─── och-api（TCP 探活 4320）───
check "och-api (4320)" \
    bash -c 'exec 3<>/dev/tcp/127.0.0.1/4320'

# ─── och-mrcp（SIP 7010 TCP）───
check "och-mrcp (7010)" \
    bash -c 'exec 3<>/dev/tcp/127.0.0.1/7010'

echo "============================================="
echo " 结果: $PASS 通过, $FAIL 失败"
echo "============================================="

[ $FAIL -eq 0 ] && exit 0 || exit 1
