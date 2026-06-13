#!/bin/bash

# 1. 提取传入的第一个参数作为模型名
PROVIDER=$1

# 如果没有提供参数，给出提示
if [ -z "$PROVIDER" ]; then
    echo "⚠️  缺少模型名称。用法: cc <模型名称> [其他参数]"
    echo "例如: cc deepseek"
    exit 1
fi

# 2. 移除第一个参数，将剩下的参数保留给 claude 原生命令
shift

# 3. 寻找对应的配置文件
CONF_FILE="$HOME/.claude/providers/${PROVIDER}.env"

if [ ! -f "$CONF_FILE" ]; then
    echo "❌ 未找到模型配置: $CONF_FILE"
    echo "请在 ~/.claude/providers/ 目录下创建对应的 .env 文件"
    exit 1
fi

# 4. 注入所有第三方模型通用的环境变量
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
export CLAUDE_CODE_EFFORT_LEVEL="max"

# 5. 读取特定的模型密钥
source "$CONF_FILE"

# 6. 启动 Claude Code
echo "🚀 正在使用 [$PROVIDER] 引擎启动 Claude Code..."
claude "$@"
