package com.och.system.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.och.system.domain.entity.SipServerConfig;
import org.apache.ibatis.annotations.Mapper;
import org.springframework.stereotype.Repository;

/**
 * SIP 服务器配置 Mapper
 */
@Repository
@Mapper
public interface SipServerConfigMapper extends BaseMapper<SipServerConfig> {
}
