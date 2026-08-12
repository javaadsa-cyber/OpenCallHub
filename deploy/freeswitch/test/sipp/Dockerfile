# SIPp 测试容器（v3.7.7 源码编译）
# Debian bookworm apt 池已无 sipp 包（stretch 后移出 archive，阿里云 pool 实测 404），只能源码编译。
# 源码由 fetch-sipp-sources.sh 预抓到 ../src/sipp（gitignore），构建期不依赖 github。
# 只编 rtp_stream 所需的最小集：不启用 pcap/ssl/gsl/sctp。
FROM debian:bookworm

# apt 换阿里云源（同 deploy/freeswitch/Dockerfile：必须 http，本机网络对 https 有 TLS 拦截）
RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i 's|http://deb.debian.org|http://mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
        g++ make cmake pkg-config libncurses-dev \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# sipp 3.7.x 用 CMake 构建；build.sh --none = 关闭 GSL/SSL/SCTP/PCAP 的最小构建
COPY src/sipp /usr/src/sipp
RUN cd /usr/src/sipp \
    && ./build.sh --none \
    && make install \
    && sipp -v | head -3

# 测试资产：场景、音调生成/录音校验脚本、媒体文件
COPY sipp/gen-tone.py sipp/check_wav.py /opt/och-test/
COPY scenarios/ /opt/och-test/scenarios/
RUN python3 /opt/och-test/gen-tone.py /opt/och-test/media/tone_pcmu.raw

CMD ["sleep", "infinity"]
