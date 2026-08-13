#!/usr/bin/env bash
# ============================================================================
# OpenCallHub 后端一键部署脚本（Ubuntu 优化版）
#
# 作用：在已有代码目录中部署 OpenCallHub 后端全套：
#   - MySQL 8.0 + Redis 7 + FreeSWITCH 1.10.12 + och-api + och-mrcp
#   - 防火墙：自动放行所需端口
#
# 用法：
#   cd /path/to/OpenCallHub
#   sudo bash deploy/scripts/install.sh                                    # 交互式
#   sudo bash deploy/scripts/install.sh --non-interactive --host-ip 1.2.3.4 # 自动化
#
# 注意：
#   - 前端（waihu-app）需单独部署，本脚本不负责
#   - 脚本假设代码已存在于当前目录，不会重新克隆
# ============================================================================

set -euo pipefail

# Ubuntu 优化：避免交互式提示
export DEBIAN_FRONTEND=noninteractive
export TZ=Asia/Shanghai

# 错误处理增强
trap 'echo -e "\033[0;31m[ERROR]\033[0m 脚本在第 $LINENO 行失败，命令: $BASH_COMMAND"; exit 1' ERR

# ----------------------------------------------------------------------------
# 全局变量
# ----------------------------------------------------------------------------
PROJECT_NAME="OpenCallHub"

# 默认参数（可被命令行或交互覆盖）
OCH_HOST_IP=""
INSTALL_DIR="$(pwd)"
MYSQL_PASSWORD="123456"
NON_INTERACTIVE=false

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------------
# 工具函数
# ----------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}==> $*${NC}"; }

die() {
    log_error "$@"
    exit 1
}

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="$3"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        eval "$var_name=\"${!var_name:-$default_val}\""
        return
    fi

    local input
    read -rp "$(echo -e "${BLUE}[?]${NC} $prompt_text [${default_val}]: ")" input
    eval "$var_name=\"${input:-$default_val}\""
}

# 检测公网 IP
detect_public_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        if ip=$(curl -s --connect-timeout 3 --max-time 5 "$svc" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
    echo "${ip:-127.0.0.1}"
}

# 检测发行版
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID,,}"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

require_cmd() {
    command -v "$1" &>/dev/null
}

# Ubuntu 优化：创建 swap 文件
create_swap_file() {
    log_info "创建 4GB swap 文件..."
    if [[ -f /swapfile ]]; then
        log_warn "/swapfile 已存在，跳过"
        return
    fi

    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1

    log_ok "Swap 文件已创建并启用"
}

# Ubuntu 优化：配置 Docker 日志轮转
configure_logrotate() {
    log_info "配置 Docker 日志轮转..."
    cat > /etc/logrotate.d/docker <<'EOF'
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    missingok
    notifempty
    copytruncate
    maxsize 100M
    dateext
}
EOF
    log_ok "日志轮转配置完成"
}

# ----------------------------------------------------------------------------
# 阶段 1：前置检查
# ----------------------------------------------------------------------------
preflight_checks() {
    log_step "阶段 1/5：前置检查"

    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要 root 权限，请用 sudo 运行"
    fi
    log_ok "root 权限"

    local distro
    distro=$(detect_distro)
    case "$distro" in
        centos|rhel|ubuntu|debian)
            log_ok "发行版: $distro"
            ;;
        *)
            die "不支持的发行版: $distro (主要支持 Ubuntu 20.04+，兼容 CentOS/RHEL/Debian)"
            ;;
    esac
    export OCH_DISTRO="$distro"

    # Ubuntu 优化：安装基础依赖
    if [[ "$distro" == "ubuntu" || "$distro" == "debian" ]]; then
        log_info "安装基础依赖包..."
        apt-get update -qq
        apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \
            build-essential git curl wget software-properties-common \
            apt-transport-https ca-certificates gnupg lsb-release
        log_ok "基础依赖已安装"
    fi

    # 内存检查
    local mem_total_mb
    mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    if [[ $mem_total_mb -lt 3800 ]]; then
        log_warn "内存 ${mem_total_mb}MB 低于推荐的 4GB"

        local swap_total_mb
        swap_total_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
        if [[ $swap_total_mb -lt 2048 ]]; then
            log_warn "Swap 空间不足 (${swap_total_mb}MB)，构建可能 OOM"
            if [[ "$NON_INTERACTIVE" != true ]]; then
                read -rp "$(echo -e "${BLUE}[?]${NC} 是否创建 4GB swap 文件? [Y/n]: ")" create_swap
                if [[ "${create_swap,,}" != "n" ]]; then
                    create_swap_file
                fi
            else
                log_info "非交互模式，跳过 swap 创建（建议手动添加）"
            fi
        else
            log_ok "Swap: ${swap_total_mb}MB"
        fi
    else
        log_ok "内存: ${mem_total_mb}MB"
    fi

    # 磁盘
    local disk_avail_gb
    disk_avail_gb=$(df -BG / | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ $disk_avail_gb -lt 20 ]]; then
        log_warn "可用磁盘 ${disk_avail_gb}GB 低于推荐的 20GB"
    else
        log_ok "磁盘可用: ${disk_avail_gb}GB"
    fi

    # 检查是否为 OpenCallHub 代码目录
    if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        die "当前目录不是 OpenCallHub 代码目录（未找到 docker-compose.yml）: $INSTALL_DIR"
    fi
    log_ok "代码目录: $INSTALL_DIR"

    # Docker
    if require_cmd docker; then
        log_ok "Docker 已安装: $(docker --version)"
    else
        log_info "Docker 未安装，即将安装..."
        install_docker
    fi

    if docker compose version &>/dev/null; then
        log_ok "docker compose 插件: $(docker compose version --short)"
    else
        die "docker compose 插件未安装。请运行: apt install docker-compose-plugin"
    fi

    if ! systemctl is-active --quiet docker; then
        log_info "启动 docker 服务..."
        systemctl start docker
        systemctl enable docker
    fi
}

# ----------------------------------------------------------------------------
# Docker 安装
# ----------------------------------------------------------------------------
install_docker() {
    log_info "安装 Docker..."

    case "$OCH_DISTRO" in
        ubuntu|debian)
            log_info "移除旧版 Docker（如有）..."
            apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

            apt-get update -qq
            apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \
                ca-certificates curl gnupg lsb-release

            install -m 0755 -d /etc/apt/keyrings
            local gpg_file="/etc/apt/keyrings/docker.gpg"
            local max_retries=3
            local retry=0

            while [[ $retry -lt $max_retries ]]; do
                if curl -fsSL --retry 3 --retry-delay 2 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o "$gpg_file" 2>/dev/null; then
                    chmod a+r "$gpg_file"
                    break
                fi
                retry=$((retry + 1))
                log_warn "GPG 密钥下载失败，重试 $retry/$max_retries..."
                sleep 2
            done

            if [[ $retry -ge $max_retries ]]; then
                die "无法下载 Docker GPG 密钥，请检查网络连接"
            fi

            local arch=$(dpkg --print-architecture)
            local codename=$(lsb_release -cs)
            echo "deb [arch=$arch signed-by=$gpg_file] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list

            apt-get update -qq
            apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \
                docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel)
            yum install -y -q yum-utils
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
            yum install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac

    systemctl start docker
    systemctl enable docker

    if [[ ! -f /etc/docker/daemon.json ]]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://hub-mirror.c.163.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
        systemctl daemon-reload
        systemctl restart docker
    fi

    if [[ "$OCH_DISTRO" == "ubuntu" || "$OCH_DISTRO" == "debian" ]]; then
        configure_logrotate
    fi

    log_ok "Docker 安装完成"
}

# ----------------------------------------------------------------------------
# 阶段 2：参数收集
# ----------------------------------------------------------------------------
collect_params() {
    log_step "阶段 2/5：配置参数"

    local detected_ip
    detected_ip=$(detect_public_ip)

    prompt OCH_HOST_IP "宿主机对外 IP（用于 SIP Contact 头和 MRCP 地址）" "$detected_ip"
    prompt INSTALL_DIR "代码目录" "$(pwd)"

    log_warn "Redis 密码被 och-mrcp 硬编码为 123456，不可修改"
    MYSQL_PASSWORD="123456"
    log_info "MySQL root 密码: $MYSQL_PASSWORD（固定）"

    echo
    log_info "配置摘要:"
    echo "  OCH_HOST_IP:  $OCH_HOST_IP"
    echo "  INSTALL_DIR:  $INSTALL_DIR"
    echo

    if [[ "$NON_INTERACTIVE" != true ]]; then
        read -rp "$(echo -e "${BLUE}[?]${NC} 确认以上配置? [Y/n]: ")" confirm
        if [[ "${confirm,,}" == "n" ]]; then
            die "安装已取消"
        fi
    fi
}

# ----------------------------------------------------------------------------
# 阶段 3：构建后端
# ----------------------------------------------------------------------------
build_backend() {
    log_step "阶段 3/5：构建后端（预计 15-25 分钟）"

    cd "$INSTALL_DIR"

    # 拉取 FreeSWITCH 源码
    if [[ ! -d "deploy/freeswitch/src/freeswitch" ]]; then
        log_info "拉取 FreeSWITCH 源码（~170MB）..."
        bash deploy/freeswitch/fetch-sources.sh
    else
        log_info "FreeSWITCH 源码已存在，跳过"
    fi
    log_ok "FreeSWITCH 源码就绪"

    # 生成 .env
    log_info "生成 .env 配置..."
    cat > .env <<EOF
# OpenCallHub 部署配置（由 install.sh 生成）
MYSQL_ROOT_PASSWORD=$MYSQL_PASSWORD
OCH_HOST_IP=$OCH_HOST_IP
EOF
    log_ok ".env 已生成"

    # 构建镜像
    log_info "构建 Docker 镜像（首次约 15-25 分钟）..."
    docker compose build

    # 启动服务
    log_info "启动服务..."
    docker compose up -d

    # 等待 healthy
    log_info "等待服务就绪（最长 120 秒）..."
    local waited=0
    local max_wait=120
    while [[ $waited -lt $max_wait ]]; do
        local unhealthy
        unhealthy=$(docker compose ps --format json 2>/dev/null | grep -c '"unhealthy"\|"starting"' || true)
        if [[ "$unhealthy" -eq 0 ]]; then
            local running
            running=$(docker compose ps --format json 2>/dev/null | grep -c '"running"\|"healthy"' || true)
            if [[ "$running" -ge 5 ]]; then
                break
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo

    if [[ $waited -ge $max_wait ]]; then
        log_warn "部分服务未在 ${max_wait}s 内就绪，请检查: docker compose logs"
    else
        log_ok "后端服务已启动 (${waited}s)"
    fi
}

# ----------------------------------------------------------------------------
# 阶段 4：防火墙
# ----------------------------------------------------------------------------
configure_firewall() {
    log_step "阶段 4/5：配置防火墙"

    local ports=(
        "4320/tcp"    # och-api HTTP / Swagger / xml_curl
        "5060/udp"    # SIP internal
        "5080/udp"    # SIP external
        "5080/tcp"    # SIP external
        "20000-20199/udp"  # FS RTP
        "10000-20000/udp"  # och-mrcp RTP
    )

    if require_cmd ufw; then
        log_info "检测到 ufw，配置规则..."

        local ufw_status=$(ufw status 2>/dev/null | head -1 || echo "")
        if echo "$ufw_status" | grep -q "inactive"; then
            log_warn "ufw 当前未启用"
            if [[ "$NON_INTERACTIVE" != true ]]; then
                read -rp "$(echo -e "${BLUE}[?]${NC} 是否启用 ufw 防火墙? [y/N]: ")" enable_ufw
                if [[ "${enable_ufw,,}" == "y" ]]; then
                    ufw allow 22/tcp >/dev/null 2>&1 || true
                    ufw --force enable
                    log_ok "ufw 已启用"
                else
                    log_info "跳过 ufw 启用（仅添加规则）"
                fi
            fi
        fi

        for port in "${ports[@]}"; do
            ufw allow "$port" >/dev/null 2>&1 || true
        done

        if ufw status | grep -q "Status: active"; then
            ufw reload >/dev/null 2>&1 || true
        fi

        log_ok "ufw 规则已添加"
        log_info "当前 ufw 状态: $(ufw status | head -1)"
    elif require_cmd firewall-cmd; then
        log_info "检测到 firewalld，配置规则..."
        for port in "${ports[@]}"; do
            firewall-cmd --permanent --add-port="$port" >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_ok "firewalld 规则已添加"
    else
        log_warn "未检测到 ufw 或 firewalld，跳过防火墙配置"
        log_warn "请手动放行以下端口:"
        for port in "${ports[@]}"; do
            echo "  - $port"
        done
    fi

    echo
    log_warn "云环境提示: 如果服务器在阿里云/腾讯云/AWS 等平台，还需在控制台的安全组中放行以上端口"
}

# ----------------------------------------------------------------------------
# 阶段 5：验证与输出
# ----------------------------------------------------------------------------
verify_and_output() {
    log_step "阶段 5/5：验证与输出"

    cd "$INSTALL_DIR"

    if [[ -x "deploy/scripts/health-check.sh" ]]; then
        log_info "运行健康检查..."
        bash deploy/scripts/health-check.sh || log_warn "部分服务可能未完全就绪"
    fi

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ $PROJECT_NAME 后端部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "  ${BLUE}Swagger API:${NC}    http://$OCH_HOST_IP:4320/swagger-ui.html"
    echo -e "  ${BLUE}Druid 监控:${NC}     http://$OCH_HOST_IP:4320/druid/ (admin / admin123)"
    echo -e "  ${BLUE}FS xml_curl:${NC}    http://$OCH_HOST_IP:4320/fs/curl/api"
    echo
    echo -e "  ${BLUE}软电话注册:${NC}     sip:<分机号>@$OCH_HOST_IP:5060 (密码 1234)"
    echo -e "  ${BLUE}测试分机:${NC}       1000 / 1234, 1001 / 1234"
    echo
    echo -e "  ${YELLOW}前端部署:${NC}"
    echo -e "    前端（waihu-app）需单独部署，配置 API 指向 http://$OCH_HOST_IP:4320/"
    echo
    echo -e "  ${YELLOW}后续步骤:${NC}"
    echo -e "    1. 运营商 SIP trunk 接入: 编辑 deploy/mysql/init/02-seed.sql"
    echo -e "    2. ASR/TTS 密钥: 创建 deploy/mrcp/config/engine.conf"
    echo -e "    3. 定时备份: crontab -e 添加 '0 2 * * * cd $INSTALL_DIR && bash deploy/scripts/backup-mysql.sh'"
    echo
    echo -e "  ${YELLOW}常用命令:${NC}"
    echo -e "    cd $INSTALL_DIR"
    echo -e "    docker compose ps                    # 查看服务状态"
    echo -e "    docker compose logs -f och-api       # 查看日志"
    echo -e "    bash deploy/scripts/health-check.sh  # 健康检查"
    echo -e "    bash deploy/scripts/backup-mysql.sh  # 备份数据库"
    echo
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
main() {
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  $PROJECT_NAME 后端部署脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --host-ip)
                OCH_HOST_IP="$2"
                shift 2
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -h|--help)
                echo "用法: sudo bash deploy/scripts/install.sh [选项]"
                echo
                echo "选项:"
                echo "  --non-interactive        非交互模式（使用默认值或环境变量）"
                echo "  --host-ip <IP>           宿主机对外 IP"
                echo "  --install-dir <PATH>     代码目录（默认当前目录）"
                echo "  -h, --help               显示帮助"
                echo
                echo "注意:"
                echo "  - 前端（waihu-app）需单独部署，本脚本仅负责后端"
                echo "  - 脚本在已有代码目录中运行，不会重新克隆代码"
                exit 0
                ;;
            *)
                die "未知参数: $1 (用 --help 查看帮助)"
                ;;
        esac
    done

    preflight_checks
    collect_params
    build_backend
    configure_firewall
    verify_and_output
}

main "$@"
