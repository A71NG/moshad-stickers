#!/usr/bin/env bash
# 心潮·念 服务器小助手：检查 / 升级 / 回滚 / 新增一个心潮
#
#   bash xinchao.sh                        只检查，不改任何东西（默认）
#   bash xinchao.sh upgrade [部署目录]      先备份数据，再把心潮原地升级到最新版
#   bash xinchao.sh rollback 备份目录       退回升级前的代码和数据
#   bash xinchao.sh add 名字 网址           在同一台服务器上再装一个独立的心潮
#
# 数据（记忆库、心潮状态）存在 docker 数据卷里。升级始终在原部署目录里操作，
# 不换目录、不删数据卷（从不使用 down -v），所以升级后接上的仍是原来的数据。
# 每个心潮一个目录、一套容器、一套数据卷，互不相通。
set -euo pipefail

REPO_URL="https://github.com/tianyupaipai-cmd/xinchao-nian.git"
BACKUP_ROOT="${BACKUP_ROOT:-/root/xinchao-backups}"
EDGE_CONTAINER="${EDGE_CONTAINER:-xinchao-edge}"

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

# 找所有心潮部署目录：看容器上 docker compose 留下的 working_dir 标签，
# 挑同时有 compose.yaml 和 xinchao/ 的。
find_install_dirs() {
  local c d
  for c in $(docker ps -aq 2>/dev/null); do
    d=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    [ -n "$d" ] || continue
    if [ -d "$d/xinchao" ] && { [ -f "$d/compose.yaml" ] || [ -f "$d/docker-compose.yml" ]; }; then
      echo "$d"
    fi
  done | sort -u
}

# 选一个要操作的部署目录：给了就用给的；没给且只有一个就用它；多个就让人指定。
pick_install_dir() {
  local want=${1:-} dirs n
  dirs=$(find_install_dirs)
  [ -n "$dirs" ] || die "没找到心潮，先运行：bash $0"
  if [ -n "$want" ]; then
    want=$(cd "$want" 2>/dev/null && pwd) || die "目录不存在：$1"
    grep -qxF "$want" <<<"$dirs" || die "$want 不是正在运行的心潮部署目录"
    echo "$want"; return
  fi
  n=$(wc -l <<<"$dirs")
  [ "$n" = 1 ] && { echo "$dirs"; return; }
  printf '  服务器上有 %s 个心潮，请指定要操作哪一个：\n' "$n" >&2
  sed "s|^|    sudo bash $0 ${CMD:-upgrade} |" <<<"$dirs" >&2
  exit 1
}

project_of() {
  docker ps -a --filter "label=com.docker.compose.project.working_dir=$1" \
    --format '{{.Label "com.docker.compose.project"}}' | head -n1
}

volumes_of() {
  docker volume ls -q --filter "label=com.docker.compose.project=$1"
}

mind_container_of() {
  docker ps -a --filter "label=com.docker.compose.project=$1" \
    --filter "label=com.docker.compose.service=dynamic-mind" --format '{{.Names}}' | head -n1
}

version_in() {
  grep -m1 '"version"' "$1/xinchao/package.json" 2>/dev/null | sed -E 's/.*"([0-9][^"]*)".*/\1/' || echo "未知"
}

env_get() { grep -m1 -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' || true; }

# 写一项配置：已有就整行替换（连同行尾注释），没有就追加。值里的特殊字符原样保留。
env_set() {
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]; done=0}
    index($0, k"=")==1 { if (!done) print k"="v; done=1; next } { print }
    END { if (!done) print k"="v }' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

rand_hex() { openssl rand -hex "$1"; }

port_busy() {
  ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && return 0
  docker ps --format '{{.Ports}}' | grep -qE "[:.]$1->" && return 0
  return 1
}

free_port() {
  local p=$1
  while port_busy "$p"; do p=$((p + 10)); done
  echo "$p"
}

caddyfile_path() {
  docker inspect "$EDGE_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
}

wait_healthy() {
  local name=$1 i s
  for i in $(seq 1 30); do
    s=$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo none)
    [ "$s" = healthy ] && return 0
    sleep 5
  done
  return 1
}

cmd_check() {
  say "服务器"
  grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true
  command -v docker >/dev/null || die "没装 docker"
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  df -h / | awk 'NR==2{print "  磁盘剩余 "$4}'
  free -m | awk '/^Mem:/{print "  内存可用 "$7" MB / 共 "$2" MB"}'

  say "正在运行的容器"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}'

  local dirs dir proj dirty latest
  dirs=$(find_install_dirs)
  if [ -z "$dirs" ]; then
    say "心潮"
    warn "没找到用 docker compose 部署的心潮·念。把上面这些输出发给 Claude 看看。"
    return 0
  fi
  while read -r dir; do
    say "心潮：$dir"
    ok "当前版本：$(version_in "$dir")"
    proj=$(project_of "$dir"); ok "compose 项目名：$proj"
    echo "  数据卷："; volumes_of "$proj" | sed 's/^/    /'
    if [ -d "$dir/.git" ]; then
      git -C "$dir" fetch -q origin 2>/dev/null || warn "拉不到 GitHub，升级时会失败"
      latest=$(git -C "$dir" show origin/main:xinchao/package.json 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"([0-9][^"]*)".*/\1/' || true)
      [ -n "$latest" ] && ok "最新版本：$latest"
      dirty=$(git -C "$dir" status --porcelain --untracked-files=no)
      [ -z "$dirty" ] && ok "没有改过源码，可以直接升级" || { warn "这些文件被改过，升级前要先处理："; echo "$dirty" | sed 's/^/    /'; }
    else
      warn "部署目录不是 git 仓库，本脚本不能自动升级"
    fi
  done <<<"$dirs"
  if [ "$(wc -l <<<"$dirs")" = 1 ]; then
    echo; echo "  确认无误后运行：sudo bash $0 upgrade"
  else
    echo; echo "  升级其中一个：sudo bash $0 upgrade 部署目录"
  fi
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
      echo "DASHBOARD_ACCESS_TOKEN=$(rand_hex 32)" >> "$dir/.env"
    else
      echo "$line" >> "$dir/.env"
    fi
    echo "    + $key"; added=1
  done < "$dir/.env.example"
  [ $added = 1 ] && ok "已补上新增配置项（默认值，原有配置没动）" || ok ".env 不用改"
}

cmd_upgrade() {
  need_root upgrade
  local dir proj ts out old mind
  dir=$(pick_install_dir "${1:-}")
  [ -d "$dir/.git" ] || die "$dir 不是 git 仓库，没法自动升级"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
    || die "源码被改过（bash $0 可以看到是哪些文件），为了不覆盖你的改动，先停下"
  proj=$(project_of "$dir")
  old=$(git -C "$dir" rev-parse HEAD)
  ts=$(date +%Y%m%d-%H%M%S); out="$BACKUP_ROOT/$proj-$ts"
  mkdir -p "$out"

  say "1/4 备份 $dir（旧版本 $(version_in "$dir")）"
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
  mind=$(mind_container_of "$proj")
  if wait_healthy "$mind"; then
    ok "心潮已启动，状态健康"
  else
    warn "心潮 2 分钟内没报健康，下面是最近日志："
  fi
  docker logs --tail 30 "$mind" 2>&1 | sed 's/^/    /'

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

# 新增一个心潮：独立目录、独立容器名、独立端口、独立数据卷、独立口令。
cmd_add() {
  need_root add
  local name=${1:-} domain=${2:-}
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]] || die "用法：sudo bash $0 add 名字 网址（名字只用小写字母、数字、横线，例如 xc）"
  [[ $domain =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "网址格式不对，例如 xc.moshad.cc（不要带 https://）"

  local first base dir proj mind_port ob_port caddyfile ip resolved
  first=$(find_install_dirs | head -n1 || true)
  base=$(dirname "${first:-/home/${SUDO_USER:-root}/x}")
  dir="$base/xinchao-$name"; proj="xinchao-$name"
  [ -e "$dir" ] && die "$dir 已经存在；换个名字，或先确认那个目录是做什么的"
  docker ps -a --format '{{.Names}}' | grep -qxE "$name-(dynamic-mind|ombre-brain)" && die "容器名 $name-* 已被占用"

  caddyfile=$(caddyfile_path)
  [ -n "$caddyfile" ] && [ -f "$caddyfile" ] || die "没找到 $EDGE_CONTAINER 的 Caddyfile，没法接网址"
  grep -qE "^[[:space:]]*${domain//./\\.}([[:space:],{]|$)" "$caddyfile" && die "$domain 已经写在 Caddyfile 里了"

  say "1/6 检查"
  mind_port=$(free_port 18120); ob_port=$(free_port 18011)
  ok "新心潮端口：$mind_port（记忆库 $ob_port），只对本机开放"
  local avail; avail=$(free -m | awk '/^Mem:/{print $7}')
  [ "${avail:-0}" -ge 700 ] && ok "内存可用 ${avail} MB" || warn "内存可用只有 ${avail} MB，两个心潮一起跑可能吃紧"
  ip=$(curl -s -4 -m 8 ifconfig.me || true)
  resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}' || true)
  if [ -n "$ip" ] && [ "$resolved" = "$ip" ]; then
    ok "$domain 已经指向本机 $ip"
  else
    warn "$domain 现在指向「${resolved:-还没有}」，本机是 ${ip:-?}。先装着，解析生效后 HTTPS 会自动配好"
  fi

  say "2/6 模型 Key"
  local key old_env="${first:+$first/.env}" base_url model
  printf '  请粘贴新 AI 用的 API Key，然后回车（屏幕上不会显示）：\n  > '
  IFS= read -rs key </dev/tty; echo
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  [ ${#key} -ge 8 ] || die "Key 看起来是空的或太短，什么都没改"
  base_url=$(env_get "$old_env" OMBRE_COMPRESS_BASE_URL); model=$(env_get "$old_env" OMBRE_COMPRESS_MODEL)
  if [ -n "$base_url$model" ]; then
    printf '  第一个心潮用的是：%s  模型 %s\n  新 Key 也是这家的就直接回车；不是的话输入 n 再回车：' "${base_url:-默认}" "${model:-默认}"
    local ans; IFS= read -r ans </dev/tty || true
    if [[ $ans =~ ^[nN] ]]; then
      printf '  新 Key 的接口地址（例如 https://api.deepseek.com/v1）：'; IFS= read -r base_url </dev/tty
      printf '  模型名（例如 deepseek-chat）：'; IFS= read -r model </dev/tty
    fi
  fi
  ok "Key 已收到（${#key} 位）"

  say "3/6 下载心潮代码到 $dir"
  git clone -q --recursive "$REPO_URL" "$dir" || die "下载失败"
  ok "版本 $(version_in "$dir")"

  say "4/6 生成配置"
  cp "$dir/.env.example" "$dir/.env"; chmod 600 "$dir/.env"
  local mcp_token dm_token oauth_token dash_token ob_pass
  mcp_token=$(rand_hex 24); dm_token=$(rand_hex 24)
  oauth_token=$(rand_hex 12); dash_token=$(rand_hex 32); ob_pass=$(rand_hex 8)
  env_set "$dir/.env" OMBRE_COMPRESS_API_KEY "$key"
  env_set "$dir/.env" OMBRE_COMPRESS_BASE_URL "$base_url"
  env_set "$dir/.env" OMBRE_COMPRESS_MODEL "$model"
  env_set "$dir/.env" OMBRE_DASHBOARD_PASSWORD "$ob_pass"
  env_set "$dir/.env" OMBRE_MCP_SERVICE_TOKEN "$mcp_token"
  env_set "$dir/.env" OMBRE_MCP_TOKEN "$mcp_token"
  env_set "$dir/.env" DYNAMIC_MIND_TOKEN "$dm_token"
  env_set "$dir/.env" DYNAMIC_MIND_URL "http://dynamic-mind:18110"
  env_set "$dir/.env" OMBRE_HOST_PORT "$ob_port"
  env_set "$dir/.env" MCP_ENABLED true
  env_set "$dir/.env" OAUTH_ENABLED true
  env_set "$dir/.env" OAUTH_PUBLIC_BASE_URL "https://$domain"
  env_set "$dir/.env" OAUTH_APPROVAL_TOKEN "$oauth_token"
  env_set "$dir/.env" DASHBOARD_ACCESS_TOKEN "$dash_token"
  env_set "$dir/.env" DASHBOARD_PUBLIC_BASE_URL "https://$domain"
  local v
  for v in PIP_INDEX_URL PIP_TRUSTED_HOST; do
    env_set "$dir/.env" "$v" "$(env_get "$old_env" "$v")"
  done
  # 第一个心潮的向量化如果和压缩用同一家同一把 Key，新心潮也跟着用新 Key；否则留空，之后在 Dashboard 里填
  if [ -n "$old_env" ] && [ -n "$(env_get "$old_env" OMBRE_EMBED_API_KEY)" ] \
     && [ "$(env_get "$old_env" OMBRE_EMBED_API_KEY)" = "$(env_get "$old_env" OMBRE_COMPRESS_API_KEY)" ] \
     && [ "$(env_get "$old_env" OMBRE_COMPRESS_BASE_URL)" = "$base_url" ]; then
    env_set "$dir/.env" OMBRE_EMBED_API_KEY "$key"
    env_set "$dir/.env" OMBRE_EMBED_BASE_URL "$(env_get "$old_env" OMBRE_EMBED_BASE_URL)"
    env_set "$dir/.env" OMBRE_EMBED_MODEL "$(env_get "$old_env" OMBRE_EMBED_MODEL)"
  fi
  # 容器名、镜像名、心潮端口都和第一个错开；数据卷按目录名自动独立
  cat > "$dir/compose.override.yaml" <<EOF
# 由 xinchao.sh add 生成：让这个心潮（$name）和同一台服务器上的其他心潮互不冲突
services:
  ombre-brain:
    container_name: $name-ombre-brain
    image: xinchao-$name/ombre-brain:local
  dynamic-mind:
    container_name: $name-dynamic-mind
    image: xinchao-$name/dynamic-mind:local
    ports: !override
      - "127.0.0.1:$mind_port:18110"
EOF
  [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER:" "$dir" 2>/dev/null || true
  ok "口令都已自动生成，写在 $dir/.env"

  # 后面的构建要几分钟：放到后台跑，手机断线也不会中断；前台只是看进度
  local log="$dir/add.log"
  nohup bash "$0" _add_finish "$name" "$domain" "$dir" > "$log" 2>&1 < /dev/null &
  local bg=$!
  echo; echo "  接下来在后台构建。断线也没关系，重新登录后粘贴这行看结果：tail -n 30 $log"
  tail -n +1 -f --pid=$bg "$log"
}

cmd_add_finish() {
  local name=$1 domain=$2 dir=$3 proj="xinchao-$1" caddyfile mind_port
  caddyfile=$(caddyfile_path)
  mind_port=$(sed -nE 's/.*"127\.0\.0\.1:([0-9]+):18110".*/\1/p' "$dir/compose.override.yaml")

  say "5/6 构建并启动（第一次要几分钟，请耐心等）"
  (cd "$dir" && compose -p "$proj" up -d --build) || die "启动失败；第一个心潮没受影响。把上面的报错截图发给 Claude"
  if wait_healthy "$name-dynamic-mind"; then
    ok "新心潮已启动，状态健康"
  else
    warn "新心潮 2 分钟内没报健康，最近日志："
    docker logs --tail 30 "$name-dynamic-mind" 2>&1 | sed 's/^/    /'
  fi

  say "6/6 接上网址 $domain"
  local bak; bak="$caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$caddyfile" "$bak"
  printf '\n%s {\n    reverse_proxy 127.0.0.1:%s {\n        flush_interval -1\n    }\n}\n' "$domain" "$mind_port" >> "$caddyfile"
  if docker exec "$EDGE_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
     && docker exec "$EDGE_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    ok "Caddy 已加上 $domain 并重新加载（其他网址不受影响）"
  else
    cat "$bak" > "$caddyfile"
    warn "Caddy 配置没通过检查，已恢复原样；新心潮本身已经在跑，把这屏截图发给 Claude"
  fi

  say "完成：新心潮「$name」"
  cat <<EOF
  网址：            https://$domain
  版本检查：        https://$domain/health
  Claude 连接器 URL：https://$domain/mcp
  连接器授权口令：  $(env_get "$dir/.env" OAUTH_APPROVAL_TOKEN)
  心潮网页口令：    $(env_get "$dir/.env" DASHBOARD_ACCESS_TOKEN)
  记忆库后台密码：  $(env_get "$dir/.env" OMBRE_DASHBOARD_PASSWORD)

  这些口令也都存在 $dir/.env 里，忘了可以再查。请截图保存好，不要发到聊天里。
EOF
}

CMD=${1:-check}
case "$CMD" in
  check)    cmd_check ;;
  upgrade)  shift; cmd_upgrade "${1:-}" ;;
  rollback) shift; cmd_rollback "${1:-}" ;;
  add)      shift; cmd_add "${1:-}" "${2:-}" ;;
  _add_finish) shift; cmd_add_finish "$@" ;;
  *) die "用法：bash $0 [check | upgrade [部署目录] | rollback 备份目录 | add 名字 网址]" ;;
esac
