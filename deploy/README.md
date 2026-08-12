# OpenCallHub Docker 本地开发/测试部署

本目录配合仓库根部的 `Dockerfile` / `docker-compose.yml` 使用，实现：
**MySQL + Redis + FreeSWITCH + och-api + och-mrcp** 一键容器化启动。

> FreeSWITCH 由 `deploy/freeswitch/Dockerfile` **源码编译**（v1.10.12，因镜像源白名单无
> signalwire/freeswitch），配置覆盖在 `deploy/freeswitch/autoload_configs/`。
> Kamailio 不在 compose 内：SIP 注册直连 FS 内置 directory（1000~1019，密码 1234），无需 Kamailio。
> 前端管理界面也不在仓库内（见根 README 的前端仓库链接），API 验证用 Swagger UI。

## 前置条件

- **Linux 宿主机**（och-mrcp 使用 host 网络，macOS/Windows 不支持，见文末降级路径）
- Docker + compose 插件
- （可选）外部 FreeSWITCH：不用 compose 内置 FS 时，改 `02-seed.sql` 的 fs_config 指向它，
  其 `xml_curl` 需指向 `http://<宿主机IP>:4320/fs/curl/api`，basic 密钥
  `b4c91178-c00e-7e42-6a9b-2c470eb0fb30`（och-api 的 `fs.xml-curl.secretKey`）

## 快速开始

```bash
cp .env.example .env      # OCH_HOST_IP = 宿主机对外 IP（仅 och-mrcp 的 SIP Contact 头用）
docker compose build      # 首次含 FS 源码编译，约 10-20 分钟
docker compose up -d
docker compose ps         # mysql/redis/freeswitch/och-api 应 healthy，och-mrcp running
```

软电话（Linphone 等）注册：**服务器 `<宿主机IP>:5060`（UDP），账号 1000，密码 1234**；
再注册 1001，两者互拨即可通话（拨号计划种子见 `02-seed.sql`）。

## 服务与端口

| 服务 | 端口 | 说明 |
|---|---|---|
| freeswitch | 5060 (udp+tcp) | SIP internal profile（软电话注册） |
| freeswitch | 8021 | ESL inbound，密码 ClueCon（宿主机 `fs_cli -H 127.0.0.1 -P 8021 -p ClueCon` 调试；注意 `-p`=密码 `-P`=端口） |
| freeswitch | 20000-20199/udp | RTP 媒体段（收窄配置见 switch.conf.xml） |
| och-api | 4320 | HTTP / Swagger (`/swagger-ui.html`) / Druid (`/druid/`，admin/admin123) / FS xml_curl (`/fs/curl/api`) |
| och-api | 9527 | 内嵌 Netty 文件服务 |
| och-mrcp | 7010 (udp+tcp) | SIP 信令（host 网络） |
| och-mrcp | 1544 | MRCP v2（host 网络） |
| och-mrcp | 10000-20000/udp | RTP 媒体端口段（host 网络） |
| mysql | 3306 | 已发布到宿主机，方便 IDE 调试（可删） |
| redis | 6379 | 密码固定 `123456`（och-mrcp 硬编码约束，**勿改**） |
| sipp | 无 | 仅测试用（profiles: `test`，`docker compose --profile test` 激活）：SIPp 无软电话自动化测试，见 `deploy/freeswitch/test/README.md` |

管理后台账号：`admin / 12345678`（system.sql 种子）。

## 重要说明

1. **Redis 密码被锁死为 123456**：`och-mrcp` 的 `RedissonManager` 硬编码了
   `redis://127.0.0.1:6379` + 密码 `123456`，无配置覆盖入口；compose 中 Redis 必须带此密码且发布
   6379（host 网络的 och-mrcp 通过宿主机回环访问）。仅适用于本地开发。
2. **种子数据只在空数据卷首次启动时执行**。修改 `02-seed.sql` 后要
   `docker compose down -v && docker compose up -d` 才会重跑（会清空数据）。
3. **fs_config 里的 FS 地址**：容器化 FS 填服务名 `freeswitch`（默认种子已配好）；
   外部 FS 填其 IP，不能填 127.0.0.1（och-api 容器内指向容器自身）。
   注意：och-api 启动时若 ESL 连不上会把 fs_config 置为下线且不再重试，
   所以 compose 里 och-api 依赖 freeswitch 先 healthy。
4. **大数据量参考表默认不导入**（`phone_location.sql` 约 51 万行）。需要时取消
   `docker-compose.yml` 中 mysql 服务里相应挂载的注释（首次初始化才会执行）。
5. **阿里云 ASR/TTS 密钥**：复制 `och-mrcp/src/main/resources/engine.conf` 到
   `deploy/mrcp/config/engine.conf`，填入真实密钥，然后取消 och-mrcp 服务的 volumes 注释。
   （`/app/config` 在 classpath 最前，同名 conf 覆盖 jar 内文件。）
6. SIP Contact 头地址：och-mrcp 通过 `-Dsip.server.address=${OCH_HOST_IP}` 覆盖，
   外部 FS 必须能路由到该 IP，否则回包失败。
7. **och-file-client 未容器化**：它正常部署在 FreeSWITCH 主机上（拉取录音/语音文件到
   `/usr/local/freeswitch/sounds`），本地验证一般用不到；需要时可参照 och-api 的 build 方式
   自行添加 service。

## macOS / Windows 降级路径

host 网络不可用时的替代方案：

```bash
# compose 只起中间件和 och-api
docker compose up -d mysql redis och-api
# och-mrcp 裸跑在宿主机（localhost 天然成立）
mvn -pl och-mrcp -am package -DskipTests
java -jar och-mrcp/target/och-mrcp-jar-with-dependencies.jar
```

## 验证清单

```bash
# 中间件
docker compose exec redis redis-cli -a 123456 ping                                   # PONG
docker compose exec mysql mysql -uroot -p123456 -e "show tables in openCallHub;"     # ~50 张表
docker compose exec mysql mysql -uroot -p123456 -e "select * from openCallHub.fs_config;"

# freeswitch
docker compose exec freeswitch fs_cli -p ClueCon -x "sofia status profile internal" | grep -E "5060|REG"
docker compose logs och-api | grep -iE "Connect failed"   # 应为空（ESL 已连上）

# och-api
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4320/swagger-ui.html       # 200
docker compose logs och-api | grep "xmlCurl"   # FS 启动时的 configuration/dialplan 拉取请求

# och-mrcp
docker compose logs och-mrcp                   # SIP 7010 / MRCP 1544 启动、Redisson 连接成功
nc -vz 127.0.0.1 1544 && nc -vzu 127.0.0.1 7010
```

之后用软电话注册 `<宿主机IP>:5060`（1000/1234、1001/1234）互拨一路，观察 och-api 日志收到
呼叫事件；端到端流程（软电话注册 → 呼叫 → 路由 → ESL 下发）走通即部署成功。
录音文件在 `och-record` 卷（`docker compose exec och-api ls /record`）。
