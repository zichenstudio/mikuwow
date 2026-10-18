#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, imoutopia
#
# mikuwow.sh - 基于 feh + curl 的随机壁纸切换工具（含收藏功能 + 安全建目录）
#
# 用法:
#   ./mikuwow.sh                  # 使用已保存的配置
#   ./mikuwow.sh -i 300           # 修改切换间隔并保存
#   ./mikuwow.sh -k 5             # 修改保留图片数并保存
#   ./mikuwow.sh -r 8             # 修改最大重试数并保存
#   ./mikuwow.sh -H 10000         # 修改哈希上限并保存
#   ./mikuwow.sh -d ~/wp          # 指定缓存目录并保存
#   ./mikuwow.sh -a <url>         # 修改 API 并保存
#   ./mikuwow.sh -c               # 删除所有缓存图片(保留哈希与收藏)
#   ./mikuwow.sh -ca              # 删除所有缓存图片并清空所有哈希记录(保留收藏)
#   ./mikuwow.sh --purge-fav      # 删除所有收藏图片
#   ./mikuwow.sh -C               # 重置所有配置为默认值
#   ./mikuwow.sh -n               # 立即切换一次(独立执行，不获取锁)
#   ./mikuwow.sh -s               # 查看运行状态与当前配置
#   ./mikuwow.sh -f               # 收藏当前壁纸
#   ./mikuwow.sh -u               # 取消收藏当前壁纸
#   ./mikuwow.sh -F               # 列出所有收藏
#   ./mikuwow.sh -N               # 随机使用一张收藏作为壁纸
#   ./mikuwow.sh -N 3             # 使用第 3 张收藏作为壁纸
#
# 配置文件固定存放于 ${XDG_CONFIG_HOME:-$HOME/.config}/mikuwow/config.conf
# 缓存目录（图片/历史/日志/收藏）可通过 -d 指定并持久化保存。
# 首次启动会提示选择 API，其余项使用默认值。
#
# ---------- end of help ----------

set -uo pipefail

# ---------- 默认值 ----------
DEF_API_URL="https://api.mikupara.com/api/h"
DEF_INTERVAL=3600
DEF_KEEP_COUNT=3
DEF_MAX_RETRY=5
DEF_MAX_HASH=0          # 0 = 不限制
DEF_CACHE_DIR="$HOME/.cache/mikuwow"

API_URL="${MIKUWOW_API_URL:-$DEF_API_URL}"
INTERVAL="$DEF_INTERVAL"
KEEP_COUNT="$DEF_KEEP_COUNT"
MAX_RETRY="$DEF_MAX_RETRY"
MAX_HASH="$DEF_MAX_HASH"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mikuwow"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# CACHE_DIR 稍后根据配置/参数确定，这里先占位
CACHE_DIR=""

LOG_MAX_LINES=5000

# ---------- 工具函数 ----------
ensure_dir() {
    local d="$1"
    [ -z "$d" ] && { echo "错误：目录路径为空" >&2; return 1; }
    if [ -d "$d" ]; then
        if [ ! -w "$d" ]; then
            echo "错误：目录不可写 -> $d" >&2
            return 1
        fi
        return 0
    fi
    if [ -e "$d" ]; then
        echo "错误：路径已存在但不是目录 -> $d" >&2
        return 1
    fi
    if ! mkdir -p "$d"; then
        echo "错误：创建目录失败 -> $d" >&2
        return 1
    fi
    return 0
}

# 根据 CACHE_DIR 派生出所有缓存相关路径
derive_paths() {
    FAVORITES_DIR="$CACHE_DIR/favorites"
    HISTORY_FILE="$CACHE_DIR/history"
    LOG_FILE="$CACHE_DIR/mikuwow.log"
    LOCK_FILE="$CACHE_DIR/mikuwow.lock"
    PID_FILE="$CACHE_DIR/mikuwow.pid"
    CURRENT_FILE="$CACHE_DIR/current"
}

# 初始化缓存目录及派生路径（先 derive 再建目录）
init_cache_paths() {
    derive_paths
    ensure_dir "$CACHE_DIR"     || exit 1
    ensure_dir "$FAVORITES_DIR" || exit 1
    touch "$HISTORY_FILE"       || { echo "错误：无法创建 $HISTORY_FILE" >&2; exit 1; }
}

# ---------- 依赖检查 ----------
for cmd in feh curl sha256sum flock; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "缺少依赖: $cmd" >&2; exit 1; }
done

# ---------- 配置文件读取（在确定 CACHE_DIR 之前） ----------
conf_get_file() {
    local key="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-
}

conf_write() {
    ensure_dir "$CONFIG_DIR" || { echo "错误：无法创建配置目录 $CONFIG_DIR" >&2; return 1; }
    {
        printf 'API_URL=%s\n' "$API_URL"
        printf 'INTERVAL=%s\n' "$INTERVAL"
        printf 'KEEP_COUNT=%s\n' "$KEEP_COUNT"
        printf 'MAX_RETRY=%s\n' "$MAX_RETRY"
        printf 'MAX_HASH=%s\n' "$MAX_HASH"
        printf 'CACHE_DIR=%s\n' "$CACHE_DIR"
    } > "$CONFIG_FILE"
}

# ---------- 参数解析（先解析，CACHE_DIR 可能被 -d 覆盖） ----------
CLEAN_IMG=0
CLEAN_HASH=0
PURGE_FAV=0
RESET_CONFIG=0
DO_ONCE=0
SHOW_STATUS=0
DO_FAV=0
DO_UNFAV=0
DO_LIST_FAV=0
FAV_NEXT=0
FAV_NEXT_IDX=""
INTERVAL_FROM_ARG=0
KEEP_FROM_ARG=0
RETRY_FROM_ARG=0
HASH_FROM_ARG=0
API_FROM_ARG=0
CACHE_FROM_ARG=0

while [ $# -gt 0 ]; do
    case "$1" in
        -ca) CLEAN_IMG=1; CLEAN_HASH=1; shift ;;
        -c)  CLEAN_IMG=1; shift ;;
        -C)  RESET_CONFIG=1; shift ;;
        -i)  INTERVAL="$2"; INTERVAL_FROM_ARG=1; shift 2 ;;
        -k)  KEEP_COUNT="$2"; KEEP_FROM_ARG=1; shift 2 ;;
        -r)  MAX_RETRY="$2"; RETRY_FROM_ARG=1; shift 2 ;;
        -H)  MAX_HASH="$2"; HASH_FROM_ARG=1; shift 2 ;;
        -d)  CACHE_DIR="$2"; CACHE_FROM_ARG=1; shift 2 ;;
        -a)  API_URL="$2"; API_FROM_ARG=1; shift 2 ;;
        -n)  DO_ONCE=1; shift ;;
        -s)  SHOW_STATUS=1; shift ;;
        -f)      DO_FAV=1; shift ;;
        -u)    DO_UNFAV=1; shift ;;
        -F) DO_LIST_FAV=1; shift ;;
        -N)
            FAV_NEXT=1
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                FAV_NEXT_IDX="$2"; shift
            fi
            shift ;;
        --purge-fav)   PURGE_FAV=1; shift ;;
        -h)  awk 'NR==1{next} /^# ---------- end of help ----------$/{exit} {print}' "$0"; exit 0 ;;
        *)   echo "未知选项: $1" >&2; exit 1 ;;
    esac
done

# ---------- 重置配置 ----------
if [ "$RESET_CONFIG" -eq 1 ]; then
    rm -f "$CONFIG_FILE"
    echo "已重置配置：$CONFIG_FILE"
    exit 0
fi

# ---------- 读取已保存的配置（API/间隔/保留/重试/哈希/CACHE_DIR） ----------
if [ -f "$CONFIG_FILE" ]; then
    v=$(conf_get_file API_URL);      [ "$API_FROM_ARG"      -eq 1 ] || [ -z "$v" ] || API_URL="$v"
    v=$(conf_get_file INTERVAL);     [ "$INTERVAL_FROM_ARG" -eq 1 ] || [ -z "$v" ] || INTERVAL="$v"
    v=$(conf_get_file KEEP_COUNT);   [ "$KEEP_FROM_ARG"     -eq 1 ] || [ -z "$v" ] || KEEP_COUNT="$v"
    v=$(conf_get_file MAX_RETRY);    [ "$RETRY_FROM_ARG"    -eq 1 ] || [ -z "$v" ] || MAX_RETRY="$v"
    v=$(conf_get_file MAX_HASH);     [ "$HASH_FROM_ARG"     -eq 1 ] || [ -z "$v" ] || MAX_HASH="$v"
    v=$(conf_get_file CACHE_DIR);    [ "$CACHE_FROM_ARG"    -eq 1 ] || [ -z "$v" ] || CACHE_DIR="$v"
fi

# 若仍为空，使用默认缓存目录
[ -z "$CACHE_DIR" ] && CACHE_DIR="$DEF_CACHE_DIR"

# 初始化缓存相关路径与目录
init_cache_paths

log() {
    local msg
    msg="[$(date '+%F %T')] $*"
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        local n
        n=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$n" -gt "$LOG_MAX_LINES" ]; then
            tail -n $((LOG_MAX_LINES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null \
                && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

trim_history() {
    [ "${MAX_HASH:-0}" -gt 0 ] || return 0
    local n
    n=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo 0)
    [ "$n" -le "$MAX_HASH" ] && return 0
    tail -n "$MAX_HASH" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" \
        && mv -f "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    log "history 超过 ${MAX_HASH} 行，已裁剪保留最新 ${MAX_HASH} 行"
}

download_wallpaper() {
    local ts tmp headers final_url src_name final_name
    ts=$(date +%s)
    tmp="$(mktemp "$CACHE_DIR/dl.XXXXXX")" || return 1
    headers="$(mktemp "$CACHE_DIR/hd.XXXXXX")" || { rm -f "$tmp"; return 1; }

    final_url=$(curl -fsSL --max-time 60 --connect-timeout 10 \
        -D "$headers" -o "$tmp" -w '%{url_effective}' "$API_URL") || {
        rm -f "$tmp" "$headers"; return 1
    }
    [ -s "$tmp" ] || { rm -f "$tmp" "$headers"; return 1; }

    src_name=$(grep -i '^content-disposition:' "$headers" \
        | sed -n 's/.*filename="\{0,1\}\([^";]*\)"\{0,1\}.*/\1/p' | head -n1)
    if [ -z "$src_name" ]; then
        src_name="${final_url##*/}"
        src_name="${src_name%%\?*}"
    fi
    if [ -z "$src_name" ] || [ "$src_name" = "/" ]; then
        src_name="${ts}-${RANDOM}.jpg"
    fi
    case "$src_name" in
        *.*) : ;;
        *) src_name="${src_name}.jpg" ;;
    esac

    final_name="${ts}-${RANDOM}-${src_name}"
    final_name="${final_name//\//_}"
    rm -f "$headers"
    mv -f "$tmp" "$CACHE_DIR/$final_name" || { rm -f "$tmp"; return 1; }
    printf '%s' "$CACHE_DIR/$final_name"
}

cleanup_old() {
    local files
    mapfile -t files < <(
        find "$CACHE_DIR" -maxdepth 1 -type f -name '[0-9]*-*' \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}'
    )
    local n=${#files[@]}
    [ "$n" -le "$KEEP_COUNT" ] && return 0
    local i
    for ((i = KEEP_COUNT; i < n; i++)); do
        local f="${files[$i]}"
        [ -n "${current_img:-}" ] && [ "$f" = "$current_img" ] && continue
        rm -f "$f" && log "清理旧壁纸: $(basename "$f")"
    done
}

fetch_unique_wallpaper() {
    RESULT_HASH=""
    RESULT_PATH=""
    local retry=0 hash path
    path=""
    while [ "$retry" -lt "$MAX_RETRY" ]; do
        path=$(download_wallpaper) || {
            log "下载失败，重试 ($((retry + 1))/$MAX_RETRY)"
            retry=$((retry + 1)); continue
        }
        hash=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
        if [ -z "$hash" ]; then
            log "计算哈希失败，删除并重试 ($((retry + 1))/$MAX_RETRY)"
            rm -f "$path"; path=""
            retry=$((retry + 1)); continue
        fi

        if grep -q "^${hash} " "$HISTORY_FILE" 2>/dev/null; then
            log "哈希重复: ${hash:0:12}... ($((retry + 1))/$MAX_RETRY)"
            if [ "$retry" -lt $((MAX_RETRY - 1)) ]; then
                rm -f "$path"; path=""
                retry=$((retry + 1)); continue
            fi
            log "已达最大重试次数，保留并直接使用重复图片（不写入 history）"
            RESULT_HASH="$hash"; RESULT_PATH="$path"; return 0
        fi

        printf '%s %s\n' "$hash" "$path" >> "$HISTORY_FILE"
        trim_history
        RESULT_HASH="$hash"; RESULT_PATH="$path"; return 0
    done
    return 1
}

set_wallpaper() {
    local img="$1"
    if [ ! -f "$img" ]; then
        log "错误：壁纸文件不存在 -> $img"; return 1
    fi
    if feh --no-fehbg --bg-fill "$img"; then
        log "已设置壁纸: $(basename "$img")"
    else
        log "feh 设置壁纸失败: $img"; return 1
    fi
}

# ---------- 收藏相关函数 ----------
fav_name_for() {
    local img="$1" hash base
    hash=$(sha256sum "$img" 2>/dev/null | awk '{print $1}')
    [ -z "$hash" ] && return 1
    base="$(basename "$img")"
    printf '%s/%s-%s' "$FAVORITES_DIR" "${hash:0:16}" "$base"
}

fav_is_favorited() {
    local img="$1" hash
    hash=$(sha256sum "$img" 2>/dev/null | awk '{print $1}')
    [ -z "$hash" ] && return 1
    ls "$FAVORITES_DIR" 2>/dev/null | grep -q "^${hash:0:16}-"
}

fav_add() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        if [ -f "$CURRENT_FILE" ]; then
            img=$(cat "$CURRENT_FILE")
        else
            log "未指定图片，且无当前壁纸记录"; return 1
        fi
    fi
    if [ ! -f "$img" ]; then
        log "收藏失败：文件不存在 -> $img"; return 1
    fi
    ensure_dir "$FAVORITES_DIR" || { log "收藏失败：收藏目录不可用"; return 1; }
    if fav_is_favorited "$img"; then
        log "已在收藏中: $(basename "$img")"; return 0
    fi
    local dest
    dest=$(fav_name_for "$img") || { log "计算哈希失败，无法收藏"; return 1; }
    if cp -f "$img" "$dest"; then
        log "已收藏: $(basename "$dest")"
        return 0
    else
        log "收藏失败: $img"; return 1
    fi
}

fav_remove() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        if [ -f "$CURRENT_FILE" ]; then
            img=$(cat "$CURRENT_FILE")
        else
            log "未指定图片，且无当前壁纸记录"; return 1
        fi
    fi
    if [ ! -f "$img" ]; then
        log "取消收藏失败：文件不存在 -> $img"; return 1
    fi
    local hash prefix removed=0 f
    hash=$(sha256sum "$img" 2>/dev/null | awk '{print $1}')
    [ -z "$hash" ] && { log "计算哈希失败"; return 1; }
    prefix="${hash:0:16}-"
    for f in "$FAVORITES_DIR"/"$prefix"*; do
        [ -e "$f" ] || continue
        rm -f "$f" && { removed=1; log "已取消收藏: $(basename "$f")"; }
    done
    [ "$removed" -eq 1 ] || log "未在收藏中找到: $(basename "$img")"
    return 0
}

fav_list() {
    local files
    mapfile -t files < <(find "$FAVORITES_DIR" -maxdepth 1 -type f -name '*-*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if [ "${#files[@]}" -eq 0 ]; then
        echo "暂无收藏。"
        return 0
    fi
    echo "===== 收藏列表（按时间倒序） ====="
    local i=1 f size
    for f in "${files[@]}"; do
        size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
        printf '%2d) %s  [%s]  %s\n' "$i" "$(basename "$f")" "$size" "$f"
        i=$((i + 1))
    done
    echo "共 ${#files[@]} 张。"
}

fav_use() {
    local idx="${1:-}"
    local files
    mapfile -t files < <(find "$FAVORITES_DIR" -maxdepth 1 -type f -name '*-*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if [ "${#files[@]}" -eq 0 ]; then
        log "收藏为空，无法设置壁纸"; return 1
    fi
    local pick
    if [ -n "$idx" ]; then
        case "$idx" in
            ''|*[!0-9]*) log "收藏索引必须是正整数"; return 1 ;;
        esac
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
            log "收藏索引越界: $idx (共 ${#files[@]} 张)"; return 1
        fi
        pick="${files[$((idx - 1))]}"
    else
        pick="${files[$((RANDOM % ${#files[@]}))]}"
    fi
    if set_wallpaper "$pick"; then
        echo "$pick" > "$CURRENT_FILE"
        log "已从收藏设置壁纸: $(basename "$pick")"
        return 0
    fi
    return 1
}

fav_purge() {
    local n
    n=$(find "$FAVORITES_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then
        log "收藏为空，无需清理"; return 0
    fi
    find "$FAVORITES_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    log "已删除全部收藏（${n} 张）"
}

# ---------- 参数校验 ----------
case "$KEEP_COUNT" in ''|*[!0-9]*) echo "-k 必须是正整数" >&2; exit 1 ;; esac
[ "$KEEP_COUNT" -ge 1 ] || { echo "-k 必须 >= 1" >&2; exit 1; }
case "$MAX_RETRY" in ''|*[!0-9]*) echo "-r 必须是正整数" >&2; exit 1 ;; esac
[ "$MAX_RETRY" -ge 1 ] || { echo "-r 必须 >= 1" >&2; exit 1; }
case "$MAX_HASH" in ''|*[!0-9]*) echo "-H 必须是非负整数" >&2; exit 1 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "-i 必须是正整数" >&2; exit 1 ;; esac
[ "$INTERVAL" -ge 1 ] || { echo "-i 必须 >= 1" >&2; exit 1; }

# 重新校验（配置文件可能带入非法值）
case "$KEEP_COUNT" in ''|*[!0-9]*) KEEP_COUNT="$DEF_KEEP_COUNT" ;; esac
[ "$KEEP_COUNT" -ge 1 ] || KEEP_COUNT="$DEF_KEEP_COUNT"
case "$MAX_RETRY" in ''|*[!0-9]*) MAX_RETRY="$DEF_MAX_RETRY" ;; esac
[ "$MAX_RETRY" -ge 1 ] || MAX_RETRY="$DEF_MAX_RETRY"
case "$MAX_HASH" in ''|*[!0-9]*) MAX_HASH="$DEF_MAX_HASH" ;; esac
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL="$DEF_INTERVAL" ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL="$DEF_INTERVAL"

# 任何一项来自命令行 -> 保存合并后的配置
if [ "$API_FROM_ARG" -eq 1 ] || [ "$INTERVAL_FROM_ARG" -eq 1 ] || [ "$KEEP_FROM_ARG" -eq 1 ] \
   || [ "$RETRY_FROM_ARG" -eq 1 ] || [ "$HASH_FROM_ARG" -eq 1 ] || [ "$CACHE_FROM_ARG" -eq 1 ]; then
    conf_write
fi

# ---------- 状态查看 ----------
if [ "$SHOW_STATUS" -eq 1 ]; then
    echo "===== mikuwow 状态 ====="
    echo "配置文件   : $CONFIG_FILE"
    echo "缓存目录   : $CACHE_DIR"
    echo "收藏目录   : $FAVORITES_DIR"
    echo "日志文件   : $LOG_FILE"
    echo "使用 API   : $API_URL"
    echo "切换间隔   : ${INTERVAL}s"
    echo "保留图片数 : $KEEP_COUNT"
    echo "最大重试数 : $MAX_RETRY"
    if [ "${MAX_HASH:-0}" -gt 0 ]; then
        echo "哈希上限   : $MAX_HASH"
    else
        echo "哈希上限   : 不限制"
    fi
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "运行状态   : 运行中 (PID $(cat "$PID_FILE"))"
    else
        echo "运行状态   : 未运行"
    fi
    echo "历史哈希数 : $(wc -l < "$HISTORY_FILE" 2>/dev/null || echo 0)"
    echo "缓存图片数 : $(find "$CACHE_DIR" -maxdepth 1 -type f -name '[0-9]*-*' 2>/dev/null | wc -l)"
    echo "收藏数量   : $(find "$FAVORITES_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    echo "缓存大小   : $(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')"
    if [ -f "$CURRENT_FILE" ]; then
        echo "当前壁纸   : $(cat "$CURRENT_FILE")"
    fi
    if [ -f "$LOG_FILE" ]; then
        echo "--- 最近 5 条日志 ---"
        tail -n 5 "$LOG_FILE"
    fi
    exit 0
fi

# ---------- 收藏相关操作（独立执行，退出） ----------
if [ "$DO_FAV" -eq 1 ]; then
    fav_add "" && exit 0 || exit 1
fi
if [ "$DO_UNFAV" -eq 1 ]; then
    fav_remove "" && exit 0 || exit 1
fi
if [ "$DO_LIST_FAV" -eq 1 ]; then
    fav_list; exit 0
fi
if [ "$FAV_NEXT" -eq 1 ]; then
    fav_use "$FAV_NEXT_IDX" && exit 0 || exit 1
fi
if [ "$PURGE_FAV" -eq 1 ]; then
    fav_purge; exit 0
fi

# ---------- 清理 ----------
if [ "$CLEAN_IMG" -eq 1 ]; then
    log "删除所有缓存图片(保留收藏): $CACHE_DIR"
    find "$CACHE_DIR" -maxdepth 1 -type f -name '[0-9]*-*' -delete
fi
if [ "$CLEAN_HASH" -eq 1 ]; then
    log "清空所有哈希记录: $HISTORY_FILE"
    : > "$HISTORY_FILE"
fi
if [ "$CLEAN_IMG" -eq 1 ] || [ "$CLEAN_HASH" -eq 1 ]; then
    log "清理完成，退出。"; exit 0
fi

# ---------- 首次启动：选择 API，并保存配置 ----------
if [ ! -f "$CONFIG_FILE" ]; then
    if [ "$API_FROM_ARG" -eq 0 ]; then
        echo "检测到首次启动，请选择随机图片 API："
        echo "  1) ${DEF_API_URL}  (默认)"
        echo "  2) 自定义输入"
        printf '请输入 [1/2]，直接回车默认 1: '
        read -r choice
        case "$choice" in
            2)
                printf '请输入 API URL: '
                read -r custom_api
                if [ -n "$custom_api" ]; then
                    API_URL="$custom_api"
                else
                    echo "输入为空，使用默认 API。"
                fi
                ;;
            *)
                echo "使用默认 API。"
                ;;
        esac
    fi
    conf_write
    log "已保存配置到 $CONFIG_FILE"
fi
log "使用 API: $API_URL"

# ---------- -n 立即切换一次（独立执行，不获取锁） ----------
if [ "$DO_ONCE" -eq 1 ]; then
    log "立即切换一次... (API: $API_URL)"
    if fetch_unique_wallpaper; then
        set_wallpaper "$RESULT_PATH"
        echo "$RESULT_PATH" > "$CURRENT_FILE"
        log "完成。"
        exit 0
    else
        log "切换失败：下载不到图片。"
        exit 1
    fi
fi

# ---------- 单实例锁（只约束后台循环） ----------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "已有 mikuwow 实例在运行 (锁: $LOCK_FILE)，退出。" >&2
    exit 1
fi
echo $$ > "$PID_FILE"

cleanup_pid() { rm -f "$PID_FILE"; }
trap 'cleanup_pid; log "退出"; exit 0' EXIT INT TERM

# ---------- 清理残留临时文件 ----------
find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'dl.*' -o -name 'hd.*' \) -mmin +1 -delete 2>/dev/null

# ---------- 主流程 ----------
count=0
preloaded_img=""
current_img=""

log "启动壁纸切换工具, 间隔 ${INTERVAL}s, 保留 ${KEEP_COUNT} 张, 最大重试 ${MAX_RETRY}, 哈希上限 ${MAX_HASH}, API=${API_URL}, PID=$$"

if fetch_unique_wallpaper; then
    current_img="$RESULT_PATH"
    set_wallpaper "$current_img"
    [ -n "$current_img" ] && echo "$current_img" > "$CURRENT_FILE"
else
    log "首次下载失败，等待下一轮"
fi

next_at=$(( $(date +%s) + INTERVAL ))

log "预加载下一张壁纸..."
if fetch_unique_wallpaper; then
    preloaded_img="$RESULT_PATH"
    log "预加载完成: $(basename "$preloaded_img")"
else
    preloaded_img=""
    log "预加载失败，下次切换时现场下载"
fi

while true; do
    now=$(date +%s)
    remaining=$(( next_at - now ))
    if [ "$remaining" -gt 0 ]; then
        sleep "$remaining"
    fi

    if [ -n "$preloaded_img" ] && [ -f "$preloaded_img" ]; then
        current_img="$preloaded_img"
        if set_wallpaper "$current_img"; then
            echo "$current_img" > "$CURRENT_FILE"
            count=$((count + 1))
            [ $((count % 3)) -eq 0 ] && cleanup_old
        fi
    elif fetch_unique_wallpaper; then
        current_img="$RESULT_PATH"
        if set_wallpaper "$current_img"; then
            echo "$current_img" > "$CURRENT_FILE"
            count=$((count + 1))
            [ $((count % 3)) -eq 0 ] && cleanup_old
        fi
    else
        log "本次切换失败：下载不到图片，保持当前壁纸"
    fi

    log "预加载下一张壁纸..."
    if fetch_unique_wallpaper; then
        preloaded_img="$RESULT_PATH"
        log "预加载完成: $(basename "$preloaded_img")"
    else
        preloaded_img=""
        log "预加载失败，下次切换时现场下载"
    fi

    next_at=$(( next_at + INTERVAL ))
    now=$(date +%s)
    if [ "$next_at" -le "$now" ]; then
        log "预加载耗时超过间隔，重置调度基准"
        next_at=$(( now + INTERVAL ))
    fi
done
