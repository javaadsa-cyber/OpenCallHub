-- 勿删：mysql Docker entrypoint 以 latin1 客户端字符集导入 init 脚本，
-- 不先 SET NAMES utf8mb4 会把本文件的 UTF-8 中文双重编码成乱码。
SET NAMES utf8mb4;

-- OpenCallHub 本地开发种子数据
-- 仅在 MySQL 数据卷为空、容器首次初始化时执行一次。
-- 改动后需 docker compose down -v && docker compose up -d 才会重新生效。

-- ============================================================
-- FreeSWITCH 节点（och-api 启动时按此表建立 ESL 连接）
-- ip     : FS 地址。容器化 FS（compose 的 freeswitch 服务）直接填服务名 freeswitch；
--          外部 FS 则填其 IP（och-api 容器须可路由到达，不要填 127.0.0.1 ——
--          容器内 127.0.0.1 指向容器自身）
-- port   : ESL inbound 端口，默认 8021
-- password: FS event_socket.conf.xml 里的密码（默认 ClueCon）
-- out_time: ESL 连接超时（秒）
-- status : 0=在线(参与连接) 1=下线
-- 注意：och-api 启动时连接失败会自动把 status 置为 1（下线）且不再重试；
--       FS 就绪后需在管理后台「FS配置」重新上线，或 UPDATE fs_config SET status=0
-- ============================================================
INSERT INTO fs_config
(`name`, `group`, `ip`, `port`, `user_name`, `password`, `status`, `out_time`, `create_by`, `create_time`, `del_flag`)
VALUES
('fs-local', '', 'freeswitch', 8021, 'admin', 'ClueCon', 0, 10, 1, NOW(), 0);
-- 外部 FS 时改为（注释掉上面一行）：
-- ('fs-local', '', '<FS主机IP>', 8021, 'admin', 'ClueCon', 0, 10, 1, NOW(), 0);

-- ============================================================
-- 拨号计划种子：本地分机互拨（1000~1099 → bridge user/分机号）。
-- 必须种：dialplan 已绑定 xml_curl，fs_dialplan 表为空时 FS 拿不到任何路由。
-- 两个 context 都种：动态 sofia 配置里 internal profile 的 context=public
-- （FsSipGatewayXmlCurlHandler），default 兜底。
-- ============================================================
INSERT INTO fs_dialplan
(`group_id`, `name`, `type`, `expression`, `context_name`, `content`, `describe`, `create_by`, `create_time`, `del_flag`)
VALUES
(1, 'local-extension', 'xml', '^(10[0-9]{2})$', 'public',
 '<extension><condition field="destination_number" expression="^(10[0-9]{2})$"><action application="bridge" data="user/$1"/></condition></extension>',
 '本地分机互拨（public）', 1, NOW(), 0),
(1, 'local-extension', 'xml', '^(10[0-9]{2})$', 'default',
 '<extension><condition field="destination_number" expression="^(10[0-9]{2})$"><action application="bridge" data="user/$1"/></condition></extension>',
 '本地分机互拨（default）', 1, NOW(), 0);

-- ============================================================
-- ACL 种子：acl.conf 也走 xml_curl（FsAclXmlCurlHandler 读 fs_acl 表）。
-- 表为空时 FS 拿到的 network-lists 是空的，deploy/freeswitch/autoload_configs/
-- 里的静态 acl.conf.xml 只在 och-api 不可达时兜底，必须种这两个 list：
--   esl_clients : event_socket.conf.xml 的 apply-inbound-acl 引用，
--                 放行 loopback + RFC1918（fs_cli 健康检查与 och-api ESL）
--   domains     : 动态 sofia internal profile 的 apply-inbound-acl 引用。
--     注意 domain= 节点的真实语义（见 FS 源码 switch_core.c
--     switch_load_network_lists）：加载时展开为 directory 里带 cidr=
--     属性的用户，并不是"放行已注册来源 IP"。本地 directory 用户没有
--     cidr 属性，所以必须直接种 RFC1918 cidr 节点放行容器网段的
--     INVITE；否则 auth-calls=true 下 INVITE 会被 407 质询
--     （REGISTER 有 digest 兜底不受影响）。domain 节点保留，
--     与上游/静态配置对齐。
-- fs_acl 为自连接结构：list_id=0 的行是 list 本身，其余行是 node（list_id 指向 list 行 id）。
-- ============================================================
INSERT INTO fs_acl
(`id`, `name`, `default_type`, `list_id`, `node_type`, `cidr`, `domain`, `create_by`, `create_time`, `del_flag`)
VALUES
(1, 'esl_clients', 'deny', 0, NULL,      NULL,            NULL,        1, NOW(), 0),
(2, NULL,          NULL,   1, 'allow',   '127.0.0.0/8',   NULL,        1, NOW(), 0),
(3, NULL,          NULL,   1, 'allow',   '::1/128',       NULL,        1, NOW(), 0),
(4, NULL,          NULL,   1, 'allow',   '10.0.0.0/8',    NULL,        1, NOW(), 0),
(5, NULL,          NULL,   1, 'allow',   '172.16.0.0/12', NULL,        1, NOW(), 0),
(6, NULL,          NULL,   1, 'allow',   '192.168.0.0/16',NULL,        1, NOW(), 0),
(7, 'domains',     'deny', 0, NULL,      NULL,            NULL,        1, NOW(), 0),
(8, NULL,          NULL,   7, 'allow',   NULL,            '$${domain}',1, NOW(), 0),
(9, NULL,          NULL,   7, 'allow',   '10.0.0.0/8',    NULL,        1, NOW(), 0),
(10, NULL,         NULL,   7, 'allow',   '172.16.0.0/12', NULL,        1, NOW(), 0),
(11, NULL,         NULL,   7, 'allow',   '192.168.0.0/16',NULL,        1, NOW(), 0);

-- ============================================================
-- 示例 SIP 坐席（可选）。agent_number 为 SIP 账号（1000/1001），
-- user_id 直接挂到内置 admin(user_id=1) 仅为本地演示；
-- 正式做法是登录管理后台创建用户后再开通坐席。
-- ============================================================
INSERT INTO sip_agent
(`name`, `user_id`, `agent_number`, `status`, `online_status`, `create_by`, `create_time`, `del_flag`)
VALUES
('坐席1000', 1, '1000', 1, 3, 1, NOW(), 0),
('坐席1001', 1, '1001', 1, 3, 1, NOW(), 0);

-- ============================================================
-- 角色-菜单授权。上游 system.sql 的 sys_role_menu 是空的：
-- admin 靠 ROLE_ADMIN 绕过权限检查所以能登录，但任何按角色
-- 取菜单/权限的逻辑（getMenuListByRoleIds）都会拿到空集。
-- 这里把全部菜单授给超级管理员角色(role_id=1)，动态跟随 sys_menu。
-- ============================================================
INSERT INTO sys_role_menu (`role_id`, `menu_id`, `create_by`, `create_time`, `del_flag`)
SELECT 1, `menu_id`, 1, NOW(), 0 FROM sys_menu WHERE `del_flag` = 0;

-- ============================================================
-- 运营商 SIP trunk 基础设施（本地演示用占位符，真实接入需替换）
-- 作用：打通 "坐席外呼 → 运营商 → PSTN" 和 "PSTN → 运营商 → 坐席" 两条通路。
-- 关键链路：
--   外呼：ICallServiceImpl.makeCall → getCallRoute(被叫, type=2) →
--         取 fs_sip_gateway(route_value) → fsClient.makeCall(sofia/external/<called>@<realm>)
--   入呼：FS external profile (context=public) → fs_dialplan 规则 → bridge user/分机
-- 参考：och-api 的 FsSipGatewayXmlCurlHandler 把 fs_sip_gateway 动态下发为 sofia gateway XML。
--
-- 真实运营商接入请替换：realm / proxy / user_name / password / fs_dialplan 的 DID
-- （常见运营商参数：天翼云通信、沃通信、阿里云通信、腾讯云 voIP、容联云 ——
--  realm/proxy 一般给 SIP SBC 域名；transport 多为 UDP，少数要 TCP；
--  认证多为 SIP Digest；部分要求 TLS/SRTP 本演示未覆盖）
-- ============================================================

-- ① 示例 SIP trunk（占位符，id=100 避开 system.sql AUTO_INCREMENT=8 的初始段）
INSERT INTO fs_sip_gateway
(`id`, `name`, `user_name`, `password`, `realm`, `proxy`, `register`, `transport`,
 `caller_id_in_from`, `from_domain`, `retry_time`, `ping_time`, `expire_time`,
 `type`, `gateway_type`, `create_by`, `create_time`, `del_flag`)
VALUES
(100, 'carrier-demo', 'trunk_user', 'trunk_pass',
 'sip.carrier.example.com', 'sip.carrier.example.com',
 1, 1, 0, '', 30, 30, 3600, 2, 1, 1, NOW(), 0);

-- ② 主叫显号 + 被叫显号（ICallServiceImpl.makeCall 取任意显号，这里种两条演示）
--    type=1 主叫显号（外呼时对端看到的来电号），type=2 被叫显号（入呼时本端显号）
--    真实值应使用运营商分配的 DID
INSERT INTO call_display
(`id`, `phone`, `type`, `area`, `create_by`, `create_time`, `del_flag`)
VALUES
(100, '85257459770', 1, '香港', 1, NOW(), 0),
(101, '85257459770', 2, '香港', 1, NOW(), 0);

-- ③ 呼出路由：匹配 11+ 位数字（中国手机号 1xx + 固话 0xx），走 carrier-demo gateway
--    SQL 用 MySQL REGEXP 匹配（见 CallRouteMapper.xml: #{routeNumber} regexp cr.route_num）
--    type=2 (呼出路由)  route_type=2 (外呼)  status=1 (启用)  level=0 (优先级)
--    route_value 是 fs_sip_gateway.id（字符串形式）
INSERT INTO call_route
(`id`, `name`, `route_num`, `type`, `level`, `status`, `route_type`, `route_value`,
 `create_by`, `create_time`, `del_flag`)
VALUES
(100, 'outbound-carrier', '^[0-9]{11,}$', 2, 0, 1, 2, '100', 1, NOW(), 0);

-- ④ DID 入向规则：运营商把入呼送到 FS external profile（context=public），
--    本规则把来电号码 = 01012345678 的呼叫桥到坐席 1000。
--    真实场景按运营商下发的 DID 号段调整 expression。
INSERT INTO fs_dialplan
(`group_id`, `name`, `type`, `expression`, `context_name`, `content`, `describe`,
 `create_by`, `create_time`, `del_flag`)
VALUES
(2, 'inbound-did-demo', 'xml', '^85257459770$', 'public',
 '<extension name="inbound-did-demo"><condition field="destination_number" expression="^85257459770$"><action application="answer"/><action application="set" data="call_direction=inbound"/><action application="bridge" data="user/1000@${domain}"/></condition></extension>',
 '运营商入向 DID 85257459770 → 坐席 1000', 1, NOW(), 0);

-- ============================================================
-- SIP 服务器动态配置（前端软电话通过 /api/sip/config 获取）
-- 作用：前端启动时调用此 API 获取 WebSocket SIP 地址，避免硬编码。
-- ws_url : 软电话 WebSocket 连接地址（浏览器用 ws:// 或 wss://）
-- sip_host : SIP 域名/IP（用于 SIP Contact/Register 头）
-- sip_port : SIP UDP 端口（internal profile，默认 5060）
-- 注意：ws_url 中的 IP 必须是宿主机对外 IP，容器内 IP 浏览器无法直连。
--       部署后请 UPDATE 为实际 IP。
-- ============================================================
CREATE TABLE IF NOT EXISTS sip_server_config (
  `id` INT AUTO_INCREMENT PRIMARY KEY,
  `ws_url` VARCHAR(255) NOT NULL COMMENT 'WebSocket SIP 地址，如 ws://120.253.136.198:5066',
  `sip_host` VARCHAR(255) NOT NULL COMMENT 'SIP 域名/IP，如 120.253.136.198',
  `sip_port` INT NOT NULL DEFAULT 5060 COMMENT 'SIP UDP 端口',
  `create_time` DATETIME DEFAULT NOW(),
  `update_time` DATETIME DEFAULT NOW() ON UPDATE NOW(),
  `del_flag` TINYINT DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SIP 服务器配置（前端软电话动态获取）';

INSERT INTO sip_server_config (`ws_url`, `sip_host`, `sip_port`)
VALUES ('ws://120.253.136.198:5066', '120.253.136.198', 5060);

-- ============================================================
-- 网关外呼前缀（如运营商接入码 9118）
-- 作用：系统发起外呼时自动将此前缀拼到被叫号码前，用户无需手动输入。
-- 字段加在 fs_sip_gateway 上：不同运营商前缀不同，是网关属性。
-- 注意：system.sql 建表时不含此列，首次部署由此处 ALTER 补上。
--       已有部署（数据卷未重建）需手动执行本段 ALTER + UPDATE。
-- ============================================================
SET @col_exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'openCallHub' AND TABLE_NAME = 'fs_sip_gateway' AND COLUMN_NAME = 'outbound_prefix');
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE fs_sip_gateway ADD COLUMN `outbound_prefix` VARCHAR(20) DEFAULT '''' COMMENT ''外呼前缀（自动加在被叫号码前）'' AFTER gateway_type',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- 为已有网关设置前缀（按实际运营商参数修改）
UPDATE fs_sip_gateway SET outbound_prefix = '9118' WHERE id = 100 AND (outbound_prefix IS NULL OR outbound_prefix = '');

-- ============================================================
-- 软电话直拨外线拨号计划
-- 作用：软电话注册到 FS 后直接拨外部号码（如 85265494339），
--       FS 自动加 9118 前缀走运营商网关。
-- 匹配：7-15 位纯数字（排除 10xx 分机，因为 local-extension 先匹配）。
-- 注意：前缀和网关地址需与 fs_sip_gateway 中的实际配置保持一致。
-- ============================================================
INSERT INTO fs_dialplan
(`group_id`, `name`, `type`, `expression`, `context_name`, `content`, `describe`,
 `create_by`, `create_time`, `del_flag`)
SELECT 1, 'outbound-via-carrier', 'xml', '^([0-9]{7,15})$', 'public',
  '<extension name="outbound-via-carrier"><condition field="destination_number" expression="^([0-9]{7,15})$"><action application="bridge" data="sofia/external/9118$1@8.222.185.49"/></condition></extension>',
  '软电话直拨外线：自动加 9118 前缀走运营商网关（按实际网关配置修改前缀和地址）',
  1, NOW(), 0
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM fs_dialplan WHERE name = 'outbound-via-carrier' AND del_flag = 0);
