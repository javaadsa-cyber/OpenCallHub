# openCallHub 故障演练文档

演练目标：验证系统在常见故障场景下的容错能力和恢复流程。
所有容器名对应 `docker-compose.yml` 的 `container_name`。

运行前先启动完整栈：`docker compose up -d`，等所有服务 healthy。
每个场景的"验证"步骤可统一用 `bash deploy/scripts/health-check.sh` 一键检查。

---

## 场景 1: MySQL 主库宕机

**模拟**: `docker stop och-mysql`

**预期行为**:
- [ ] `health-check.sh` 显示 MySQL ❌，och-api ❌（连不上 DB，TCP 探活失败）
- [ ] FreeSWITCH 自身不受影响（已启动的进程继续运行）
- [ ] 已有通话不受影响（FS 状态保存在内存）
- [ ] 新呼叫可能失败（dialplan 查询走 xml_curl → och-api → MySQL）

**恢复**: `docker start och-mysql`

**验证**:
- [ ] `health-check.sh` 全部 ✅
- [ ] `docker compose exec mysql mysql -uroot -p123456 -e "select 1"` 返回 1
- [ ] 新呼叫可正常路由

---

## 场景 2: FreeSWITCH ESL 断连

**模拟**: `docker stop och-freeswitch`

**预期行为**:
- [ ] `health-check.sh` 显示 FreeSWITCH ❌
- [ ] `docker compose logs och-api | grep -iE "Connect failed"` 出现 ESL 重连失败日志
- [ ] 已有通话立即中断（媒体/信令均经 FS）
- [ ] 软电话注册失效

**恢复**: `docker start och-freeswitch`

**验证**:
- [ ] `health-check.sh` 全部 ✅
- [ ] `docker compose exec freeswitch fs_cli -p ClueCon -x "show channels count"` 返回 `0 total.`
- [ ] `docker compose logs och-api | grep "xmlCurl"` 能看到 FS 重启后重新拉取 configuration/dialplan

---

## 场景 3: Redis 宕机

**模拟**: `docker stop och-redis`

**预期行为**:
- [ ] `health-check.sh` 显示 Redis ❌
- [ ] och-mrcp（依赖 Redis）可能停止工作
- [ ] 已有通话继续（FS 不依赖 Redis）
- [ ] och-api 缓存失效但基础功能仍可用

**恢复**: `docker start och-redis`

**验证**:
- [ ] `health-check.sh` 全部 ✅
- [ ] `docker compose exec redis redis-cli -a 123456 ping` 返回 PONG
- [ ] och-mrcp 日志重新出现 "Redisson connect"

---

## 场景 4: och-api 宕机

**模拟**: `docker stop och-api`

**预期行为**:
- [ ] `health-check.sh` 显示 och-api ❌
- [ ] xml_curl 失败：FS 新呼叫拿不到 dialplan/acl → 路由失败
- [ ] FS 已加载的动态配置仍在内存，已有通话不受影响
- [ ] ESL 事件停止上报，WebSocket 推送停止

**恢复**: `docker start och-api`

**验证**:
- [ ] `health-check.sh` 全部 ✅
- [ ] `curl -s -o /dev/null -w "%{http_code}" http://localhost:4320/swagger-ui.html` 返回 200
- [ ] 新呼叫可正常路由

---

## 场景 5: och-mrcp 宕机

**模拟**: `docker stop och-mrcp`

**预期行为**:
- [ ] `health-check.sh` 显示 och-mrcp ❌
- [ ] ASR/TTS 不可用（涉及语音识别/合成的 IVR 节点失败）
- [ ] 普通 SIP 通话不受影响（媒体不经过 MRCP）

**恢复**: `docker start och-mrcp`

**验证**:
- [ ] `health-check.sh` 全部 ✅
- [ ] `docker compose logs och-mrcp | grep -i "SIP server started"` 重新出现
- [ ] MRCP 客户端可重新建立 SIP 注册

---

## 场景 6: 数据卷损坏（最坏情况）

**模拟**: `docker compose down -v`（会清空 mysql-data / och-record / och-temp）

**预期行为**:
- [ ] 所有数据丢失（数据库、录音）
- [ ] 下次 `docker compose up -d` 会重新初始化（doc/system.sql + 02-seed.sql 重跑）

**恢复**:
```bash
# 从最近的备份恢复
bash deploy/scripts/restore-mysql.sh ./data/backups/openCallHub_XXXXXXXX_XXXXXX.sql.gz
```

**预防**:
- [ ] 配置 crontab 定期执行 `backup-mysql.sh`（建议每日凌晨）
- [ ] 备份文件定期异地保存（对象存储 / NAS）

---

## 通用排查命令

```bash
# 全链路健康
bash deploy/scripts/health-check.sh

# 单服务日志
docker compose logs -f --tail 100 <service>    # service: mysql / redis / freeswitch / och-api / och-mrcp

# 进入容器调试
docker compose exec <service> sh

# 查看 compose 资源占用
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
```
