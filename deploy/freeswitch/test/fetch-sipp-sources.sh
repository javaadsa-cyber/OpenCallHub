#!/usr/bin/env bash
# 抓取 sipp v3.7.7 源码到 src/sipp/（供 Dockerfile COPY，构建期不再依赖网络）。
# 用法：bash deploy/freeswitch/test/fetch-sipp-sources.sh
# 风格同 deploy/freeswitch/fetch-sources.sh；github 时断时续：每个源重试 3 次，
# github 失败自动回退 gitcode 镜像（本机实测 github 长期不可达、gitcode 稳定）。
# 两个都失败则手工下载 https://github.com/SIPp/sipp/archive/refs/tags/v3.7.7.tar.gz 解压到 src/sipp/。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p src
export GIT_TERMINAL_PROMPT=0

clone_retry() { # url dir [branch] [tries]
  local url=$1 dir=$2 branch=${3:-} tries=${4:-3}
  [ -d "src/$dir" ] && { echo "src/$dir 已存在，跳过"; return 0; }
  local args=(--depth 1)
  [ -n "$branch" ] && args+=(--branch "$branch")
  for ((i = 1; i <= tries; i++)); do
    git clone "${args[@]}" "$url" "src/$dir" && break || { rm -rf "src/$dir"; echo "重试 $i/$tries ($url)"; sleep 5; }
  done
  [ -d "src/$dir" ]
}

if clone_retry https://github.com/SIPp/sipp sipp v3.7.7; then
  echo "已从 github 抓取"
elif clone_retry https://gitcode.com/gh_mirrors/si/sipp sipp v3.7.7; then
  echo "github 不可达，已从 gitcode 镜像抓取"
else
  echo "抓取 sipp 失败：请手工下载 v3.7.7 tarball 解压到 src/sipp/"
  exit 1
fi
# include/version.h 在仓库里是带 #error 的占位 stub：CMake 仅在 .git 存在时
# 用 git describe 渲染真身。删 .git 前先渲染好（格式同 configure_file 产物），
# 否则容器内构建（无 git、无 .git）直接编译报错
if [ -d src/sipp/.git ]; then
  ver="$(git -C src/sipp describe --tags --always --first-parent)"
  printf '#define SIPP_VERSION VERSION\n#define VERSION "%s"\n' "$ver" > src/sipp/include/version.h
fi
rm -rf src/sipp/.git
echo "完成：$(du -sh src/*)"
