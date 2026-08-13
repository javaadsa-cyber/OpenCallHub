#!/usr/bin/env bash
# ============================================================================
# OpenCallHub 一键安装脚本（Ubuntu 优化版）
#
# 作用：在干净的 Ubuntu 服务器上从零部署 OpenCallHub 全套：
#   - 后端：MySQL 8.0 + Redis 7 + FreeSWITCH 1.10.12 + och-api + och-mrcp
#   - 前端：waihu-app (Vue 3 SPA)
#   - 反向代理：nginx（静态 SPA + API 代理 + WebSocket）
#   - 防火墙：自动放行所需端口
#
# 支持发行版：Ubuntu 20.04/22.04/24.04（主要优化），CentOS/RHEL/Debian（兼容）
# 最低配置：4GB RAM, 20GB 磁盘
#
# 用法：
#   sudo bash install.sh                  # 交互式
#   sudo bash install.sh --non-interactive --host-ip 1.2.3.4  # 自动化
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="OpenCallHub"
BACKEND_REPO="https://github.com/javaadsa-cyber/OpenCallHub.git"
FRONTEND_REPO="https://gitee.com/zhongjiwei999/waihu-app.git"

# 默认参数（可被命令行或交互覆盖）
OCH_HOST_IP=""
INSTALL_DIR="/opt/openCallHub"
FRONTEND_DIR="/opt/waihu-app"
MYSQL_PASSWORD="123456"
DOMAIN=""
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

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="$3"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        eval "$var_name=\"${!var_name:-$default_val}\""
        return
    fi

    local input
    read -rsp "$(echo -e "${BLUE}[?]${NC} $prompt_text [${default_val}]: ")" input
    echo
    eval "$var_name=\"${input:-$default_val}\""
}

# 检测公网 IP
detect_public_ip() {
    local ip=""
    # 尝试多个服务
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        if ip=$(curl -s --connect-timeout 3 --max-time 5 "$svc" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    # 降级：取默认路由网卡 IP
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

# 检查命令是否存在
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

    # 持久化
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # 优化 swappiness（服务器推荐 10）
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1

    log_ok "Swap 文件已创建并启用"
}

# ----------------------------------------------------------------------------
# 阶段 1：前置检查
# ----------------------------------------------------------------------------
preflight_checks() {
    log_step "阶段 1/8：前置检查"

    # root 权限
    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要 root 权限，请用 sudo 运行"
    fi
    log_ok "root 权限"

    # 发行版
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

        # Ubuntu 优化：检测 swap
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

    # Docker
    if require_cmd docker; then
        log_ok "Docker 已安装: $(docker --version)"
    else
        log_info "Docker 未安装，即将安装..."
        install_docker
    fi

    # docker compose
    if docker compose version &>/dev/null; then
        log_ok "docker compose 插件: $(docker compose version --short)"
    else
        die "docker compose 插件未安装。请运行: apt install docker-compose-plugin 或 yum install docker-compose-plugin"
    fi

    # 检查 docker 服务是否运行
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
            # 卸载旧版 Docker（避免冲突）
            log_info "移除旧版 Docker（如有）..."
            apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

            # 安装依赖
            apt-get update -qq
            apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \
                ca-certificates curl gnupg lsb-release

            # 使用阿里云镜像源（带重试）
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

            # 添加 Docker 源
            local arch=$(dpkg --print-architecture)
            local codename=$(lsb_release -cs)
            echo "deb [arch=$arch signed-by=$gpg_file] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list

            # 安装 Docker
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

    # 配置 Docker 镜像加速（阿里云公共镜像）
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

    # Ubuntu 优化：配置 Docker 日志轮转
    if [[ "$OCH_DISTRO" == "ubuntu" || "$OCH_DISTRO" == "debian" ]]; then
        configure_logrotate
    fi

    log_ok "Docker 安装完成"
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
# 阶段 2：参数收集
# ----------------------------------------------------------------------------
collect_params() {
    log_step "阶段 2/8：配置参数"

    # 自动检测 IP
    local detected_ip
    detected_ip=$(detect_public_ip)

    prompt OCH_HOST_IP "宿主机对外 IP（用于 SIP Contact 头和 nginx server_name）" "$detected_ip"
    DOMAIN="${DOMAIN:-$OCH_HOST_IP}"
    prompt DOMAIN "域名或 IP（nginx server_name）" "$OCH_HOST_IP"

    prompt INSTALL_DIR "后端安装目录" "/opt/openCallHub"
    prompt FRONTEND_DIR "前端仓库目录" "/opt/waihu-app"

    log_warn "Redis 密码被 och-mrcp 硬编码为 123456，不可修改"
    MYSQL_PASSWORD="123456"
    log_info "MySQL root 密码: $MYSQL_PASSWORD（固定）"

    echo
    log_info "配置摘要:"
    echo "  OCH_HOST_IP:  $OCH_HOST_IP"
    echo "  DOMAIN:       $DOMAIN"
    echo "  INSTALL_DIR:  $INSTALL_DIR"
    echo "  FRONTEND_DIR: $FRONTEND_DIR"
    echo

    if [[ "$NON_INTERACTIVE" != true ]]; then
        read -rp "$(echo -e "${BLUE}[?]${NC} 确认以上配置? [Y/n]: ")" confirm
        if [[ "${confirm,,}" == "n" ]]; then
            die "安装已取消"
        fi
    fi
}

# ----------------------------------------------------------------------------
# 阶段 3：克隆仓库
# ----------------------------------------------------------------------------
clone_repos() {
    log_step "阶段 3/8：克隆仓库"

    require_cmd git || die "git 未安装"

    # 后端
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log_info "后端仓库已存在: $INSTALL_DIR"
        cd "$INSTALL_DIR"
        git pull --ff-only || log_warn "git pull 失败，使用现有代码"
    else
        log_info "克隆后端仓库到 $INSTALL_DIR ..."
        git clone "$BACKEND_REPO" "$INSTALL_DIR"
    fi
    log_ok "后端仓库就绪"

    # 前端
    if [[ -d "$FRONTEND_DIR/.git" ]]; then
        log_info "前端仓库已存在: $FRONTEND_DIR"
        cd "$FRONTEND_DIR"
        git pull --ff-only || log_warn "git pull 失败，使用现有代码"
    else
        log_info "克隆前端仓库到 $FRONTEND_DIR ..."
        git clone "$FRONTEND_REPO" "$FRONTEND_DIR"
    fi
    log_ok "前端仓库就绪"
}

# ----------------------------------------------------------------------------
# 阶段 4：构建后端
# ----------------------------------------------------------------------------
build_backend() {
    log_step "阶段 4/8：构建后端（预计 15-25 分钟）"

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
            # 额外确认所有服务都在运行
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
# 阶段 5：构建前端
# ----------------------------------------------------------------------------
build_frontend() {
    log_step "阶段 5/8：构建前端"

    # 安装 Node.js
    if ! require_cmd node; then
        log_info "安装 Node.js 18..."
        case "$OCH_DISTRO" in
            ubuntu|debian)
                # Ubuntu 优化：使用 NodeSource 官方脚本（带重试）
                local max_retries=3
                local retry=0
                while [[ $retry -lt $max_retries ]]; do
                    if curl -fsSL --retry 3 --retry-delay 2 https://deb.nodesource.com/setup_18.x | bash -; then
                        break
                    fi
                    retry=$((retry + 1))
                    log_warn "NodeSource 脚本执行失败，重试 $retry/$max_retries..."
                    sleep 2
                done

                if [[ $retry -ge $max_retries ]]; then
                    die "Node.js 安装失败，请手动安装或检查网络连接"
                fi

                apt-get install -y -qq -o Dpkg::Options::="--force-confdef" nodejs
                ;;
            centos|rhel)
                curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
                yum install -y -q nodejs
                ;;
        esac
        log_ok "Node.js $(node --version) 已安装"
    else
        log_ok "Node.js 已安装: $(node --version)"
    fi

    # 使用 npm（packageManager 声明 pnpm 但实际 lockfile 是 npm）
    cd "$FRONTEND_DIR"

    # 写入 .env.production
    log_info "配置前端 API 地址..."
    cat > .env.production <<EOF
VITE_API_BASE_URL=/api/
EOF
    log_ok ".env.production 已生成"

    # 安装依赖（带重试）
    log_info "安装前端依赖（npm install）..."
    local max_retries=3
    local retry=0
    while [[ $retry -lt $max_retries ]]; do
        if npm install --silent --prefer-offline 2>/dev/null; then
            break
        fi
        retry=$((retry + 1))
        log_warn "npm install 失败，重试 $retry/$max_retries..."
        sleep 2
    done

    if [[ $retry -ge $max_retries ]]; then
        die "npm install 失败，请检查网络连接或手动安装"
    fi

    # 构建
    log_info "构建前端（npm run build）..."
    if ! npm run build; then
        die "前端构建失败"
    fi

    if [[ ! -d "dist" ]]; then
        die "前端构建失败: dist/ 目录不存在"
    fi
    log_ok "前端构建完成: $FRONTEND_DIR/dist/"
}

# ----------------------------------------------------------------------------
# 阶段 6：配置 nginx
# ----------------------------------------------------------------------------
configure_nginx() {
    log_step "阶段 6/8：配置 nginx"

    # 安装 nginx
    if ! require_cmd nginx; then
        log_info "安装 nginx..."
        case "$OCH_DISTRO" in
            ubuntu|debian)
                apt-get install -y -qq -o Dpkg::Options::="--force-confdef" nginx
                ;;
            centos|rhel)
                yum install -y -q epel-release
                yum install -y -q nginx
                ;;
        esac
        log_ok "nginx 已安装"
    else
        log_ok "nginx 已存在: $(nginx -v 2>&1)"
    fi

    # Ubuntu 优化：根据 CPU 核心数优化 worker_processes
    local cpu_cores=$(nproc)
    local worker_processes=$((cpu_cores > 4 ? 4 : cpu_cores))

    # 优化 nginx 主配置（仅 Ubuntu）
    if [[ "$OCH_DISTRO" == "ubuntu" || "$OCH_DISTRO" == "debian" ]]; then
        log_info "优化 nginx 性能配置..."
        cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes $worker_processes;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    # 性能优化
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml application/atom+xml image/svg+xml;

    # 安全头
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    # 生成站点配置
    local nginx_conf="/etc/nginx/conf.d/openCallHub.conf"
    log_info "生成 nginx 配置: $nginx_conf"

    # 移除默认配置（避免冲突）
    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/sites-enabled/default

    cat > "$nginx_conf" <<EOF
# OpenCallHub nginx 配置（由 install.sh 生成）
server {
    listen 80;
    server_name $DOMAIN;

    root $FRONTEND_DIR/dist;
    index index.html;

    # 前端 SPA 路由
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 后端 API 反向代理（strip /api 前缀）
    location /api/ {
        proxy_pass http://127.0.0.1:4320/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_send_timeout 300s;
    }

    # WebSocket（/ws 路径，用于推送通知）
    location /ws {
        proxy_pass http://127.0.0.1:4320/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }

    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # 测试配置
    if ! nginx -t; then
        die "nginx 配置测试失败"
    fi

    # 启动/重载
    systemctl enable nginx
    systemctl restart nginx
    log_ok "nginx 配置完成并已启动"
}

# ----------------------------------------------------------------------------
# 阶段 7：防火墙
# ----------------------------------------------------------------------------
configure_firewall() {
    log_step "阶段 7/8：配置防火墙"

    # 端口列表
    local ports=(
        "80/tcp"      # HTTP
        "443/tcp"     # HTTPS
        "5060/udp"    # SIP internal
        "5080/udp"    # SIP external
        "5080/tcp"    # SIP external
        "20000-20199/udp"  # FS RTP
        "10000-20000/udp"  # och-mrcp RTP
    )

    if require_cmd ufw; then
        log_info "检测到 ufw，配置规则..."

        # Ubuntu 优化：检测 ufw 状态
        local ufw_status=$(ufw status 2>/dev/null | head -1 || echo "")
        if echo "$ufw_status" | grep -q "inactive"; then
            log_warn "ufw 当前未启用"
            if [[ "$NON_INTERACTIVE" != true ]]; then
                read -rp "$(echo -e "${BLUE}[?]${NC} 是否启用 ufw 防火墙? [y/N]: ")" enable_ufw
                if [[ "${enable_ufw,,}" == "y" ]]; then
                    # 先允许 SSH（避免锁定）
                    ufw allow 22/tcp >/dev/null 2>&1 || true
                    ufw --force enable
                    log_ok "ufw 已启用"
                else
                    log_info "跳过 ufw 启用（仅添加规则）"
                fi
            fi
        fi

        # 添加规则
        for port in "${ports[@]}"; do
            ufw allow "$port" >/dev/null 2>&1 || true
        done

        # 重载（如果已启用）
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
# 阶段 8：验证与输出
# ----------------------------------------------------------------------------
verify_and_output() {
    log_step "阶段 8/8：验证与输出"

    cd "$INSTALL_DIR"

    # 运行健康检查
    if [[ -x "deploy/scripts/health-check.sh" ]]; then
        log_info "运行健康检查..."
        bash deploy/scripts/health-check.sh || log_warn "部分服务可能未完全就绪"
    fi

    # 打印最终信息
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ $PROJECT_NAME 部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "  ${BLUE}管理后台:${NC}       http://$DOMAIN"
    echo -e "  ${BLUE}账号/密码:${NC}      admin / 12345678"
    echo
    echo -e "  ${BLUE}Swagger API:${NC}    http://$DOMAIN/api/swagger-ui.html"
    echo -e "  ${BLUE}Druid 监控:${NC}     http://$DOMAIN/api/druid/ (admin / admin123)"
    echo
    echo -e "  ${BLUE}软电话注册:${NC}     sip:<分机号>@$DOMAIN:5060 (密码 1234)"
    echo -e "  ${BLUE}测试分机:${NC}       1000 / 1234, 1001 / 1234"
    echo
    echo -e "  ${YELLOW}后续步骤:${NC}"
    echo -e "    1. 运营商 SIP trunk 接入: 编辑 $INSTALL_DIR/deploy/mysql/init/02-seed.sql"
    echo -e "    2. ASR/TTS 密钥: 创建 $INSTALL_DIR/deploy/mrcp/config/engine.conf"
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
    echo -e "${GREEN}  $PROJECT_NAME 一键安装脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo

    # 解析命令行参数
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
            --frontend-dir)
                FRONTEND_DIR="$2"
                shift 2
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            -h|--help)
                echo "用法: sudo bash install.sh [选项]"
                echo
                echo "选项:"
                echo "  --non-interactive        非交互模式（使用默认值或环境变量）"
                echo "  --host-ip <IP>           宿主机对外 IP"
                echo "  --install-dir <PATH>     后端安装目录（默认 /opt/openCallHub）"
                echo "  --frontend-dir <PATH>    前端仓库目录（默认 /opt/waihu-app）"
                echo "  --domain <DOMAIN>        nginx server_name（默认同 host-ip）"
                echo "  -h, --help               显示帮助"
                exit 0
                ;;
            *)
                die "未知参数: $1 (用 --help 查看帮助)"
                ;;
        esac
    done

    preflight_checks
    collect_params
    clone_repos
    build_backend
    build_frontend
    configure_nginx
    configure_firewall
    verify_and_output
}

main "$@"
