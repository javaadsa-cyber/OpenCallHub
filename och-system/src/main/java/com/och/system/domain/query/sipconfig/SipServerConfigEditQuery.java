package com.och.system.domain.query.sipconfig;

import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Data;

@Schema
@Data
public class SipServerConfigEditQuery {

    @Schema(description = "主键ID")
    @NotNull(message = "ID不能为空")
    private Integer id;

    @Schema(description = "WebSocket SIP 地址，如 ws://120.253.136.198:5066")
    @NotBlank(message = "wsUrl不能为空")
    private String wsUrl;

    @Schema(description = "SIP 域名/IP")
    @NotBlank(message = "sipHost不能为空")
    private String sipHost;

    @Schema(description = "SIP UDP 端口")
    private Integer sipPort;
}
