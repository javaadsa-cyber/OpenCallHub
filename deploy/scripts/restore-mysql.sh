#!/bin/bash
# ============================================================
# openCallHub MySQL 恢复脚本
# 用法: ./restore-mysql.sh <备份文件路径>
# 示例: ./restore-mysql.sh ./data/backups/openCallHub_20260602_020000.sql.gz
#
# 默认通过 `docker compose exec` 在 mysql 容器内恢复；
# 外部 DB 走 OCH_DB_MODE=host + MYSQL_* env。
#
# 警告：会覆盖目标数据库现有数据。
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."

BACKUP_FILE="$1"
if [ -z "$BACKUP_FILE" ]; then
    echo "错误: 请指定备份文件路径"
    echo "用法: $0 <备份文件>"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "错误: 备份文件不存在: $BACKUP_FILE"
    exit 1
fi

MYSQL_DATABASE="${MYSQL_DATABASE:-openCallHub}"
OCH_DB_MODE="${OCH_DB_MODE:-container}"   # container | host

echo "[$(date)] 警告: 即将覆盖数据库 $MYSQL_DATABASE (mode=$OCH_DB_MODE)"
read -p "确认继续? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "已取消"
    exit 0
fi

echo "[$(date)] 开始恢复 $MYSQL_DATABASE 从 $BACKUP_FILE ..."

if [ "$OCH_DB_MODE" = "container" ]; then
    gunzip -c "$BACKUP_FILE" \
        | docker compose exec -T mysql sh -c \
            "mysql -uroot -p\"\${MYSQL_ROOT_PASSWORD:-123456}\" $MYSQL_DATABASE"
else
    gunzip -c "$BACKUP_FILE" \
        | mysql -h"${MYSQL_HOST:-127.0.0.1}" -P"${MYSQL_PORT:-3306}" \
            -u"${MYSQL_USER:-root}" -p"${MYSQL_PASSWORD:-123456}" "$MYSQL_DATABASE"
fi

echo "[$(date)] 恢复完成"
