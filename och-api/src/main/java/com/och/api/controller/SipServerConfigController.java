package com.och.api.controller;

import com.och.common.annotation.Log;
import com.och.common.base.BaseController;
import com.och.common.base.ResResult;
import com.och.common.enums.BusinessTypeEnum;
import com.och.system.domain.entity.SipServerConfig;
import com.och.system.domain.query.sipconfig.SipServerConfigEditQuery;
import com.och.system.service.ISipServerConfigService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;

/**
 * SIP 服务器配置（公开 API，前端软电话启动时获取 WebSocket 地址）
 */
@Tag(name = "SIP 服务器配置")
@RestController
@RequestMapping("/api/sip")
@RequiredArgsConstructor
public class SipServerConfigController extends BaseController {

    private final ISipServerConfigService sipServerConfigService;

    @Operation(summary = "获取 SIP 连接配置（无需鉴权）")
    @GetMapping("/config")
    public ResResult<SipServerConfig> getConfig() {
        SipServerConfig config = sipServerConfigService.getLatestConfig();
        return success(config);
    }

    @Log(title = "编辑SIP服务器配置", businessType = BusinessTypeEnum.UPDATE)
    @PreAuthorize("@authz.hasPerm('system:sip:edit')")
    @Operation(summary = "编辑SIP服务器配置")
    @PostMapping("/config/edit")
    public ResResult editConfig(@RequestBody @Validated SipServerConfigEditQuery query) {
        sipServerConfigService.editConfig(query);
        return success();
    }
}
