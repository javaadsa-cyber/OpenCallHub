# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenCallHub is an open-source call center platform (Java 17, Spring Boot 3.5.3, Maven multi-module). It integrates FreeSWITCH (VoIP media/signaling via ESL), Kamailio (SIP proxy), MRCP v2 speech services, and IVR flows. Primary language of comments/docs is Chinese.

## Build & Run

```bash
mvn clean install                 # build all modules
mvn -pl och-api -am spring-boot:run   # run the main API service
java -jar och-api/target/och-api-0.0.1.jar
mvn -pl och-system test           # run tests for one module
mvn -pl och-system -Dtest=SomeTest#method test   # single test
```

Runtime dependencies: MySQL (schema in `doc/system.sql`), Redis, RabbitMQ, and a FreeSWITCH server. Config lives in each runnable module's `src/main/resources/application.yml`.

There are effectively no unit tests in the repo (only a stub context test) — don't claim test verification.

## Modules

- **och-api** — the main deployable service (`OchApiApplication`). REST controllers, WebSocket endpoints, and FreeSWITCH `xml_curl` handlers (`FsDirectoryXmlCurlHandler`, `FsAclXmlCurlHandler`, `FsSipGatewayXmlCurlHandler`) that serve dynamic FS configuration (directory, ACL, gateways) over HTTP.
- **och-esl** — FreeSWITCH ESL client built on Netty (`FsClient`). Core piece: controls calls and receives FS events (`FsEslEventRunnable`).
- **och-ivr** — IVR flow engine: flow definitions, node handlers, listeners; drives call flows on top of och-esl events.
- **och-mrcp** — standalone MRCP v2 server: SIP signaling (`sip/`), RTP media (`rtp/`, G.711/G.722 codec handling, port pooling), and pluggable ASR/TTS engines (`engine/` — Aliyun and Tencent cloud implementations behind `AsrEngine`/`TtsEngine` interfaces + `EngineFactory`). Uses Redisson directly, not Spring Data Redis.
- **och-system** — system management (users, permissions, skill groups, routing).
- **och-security** — auth/JWT/Spring Security.
- **och-call-task** — outbound calling tasks (Quartz).
- **och-ai** — LLM integration (spring-ai-alibaba), in progress.
- **och-websocket**, **och-file**, **och-file-client** — websocket push, file upload/download service (separate runnable app `OchFileClientApplication`).
- **och-common** — NOT a module in this repo; it's an external versioned dependency (`com.och:och-common:1.0.1`) pulled from a repository. Don't look for its source here.

## Architecture Notes

- Call control flow: FreeSWITCH events arrive via och-esl (Netty) → och-ivr handlers execute flow nodes → commands sent back over ESL. Dynamic FS config (users/ACL/gateways) is fetched by FS itself via xml_curl into och-api handlers.
- Speech path: FreeSWITCH negotiates MRCP v2 with och-mrcp over SIP; och-mrcp decodes RTP audio and forwards to the configured cloud ASR/TTS engine.
- Persistence: MyBatis-Plus + MySQL; Redis for cache/session; RabbitMQ for async tasks.
- `doc/` contains ops material: FreeSWITCH/Kamailio setup guides, `kamailio.cfg`/`kamailio.lua`, and SQL schemas (`system.sql` is the main one).

## Docker 部署

`deploy/scripts/` 下提供三个脚本，覆盖从首次安装到日常运维：

| 脚本 | 作用 |
|---|---|
| `install.sh` | 首次安装（装 Docker + 防火墙 + 全套构建），需要 sudo |
| `deploy.sh` | 增量部署（代码更新后重建变更的服务），支持 `--all` / `--backup` / `--reset-network` 等选项 |
| `health-check.sh` | 健康检查（MySQL/Redis/FS/och-api/och-mrcp 端口 + 端到端登录） |

### 典型用法

```bash
# 首次部署
sudo bash deploy/scripts/install.sh

# 日常发版
sudo bash deploy/scripts/deploy.sh                 # 默认更新 och-api + och-mrcp
sudo bash deploy/scripts/deploy.sh --all           # 含 freeswitch（重新编译源码，慢）
sudo bash deploy/scripts/deploy.sh --backup        # 先备份数据库再发布

# 健康检查
bash deploy/scripts/health-check.sh
```

### 网络孤儿故障

症状：`och-api` 启动日志出现 `java.net.UnknownHostException: mysql`，但 `docker compose ps` 显示 mysql Up。

原因：容器脱离了自定义网络 `och`（常见于非正常启停），Docker 内部 DNS 失效。`inspect` 其 `NetworkSettings.Networks` 字段为 `{}`。

修复：

```bash
sudo bash deploy/scripts/deploy.sh --reset-network   # 不丢数据，仅重建容器和网络
```

常规 `deploy.sh` 流程结束时也会跑一次网络完整性检查，发现孤儿会在输出中提示。
