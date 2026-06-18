#!/bin/bash
# ============================================================
#  开荒引导脚本 — 先搭代理，再在线装 age + chezmoi + dotfiles
#
#  用法:
#    在线首次 (一行命令):
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/luduihang/dotfiles/main/bootstrap.sh)"
#
#    离线 (已 clone 过仓库, bin/ 里有 mihomo):
#      bash bootstrap.sh
#
#  原理: 新机器唯一需要离线的是 mihomo 内核 + 明文 config。
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
        step "下载 mihomo (通过母鸡/代理)..."
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

# ---- 启动 mihomo ----
start_mihomo() {
    if [ -f "$MIHOMO_PID_FILE" ] && kill -0 "$(cat "$MIHOMO_PID_FILE")" 2>/dev/null; then
        step "mihomo 已在运行 (PID: $(cat "$MIHOMO_PID_FILE"))"
        return 0
    fi

    pkill -f "mihomo" 2>/dev/null || true
    sleep 0.5

    step "启动 mihomo (mixed-port: 7897)..."
    nohup "$MIHOMO_BIN" -f "$MIHOMO_CONFIG_DST" > "$MIHOMO_LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$MIHOMO_PID_FILE"

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        step "mihomo 启动成功 (PID: $pid)"
    else
        error "mihomo 启动失败，查看日志: $MIHOMO_LOG_FILE"
    fi
}

# ---- 检查代理连通性 ----
check_proxy() {
    step "检测代理连通性..."
    local http_code
    http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" --proxy "http://127.0.0.1:7897" "http://www.google.com" 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
        step "代理连通正常 (HTTP $http_code)"
    else
        warn "代理暂不可达 (HTTP $http_code)，继续尝试在线安装..."
    fi
}

# ---- 安装 age (纯在线) ----
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

# ---- 安装 chezmoi (纯在线) ----
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

# ---- 初始化并应用 dotfiles ----
apply_dotfiles() {
    if [ -d ~/.local/share/chezmoi/.git ]; then
        step "chezmoi 仓库已存在，跳过 init..."
    else
        # 如果 SCRIPT_DIR 和默认路径不同，用 SCRIPT_DIR
        if [ "$SCRIPT_DIR" != "$HOME/.local/share/chezmoi" ]; then
            step "chezmoi init --source=$SCRIPT_DIR"
            chezmoi init --source="$SCRIPT_DIR"
        else
            step "chezmoi init $DOTFILES_REPO (从远端 clone)"
            chezmoi init "$DOTFILES_REPO"
        fi
    fi

    step "chezmoi apply..."
    if [ "$SCRIPT_DIR" != "$HOME/.local/share/chezmoi" ]; then
        chezmoi apply --source="$SCRIPT_DIR" -v
    else
        chezmoi apply -v
    fi
}

# ---- 入口 ----
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Dotfiles 开荒引导脚本              ║"
echo "  ║  OS : $(uname -s) ($(uname -m))                         ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# 阶段 1: 搭代理 (唯一需要离线包的部分)
install_mihomo
copy_mihomo_config
start_mihomo
check_proxy

# 阶段 2: 代理通了，在线装 age 和 chezmoi
install_age
install_chezmoi

# 阶段 3: 配置密钥 + 部署 dotfiles
setup_age_key
apply_dotfiles

echo ""
echo "  ████████████████████████████████████████████"
echo "  ▎  开荒完成！                              ▎"
echo "  ▎  下次同步只需: czsync                    ▎"
echo "  ▎  切换模型:      cc-switch deepseek       ▎"
echo "  ████████████████████████████████████████████"
echo ""
