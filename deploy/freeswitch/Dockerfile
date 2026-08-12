# FreeSWITCH 本地开发镜像（源码编译 v1.10.12）
# 背景：docker.m.daocloud.io 白名单不含 signalwire/freeswitch（403），
#       github 在构建容器内时断时续，故源码预先抓到 src/ 下离线编译。
# 源码获取（src/ 已 gitignore）：bash deploy/freeswitch/fetch-sources.sh
# 构建：docker compose build freeswitch   （约 10-15 分钟）
FROM debian:bookworm

# apt 换阿里云源（本机直连 deb.debian.org 不稳定）。
# 注意用 http：本机网络对 https 有 TLS 拦截，容器内证书链不受信（包完整性仍由 Release 校验和保证）
RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i 's|http://deb.debian.org|http://mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git autoconf automake libtool libtool-bin make pkg-config g++ \
        libncurses-dev zlib1g-dev libjpeg-dev libssl-dev libsqlite3-dev \
        libcurl4-openssl-dev libpcre3-dev libspeex-dev libspeexdsp-dev \
        libldns-dev libedit-dev libxml2-dev libdb-dev liblua5.4-dev \
        libsndfile1-dev libopus-dev uuid-dev libtiff-dev libpng-dev libc-ares-dev yasm \
    && rm -rf /var/lib/apt/lists/*

# 1. sofia-sip（FS 1.10 必需依赖）
COPY src/sofia-sip /usr/src/sofia-sip
RUN cd /usr/src/sofia-sip \
    && ./bootstrap.sh -j \
    && ./configure && make -j"$(nproc)" && make install \
    && ldconfig

# 2. spandsp 3.0（FS 1.10.12 configure 硬性要求，无 debian 包）
COPY src/spandsp /usr/src/spandsp
RUN cd /usr/src/spandsp \
    && ./bootstrap.sh \
    && ./configure && make -j"$(nproc)" && make install \
    && ldconfig

# 3. FreeSWITCH v1.10.12
COPY src/freeswitch /usr/src/freeswitch
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig
RUN cd /usr/src/freeswitch \
    && ./bootstrap.sh -j \
    # 模块裁剪（modules.conf 由 bootstrap 从 build/modules.conf.in 生成）：
    # - 启用 mod_xml_curl（默认注释，本项目动态配置的核心通道）
    # - 禁用需要 libks/libvpx/bcg729/libpq 的模块（本地语音测试用不到）
    # - mod_spandsp：传真/modem DSP，且 master 版 spandsp 的 v18 API 已不兼容
    && sed -i -e 's|^#xml_int/mod_xml_curl|xml_int/mod_xml_curl|' \
              -e 's|^endpoints/mod_verto|#endpoints/mod_verto|' \
              -e 's|^endpoints/mod_rtc|#endpoints/mod_rtc|' \
              -e 's|^applications/mod_signalwire|#applications/mod_signalwire|' \
              -e 's|^applications/mod_spandsp|#applications/mod_spandsp|' \
              -e 's|^applications/mod_av|#applications/mod_av|' \
              -e 's|^codecs/mod_g729|#codecs/mod_g729|' \
              -e 's|^databases/mod_pgsql|#databases/mod_pgsql|' \
              modules.conf \
    && ./configure --prefix=/usr/local/freeswitch \
    && make -j"$(nproc)" && make install

# 注意：configure 按 FHS 布局生成目录，实际 conf 目录是
# $prefix/etc/freeswitch（不是 $prefix/conf），make install 已装入 vanilla 配置树。
# 调整其 modules.conf.xml：
# - 加载 mod_xml_curl（vanilla 默认注释，本项目动态配置的核心通道）
# - 注释掉构建时已禁用的模块（无对应 .so，避免加载报错）
RUN sed -i -e 's|<!-- *<load module="mod_xml_curl"/> *-->|<load module="mod_xml_curl"/>|' \
           -e 's|^\( *\)<load module="mod_rtc"/>|\1<!-- <load module="mod_rtc"/> -->|' \
           -e 's|^\( *\)<load module="mod_verto"/>|\1<!-- <load module="mod_verto"/> -->|' \
           -e 's|^\( *\)<load module="mod_signalwire"/>|\1<!-- <load module="mod_signalwire"/> -->|' \
           -e 's|^\( *\)<load module="mod_spandsp"/>|\1<!-- <load module="mod_spandsp"/> -->|' \
           -e 's|^\( *\)<load module="mod_g729"/>|\1<!-- <load module="mod_g729"/> -->|' \
           -e 's|^\( *\)<load module="mod_av"/>|\1<!-- <load module="mod_av"/> -->|' \
           /usr/local/freeswitch/etc/freeswitch/autoload_configs/modules.conf.xml \
    # pre_load_modules.conf.xml 预加载 mod_pgsql（未编译），同样注释掉
    && sed -i 's|^\( *\)<load module="mod_pgsql"/>|\1<!-- <load module="mod_pgsql"/> -->|' \
           /usr/local/freeswitch/etc/freeswitch/autoload_configs/pre_load_modules.conf.xml

ENV PATH=/usr/local/freeswitch/bin:$PATH

# -nonat: 容器内关闭自动 NAT 探测；-c: 前台运行便于 docker logs 观察
CMD ["freeswitch", "-nonat", "-c"]
