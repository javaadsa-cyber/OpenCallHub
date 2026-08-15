package com.och.system.service.impl;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.extension.service.impl.ServiceImpl;
import com.och.system.domain.entity.SipServerConfig;
import com.och.system.domain.query.sipconfig.SipServerConfigEditQuery;
import com.och.system.mapper.SipServerConfigMapper;
import com.och.system.service.ISipServerConfigService;
import org.springframework.stereotype.Service;

/**
 * SIP 服务器配置 Service 实现
 */
@Service
public class SipServerConfigServiceImpl extends ServiceImpl<SipServerConfigMapper, SipServerConfig>
        implements ISipServerConfigService {

    @Override
    public SipServerConfig getLatestConfig() {
        LambdaQueryWrapper<SipServerConfig> wrapper = new LambdaQueryWrapper<>();
        wrapper.eq(SipServerConfig::getDelFlag, 0)
                .orderByDesc(SipServerConfig::getId)
                .last("LIMIT 1");
        return getOne(wrapper);
    }

    @Override
    public void editConfig(SipServerConfigEditQuery query) {
        SipServerConfig config = new SipServerConfig();
        config.setId(query.getId());
        config.setWsUrl(query.getWsUrl());
        config.setSipHost(query.getSipHost());
        config.setSipPort(query.getSipPort());
        updateById(config);
    }
}
