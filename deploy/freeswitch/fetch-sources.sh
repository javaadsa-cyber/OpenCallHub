#!/usr/bin/env bash
# 抓取 FreeSWITCH 构建源码到 src/（供 Dockerfile COPY，构建期不再依赖网络）。
# 用法：bash deploy/freeswitch/fetch-sources.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p src

clone_retry() { # url dir [branch]
  local url=$1 dir=$2 branch=${3:-}
  [ -d "src/$dir" ] && { echo "src/$dir 已存在，跳过"; return; }
  local args=(--depth 1)
  [ -n "$branch" ] && args+=(--branch "$branch")
  for i in 1 2 3 4 5; do
    git clone "${args[@]}" "$url" "src/$dir" && break || { echo "重试 $i ($dir)"; sleep 5; }
  done
  [ -d "src/$dir" ] || { echo "抓取 $dir 失败"; exit 1; }
  rm -rf "src/$dir/.git"
}

clone_retry https://github.com/freeswitch/sofia-sip sofia-sip
clone_retry https://github.com/freeswitch/spandsp spandsp
clone_retry https://gitee.com/mirrors/freeswitch freeswitch v1.10.12
echo "完成：$(du -sh src/*)"
