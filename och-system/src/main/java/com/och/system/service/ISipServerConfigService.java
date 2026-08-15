package com.och.system.service;

import com.baomidou.mybatisplus.extension.service.IService;
import com.och.system.domain.entity.SipServerConfig;
import com.och.system.domain.query.sipconfig.SipServerConfigEditQuery;

/**
 * SIP 服务器配置 Service
 */
public interface ISipServerConfigService extends IService<SipServerConfig> {

    /**
     * 获取最新的 SIP 服务器配置（前端软电话用）
     */
    SipServerConfig getLatestConfig();

    /**
     * 编辑 SIP 服务器配置
     */
    void editConfig(SipServerConfigEditQuery query);
}
