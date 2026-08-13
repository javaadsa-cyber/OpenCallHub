#!/usr/bin/env bash
# ============================================================================
# OpenCallHub 增量部署脚本
#
# 作用：已有部署在代码更新后快速增量发布：
#   拉最新代码 → 只重建变更的服务 → 滚动重启 → 健康检查
#   利用 BuildKit 层缓存 + docker compose up -d 的「只重建变更容器」特性。
#
# 与 install.sh 的区分：
#   install.sh = 首次/全新服务器（装 Docker + 依赖 + 防火墙 + 构建全套）
#   deploy.sh  = 已有部署，代码更新后增量发布
#
# 用法：
#   sudo bash deploy/scripts/deploy.sh                # 默认更新业务服务（och-api + och-mrcp）
#   sudo bash deploy/scripts/deploy.sh och-api        # 只更新指定服务
#   sudo bash deploy/scripts/deploy.sh --all          # 含 freeswitch（重新编译源码，慢）
#   sudo bash deploy/scripts/deploy.sh --no-build     # 只重启不构建（配置/环境变量变更）
#   sudo bash deploy/scripts/deploy.sh --backup       # 先备份数据库再发布
#   sudo bash deploy/scripts/deploy.sh --no-pull      # 跳过 git pull
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# 全局变量
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="OpenCallHub"

# 服务分组：mysql/redis 是数据容器，永不在 deploy.sh 重建
BUSINESS_SERVICES=("och-api" "och-mrcp")        # 默认更新目标
ALL_SERVICES=("och-api" "och-mrcp" "freeswitch") # --all

# 选项
TARGET_SERVICES=()
DO_BUILD=true
DO_PULL=true
DO_BACKUP=false
DO_RESET_NETWORK=false

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----------------------------------------------------------------------------
# 工具函数（沿用 install.sh 风格）
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

require_cmd() {
    command -v "$1" &>/dev/null
}

# 取某服务当前镜像 ID（用于前后对比，确认是否真的更新）
get_image_id() {
    local svc="$1"
    docker compose images "$svc" 2>/dev/null | awk 'NR==2 {print $3}' || echo ""
}

# ----------------------------------------------------------------------------
# 阶段 1：前置检查
# ----------------------------------------------------------------------------
preflight() {
    log_step "阶段 1/5：前置检查"

    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要 root 权限，请用 sudo 运行"
    fi
    log_ok "root 权限"

    if ! require_cmd docker; then
        die "Docker 未安装。首次部署请先运行: sudo bash deploy/scripts/install.sh"
    fi

    if ! docker compose version &>/dev/null; then
        die "docker compose 插件不可用"
    fi
    log_ok "docker compose: $(docker compose version --short)"

    # 必须在代码目录运行
    if [[ ! -f "docker-compose.yml" ]]; then
        die "当前目录不是 OpenCallHub 代码目录（未找到 docker-compose.yml）。请 cd 到项目根目录"
    fi
    log_ok "代码目录: $(pwd)"

    # 必须已有运行中的 compose 栈（否则应跑 install.sh）
    local running_count
    running_count=$(docker compose ps --format json 2>/dev/null | grep -c '"running"\|"healthy"' || true)
    if [[ "$running_count" -eq 0 ]]; then
        die "未检测到运行中的 OpenCallHub 服务。首次部署请运行: sudo bash deploy/scripts/install.sh"
    fi
    log_ok "当前运行服务数: $running_count"
}

# ----------------------------------------------------------------------------
# 阶段 2：拉取最新代码
# ----------------------------------------------------------------------------
pull_code() {
    if [[ "$DO_PULL" == false ]]; then
        log_info "跳过 git pull（--no-pull）"
        return
    fi

    log_step "阶段 2/5：拉取最新代码"

    if ! require_cmd git; then
        die "git 未安装"
    fi

    # 检查是否有未提交的本地改动（避免 pull 冲突）
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_warn "检测到本地有未提交的改动，git pull 可能冲突："
        git status --short | head -10
        if [[ "${FORCE:-false}" != true ]]; then
            read -rp "$(echo -e "${BLUE}[?]${NC} 仍要继续 pull? [y/N]: ")" cont
            [[ "${cont,,}" != "y" ]] && die "已取消（请先 commit/stash 本地改动）"
        fi
    fi

    log_info "git pull ..."
    if ! git pull --ff-only; then
        log_warn "git pull --ff-only 失败（可能有分歧提交），尝试普通 pull"
        git pull || die "git pull 失败，请手动解决"
    fi

    # 打印本次从上次部署至今的变更摘要
    local last_commit_file="${SCRIPT_DIR}/.last-deploy-commit"
    local current_commit prev_commit
    current_commit=$(git rev-parse --short HEAD)
    if [[ -f "$last_commit_file" ]]; then
        prev_commit=$(cat "$last_commit_file")
        if [[ "$prev_commit" != "$current_commit" ]]; then
            log_info "自上次部署（$prev_commit）以来的变更："
            git log --oneline "${prev_commit}..HEAD" 2>/dev/null | head -20 || true
            echo "---"
            git diff --stat "${prev_commit}..HEAD" 2>/dev/null | tail -5 || true
        else
            log_info "代码未变化（仍在 $current_commit）"
        fi
    else
        log_info "首次运行 deploy.sh，当前提交: $current_commit"
    fi
}

# ----------------------------------------------------------------------------
# 阶段 3：可选备份
# ----------------------------------------------------------------------------
maybe_backup() {
    if [[ "$DO_BACKUP" == false ]]; then
        return
    fi

    log_step "阶段 3/5：备份数据库"

    local backup_script="${SCRIPT_DIR}/backup-mysql.sh"
    if [[ ! -x "$backup_script" ]]; then
        log_warn "未找到 backup-mysql.sh，跳过备份"
        return
    fi

    log_info "执行数据库备份 ..."
    if bash "$backup_script"; then
        log_ok "数据库备份完成"
    else
        log_warn "数据库备份失败（继续部署，请稍后检查）"
    fi
}

# ----------------------------------------------------------------------------
# 阶段 4：重建 + 滚动重启
# ----------------------------------------------------------------------------
rebuild_and_restart() {
    log_step "阶段 4/5：重建并重启服务"

    if [[ ${#TARGET_SERVICES[@]} -eq 0 ]]; then
        die "没有指定要更新的服务"
    fi

    log_info "目标服务: ${TARGET_SERVICES[*]}"

    # 重建
    if [[ "$DO_BUILD" == true ]]; then
        log_info "构建镜像（BuildKit 缓存，未变层秒过）..."
        # 记录构建前镜像 ID
        declare -A before_ids
        for svc in "${TARGET_SERVICES[@]}"; do
            before_ids["$svc"]=$(get_image_id "$svc")
        done

        if ! docker compose build "${TARGET_SERVICES[@]}"; then
            log_error "构建失败，打印日志辅助排查："
            for svc in "${TARGET_SERVICES[@]}"; do
                echo "--- $svc 最近日志 ---"
                docker compose logs --tail=30 "$svc" 2>/dev/null || true
            done
            die "docker compose build 失败"
        fi

        # 对比镜像 ID，确认是否真的重建
        for svc in "${TARGET_SERVICES[@]}"; do
            local after_id
            after_id=$(get_image_id "$svc")
            if [[ "${before_ids[$svc]}" != "$after_id" ]]; then
                log_ok "$svc 镜像已更新: ${before_ids[$svc]:-无} → $after_id"
            else
                log_info "$svc 镜像未变（代码无改动或层缓存命中）"
            fi
        done
    else
        log_info "跳过构建（--no-build），仅重启"
    fi

    # 滚动重启：只重建变更容器，--no-deps 避免连带重启 mysql/redis
    log_info "滚动重启（仅变更容器，不触碰 mysql/redis/freeswitch）..."
    docker compose up -d --no-deps "${TARGET_SERVICES[@]}"
    log_ok "服务已应用变更"
}

# ----------------------------------------------------------------------------
# 阶段 5：健康检查
# ----------------------------------------------------------------------------
health_check() {
    log_step "阶段 5/5：健康检查"

    # 等待目标服务就绪
    log_info "等待服务就绪（最长 60 秒）..."
    local waited=0
    local max_wait=60
    while [[ $waited -lt $max_wait ]]; do
        local not_ready=0
        for svc in "${TARGET_SERVICES[@]}"; do
            local state
            state=$(docker compose ps --format json "$svc" 2>/dev/null | grep -oE '"Health":"[^"]*"|"Status":"[^"]*"' | head -2 | tr '\n' ' ')
            if ! echo "$state" | grep -qE "healthy|running"; then
                not_ready=1
            fi
        done
        [[ $not_ready -eq 0 ]] && break
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo

    # 跑通用健康检查脚本
    local health_script="${SCRIPT_DIR}/health-check.sh"
    if [[ -x "$health_script" ]]; then
        log_info "运行健康检查 ..."
        bash "$health_script" || log_warn "部分探针未通过，请检查日志"
    else
        log_warn "未找到 health-check.sh，仅展示容器状态："
        docker compose ps
    fi

    # 记录本次部署的 commit
    local last_commit_file="${SCRIPT_DIR}/.last-deploy-commit"
    git rev-parse --short HEAD > "$last_commit_file" 2>/dev/null || true

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ 增量部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  ${BLUE}本次更新服务:${NC}  ${TARGET_SERVICES[*]}"
    echo -e "  ${BLUE}当前提交:${NC}      $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo
    echo -e "  ${YELLOW}查看日志:${NC}      docker compose logs -f ${TARGET_SERVICES[0]}"
    echo
}

# ----------------------------------------------------------------------------
# 解析参数
# ----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                TARGET_SERVICES=("${ALL_SERVICES[@]}")
                shift
                ;;
            --no-build)
                DO_BUILD=false
                shift
                ;;
            --no-pull)
                DO_PULL=false
                shift
                ;;
            --backup)
                DO_BACKUP=true
                shift
                ;;
            --reset-network)
                DO_RESET_NETWORK=true
                shift
                ;;
            -h|--help)
                cat <<EOF
用法: sudo bash deploy/scripts/deploy.sh [选项] [服务...]

选项:
  --all             更新全部服务（含 freeswitch，重新编译源码，慢）
  --no-build        只重启不重新构建（仅配置/环境变量变更）
  --no-pull         跳过 git pull（本地已有最新代码）
  --backup          先备份数据库再发布
  --reset-network   修复「网络孤儿」状态（容器脱离 och 网络，不丢数据）
  -h, --help        显示帮助

服务（可选，未指定则默认业务服务 och-api och-mrcp）:
  och-api, och-mrcp, freeswitch
  （mysql / redis 是数据容器，不会被 deploy.sh 重建）

示例:
  sudo bash deploy/scripts/deploy.sh                       # 更新 och-api + och-mrcp
  sudo bash deploy/scripts/deploy.sh och-api               # 只更新 och-api
  sudo bash deploy/scripts/deploy.sh --all --backup        # 全量更新，先备份
  sudo bash deploy/scripts/deploy.sh --reset-network       # 修复容器网络问题
EOF
                exit 0
                ;;
            --*)
                die "未知选项: $1 (用 --help 查看帮助)"
                ;;
            *)
                # 位置参数 = 服务名
                TARGET_SERVICES+=("$1")
                shift
                ;;
        esac
    done

    # 拦截：不允许直接动 mysql/redis（reset-network 不需要此检查，它不重建容器）
    if [[ "$DO_RESET_NETWORK" != true ]]; then
        for svc in "${TARGET_SERVICES[@]}"; do
            case "$svc" in
                mysql|redis)
                    die "不允许通过 deploy.sh 重建数据容器 '$svc'（会丢数据）。如需重建请手动处理"
                    ;;
                och-api|och-mrcp|freeswitch|sipp)
                    ;;
                *)
                    die "未知服务名: $svc (有效: och-api / och-mrcp / freeswitch / sipp)"
                    ;;
            esac
        done

        # 默认目标
        if [[ ${#TARGET_SERVICES[@]} -eq 0 ]]; then
            TARGET_SERVICES=("${BUSINESS_SERVICES[@]}")
        fi
    fi
}

# ----------------------------------------------------------------------------
# 网络完整性检查 / 修复
# ----------------------------------------------------------------------------
# 自定义网络 och 下的容器偶尔会因非正常启停脱离网络，导致 DNS 解析失败
# （och-api 报 UnknownHostException: mysql 就是典型症状）。
# 症状：docker inspect 其 NetworkSettings.Networks 字段为 {} 或不含 _och。
COMPOSE_PROJECT="opencallhub"
OCH_NETWORK="${COMPOSE_PROJECT}_och"
OCH_SERVICES=(mysql redis freeswitch och-api)

check_network_integrity() {
    local broken=()
    for svc in "${OCH_SERVICES[@]}"; do
        local cid
        cid=$(docker compose ps -q "$svc" 2>/dev/null) || true
        [[ -z "$cid" ]] && continue
        local nets
        nets=$(docker inspect -f '{{json .NetworkSettings.Networks}}' "$cid" 2>/dev/null) || continue
        if [[ "$nets" == "{}" ]] || ! echo "$nets" | grep -q "_och"; then
            broken+=("$svc")
        fi
    done

    if [[ ${#broken[@]} -gt 0 ]]; then
        log_warn "以下服务容器不在 och 网络上：${broken[*]}"
        log_warn "→ 运行 sudo bash $0 --reset-network 修复（不丢数据）"
        return 1
    fi
    log_ok "所有 och 网络容器均正常挂载"
    return 0
}

reset_network() {
    log_step "修复网络孤儿状态"
    log_info "停止所有容器（数据卷保留，数据库数据不受影响）..."
    docker compose down

    log_info "重新创建容器和网络..."
    docker compose up -d

    log_info "等待关键服务就绪..."
    sleep 10
    check_network_integrity || log_warn "网络仍异常，可能需要查看 Docker daemon 日志"

    log_step "健康检查"
    health_check
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
main() {
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  $PROJECT_NAME 增量部署${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo

    parse_args "$@"

    # --reset-network 是独立分支：跳过常规 pull/build，只做 down + up
    if [[ "$DO_RESET_NETWORK" == true ]]; then
        preflight
        reset_network
        return
    fi

    preflight
    pull_code
    maybe_backup
    rebuild_and_restart
    health_check

    # 部署完成后检查网络完整性（非阻塞，仅告警）
    echo
    check_network_integrity || true
}

main "$@"
