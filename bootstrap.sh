#!/bin/bash
# ==========================================
# 极客透明开荒引导脚本 (仅需在新服务器手动执行一次)
# ==========================================

set -e # 遇到错误立即停止，方便你排查

echo "🚀 [1/4] 开始检查并安装基础依赖 (age / chezmoi)..."

# 1. 透明安装 age
if ! command -v age &> /dev/null; then
    echo "📦 检测到未安装 age，正在通过 apt 安装..."
    sudo apt-get update -y && sudo apt-get install -y age
else
    echo "✅ age 已安装"
fi

# 2. 透明全局安装 chezmoi (装到 /usr/local/bin，避免路径找不到)
if ! command -v chezmoi &> /dev/null; then
    echo "📦 检测到未安装 chezmoi，正在拉取..."
    sudo sh -c "$(curl -fsLS get.chezmoi.io)" -b /usr/local/bin
else
    echo "✅ chezmoi 已安装"
fi

echo "🔑 [2/4] 配置解密环境..."
mkdir -p ~/.config/age

# 3. 交互式索要私钥（直接在终端输，不写死在任何文件里）
if [ ! -f ~/.config/age/key.txt ]; then
    read -r -p "请输入你的 AGE-SECRET-KEY (以 AGE-SECRET-KEY- 开头): " AGE_KEY
    echo "$AGE_KEY" > ~/.config/age/key.txt
    chmod 600 ~/.config/age/key.txt
    echo "✅ 密钥已安全写入 ~/.config/age/key.txt"
else
    echo "✅ 密钥文件已存在，跳过配置"
fi

echo "⚙️ [3/4] 动态生成自适应绝对路径配置..."
mkdir -p ~/.config/chezmoi
cat << EOF > ~/.config/chezmoi/chezmoi.toml
encryption = "age"

[age]
    identity = "${HOME}/.config/age/key.txt"
    recipient = "age126732mgceh7cdfevzdv6tg63h00y2tmk2gza7dwvfu0jaa930aqs4lrln3"
EOF
echo "✅ chezmoi.toml 已生成 (路径: $HOME)"

echo "🎉 [4/4] 引导完成！系统环境已对齐。"
echo "👉 请在终端手动执行: chezmoi apply -v"
