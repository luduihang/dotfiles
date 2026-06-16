#!/bin/bash
# ============================================================
#  开荒引导脚本 — 新机器一键配齐 chezmoi + age + 全套 dotfiles
#
#  用法（一行命令）:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/luduihang/dotfiles/main/bootstrap.sh)"
#
#  或者本地执行:
#    bash bootstrap.sh
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
        Darwin)  echo "macos" ;;
        Linux)   echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}
OS=$(detect_os)

# ---- 安装 age ----
install_age() {
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
        macos) brew install chezmoi 2>/dev/null || error "brew install chezmoi 失败" ;;
        linux) sudo sh -c "$(curl -fsLS get.chezmoi.io)" -b /usr/local/bin ;;
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
    # 第一步：clone 仓库（只拉取，不 apply）
    if [ -d ~/.local/share/chezmoi/.git ]; then
        step "chezmoi 仓库已存在，跳过 init..."
    else
        step "chezmoi init $DOTFILES_REPO (仅拉取，暂不应用)"
        chezmoi init "$DOTFILES_REPO"
    fi

    # 第二步：不信任模板，强制覆写本地配置
    # 这是关键：跳过 .chezmoi.toml.tmpl 的模板解析，直接用 ${HOME} 动态拼路径
    step "强制覆写 chezmoi.toml (绕过模板解析)"
    mkdir -p ~/.config/chezmoi
    cat << EOF > ~/.config/chezmoi/chezmoi.toml
encryption = "age"

[age]
    identity = "${HOME}/.config/age/key.txt"
    recipient = "age126732mgceh7cdfevzdv6tg63h00y2tmk2gza7dwvfu0jaa930aqs4lrln3"
EOF

    # 第三步：带着确定正确的配置执行 apply
    step "chezmoi apply..."
    chezmoi apply -v
}

# ---- 入口 ----
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Dotfiles 开荒引导脚本              ║"
echo "  ║  OS : $(uname -s) ($(uname -m))                         ║"
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
