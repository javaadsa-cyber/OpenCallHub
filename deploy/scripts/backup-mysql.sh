#!/bin/bash
# ============================================================
# openCallHub MySQL 备份脚本
# 用法: ./backup-mysql.sh
# 建议 crontab: 0 2 * * * /path/to/backup-mysql.sh
#
# 默认通过 `docker compose exec` 在 mysql 容器内运行 mysqldump
# （无宿主机客户端依赖，容器内连接 localhost 即可）。
# 若 MySQL 不在本 compose 栈内（外部 DB），改 env 走 mysqldump 直连：
#   OCH_DB_MODE=host MYSQL_HOST=x.x.x.x MYSQL_PORT=3306 \
#   MYSQL_USER=root MYSQL_PASSWORD=xxx ./backup-mysql.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."   # 回到仓库根，保证 docker compose 能找到 compose 文件

BACKUP_DIR="${BACKUP_DIR:-./data/backups}"
MYSQL_DATABASE="${MYSQL_DATABASE:-openCallHub}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
OCH_DB_MODE="${OCH_DB_MODE:-container}"   # container | host

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${MYSQL_DATABASE}_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] 开始备份 $MYSQL_DATABASE (mode=$OCH_DB_MODE) ..."

DUMP_OPTS="--single-transaction --routines --triggers --events --set-gtid-purged=OFF"

if [ "$OCH_DB_MODE" = "container" ]; then
    docker compose exec -T mysql sh -c \
        "mysqldump -uroot -p\"\${MYSQL_ROOT_PASSWORD:-123456}\" $DUMP_OPTS $MYSQL_DATABASE" \
        | gzip > "$BACKUP_FILE"
else
    mysqldump \
        -h"${MYSQL_HOST:-127.0.0.1}" -P"${MYSQL_PORT:-3306}" \
        -u"${MYSQL_USER:-root}" -p"${MYSQL_PASSWORD:-123456}" \
        $DUMP_OPTS "$MYSQL_DATABASE" | gzip > "$BACKUP_FILE"
fi

echo "[$(date)] 备份完成: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# 删除超过保留期的备份
find "$BACKUP_DIR" -name "${MYSQL_DATABASE}_*.sql.gz" -mtime +$RETENTION_DAYS -delete
echo "[$(date)] 清理超过 ${RETENTION_DAYS} 天的旧备份完成"
