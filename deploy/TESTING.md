# OpenCallHub 测试指南

仓库本身**没有可用的自动化测试**（仅 2 个 @SpringBootTest：一个需要真实 DashScope key，一个是无法启动的空壳），验证只能手工进行。本文按依赖从轻到重分 4 层，L1/L2 的预期输出均已在本地 Docker 环境实测（2026-08-11）。

> **前端说明**：本仓库是纯后端，无前端代码。前端在独立仓库
> `https://gitee.com/zhongjiawei999/waihu-app`（见根 README），克隆运行后把后端地址指向
> `http://<宿主机IP>:4320` 即可。没有前端时用 Swagger UI 可完成全部 API 验证；
> 官方演示站 `https://opencallhub.com`（admin/12345678）可对照预期行为。

## 重要约定

- 所有业务接口 HTTP 状态码都返回 200，**成功与否看响应体 `code` 字段**（200=成功，401=未登录等）
- 认证方式：`Authorization: Bearer <accessToken>`（登录返回，JWT，`expiresIn: 720`）
- 登录账号：`admin / 12345678`（system.sql 种子）

---

## L1 栈健康检查（无需 FreeSWITCH，30 秒）

```bash
docker compose ps
# 预期：och-mysql healthy、och-redis healthy、och-freeswitch healthy、och-api healthy、och-mrcp running

docker compose exec -T mysql mysql -uroot -p123456 -N -e \
  "select count(*) from information_schema.tables where table_schema='openCallHub';"
# 预期：60（业务表 50 + Quartz QRTZ_* 10）

docker compose exec -T mysql mysql -uroot -p123456 -e \
  "select name,ip,port,status from openCallHub.fs_config;"
# 预期：至少 1 行（status 0=在线 1=下线；FS 未配置时下线是正常的）

docker compose exec -T redis redis-cli -a 123456 ping
# 预期：PONG
```

## L2 API 功能测试（无需 FreeSWITCH）

### 登录（已实测）

```bash
curl -s -X POST http://localhost:4320/auth/v1/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"12345678","loginType":"1"}'
# 预期：{"code":200,"msg":"操作成功","data":{"accessToken":"eyJhbG...","expiresIn":720}}
```

### 带 token 调只读接口（已实测）

```bash
TOKEN=<上一步返回的 accessToken>
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4320/system/v1/user/getRouters
# 预期：{"code":200,...} 返回菜单路由树

curl -s http://localhost:4320/system/v1/user/getRouters
# 预期：HTTP 状态仍是 200，但响应体 {"code":401,"msg":"未授权,请登录后重试"}
```

### WebSocket（已实测）

握手走 `?token=` 查询参数，且 token 必须在 Redis 会话中（即先登录）：

```bash
curl -s -i -N -m 3 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://localhost:4320/ws?token=$TOKEN" | head -1
# 预期：HTTP/1.1 101（Switching Protocols）；无 token 时返回 200 且不升级
```

### Swagger / Druid

- Swagger UI：`http://localhost:4320/swagger-ui/index.html`（预期 200；`/v3/api-docs` 可导入 Postman/Apifox）
- Druid SQL 监控：`http://localhost:4320/druid/`（admin/admin123）——手工测试时观察慢 SQL 与执行次数
- 控制器分组：`/auth/v1`（登录）、`/system/v1`（用户/角色/菜单/日志）、call/calltask/customer/fs/ko 等业务域

## L3 通话链路测试（FreeSWITCH 已容器化，无需外部组件）

compose 内置 FS（源码编译 v1.10.12）：xml_curl 指向容器内 `och-api:4320`，
SIP 注册走 FS 内置 directory（**1000~1019，密码 1234**，无需 Kamailio），
拨号计划由 `fs_dialplan` 种子提供（1000~1099 分机互拨）。

### 前置配置

1. `.env` 的 `OCH_HOST_IP` = 宿主机对外 IP（软电话/话机要能路由到它）
2. `docker compose up -d` 后等 och-freeswitch 变 healthy（种子已把 fs_config 指向 `freeswitch`）

### 验证步骤

```bash
# ① ESL 连接：不应出现 Connect failed
docker compose logs och-api | grep -iE "Connect failed|fsClient" | tail

# ② xml_curl：FS 启动即向 och-api 拉 configuration/dialplan
docker compose logs och-api | grep "xmlCurl" | tail   # 应看到请求与返回的 XML

# ③ FS 侧状态：internal profile 监听 5060
docker compose exec freeswitch fs_cli -P ClueCon -x "sofia status profile internal" | head -15

# ④ 软电话互拨：两台软电话注册 <宿主机IP>:5060（UDP），
#    账号 1000/1234 与 1001/1234；1000 拨 1001 → 振铃、接听、双向语音
docker compose exec freeswitch fs_cli -P ClueCon -x "show channels"   # 通话中可见通道

# ⑤ 话单入库（注意：mod_odbc_cdr/mod_xml_cdr 默认未加载，CDR 入库暂不可用，后续项）
docker compose exec -T mysql mysql -uroot -p123456 -e "select count(*) from openCallHub.fs_cdr;"

# ⑥ 录音文件（如呼叫开启录音）
docker compose exec och-api ls -l /record
```

## L4 语音识别/合成测试（需要阿里云 NLS 密钥）

1. 复制 `och-mrcp/src/main/resources/engine.conf` 到 `deploy/mrcp/config/engine.conf`，填入真实
   appKey/apiKey/apiSecret，取消 docker-compose.yml 中 och-mrcp 的 volumes 注释后 `docker compose up -d och-mrcp`
2. 端口可达性（容器化 FS 走宿主机回连 och-mrcp，FS 容器内验证）：

   ```bash
   docker compose exec freeswitch bash -c 'exec 3<>/dev/tcp/<宿主机IP>/1544 && echo OK'  # MRCP
   ```

3. FS 侧用 `detect_speech unimrcp:<宿主机IP> ...` 发起会话（`docker compose exec freeswitch fs_cli`）；
   `docker compose logs och-mrcp` 应出现 SDP 协商与 10000-20000 段的 RTP 端口分配

---

## 快速判定表（现象 → 结论）

| 现象 | 结论/处理 |
|---|---|
| `docker compose ps` 有容器非 healthy | `docker compose logs <名>` 看启动错误 |
| 4320 无法访问 | och-api 没起来或防火墙未放行（外部 FS 也需要能访问 4320） |
| 登录返回 code≠200 | 密码被改（种子是 admin/12345678）；数据库未初始化则所有接口 500 |
| 侧边栏只有一级目录、点开没有子菜单 | sys_menu 的 parent_id 与 menu_id 失联（种子省略 menu_id 被 AUTO_INCREMENT 漂移过）。校验：`SELECT count(*) FROM sys_menu m WHERE m.parent_id<>0 AND NOT EXISTS(SELECT 1 FROM sys_menu p WHERE p.menu_id=m.parent_id)` 应为 0。doc/system.sql 的种子必须显式写 menu_id |
| 改了菜单但前端不生效 | 前端把菜单缓存在 localStorage `niubee-menus` 且旧版从不清除；重新登录一次即可（新版登录时会清缓存） |
| 带 token 仍 401 | token 过期（720 分钟）或 Redis 被清空（会话存 Redis） |
| 软电话注册失败 | 服务器地址要填**宿主机 IP**:5060（不是 127.0.0.1，除非软电话就在宿主机）；密码 1234（FS 内置 directory）；`docker compose exec freeswitch fs_cli -P ClueCon -x "sofia loglevel all 9"` 看 SIP 报文 |
| ESL 一直 `Connect failed: xxx:8021` | fs_config 的 ip/密码错误、FS 未放行 8021、或容器到 FS 网络不通（容器化 FS 时 ip 应为服务名 freeswitch） |
| FS 已启动但 ESL 仍不连（日志也无重试） | och-api 启动时连接失败会把 fs_config.status 自动置为 1（下线），之后不再重试。需到管理后台「FS配置」重新上线，或 `UPDATE openCallHub.fs_config SET status=0` |
| FS 呼叫时报 xml_curl 错误 | 密钥不一致或 FS 访问不到 4320；文档里的 8080 端口是过时的，实际 4320 |
| 通话无声 | RTP 端口段未放行；och-mrcp 场景检查 10000-20000/udp |
| och-mrcp 启动即退 | Redis 不可用（硬编码 127.0.0.1:6379 + 密码 123456） |
| ASR/TTS 无结果 | engine.conf 仍是占位符密钥 |
