#!/bin/bash
# ============================================================
#  开荒引导脚本 — 先搭代理，再在线装 age + chezmoi + dotfiles
#
#  用法:
#    一行命令:
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/luduihang/dotfiles/main/bootstrap.sh)"
#
#    本地:
#      bash bootstrap.sh
#
#  原理: 新机器唯一离线依赖是 mihomo 内核 + 明文 config (放 bin/)。
#        代理一通，age/chezmoi 都能在线装。
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
DOTFILES_REPO="luduihang/dotfiles"

step()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC} $*"; exit 1; }
info()  { echo -e "   $*"; }

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) error "未知参数: $arg (--help 查看用法)" ;;
    esac
done

# ---- 检测系统 ----
detect_os() {
    case "$(uname -s)" in
        Darwin)  echo "darwin" ;;
        Linux)   echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}
OS=$(detect_os)

detect_arch() {
    case "$(uname -m)" in
        x86_64)         echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "$(uname -m)" ;;
    esac
}
ARCH=$(detect_arch)

# ---- 检测 SCRIPT_DIR (chezmoi 源目录) ----
detect_script_dir() {
    local me="${BASH_SOURCE[0]:-$0}"
    local dir
    dir="$(cd "$(dirname "$me")" && pwd)"
    echo "$dir"
}
SCRIPT_DIR="${SCRIPT_DIR:-$(detect_script_dir)}"

# ---- 确保基础工具 (精简系统可能缺 curl/unzip/sudo) ----
ensure_base() {
    # 只 Linux 需要补这些
    [ "$OS" = "darwin" ] && return
    for tool in curl unzip sudo; do
        command -v "$tool" &>/dev/null && continue
        apt-get update -y 2>/dev/null
        apt-get install -y "$tool" 2>/dev/null || true
    done
}

# ---- mihomo 路径 ----
MIHOMO_DIR="$HOME/.local/bin"
MIHOMO_BIN="$MIHOMO_DIR/mihomo"
MIHOMO_CONFIG_SRC="$SCRIPT_DIR/dot_config/mihomo/config.yaml"
MIHOMO_CONFIG_DST="$HOME/.config/mihomo/config.yaml"
MIHOMO_PID_FILE="$HOME/.config/mihomo/mihomo.pid"
MIHOMO_LOG_FILE="$HOME/.config/mihomo/mihomo.log"

# ---- 安装 mihomo (优先本地 bin/, 否则下载) ----
install_mihomo() {
    if [ -x "$MIHOMO_BIN" ]; then
        step "mihomo 已存在: $MIHOMO_BIN"
        return 0
    fi

    local local_src="$SCRIPT_DIR/bin/mihomo-${OS}-${ARCH}"
    if [ -f "$local_src" ]; then
        step "从本地 $local_src 安装 mihomo"
        mkdir -p "$MIHOMO_DIR"
        install -m 0755 "$local_src" "$MIHOMO_BIN"
    else
        step "下载 mihomo..."
        local url="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.6/mihomo-${OS}-${ARCH}-v1.19.6.gz"
        mkdir -p "$MIHOMO_DIR"
        curl -fSL --progress-bar -o "${MIHOMO_BIN}.gz" "$url" || \
            error "下载 mihomo 失败: $url"
        gunzip -f "${MIHOMO_BIN}.gz"
        chmod +x "$MIHOMO_BIN"
    fi
    step "mihomo 安装完成: $MIHOMO_BIN"
}

# ---- 部署 mihomo 配置 (明文, 不需要 age 解密) ----
copy_mihomo_config() {
    if [ -f "$MIHOMO_CONFIG_DST" ]; then
        step "mihomo 配置已存在: $MIHOMO_CONFIG_DST"
        return 0
    fi
    if [ ! -f "$MIHOMO_CONFIG_SRC" ]; then
        error "mihomo 配置源文件不存在: $MIHOMO_CONFIG_SRC"
    fi
    step "部署 mihomo 配置 (明文)"
    mkdir -p "$(dirname "$MIHOMO_CONFIG_DST")"
    cp "$MIHOMO_CONFIG_SRC" "$MIHOMO_CONFIG_DST"
    chmod 600 "$MIHOMO_CONFIG_DST"
}

# ---- 检测桌面环境 ----
has_desktop() {
    [ -f /.dockerenv ] && return 1   # 容器不算桌面
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# ---- 启动 mihomo ----
start_mihomo() {
    # 直接 curl 测端口，不依赖 ss/netstat/lsof（精简 Docker 镜像都没有）
    if curl -s --max-time 1 -o /dev/null --proxy "http://127.0.0.1:7897" "http://127.0.0.1:7897" 2>/dev/null; then
        step "mihomo 已在运行 (端口 7897 可连通)"
        return 0
    fi

    # 端口不通，清理残留后重启
    pkill -f "mihomo" 2>/dev/null || true
    sleep 0.5

    step "启动 mihomo (mixed-port: 7897)..."
    mkdir -p "$(dirname "$MIHOMO_LOG_FILE")"
    nohup "$MIHOMO_BIN" -f "$MIHOMO_CONFIG_DST" > "$MIHOMO_LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$MIHOMO_PID_FILE"

    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        step "mihomo 启动成功 (PID: $pid)"
    else
        error "mihomo 启动失败，查看日志: $MIHOMO_LOG_FILE"
    fi
}

# ---- 检查代理连通性 ----
check_proxy() {
    step "检测代理连通性 (VLess 握手约需 5-10 秒)..."
    local http_code
    for i in 1 2 3; do
        http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" --proxy "http://127.0.0.1:7897" "http://www.google.com" 2>/dev/null)
        http_code="${http_code:-000}"
        if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
            step "代理连通正常 (HTTP $http_code, 第 ${i} 次尝试)"
            return
        fi
        [ "$i" -lt 3 ] && sleep 3
    done
    warn "代理暂不可达 (HTTP $http_code)，继续尝试在线安装..."
}

# ---- 安装 age ----
install_age() {
    if command -v age &>/dev/null; then
        step "age 已安装 ($(age --version 2>&1 | head -1))"
        return
    fi
    step "安装 age..."
    case "$OS" in
        darwin) brew install age 2>/dev/null || error "brew install age 失败" ;;
        linux)
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -y && sudo apt-get install -y age
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y age
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm age
            else
                error "未检测到 apt/dnf/pacman，请手动安装 age"
            fi
            ;;
    esac
    command -v age &>/dev/null || error "age 安装失败"
}

# ---- 安装 chezmoi ----
install_chezmoi() {
    if command -v chezmoi &>/dev/null; then
        step "chezmoi 已安装 ($(chezmoi --version 2>&1 | head -1))"
        return
    fi
    step "安装 chezmoi..."
    case "$OS" in
        darwin) brew install chezmoi 2>/dev/null || error "brew install chezmoi 失败" ;;
        linux) sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin ;;
    esac
    command -v chezmoi &>/dev/null || error "chezmoi 安装失败"
}

# ---- 提示安装日常工具 (可选) ----
# nvim / yazi / zoxide 不在此脚本安装，保持 chezmoi 职责单一
# 需要时跑: ~/.local/bin/install-tools  或手动安装
maybe_install_tools_note() {
    if [ -x "$HOME/.local/bin/install-tools" ]; then
        step "可运行 ~/.local/bin/install-tools 安装 nvim + yazi + zoxide"
    fi
}

# ---- 配置 age 密钥 ----
setup_age_key() {
    mkdir -p ~/.config/age
    if [ -f ~/.config/age/key.txt ]; then
        step "age 密钥已存在 (~/.config/age/key.txt)"
        return
    fi
    step "请输入 AGE 私钥"
    echo ""
    echo "  ▎密钥格式: AGE-SECRET-KEY-1..."
    echo "  ▎密钥只存在你本地，不会上传到任何地方"
    echo ""
    read -r -p "AGE-SECRET-KEY: " AGE_KEY
    if [ -z "$AGE_KEY" ]; then
        warn "未输入密钥，跳过。稍后可手动放到 ~/.config/age/key.txt"
        return
    fi
    echo "$AGE_KEY" > ~/.config/age/key.txt
    chmod 600 ~/.config/age/key.txt
    step "密钥已写入 ~/.config/age/key.txt"
}

# ---- 修复 chezmoi 仓库 git 分支跟踪 ----
fix_git_branch() {
    local current_branch
    current_branch=$(chezmoi git -- branch --show-current 2>/dev/null || echo "")
    if [ -z "$current_branch" ]; then
        warn "无法检测 chezmoi 仓库当前分支，跳过分支修复"
        return
    fi

    # 已有 upstream 则跳过
    chezmoi git -- rev-parse --abbrev-ref '@{upstream}' &>/dev/null && return

    # 尝试设 upstream 到 origin/<当前分支>
    if chezmoi git -- branch --set-upstream-to="origin/$current_branch" 2>/dev/null; then
        step "分支跟踪已设置: $current_branch -> origin/$current_branch"
        return
    fi

    # origin/<当前分支> 不存在 (如旧 master → 新 main), 切到 main
    if chezmoi git -- fetch origin main 2>/dev/null; then
        step "远端无 origin/$current_branch，切换到 main"
        chezmoi git -- checkout -B main origin/main 2>/dev/null
        chezmoi git -- branch --set-upstream-to=origin/main main 2>/dev/null || true
    else
        warn "无法获取远端 origin/main，跳过分支修复（检查网络/SSH Key）"
    fi
}

# ---- 初始化并应用 dotfiles ----
apply_dotfiles() {
    step "chezmoi init..."
    local src_flag=""

    if [ -f "$SCRIPT_DIR/.chezmoi.toml.tmpl" ]; then
        # 本地: 从 SCRIPT_DIR 初始化, sourceDir 由模板固化到 config
        chezmoi init --source="$SCRIPT_DIR"
        src_flag="--source=$SCRIPT_DIR"
    elif [ -d "$HOME/.local/share/chezmoi/.git" ]; then
        chezmoi init
    else
        # oneliner / 全新: 从远端 clone 到默认路径
        chezmoi init "$DOTFILES_REPO"
    fi

    fix_git_branch

    step "chezmoi apply..."
    mkdir -p "$HOME/.local/share/chezmoi"
    chezmoi apply $src_flag -v
}

# ---- 入口 ----
ensure_base

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Dotfiles 开荒引导脚本              ║"
echo "  ║  OS : $(uname -s) ($(uname -m))                         ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# 阶段 1: 搭代理
install_mihomo
copy_mihomo_config

if has_desktop; then
    warn "检测到桌面环境 (DISPLAY/WAYLAND_DISPLAY)，跳过 mihomo 内核启动"
    warn "请使用桌面端 Clash Verge 来管理代理"
else
    start_mihomo
    check_proxy
    # 代理通了，设全局环境变量，后续 curl/wget 自动走代理
    export http_proxy="http://127.0.0.1:7897" https_proxy="http://127.0.0.1:7897" all_proxy="http://127.0.0.1:7897"
fi

# 阶段 2: 在线装 age + chezmoi
install_age
install_chezmoi

# 阶段 3: 配置密钥 + 部署 dotfiles
setup_age_key
apply_dotfiles

echo ""
echo "  ████████████████████████████████████████████"
echo "  ▎  开荒完成！                              ▎"
echo "  ▎  安装工具:      install-tools                       ▎"
echo "  ▎  切换模型:      cc-switch deepseek       ▎"
echo "  ████████████████████████████████████████████"
echo ""
