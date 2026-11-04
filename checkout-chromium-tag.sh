#!/usr/bin/env bash
# checkout-chromium-tag.sh
# 按指定 Chromium 发布标签检出「完整可编译」源码树（同步 DEPS + runhooks），不编译。
#
# 用法:
#   ./checkout-chromium-tag.sh <tag> [输出目录]
#
# 示例:
#   ./checkout-chromium-tag.sh 154.0.8037.57
#   ./checkout-chromium-tag.sh 154.0.8037.57 ~/src/chromium-154
#
# 环境变量（可选）:
#   DEPOT_TOOLS_DIR   depot_tools 路径（默认: <输出目录的父目录>/depot_tools 或 $HOME/depot_tools）
#   JOBS              gclient 并行数（默认: 8）
#   FULL_HISTORY=1    拉完整 git 历史（默认关闭；完整历史仅 src 就可能接近 90GB）
#   SKIP_HOOKS=1      跳过 gclient runhooks（默认会跑，以便树达到可编译准备状态）
#   MIN_FREE_GB       开始前要求的最小剩余磁盘 GB（默认: 40）
#
# 说明:
#   - 默认使用 gclient --no-history，按标签浅检出，体积约为完整历史的几分之一，
#     仍同步全部 DEPS，跑 hooks 后可直接 gn/ninja（本脚本不执行编译）。
#   - 需要能访问 https://chromium.googlesource.com/
#   - 依赖: bash, git, python3, curl

set -euo pipefail

TAG="${1:-}"
OUT_DIR="${2:-}"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ -n "$TAG" ]] || usage 1
[[ "$TAG" != "-h" && "$TAG" != "--help" ]] || usage 0

if [[ ! "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误: 标签格式应为 X.Y.Z.W，例如 154.0.8037.57（收到: $TAG）" >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(pwd)/chromium-${TAG}"
fi
OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
PARENT_DIR="$(dirname "$OUT_DIR")"
JOBS="${JOBS:-8}"
MIN_FREE_GB="${MIN_FREE_GB:-40}"
REF="refs/tags/${TAG}"
SRC_URL="https://chromium.googlesource.com/chromium/src.git@${REF}"
LOG="${OUT_DIR}/checkout.log"
STATUS="${OUT_DIR}/CHECKOUT_STATUS.txt"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { log "错误: $*"; exit 1; }

# --- depot_tools ---
resolve_depot_tools() {
  if [[ -n "${DEPOT_TOOLS_DIR:-}" ]]; then
    printf '%s\n' "$DEPOT_TOOLS_DIR"
    return
  fi
  for candidate in "${PARENT_DIR}/depot_tools" "${HOME}/depot_tools" "$(pwd)/depot_tools"; do
    if [[ -x "${candidate}/gclient" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "${PARENT_DIR}/depot_tools"
}

DEPOT_TOOLS_DIR="$(resolve_depot_tools)"
mkdir -p "$OUT_DIR"
: >"$LOG"

log "=== Chromium 标签检出 ==="
log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "标签: $TAG"
log "输出: $OUT_DIR"
log "depot_tools: $DEPOT_TOOLS_DIR"
log "历史: $([[ "${FULL_HISTORY:-0}" == "1" ]] && echo 完整 || echo 无历史浅检出)"
log ""

# --- 磁盘检查 ---
avail_gb="$(df -BG --output=avail "$OUT_DIR" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
if [[ -n "$avail_gb" ]]; then
  log "可用磁盘: ${avail_gb}G（要求至少 ${MIN_FREE_GB}G）"
  if (( avail_gb < MIN_FREE_GB )); then
    die "磁盘不足：可用 ${avail_gb}G < ${MIN_FREE_GB}G。可调低 MIN_FREE_GB=… 强制继续（有风险）。"
  fi
fi

# --- 安装 / 更新 depot_tools ---
if [[ ! -x "${DEPOT_TOOLS_DIR}/gclient" ]]; then
  log ">>> 克隆 depot_tools …"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
  log ">>> 更新 depot_tools …"
  git -C "$DEPOT_TOOLS_DIR" pull --ff-only || log "警告: depot_tools git pull 失败，继续使用现有版本"
fi
export PATH="${DEPOT_TOOLS_DIR}:${PATH}"
command -v gclient >/dev/null || die "找不到 gclient，请检查 DEPOT_TOOLS_DIR=$DEPOT_TOOLS_DIR"
command -v python3 >/dev/null || die "需要 python3"

# --- 写入 .gclient（标签钉扎）---
if [[ -e "${OUT_DIR}/src/.git" && -f "${OUT_DIR}/.gclient" ]]; then
  log ">>> 检测到已有检出，将按标签重新 sync …"
else
  if [[ -e "${OUT_DIR}/src" && ! -e "${OUT_DIR}/src/.git" ]]; then
    die "${OUT_DIR}/src 已存在但不是 git 仓库，请换目录或清掉后重试"
  fi
fi

cat >"${OUT_DIR}/.gclient" <<EOF
solutions = [
  {
    "name": "src",
    "url": "${SRC_URL}",
    "custom_deps": {},
    "custom_vars": {},
  },
]
EOF
log ">>> 已写入 .gclient -> ${SRC_URL}"

# --- sync ---
SYNC_FLAGS=(sync --nohooks --with_tags --with_branch_heads -D --jobs="${JOBS}" -r "src@${REF}")
if [[ "${FULL_HISTORY:-0}" != "1" ]]; then
  SYNC_FLAGS+=(--no-history)
fi

log ">>> gclient ${SYNC_FLAGS[*]}"
log "（大仓库拉取时 gclient 可能报 STALL DETECTED，若 git 仍在跑通常可忽略）"
(
  cd "$OUT_DIR"
  # 不把整个巨大输出全 tee 进内存；同步写日志
  gclient "${SYNC_FLAGS[@]}" 2>&1 | tee -a "$LOG"
)
log ">>> gclient sync 完成"

# --- hooks（可编译准备，不编译）---
if [[ "${SKIP_HOOKS:-0}" != "1" ]]; then
  log ">>> gclient runhooks"
  (
    cd "$OUT_DIR"
    gclient runhooks 2>&1 | tee -a "$LOG"
  )
  log ">>> runhooks 完成"
else
  log ">>> 已跳过 runhooks（SKIP_HOOKS=1）"
fi

# --- 校验 ---
[[ -d "${OUT_DIR}/src/.git" ]] || die "缺少 ${OUT_DIR}/src/.git"
HEAD="$(git -C "${OUT_DIR}/src" rev-parse HEAD)"
DESCRIBE="$(git -C "${OUT_DIR}/src" describe --tags --exact-match 2>/dev/null || true)"
if [[ "$DESCRIBE" != "$TAG" ]]; then
  # 浅检出有时 exact-match 仍可用；若失败再核对是否指向该 tag 对象
  TAG_SHA="$(git -C "${OUT_DIR}/src" rev-list -n 1 "$REF" 2>/dev/null || true)"
  if [[ -z "$TAG_SHA" || "$TAG_SHA" != "$HEAD" ]]; then
    die "标签校验失败: describe='$DESCRIBE' HEAD=$HEAD 期望=$TAG"
  fi
  log "警告: describe 未 exact-match，但 HEAD 与 ${REF} 一致 ($HEAD)"
fi

TREE_SIZE="$(du -sh "$OUT_DIR" 2>/dev/null | awk '{print $1}')"
SRC_SIZE="$(du -sh "${OUT_DIR}/src" 2>/dev/null | awk '{print $1}')"
DF_LINE="$(df -h "$OUT_DIR" | tail -1)"

cat >"$STATUS" <<EOF
Chromium checkout status
========================
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')
Result: SUCCESS

Location
--------
Root: $OUT_DIR
Src:  $OUT_DIR/src

Revision
--------
Tag:  $TAG
Ref:  $REF
HEAD: $HEAD
git describe --tags --exact-match: ${DESCRIBE:-"(n/a, HEAD matches tag object)"}

gclient
-------
.gclient url: $SRC_URL
sync: gclient ${SYNC_FLAGS[*]}
runhooks: $([[ "${SKIP_HOOKS:-0}" == "1" ]] && echo skipped || echo done)
compile: NOT run

Disk
----
Tree: $TREE_SIZE
Src:  $SRC_SIZE
df:   $DF_LINE

Notes
-----
- Default is --no-history (shallow) for space; set FULL_HISTORY=1 for full git history.
- This tree is meant to be buildable after hooks; gn/ninja were not invoked.
Log: $LOG
EOF

log ""
log "=== 成功 ==="
log "源码: $OUT_DIR/src"
log "标签: $TAG  ($HEAD)"
log "体积: $TREE_SIZE"
log "状态: $STATUS"
log "之后可自行: cd $OUT_DIR/src && gn gen out/Default && autoninja -C out/Default chrome"
