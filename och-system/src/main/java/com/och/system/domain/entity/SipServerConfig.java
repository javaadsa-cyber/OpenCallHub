package com.och.system.domain.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import io.swagger.v3.oas.annotations.media.Schema;
import lombok.Data;

import java.io.Serializable;
import java.time.LocalDateTime;

/**
 * SIP 服务器配置（前端软电话动态获取 WebSocket 地址）
 */
@Schema
@Data
@SuppressWarnings("serial")
@TableName("sip_server_config")
public class SipServerConfig implements Serializable {

    @Schema(description = "主键ID")
    @TableId(type = IdType.AUTO)
    private Integer id;

    @Schema(description = "WebSocket SIP 地址，如 ws://120.253.136.198:5066")
    @TableField("ws_url")
    private String wsUrl;

    @Schema(description = "SIP 域名/IP")
    @TableField("sip_host")
    private String sipHost;

    @Schema(description = "SIP UDP 端口")
    @TableField("sip_port")
    private Integer sipPort;

    @Schema(description = "创建时间")
    @TableField("create_time")
    private LocalDateTime createTime;

    @Schema(description = "更新时间")
    @TableField("update_time")
    private LocalDateTime updateTime;

    @Schema(description = "删除标志 0-正常 1-已删除")
    @TableField("del_flag")
    private Integer delFlag;
}
