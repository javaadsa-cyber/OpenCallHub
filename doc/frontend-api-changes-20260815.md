# 后端 API 变更通知（2026-08-15）

前端仓库 `waihu-app` 需要适配以下后端变更。所有 API 基地址：`http://<host>:4320`。

---

## 1. SIP 网关增加「外呼前缀」字段

**后端已完成，前端需加表单字段。**

### 影响接口

| 接口 | 方法 | 路径 |
|---|---|---|
| 网关详情 | POST | `/system/v1/gateway/get/{id}` |
| 新增网关 | POST | `/system/v1/gateway/add` |
| 编辑网关 | POST | `/system/v1/gateway/edit/{id}` |
| 网关列表 | POST | `/system/v1/gateway/page/list` |
| 网关列表(不分页) | POST | `/system/v1/gateway/list` |

### 新增字段

```json
{
  "outboundPrefix": "9118"
}
```

- 类型：`String`
- 可空：是（空字符串 = 不加前缀）
- 含义：运营商要求的外呼接入码，系统自动拼到被叫号码前。如 `9118` 表示拨 `85265494339` 实际发送 `911885265494339`。

### 前端改动

在网关**新增/编辑**表单中增加一个输入框：

```vue
<el-form-item label="外呼前缀" prop="outboundPrefix">
  <el-input v-model="form.outboundPrefix" placeholder="运营商接入码，如 9118（留空表示不加）" />
</el-form-item>
```

在网关**列表**页增加一列显示 `outboundPrefix`（可选）。

---

## 2. SIP 服务器动态配置 API（公开，无需鉴权）

**前端软电话启动时调用，替代硬编码的 WebSocket 地址。**

```
GET /api/sip/config
```

响应（无需 Authorization header）：

```json
{
  "code": 200,
  "data": {
    "wsUrl": "ws://120.253.136.198:5066",
    "sipHost": "120.253.136.198",
    "sipPort": 5060
  }
}
```

### 前端改动

软电话初始化时：

```javascript
// 替代硬编码的 VITE_SIP_WS_SERVERS / VITE_SIP_HOST
const res = await fetch('http://<host>:4320/api/sip/config')
const { wsUrl, sipHost, sipPort } = (await res.json()).data

// 用 wsUrl 连接 WebSocket SIP
// 用 sipHost 作为 SIP 域名
```

可保留 env 变量作为 fallback（API 调用失败时用）。

---

## 3. 当前环境数据（供调试参考）

| 配置项 | 值 |
|---|---|
| 运营商网关 ID | 100 |
| 网关名称 | carrier-8.222.185.49 |
| Realm / Proxy | 8.222.185.49 |
| 注册模式 | IP 鉴权（register=0） |
| 外呼前缀 | 9118 |
| 运营商分配 DID | 85257459770 |
| SIP 分机 | 1000 / 1001（密码 1234） |
| WebSocket SIP | ws://120.253.136.198:5066 |
| 管理后台账号 | admin / 12345678 |

---

## 4. Swagger UI 在线调试

`http://120.253.136.198:4320/swagger-ui.html`

可直接在浏览器中测试所有接口，无需写代码。
