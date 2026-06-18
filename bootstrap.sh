#!/bin/bash
# ============================================================
#  开荒引导脚本 — 新机器一键配齐 chezmoi + age + 全套 dotfiles
#
#  用法:
#    在线首次 (一行命令):
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/luduihang/dotfiles/main/bootstrap.sh)"
#
#    离线 (已 clone 过仓库的环境，bin/ 里要有离线包):
#      bash bootstrap.sh --offline
#
#    本地执行:
#      bash bootstrap.sh
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

# ---- 解析参数 ----
OFFLINE=0
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *) error "未知参数: $arg (--help 查看用法)" ;;
    esac
done

# ---- 检测系统 ----
detect_os() {
    case "$(uname -s)" in
        Darwin)  echo "macos" ;;
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
# bootstrap.sh 自身就在源根
detect_script_dir() {
    local me="${BASH_SOURCE[0]:-$0}"
    local dir
    dir="$(cd "$(dirname "$me")" && pwd)"
    if [[ "$(basename "$me")" == "proxy-setup" ]]; then
        # proxy-setup 在 dot_local/bin/, 源是上一级的上一级
        (cd "$dir/../.." && pwd)
    else
        echo "$dir"
    fi
}
SCRIPT_DIR="${SCRIPT_DIR:-$(detect_script_dir)}"

# ---- 拼 bin/{name}-{os}-{arch} 路径 ----
# 用法: local_bin age              → $SCRIPT_DIR/bin/age-linux-amd64
#       local_bin chezmoi darwin arm64
local_bin() {
    local name="$1" os="${2:-$OS}" arch="${3:-$ARCH}"
    echo "$SCRIPT_DIR/bin/${name}-${os}-${arch}"
}

# ---- 安装 age ----
install_age() {
    if [ "$OFFLINE" = 1 ]; then
        src=$(local_bin age)
        if [ ! -f "$src" ]; then
            error_msg="[offline] 缺少 $src, 请先在线模式跑过一次把离线包放进 bin/"
            error "$error_msg"
        fi
        step "[offline] 从 $src 安装 age → /usr/local/bin/age"
        sudo install -m 0755 "$src" /usr/local/bin/age
    else
        if command -v age &>/dev/null; then
            step "age 已安装 ($(age --version 2>&1 | head -1))"
            return
        fi
        step "安装 age..."
        case "$OS" in
            macos) brew install age 2>/dev/null || error "brew install age 失败" ;;
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
    fi
    command -v age &>/dev/null || error "age 安装失败"
}

# ---- 安装 chezmoi ----
install_chezmoi() {
    if [ "$OFFLINE" = 1 ]; then
        src=$(local_bin chezmoi)
        if [ ! -f "$src" ]; then
            error_msg="[offline] 缺少 $src"
            error "$error_msg"
        fi
        step "[offline] 从 $src 安装 chezmoi → /usr/local/bin/chezmoi"
        sudo install -m 0755 "$src" /usr/local/bin/chezmoi
    else
        if command -v chezmoi &>/dev/null; then
            step "chezmoi 已安装 ($(chezmoi --version 2>&1 | head -1))"
            return
        fi
        step "安装 chezmoi..."
        case "$OS" in
            macos) brew install chezmoi 2>/dev/null || error "brew install chezmoi 失败" ;;
            # 注意: 中间的 -- 必须保留, 否则 -b /usr/local/bin 会被 sh -c 吞掉,
            # 装到 $HOME/bin/ 而不是 /usr/local/bin/
            linux) sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin ;;
        esac
    fi
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
    if [ "$OFFLINE" = 1 ]; then
        # 离线: 直接用本地 SCRIPT_DIR 当源, 不联网 clone
        step "[offline] 使用本地源 $SCRIPT_DIR (不联网 clone)"
        chezmoi init --source="$SCRIPT_DIR"
    else
        # 在线: clone 远端
        if [ -d ~/.local/share/chezmoi/.git ]; then
            step "chezmoi 仓库已存在，跳过 init..."
        else
            step "chezmoi init $DOTFILES_REPO (仅拉取，暂不应用)"
            chezmoi init "$DOTFILES_REPO"
        fi
    fi

    # 强制覆写 chezmoi.toml
    # 关键: 必须写 [source] dir, 否则上面 --source 设置会被覆写冲掉
    step "写 chezmoi.toml (含 [source] dir 持久化源路径)"
    mkdir -p ~/.config/chezmoi
    cat << EOF > ~/.config/chezmoi/chezmoi.toml
encryption = "age"

[age]
    identity = "${HOME}/.config/age/key.txt"
    recipient = "age126732mgceh7cdfevzdv6tg63h00y2tmk2gza7dwvfu0jaa930aqs4lrln3"

[source]
    dir = "${SCRIPT_DIR}"
EOF

    step "chezmoi apply..."
    chezmoi apply -v
}

# ---- 入口 ----
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Dotfiles 开荒引导脚本              ║"
echo "  ║  OS : $(uname -s) ($(uname -m))                         ║"
[ "$OFFLINE" = 1 ] && echo "  ║  模式: 离线 (使用本地 bin/)               ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

install_age
install_chezmoi
setup_age_key
apply_dotfiles

echo ""
echo "  ████████████████████████████████████████████"
echo "  ▎  开荒完成！                              ▎"
echo "  ▎  下次同步只需: csz                       ▎"
echo "  ▎  切换模型:      cc-switch deepseek       ▎"
echo "  ████████████████████████████████████████████"
echo ""
