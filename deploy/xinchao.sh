#!/usr/bin/env bash
# 心潮·念 服务器小助手：检查 / 备份并原地升级 / 回滚
#
#   bash xinchao.sh              只检查，不改任何东西（默认）
#   bash xinchao.sh upgrade      先备份数据，再把旧的心潮原地升级到最新版
#   bash xinchao.sh rollback 备份目录   退回升级前的代码和数据
#
# 数据（记忆库、心潮状态）存在 docker 数据卷里。本脚本始终在旧的部署目录里操作，
# 不换目录、不删数据卷（从不使用 down -v），所以升级后接上的仍是原来的数据。
set -euo pipefail

REPO_URL="https://github.com/tianyupaipai-cmd/xinchao-nian.git"
BACKUP_ROOT="${BACKUP_ROOT:-/root/xinchao-backups}"

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行：sudo bash $0 $*"; }

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@";
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@";
  else die "没找到 docker compose"; fi
}

# 找旧的心潮部署目录：看容器上 docker compose 留下的 working_dir 标签，
# 挑同时有 compose.yaml 和 xinchao/ 的那个。
find_install_dir() {
  local d
  for c in $(docker ps -aq 2>/dev/null); do
    d=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    [ -n "$d" ] || continue
    if [ -d "$d/xinchao" ] && { [ -f "$d/compose.yaml" ] || [ -f "$d/docker-compose.yml" ]; }; then
      echo "$d"; return 0
    fi
  done
  return 1
}

project_of() {
  docker ps -a --filter "label=com.docker.compose.project.working_dir=$1" \
    --format '{{.Label "com.docker.compose.project"}}' | head -n1
}

volumes_of() {
  docker volume ls -q --filter "label=com.docker.compose.project=$1"
}

version_in() {
  grep -m1 '"version"' "$1/xinchao/package.json" 2>/dev/null | sed -E 's/.*"([0-9][^"]*)".*/\1/' || echo "未知"
}

cmd_check() {
  say "服务器"
  grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true
  command -v docker >/dev/null || die "没装 docker"
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  df -h / | awk 'NR==2{print "  磁盘剩余 "$4}'

  say "正在运行的容器"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}'

  say "旧的心潮"
  local dir
  if ! dir=$(find_install_dir); then
    warn "没找到用 docker compose 部署的心潮·念。把上面这些输出发给 Claude 看看。"
    return 0
  fi
  ok "部署目录：$dir"
  ok "当前版本：$(version_in "$dir")"
  local proj; proj=$(project_of "$dir"); ok "compose 项目名：$proj"
  echo "  数据卷："; volumes_of "$proj" | sed 's/^/    /'
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q origin 2>/dev/null || warn "拉不到 GitHub，升级时会失败"
    local latest
    latest=$(git -C "$dir" show origin/main:xinchao/package.json 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"([0-9][^"]*)".*/\1/' || true)
    [ -n "$latest" ] && ok "最新版本：$latest"
    local dirty; dirty=$(git -C "$dir" status --porcelain --untracked-files=no)
    [ -z "$dirty" ] && ok "没有改过源码，可以直接升级" || { warn "这些文件被改过，升级前要先处理："; echo "$dirty" | sed 's/^/    /'; }
  else
    warn "部署目录不是 git 仓库，本脚本不能自动升级"
  fi
  echo; echo "  确认无误后运行：sudo bash $0 upgrade"
}

backup_volumes() {
  local proj=$1 out=$2 v
  for v in $(volumes_of "$proj"); do
    docker run --rm -v "$v":/data:ro -v "$out":/backup alpine \
      tar czf "/backup/$v.tar.gz" -C /data . \
      || die "备份数据卷 $v 失败，已停止，什么都没改"
    ok "已备份 $v"
  done
}

# 把 .env.example 里有、.env 里没有的配置项补到 .env 末尾；已有的一律不动。
merge_env() {
  local dir=$1 added=0 line key
  [ -f "$dir/.env" ] || die "$dir/.env 不存在"
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)= ]] || continue
    key=${BASH_REMATCH[1]}
    grep -qE "^${key}=" "$dir/.env" && continue
    [ $added = 0 ] && printf '\n# ── 升级到新版时自动补上的配置项（%s）──\n' "$(date +%F)" >> "$dir/.env"
    if [ "$key" = DASHBOARD_ACCESS_TOKEN ]; then
      echo "DASHBOARD_ACCESS_TOKEN=$(openssl rand -hex 32)" >> "$dir/.env"
    else
      echo "$line" >> "$dir/.env"
    fi
    echo "    + $key"; added=1
  done < "$dir/.env.example"
  [ $added = 1 ] && ok "已补上新增配置项（默认值，原有配置没动）" || ok ".env 不用改"
}

wait_healthy() {
  local i s
  for i in $(seq 1 30); do
    s=$(docker inspect ombre-dynamic-mind --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo none)
    [ "$s" = healthy ] && return 0
    sleep 5
  done
  return 1
}

cmd_upgrade() {
  need_root upgrade
  local dir proj ts out old
  dir=$(find_install_dir) || die "没找到旧的心潮，先运行：bash $0"
  [ -d "$dir/.git" ] || die "$dir 不是 git 仓库，没法自动升级"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
    || die "源码被改过（bash $0 可以看到是哪些文件），为了不覆盖你的改动，先停下"
  proj=$(project_of "$dir")
  old=$(git -C "$dir" rev-parse HEAD)
  ts=$(date +%Y%m%d-%H%M%S); out="$BACKUP_ROOT/$ts"
  mkdir -p "$out"

  say "1/4 备份（旧版本 $(version_in "$dir")）"
  cp -a "$dir/.env" "$out/env.bak"
  echo "$dir" > "$out/install_dir"; echo "$old" > "$out/commit"; echo "$proj" > "$out/project"
  # 备份时先停服务，避免拷到写了一半的文件；中途出错也会把服务重新拉起来
  (cd "$dir" && compose -p "$proj" stop)
  trap '(cd "$dir" && compose -p "$proj" start) >/dev/null 2>&1 || true' EXIT
  backup_volumes "$proj" "$out"
  ok "备份放在 $out"

  say "2/4 下载新代码"
  git -C "$dir" fetch origin
  git -C "$dir" merge --ff-only origin/main || die "没法直接快进到新版本，已停止；数据和备份都在"
  git -C "$dir" submodule update --init --recursive || warn "bridge 子模块没拉下来（不影响服务端）"
  ok "代码已到 $(version_in "$dir")"

  say "3/4 检查配置"
  merge_env "$dir"

  say "4/4 重新构建并启动（几分钟，请耐心等）"
  (cd "$dir" && compose -p "$proj" up -d --build)
  trap - EXIT
  if wait_healthy; then
    ok "心潮已启动，状态健康"
  else
    warn "心潮 2 分钟内没报健康，下面是最近日志："
  fi
  docker logs --tail 30 ombre-dynamic-mind 2>&1 | sed 's/^/    /'

  say "完成"
  echo "  现在版本：$(version_in "$dir")"
  echo "  如果不对劲，退回原样：sudo bash $0 rollback $out"
}

cmd_rollback() {
  need_root rollback
  local out=${1:-}
  [ -n "$out" ] && [ -f "$out/commit" ] || die "用法：sudo bash $0 rollback 备份目录（升级结束时打印过）"
  local dir proj v
  dir=$(cat "$out/install_dir"); proj=$(cat "$out/project")

  say "停止服务（数据卷保留）"
  (cd "$dir" && compose -p "$proj" stop)

  say "还原数据"
  for f in "$out"/*.tar.gz; do
    v=$(basename "$f" .tar.gz)
    docker run --rm -v "$v":/data -v "$out":/backup alpine \
      sh -c "find /data -mindepth 1 -delete && tar xzf /backup/$v.tar.gz -C /data"
    ok "已还原 $v"
  done

  say "还原代码和配置"
  git -C "$dir" checkout -q "$(cat "$out/commit")"
  git -C "$dir" submodule update --init --recursive || true
  cp -a "$out/env.bak" "$dir/.env"
  (cd "$dir" && compose -p "$proj" up -d --build)
  ok "已退回 $(version_in "$dir")"
  warn "代码现在停在旧提交上；以后想再升级，先运行：git -C $dir checkout main"
}

case "${1:-check}" in
  check)    cmd_check ;;
  upgrade)  cmd_upgrade ;;
  rollback) shift; cmd_rollback "${1:-}" ;;
  *) die "用法：bash $0 [check|upgrade|rollback 备份目录]" ;;
esac
