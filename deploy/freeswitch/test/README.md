# FreeSWITCH 无软电话自动化测试套件

不依赖软电话、可重复执行的 FreeSWITCH 呼叫面验证，覆盖三层：

| 测试 | 脚本 | 覆盖内容 |
|---|---|---|
| ① 冒烟 | `smoke.sh` | compose 健康、ESL 可达、sofia RUNNING/5060、无残留通道、fs_config.status=0 |
| ② dialplan | `loopback-dialplan.sh` | 运行时插入临时路由 `^9990$` → `originate loopback/9990/default` 验证 xml_curl 按呼叫实时拉取 dialplan 的完整链路 |
| ③ SIP+RTP | `sipp-call.sh` | SIPp 注册 1000/1001 → 1000 呼 1001（种子 dialplan `bridge user/$1`）→ 接通后放 440Hz 音调 → FS 侧录音断言 RTP 真实到达 |

## 运行

```bash
docker compose up -d                      # 核心栈先起来并全部 healthy
bash deploy/freeswitch/test/run-all.sh    # 依次跑三项，退出码 0 = 全绿
```

首次运行测试 ③ 会自动：
1. 抓取 sipp v3.7.7 源码到 `src/sipp/`（github 优先、失败自动回退 gitcode 镜像
   `gitcode.com/gh_mirrors/si/sipp`；两个都失败可手工下载
   `https://github.com/SIPp/sipp/archive/refs/tags/v3.7.7.tar.gz` 解压到该目录）
2. 构建 `och-sipp:local` 镜像并启动 sipp 容器（compose profile `test`，不影响核心栈）

单独跑某一项：`bash deploy/freeswitch/test/smoke.sh` 等；每项脚本自带幂等预清理，
崩溃残留（DB 行/通道/注册）不影响下次运行。

## 设计要点

- **测试 ② 无需 reload**：FS 的 dialplan 绑定 xml_curl，每次建 channel 都实时向 och-api
  拉取，因此运行时 INSERT `fs_dialplan` 立即生效，测完 DELETE 即可。路由 content 里 app 名
  用小写（解析端 `AppEnum` 经 fastjson2 反序列化，大小写不敏感，与种子一致）。
- **媒体断言防假阳性**：SIPp 默认不发任何 RTP（含静音）；且即使没有 RTP，FS soft timer
  也会写静音帧让录音文件非零。因此 UAC 用 `rtp_stream` 显式放 440Hz μ-law 音调
  （构建期 `gen-tone.py` 生成裸采样），断言 =「录音 ≥ 20KB」**且**「采样方差 > 阈值」
  （静音方差≈0，音调方差大），见 `check_wav.py`。
- **ACL 是测试 ③ 的前提**：动态 sofia internal profile 带 `auth-calls=true` +
  `apply-inbound-acl=domains`。注意 acl 里 `domain=` 节点的真实语义是"展开 directory
  中带 cidr= 属性的用户"（见 FS 源码 `switch_core.c` 的 `switch_load_network_lists`），
  并不是"放行已注册来源 IP"——本地 directory 用户没有 cidr 属性，所以 02-seed.sql
  必须给 domains 列表种 RFC1918 cidr 节点，否则 INVITE 会被 407 质询而失败
  （REGISTER 有 digest 兜底不受影响）。
- **已知局限**：媒体断言只覆盖 sipp→FS 单向；FS→sipp 方向无测量钩子
  （可给 UAS 场景加 `-mi` 开 RTP echo，仅肉眼/抓包辅助）。
- SIPp SDP 只协商 PCMU：本 FS 构建禁用了 mod_spandsp，G722 不可用。

## 目录结构

```
test/
├── run-all.sh               # 入口：预清理 → ①②③ → PASS/FAIL 汇总
├── lib/common.sh            # fs_cli/mysql 封装、断言、wait_for 轮询
├── smoke.sh                 # 测试①
├── loopback-dialplan.sh     # 测试②
├── sipp-call.sh             # 测试③编排
├── fetch-sipp-sources.sh    # 预抓 sipp 源码（构建离线化）
├── sipp/                    # Dockerfile + gen-tone.py + check_wav.py
├── scenarios/               # 4 个 SIPp 场景（REGISTER×2、UAS、UAC）
└── src/sipp/                # fetch 产物，gitignore，勿提交
```
