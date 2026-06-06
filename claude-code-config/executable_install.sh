#!/usr/bin/env bash
# ============================================================
# install.sh — Claude Code 跨设备配置部署/更新脚本
# 支持: Ubuntu (bash) / macOS (zsh)
# 用法:
#   ./install.sh          首次部署（完整安装）
#   ./install.sh --update 更新同步（仅合并配置和 skills）
#   cc-switch update       等效快捷命令
# 仓库: https://github.com/luduihang/claude-code-config
# ============================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 跨平台 sed -i 封装（macOS BSD sed vs Linux GNU sed）
_sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

MODE="install"  # install | update

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Claude Code 跨设备配置 — 一键部署                  ║${NC}"
echo -e "${BLUE}║   仓库: github.com/luduihang/claude-code-config      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
# 1. 检测 Shell 类型
# ============================================================
detect_shell() {
    # 优先检测用户的登录 shell（$SHELL），而非脚本运行时的 shell
    # 因为 install.sh 通过 #!/usr/bin/env bash 运行，$BASH_VERSION 永远为真
    case "$(basename "${SHELL:-}")" in
        zsh)
            RC_FILE="$HOME/.zshrc"
            SHELL_TYPE="zsh"
            ;;
        bash)
            RC_FILE="$HOME/.bashrc"
            SHELL_TYPE="bash"
            ;;
        *)
            # 回退：检测当前脚本运行环境
            if [ -n "$ZSH_VERSION" ]; then
                RC_FILE="$HOME/.zshrc"
                SHELL_TYPE="zsh"
            elif [ -n "$BASH_VERSION" ]; then
                RC_FILE="$HOME/.bashrc"
                SHELL_TYPE="bash"
            else
                RC_FILE="$HOME/.profile"
                SHELL_TYPE="unknown"
            fi
            ;;
    esac
    echo -e "检测到 Shell: ${CYAN}$SHELL_TYPE${NC} → RC 文件: ${CYAN}$RC_FILE${NC}"
}

# ============================================================
# 2. 确定仓库路径
# ============================================================
find_repo() {
    # 如果当前就在仓库目录中
    if [ -f "./cc-switch.sh" ] && [ -f "./models.conf" ]; then
        REPO_DIR="$(pwd)"
    # 如果在 ~/claude-code-config
    elif [ -f "$HOME/claude-code-config/cc-switch.sh" ]; then
        REPO_DIR="$HOME/claude-code-config"
    else
        echo -e "${RED}错误: 找不到 claude-code-config 仓库！${NC}"
        echo "请先克隆仓库:"
        echo "  git clone git@github.com:luduihang/claude-code-config.git ~/claude-code-config"
        echo "  cd ~/claude-code-config && ./install.sh"
        exit 1
    fi
    echo -e "仓库路径: ${CYAN}$REPO_DIR${NC}"
}

# ============================================================
# 3. 创建目录结构
# ============================================================
create_dirs() {
    echo ""
    echo -e "${BLUE}--- 创建目录结构 ---${NC}"

    mkdir -p "$HOME/.claude/secrets/mcp"
    echo -e "  ✅ $HOME/.claude/secrets/"
    echo -e "  ✅ $HOME/.claude/secrets/mcp/"

    # 确保 rc 文件存在
    touch "$RC_FILE"
    echo -e "  ✅ $RC_FILE (已确保存在)"
}

# ============================================================
# 4. 安装 cc-switch (写入 rc 文件)
# ============================================================
install_cc_switch() {
    echo ""
    echo -e "${BLUE}--- 安装 cc-switch ---${NC}"

    local SOURCE_LINE="source $REPO_DIR/cc-switch.sh"
    local RESTORE_LINE="source $HOME/.claude_code_env 2>/dev/null"

    # 移除旧的 cc-switch 引用（如果存在）
    if grep -q "cc-switch" "$RC_FILE" 2>/dev/null; then
        _sed_inplace '/cc-switch/d' "$RC_FILE"
        _sed_inplace '/claude_code_env/d' "$RC_FILE"
        echo -e "  ${YELLOW}已移除旧的 cc-switch 引用${NC}"
    fi

    # 写入新的 source 行
    {
        echo ""
        echo "# >>> Claude Code cc-switch (自动添加于 $(date))"
        echo "$SOURCE_LINE"
        echo "$RESTORE_LINE"
        echo "# <<< Claude Code cc-switch"
    } >> "$RC_FILE"

    echo -e "  ✅ 已写入 $RC_FILE"
    echo -e "     ${CYAN}$SOURCE_LINE${NC}"
    echo -e "     ${CYAN}$RESTORE_LINE${NC}"
}

# ============================================================
# 5. 合并 settings.json
# ============================================================
merge_settings() {
    echo ""
    echo -e "${BLUE}--- 合并 Claude Code 设置 ---${NC}"

    local SHARED_SETTINGS="$REPO_DIR/claude-settings.json"
    local LOCAL_SETTINGS="$HOME/.claude/settings.json"

    if [ ! -f "$SHARED_SETTINGS" ]; then
        echo -e "  ${YELLOW}跳过: $SHARED_SETTINGS 不存在${NC}"
        return
    fi

    # 备份现有设置
    if [ -f "$LOCAL_SETTINGS" ]; then
        cp "$LOCAL_SETTINGS" "$LOCAL_SETTINGS.backup.$(date +%s)"
        echo -e "  ✅ 已备份现有 settings.json"
    fi

    # 如果 jq 可用，用 jq 合并（保留本地 env 块）
    if command -v jq &>/dev/null; then
        # 读取共享设置，但保留本地 env 块
        if [ -f "$LOCAL_SETTINGS" ]; then
            local LOCAL_ENV
            LOCAL_ENV=$(jq '.env // {}' "$LOCAL_SETTINGS" 2>/dev/null || echo "{}")
            jq --argjson env "$LOCAL_ENV" '. + {env: $env}' "$SHARED_SETTINGS" > "${LOCAL_SETTINGS}.tmp" 2>/dev/null && \
            mv "${LOCAL_SETTINGS}.tmp" "$LOCAL_SETTINGS"
            echo -e "  ✅ 已合并设置 (保留 env 块)"
        else
            mkdir -p "$(dirname "$LOCAL_SETTINGS")"
            jq '. + {env: {}}' "$SHARED_SETTINGS" > "$LOCAL_SETTINGS"
            echo -e "  ✅ 已创建新 settings.json"
        fi

        # 解析 ${SECRETS:...} 占位符
        resolve_secrets_placeholders "$LOCAL_SETTINGS"
    else
        echo -e "  ${YELLOW}警告: jq 未安装，使用 cp 复制${NC}"
        echo -e "  ${YELLOW}安装 jq 以启用智能合并: sudo apt install jq${NC}"
        [ -f "$LOCAL_SETTINGS" ] && cp "$LOCAL_SETTINGS" "$LOCAL_SETTINGS.backup.$(date +%s)"
        mkdir -p "$(dirname "$LOCAL_SETTINGS")"
        cp "$SHARED_SETTINGS" "$LOCAL_SETTINGS"
        echo -e "  ✅ 已复制共享设置"
    fi
}

# 解析 settings.json 中的 ${SECRETS:<path>:<var>} 占位符
resolve_secrets_placeholders() {
    local settings_file="$1"
    [ ! -f "$settings_file" ] && return

    local content
    content=$(cat "$settings_file")

    # 查找所有 ${SECRETS:...} 占位符
    local placeholders
    placeholders=$(echo "$content" | command -p grep -o '\${SECRETS:[^}]*}' 2>/dev/null || true)

    if [ -z "$placeholders" ]; then
        echo -e "  ${CYAN}(无 MCP 密钥占位符需要解析)${NC}"
        return
    fi

    echo -e "  ${YELLOW}检测到 MCP 密钥占位符:${NC}"

    while IFS= read -r placeholder; do
        [ -z "$placeholder" ] && continue
        # 解析 ${SECRETS:path:var}
        local inner="${placeholder#\${SECRETS:}"
        inner="${inner%\}}"
        local secret_path="${inner%%:*}"
        local var_name="${inner##*:}"

        echo -e "    → $secret_path → \$$var_name"

        local full_path="$HOME/.claude/secrets/$secret_path"
        if [ -f "$full_path" ]; then
            source "$full_path" 2>/dev/null || true
            local actual_value="${!var_name}"
            if [ -n "$actual_value" ]; then
                # 用 jq 替换占位符
                jq --arg val "$actual_value" --arg placeholder "$placeholder" \
                    'walk(if type == "string" then gsub($placeholder; $val) else . end)' \
                    "$settings_file" > "${settings_file}.tmp" 2>/dev/null && \
                    mv "${settings_file}.tmp" "$settings_file"
                echo -e "      ${GREEN}✅ 已填充${NC}"
            else
                echo -e "      ${RED}⚠ 变量 $var_name 在 $secret_path 中为空${NC}"
            fi
        else
            echo -e "      ${RED}⚠ 密钥文件不存在: $full_path${NC}"
            echo -e "      ${YELLOW}  请创建该文件并重新运行 install.sh${NC}"
        fi
    done <<< "$placeholders"
}

# ============================================================
# 6. 初始化 .claude.json（绕过 OAuth 登录）
# ============================================================
init_claude_json() {
    echo ""
    echo -e "${BLUE}--- 初始化 Claude Code 配置 ---${NC}"

    local CLAUDE_JSON="$HOME/.claude.json"

    if [ ! -f "$CLAUDE_JSON" ]; then
        echo '{"hasCompletedOnboarding": true}' > "$CLAUDE_JSON"
        echo -e "  ✅ 已创建 ~/.claude.json (hasCompletedOnboarding: true)"
    else
        if command -v jq &>/dev/null; then
            if ! jq -e '.hasCompletedOnboarding' "$CLAUDE_JSON" >/dev/null 2>&1; then
                jq '. + {"hasCompletedOnboarding": true}' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
                echo -e "  ✅ 已 patch ~/.claude.json (hasCompletedOnboarding: true)"
            else
                echo -e "  ✅ ~/.claude.json 已包含 onboarding 标记"
            fi
        else
            if ! grep -q "hasCompletedOnboarding" "$CLAUDE_JSON"; then
            _sed_inplace 's/{/{\n  "hasCompletedOnboarding": true,/' "$CLAUDE_JSON"
                echo -e "  ✅ 已 patch ~/.claude.json (hasCompletedOnboarding: true)"
            else
                echo -e "  ✅ ~/.claude.json 已包含 onboarding 标记"
            fi
        fi
    fi
}

# ============================================================
# 7. 安装 Skills
# ============================================================
install_skills() {
    echo ""
    echo -e "${BLUE}--- 安装 Skills ---${NC}"

    local SKILLS_SRC="$REPO_DIR/skills"

    if [ ! -d "$SKILLS_SRC" ]; then
        echo -e "  ${YELLOW}跳过: skills/ 目录不存在${NC}"
        return
    fi

    local skill_count
    skill_count=$(find "$SKILLS_SRC" -name "*.md" -type f 2>/dev/null | wc -l)

    if [ "$skill_count" -eq 0 ]; then
        echo -e "  ${CYAN}skills/ 目录为空，跳过${NC}"
        return
    fi

    # Claude Code 的 skills 目录（根据文档，skills 通过插件系统管理）
    # 自定义 skills 可以放在 ~/.claude/skills/ 或在 settings 中引用
    local SKILLS_DEST="$HOME/.claude/skills"
    mkdir -p "$SKILLS_DEST"

    # 使用进程替换避免管道子 shell（确保 cp 在主 shell 执行）
    local installed=0
    while IFS= read -r skill; do
        [ -z "$skill" ] && continue
        local basename
        basename=$(basename "$skill")
        cp "$skill" "$SKILLS_DEST/$basename"
        echo -e "  ✅ $basename"
        installed=$((installed + 1))
    done < <(find "$SKILLS_SRC" -name "*.md" -type f 2>/dev/null)

    if [ "$installed" -gt 0 ]; then
        echo -e "  ${GREEN}已安装 $installed 个 Skills 到 $SKILLS_DEST/${NC}"
    else
        echo -e "  ${CYAN}skills/ 目录为空，跳过${NC}"
    fi
}

# ============================================================
# 8. 引导密钥配置
# ============================================================
setup_secrets() {
    echo ""
    echo -e "${BLUE}--- 密钥配置 ---${NC}"

    # 从 models.conf 读取需要的密钥文件
    local secrets_needed
    secrets_needed=$(_get_all_secret_files)

    for sf in $secrets_needed; do
        local secret_path="$HOME/.claude/secrets/$sf"
        if [ -f "$secret_path" ]; then
            echo -e "  ✅ $sf ${GREEN}(已存在)${NC}"
        else
            echo -e "  ${YELLOW}⚠ $sf 不存在，创建模板...${NC}"

            # 判断 auth_type
            local auth_type
            auth_type=$(grep -A 10 "secret_file=$sf" "$REPO_DIR/models.conf" 2>/dev/null | grep "auth_type=" | head -1 | cut -d= -f2)

            case "$auth_type" in
                api_key)
                    echo "# $sf — API Key 认证" > "$secret_path"
                    echo "ANTHROPIC_API_KEY=请填入你的API密钥" >> "$secret_path"
                    ;;
                auth_token)
                    echo "# $sf — Auth Token 认证" > "$secret_path"
                    echo "ANTHROPIC_AUTH_TOKEN=请填入你的API密钥" >> "$secret_path"
                    ;;
                *)
                    echo "# $sf" > "$secret_path"
                    echo "# 请根据供应商要求填入认证信息" >> "$secret_path"
                    ;;
            esac
            chmod 600 "$secret_path"
            echo -e "     ${CYAN}已创建模板: $secret_path${NC}"
            echo -e "     ${YELLOW}请编辑此文件填入真实密钥后重新运行 install.sh${NC}"
        fi
    done
}

# 从 models.conf 和 models.local.conf 读取所有 secret_file
_get_all_secret_files() {
    {
        [ -f "$REPO_DIR/models.conf" ] && grep "secret_file=" "$REPO_DIR/models.conf" | cut -d= -f2
        [ -f "$HOME/.claude/secrets/models.local.conf" ] && grep "secret_file=" "$HOME/.claude/secrets/models.local.conf" | cut -d= -f2
    } | sort -u
}

# ============================================================
# 9. 检查系统依赖
# ============================================================
check_deps() {
    echo ""
    echo -e "${BLUE}--- 检查依赖 ---${NC}"

    local missing=()

    command -v git &>/dev/null || missing+=("git")
    command -v curl &>/dev/null || missing+=("curl")

    if command -v jq &>/dev/null; then
        echo -e "  ✅ git, curl, jq ${GREEN}(完整)${NC}"
    else
        echo -e "  ⚠ jq 未安装"
        echo -e "    Ubuntu: ${CYAN}sudo apt install jq${NC}"
        echo -e "    Mac:    ${CYAN}brew install jq${NC}"
        echo -e "  ${YELLOW}jq 用于 MCP 密钥占位符解析，非必需${NC}"
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}缺少依赖: ${missing[*]}${NC}"
        echo "请先安装后再运行 install.sh"
        exit 1
    fi
}

# ============================================================
# 10. 完成
# ============================================================
finish() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ 部署完成！                                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "接下来请执行:"
    echo -e "  ${CYAN}source $RC_FILE${NC}"
    echo ""
    echo -e "然后测试:"
    echo -e "  ${CYAN}cc-switch list${NC}          # 查看可用渠道"
    echo -e "  ${CYAN}cc-switch ds-pro${NC}        # 切换到 DeepSeek"
    echo -e "  ${CYAN}cc-switch test${NC}          # 测试 API 连通性"
    echo ""
    echo -e "${YELLOW}⚠ 请确保已配置密钥文件:${NC}"
    local secrets_needed
    secrets_needed=$(_get_all_secret_files)
    for sf in $secrets_needed; do
        if [ -f "$HOME/.claude/secrets/$sf" ]; then
            if grep -q "请填入" "$HOME/.claude/secrets/$sf" 2>/dev/null; then
                echo -e "  ${RED}✗ $sf (待填写密钥)${NC}"
            else
                echo -e "  ${GREEN}✓ $sf${NC}"
            fi
        fi
    done
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    # 解析参数
    case "${1:-}" in
        --update|-u)
            MODE="update"
            ;;
        --help|-h)
            echo "用法: ./install.sh [--update]"
            echo "  (无参数)    首次部署，完整安装"
            echo "  --update    更新同步，仅合并配置+skills，不动 shell rc"
            exit 0
            ;;
    esac

    detect_shell
    find_repo

    if [ "$MODE" = "update" ]; then
        echo -e "${BLUE}模式: 更新同步${NC}"
        echo ""

        # 拉取最新
        echo -e "${BLUE}--- 拉取最新仓库 ---${NC}"
        cd "$REPO_DIR"
        git pull 2>/dev/null && echo -e "  ✅ git pull 完成" || echo -e "  ${YELLOW}⚠ git pull 失败，使用本地版本${NC}"

        merge_settings
        init_claude_json
        install_skills

        echo ""
        echo -e "${GREEN}✅ 更新完成！${NC}"
        echo -e "新终端或 source ~/.bashrc 后生效。"
        return 0
    fi

    # --- 完整安装模式 ---
    check_deps
    create_dirs
    install_cc_switch
    merge_settings
    init_claude_json
    install_skills
    setup_secrets
    finish
}

main "$@"
