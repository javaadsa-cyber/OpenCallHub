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
