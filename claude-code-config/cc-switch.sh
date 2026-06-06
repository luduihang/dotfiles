#!/usr/bin/env bash
# ============================================================
# cc-switch.sh — Claude Code 渠道切换 Shell 函数
# 使用方式: 在 .bashrc/.zshrc 中 source 此文件
#           source /path/to/claude-code-config/cc-switch.sh
# 注意:    必须用 source 加载，不可直接执行
#          因为需要修改当前 shell 的环境变量
# 兼容:    bash (Linux) / zsh (macOS)
# ============================================================

# ---- 路径常量 ----
# 优先使用硬编码路径（避免 zsh 子 shell 丢失 source 上下文）
if [ -f "$HOME/claude-code-config/cc-switch.sh" ]; then
    SCRIPT_DIR="$HOME/claude-code-config"
else
    # 回退：动态检测（仅在非标准安装时使用）
    if [ -n "${BASH_SOURCE:-}" ]; then
        _detected="${BASH_SOURCE[0]}"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        _detected="${(%):-%x}"
    fi
    SCRIPT_DIR="$(cd "$(dirname "${_detected:-$HOME/claude-code-config}")" 2>/dev/null && pwd)"
fi

SECRETS_DIR="$HOME/.claude/secrets"
STATUS_FILE="$HOME/.claude_code_env"
CLAUDE_JSON="$HOME/.claude.json"
MODELS_CONF="$SCRIPT_DIR/models.conf"
MODELS_LOCAL_CONF="$SECRETS_DIR/models.local.conf"

# ---- 颜色 ----
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- 跨平台 sed -i 封装 ----
_sed_inplace() {
    case "$OSTYPE" in
        darwin*) sed -i '' "$@" ;;
        *)       sed -i "$@" ;;
    esac
}

# ---- 辅助: trim 首尾空白 (纯字符串操作，不依赖正则) ----
_trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ============================================================
# 配置解析 (纯 grep/tr/cut 实现，零正则依赖，bash/zsh 通用)
# ============================================================

# 从 INI 文件中提取指定 section 的所有键值对
# 用法: _parse_section <file> <section>
# 输出: key=value (一行一对，值已 trim)
_parse_section() {
    local file="$1"
    local target="$2"
    local found=0

    [ ! -f "$file" ] && return 1

    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释
        line="${line#"${line%%[![:space:]]*}"}"  # trim left
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        # 检测 section 标记
        case "$line" in
            \[*\])
                local sec
                sec=$(echo "$line" | tr -d '[]')
                if [ "$sec" = "$target" ]; then
                    found=1
                else
                    [ "$found" = 1 ] && return 0  # 下一个 section，退出
                fi
                continue
                ;;
        esac

        # 在目标 section 中，输出键值对
        if [ "$found" = 1 ]; then
            case "$line" in
                *=*)
                    echo "$line"
                    ;;
            esac
        fi
    done < "$file"
}

# 获取单个配置值
_get_config() {
    local file="$1"
    local section="$2"
    local key="$3"
    local val
    val=$(_parse_section "$file" "$section" | grep "^${key}=" | head -1 | cut -d= -f2-)
    _trim "$val"
}

# 列出所有 section 名称
_list_sections() {
    local file="$1"
    [ ! -f "$file" ] && return
    grep -o '^\[[^]]*\]' "$file" 2>/dev/null | tr -d '[]'
}

# 合并读取：本地覆盖优先
_get_config_merged() {
    local section="$1"
    local key="$2"
    local val

    # 先查本地覆盖
    val=$(_get_config "$MODELS_LOCAL_CONF" "$section" "$key")
    [ -n "$val" ] && { echo "$val"; return; }

    # 再查仓库配置
    _get_config "$MODELS_CONF" "$section" "$key"
}

# 检查 section 是否存在
_section_exists() {
    local section="$1"
    _list_sections "$MODELS_LOCAL_CONF" 2>/dev/null | grep -qx "$section" && return 0
    _list_sections "$MODELS_CONF" 2>/dev/null | grep -qx "$section" && return 0
    return 1
}

# ============================================================
# 辅助功能
# ============================================================

# Patch .claude.json 避免 OAuth 拦截
_patch_claude_json() {
    if [ ! -f "$CLAUDE_JSON" ]; then
        echo '{"hasCompletedOnboarding": true}' > "$CLAUDE_JSON"
    elif command -v jq &>/dev/null; then
        if ! jq -e '.hasCompletedOnboarding' "$CLAUDE_JSON" >/dev/null 2>&1; then
            jq '. + {"hasCompletedOnboarding": true}' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && \
                mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
        fi
    fi
}

# 列出所有可用供应商
_list_providers() {
    echo -e "${BLUE}=== 可用供应商 (models.conf) ===${NC}"
    echo ""
    local sections
    sections=$(_list_sections "$MODELS_CONF")
    for s in $sections; do
        local name model
        name=$(_get_config "$MODELS_CONF" "$s" "name")
        model=$(_get_config "$MODELS_CONF" "$s" "model")
        printf "  ${CYAN}%-15s${NC} → %-25s (model: %s)\n" "$s" "$name" "$model"
    done

    if [ -f "$MODELS_LOCAL_CONF" ]; then
        echo ""
        echo -e "${BLUE}=== 本地覆盖 (models.local.conf) ===${NC}"
        echo ""
        local local_sections
        local_sections=$(_list_sections "$MODELS_LOCAL_CONF")
        for s in $local_sections; do
            local name model
            name=$(_get_config "$MODELS_LOCAL_CONF" "$s" "name")
            model=$(_get_config "$MODELS_LOCAL_CONF" "$s" "model")
            printf "  ${CYAN}%-15s${NC} → %-25s (model: %s) ${YELLOW}[local]${NC}\n" "$s" "$name" "$model"
        done
    fi
    echo ""
}

# 解析 extra_env 并导出 (纯字符串操作，不依赖 BASH_REMATCH)
_apply_extra_env() {
    local extra_env="$1"
    [ -z "$extra_env" ] && return

    # 按逗号分隔
    local pairs saved_ifs
    saved_ifs="$IFS"
    IFS=','
    for pair in $extra_env; do
        case "$pair" in
            *=*)
                local k v
                k="${pair%%=*}"
                v="${pair#*=}"
                export "$k"="$v"
                ;;
        esac
    done
    IFS="$saved_ifs"
}

# 将 extra_env 对写入状态文件
_write_extra_env() {
    local extra_env="$1"
    [ -z "$extra_env" ] && return

    local pairs saved_ifs
    saved_ifs="$IFS"
    IFS=','
    for pair in $extra_env; do
        case "$pair" in
            *=*)
                local k v
                k="${pair%%=*}"
                v="${pair#*=}"
                echo "export $k=\"$v\""
                ;;
        esac
    done
    IFS="$saved_ifs"
}

# ============================================================
# 主函数: cc-switch
# ============================================================
cc-switch() {
    local provider="$1"

    # --- 无参数: 帮助 ---
    if [ -z "$provider" ]; then
        echo -e "${BLUE}Claude Code 渠道切换工具${NC}"
        echo "用法: cc-switch [选项]"
        echo ""
        echo "切换:"
        echo "  cc-switch <provider>    切换到指定供应商"
        echo ""
        echo "查看:"
        echo "  cc-switch list          列出所有可用供应商"
        echo "  cc-switch status        查看当前渠道和环境变量"
        echo ""
        echo "测试:"
        echo "  cc-switch test          测试当前 API 连通性"
        echo ""
        echo "同步:"
        echo "  cc-switch update        拉取最新仓库 + 合并配置 (一键同步)"
        echo ""
        echo -e "提示: 运行 ${YELLOW}cc-switch list${NC} 查看所有可用供应商"
        return 0
    fi

    # --- update: 同步仓库更新 ---
    if [ "$provider" = "update" ]; then
        echo -e "${BLUE}正在同步最新配置...${NC}"
        if [ -f "$SCRIPT_DIR/install.sh" ]; then
            bash "$SCRIPT_DIR/install.sh" --update
        else
            echo -e "${RED}错误: 找不到 install.sh${NC}"
            return 1
        fi
        # 重新 source cc-switch
        source "$SCRIPT_DIR/cc-switch.sh" 2>/dev/null || true
        echo -e "${GREEN}cc-switch 函数已重新加载${NC}"
        return 0
    fi

    # --- list: 列出供应商 ---
    if [ "$provider" = "list" ]; then
        _list_providers
        return 0
    fi

    # --- status: 查看当前状态 ---
    if [ "$provider" = "status" ]; then
        echo -e "${BLUE}=== 当前配置信息 ===${NC}"
        if [ -f "$STATUS_FILE" ]; then
            cat "$STATUS_FILE"
        else
            echo -e "${RED}尚未配置任何渠道。${NC}"
        fi
        echo ""
        echo -e "${BLUE}当前生效的环境变量:${NC}"
        echo "  ANTHROPIC_BASE_URL     = ${ANTHROPIC_BASE_URL:-未设置}"
        echo "  ANTHROPIC_MODEL        = ${ANTHROPIC_MODEL:-未设置}"
        echo "  ANTHROPIC_API_KEY      = ${ANTHROPIC_API_KEY:+已设置 (${#ANTHROPIC_API_KEY} 字符)}"
        echo "  ANTHROPIC_AUTH_TOKEN   = ${ANTHROPIC_AUTH_TOKEN:+已设置 (${#ANTHROPIC_AUTH_TOKEN} 字符)}"
        echo "  CLAUDE_CODE_SUBAGENT   = ${CLAUDE_CODE_SUBAGENT_MODEL:-未设置}"
        return 0
    fi

    # --- test: 连通性测试 ---
    if [ "$provider" = "test" ]; then
        echo -e "${BLUE}正在测试当前 API 连通性...${NC}"

        local REAL_KEY=""
        local KEY_TYPE=""
        local BASE_URL="${ANTHROPIC_BASE_URL}"
        local TEST_MODEL="${ANTHROPIC_MODEL}"

        if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            REAL_KEY="$ANTHROPIC_AUTH_TOKEN"
            KEY_TYPE="ANTHROPIC_AUTH_TOKEN"
        elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            REAL_KEY="$ANTHROPIC_API_KEY"
            KEY_TYPE="ANTHROPIC_API_KEY"
        else
            echo -e "${RED}错误: 未检测到 API 密钥。请先执行 cc-switch <provider>${NC}"
            return 1
        fi

        echo -e "鉴权类型: ${YELLOW}$KEY_TYPE${NC}"
        echo -e "目标端点: ${YELLOW}$BASE_URL${NC}"
        echo -e "测试模型: ${YELLOW}$TEST_MODEL${NC}"

        local RESPONSE HTTP_STATUS BODY REPLY_TEXT
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/v1/messages" \
          -H "content-type: application/json" \
          -H "x-api-key: $REAL_KEY" \
          -H "anthropic-version: 2023-06-01" \
          -d '{
            "model": "'"$TEST_MODEL"'",
            "max_tokens": 10,
            "messages": [{"role": "user", "content": "Say Ready."}]
          }' 2>&1)

        HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_STATUS" -eq 200 ]; then
            echo -e "${GREEN}✅ 连接成功！API 响应正常 (HTTP 200)${NC}"
            REPLY_TEXT=$(echo "$BODY" | command -p grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')
            [ -n "$REPLY_TEXT" ] && echo -e "模型回复: ${YELLOW}$REPLY_TEXT${NC}"
        else
            echo -e "${RED}❌ 测试失败！HTTP 状态码: $HTTP_STATUS${NC}"
            echo -e "报错详情: $BODY"
        fi
        return 0
    fi

    # --- 切换供应商 ---
    if ! _section_exists "$provider"; then
        echo -e "${RED}错误: 未知的供应商 '$provider'${NC}"
        echo -e "运行 ${YELLOW}cc-switch list${NC} 查看可用供应商"
        return 1
    fi

    # 读取配置（优先本地覆盖）
    local name base_url auth_type secret_file model
    local sonnet_model opus_model haiku_model subagent_model extra_env

    name=$(_get_config_merged "$provider" "name")
    base_url=$(_get_config_merged "$provider" "base_url")
    auth_type=$(_get_config_merged "$provider" "auth_type")
    secret_file=$(_get_config_merged "$provider" "secret_file")
    model=$(_get_config_merged "$provider" "model")
    sonnet_model=$(_get_config_merged "$provider" "sonnet_model")
    opus_model=$(_get_config_merged "$provider" "opus_model")
    haiku_model=$(_get_config_merged "$provider" "haiku_model")
    subagent_model=$(_get_config_merged "$provider" "subagent_model")
    extra_env=$(_get_config_merged "$provider" "extra_env")

    # 验证必要字段
    if [ -z "$base_url" ] || [ -z "$auth_type" ] || [ -z "$model" ]; then
        echo -e "${RED}错误: 供应商 '$provider' 配置不完整 (缺少 base_url/auth_type/model)${NC}"
        echo -e "${YELLOW}提示: 检查 $MODELS_CONF 中 [$provider] section 是否完整${NC}"
        return 1
    fi

    # 加载密钥文件
    local SECRET_FILE_PATH="$SECRETS_DIR/$secret_file"
    if [ -n "$secret_file" ] && [ -f "$SECRET_FILE_PATH" ]; then
        source "$SECRET_FILE_PATH"
    elif [ -n "$secret_file" ]; then
        echo -e "${RED}警告: 密钥文件不存在: $SECRET_FILE_PATH${NC}"
        echo -e "请创建该文件并填入对应的 API 密钥后重试。"
        echo -e "示例: echo 'ANTHROPIC_API_KEY=sk-xxx' > $SECRET_FILE_PATH"
    fi

    # 根据 auth_type 处理认证
    case "$auth_type" in
        api_key)
            unset ANTHROPIC_AUTH_TOKEN
            ;;
        auth_token)
            unset ANTHROPIC_API_KEY
            ;;
    esac

    # 设置通用环境变量
    export ANTHROPIC_BASE_URL="$base_url"
    export ANTHROPIC_MODEL="$model"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model:-$model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model:-$model}"
    [ -n "$opus_model" ] && export ANTHROPIC_DEFAULT_OPUS_MODEL="$opus_model"
    [ -n "$subagent_model" ] && export CLAUDE_CODE_SUBAGENT_MODEL="$subagent_model"

    # 处理额外环境变量
    _apply_extra_env "$extra_env"

    # Patch .claude.json
    _patch_claude_json

    # 写入状态文件（供新终端恢复）
    {
        echo "# Claude Code Current Provider: $name ($provider)"
        echo "# Generated by cc-switch at $(date)"
        echo "export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\""
        echo "export ANTHROPIC_MODEL=\"$ANTHROPIC_MODEL\""
        echo "export ANTHROPIC_DEFAULT_SONNET_MODEL=\"${ANTHROPIC_DEFAULT_SONNET_MODEL:-}\""
        echo "export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}\""
        [ -n "$ANTHROPIC_DEFAULT_OPUS_MODEL" ] && echo "export ANTHROPIC_DEFAULT_OPUS_MODEL=\"$ANTHROPIC_DEFAULT_OPUS_MODEL\""
        [ -n "$CLAUDE_CODE_SUBAGENT_MODEL" ] && echo "export CLAUDE_CODE_SUBAGENT_MODEL=\"$CLAUDE_CODE_SUBAGENT_MODEL\""

        # 写入密钥（仅在当前 shell 的 env 中，通过 source secret file 获得）
        if [ "$auth_type" = "api_key" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            echo "export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\""
        elif [ "$auth_type" = "auth_token" ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            echo "export ANTHROPIC_AUTH_TOKEN=\"$ANTHROPIC_AUTH_TOKEN\""
        fi

        # 额外环境变量
        _write_extra_env "$extra_env"
    } > "$STATUS_FILE"

    echo ""
    echo -e "${GREEN}✅ 已切换到 ${name} ($provider)${NC}"
    echo -e "   Base URL:  ${YELLOW}$base_url${NC}"
    echo -e "   Model:     ${YELLOW}$model${NC}"
    echo -e "   Auth:      ${YELLOW}$auth_type${NC}"
    echo ""
    echo -e "环境变量已立即生效。${CYAN}无需 source ~/.bashrc${NC}"
}

# ============================================================
# 脚本被 source 时的输出提示
# ============================================================
echo -e "${GREEN}cc-switch 已加载${NC} — 运行 ${YELLOW}cc-switch${NC} 查看用法，${YELLOW}cc-switch list${NC} 查看可用供应商"
