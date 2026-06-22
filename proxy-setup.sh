#!/bin/bash
# ============================================================
#  proxy-setup.sh — 一键部署 mihomo 代理 (国内 Gitee 可达)
#
#  用法:
#    bash -c "$(curl -fsSL https://gitee.com/lu-dunhang/dotfiles-proxy/raw/master/proxy-setup.sh)"
#
#  代理打通后, 接着跑 dotfiles 开荒:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/luduihang/dotfiles/main/bootstrap.sh)"
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
step()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC}  $*"; exit 1; }

MIHOMO_VERSION="v1.19.6"
MIHOMO_DIR="$HOME/.local/bin"
MIHOMO_BIN="$MIHOMO_DIR/mihomo"
CONFIG_DIR="$HOME/.config/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
CONFIG_PID="$CONFIG_DIR/mihomo.pid"
CONFIG_LOG="$CONFIG_DIR/mihomo.log"

# 国内可改 Gitee 加速: https://gitee.com/<you>/mihomo-mirror/raw/main
GH_PROXY="${GH_PROXY:-https://github.com}"

# ── 检测系统 ──
case "$(uname -s)" in Darwin) OS="darwin";; Linux) OS="linux";; *) err "不支持: $(uname -s)";; esac
case "$(uname -m)" in
    x86_64)         ARCH="amd64"  ; TARGET="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64)  ARCH="arm64"  ; TARGET="aarch64-unknown-linux-gnu" ;;
    *)              ARCH="$(uname -m)"; TARGET="$ARCH-unknown-linux-gnu" ;;
esac

# ── 安装 mihomo ──
install_mihomo() {
    if [ -x "$MIHOMO_BIN" ]; then
        step "mihomo 已存在: $MIHOMO_BIN"
        return
    fi
    step "下载 mihomo ${MIHOMO_VERSION} ..."
    local url="${GH_PROXY}/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-${OS}-${ARCH}-${MIHOMO_VERSION}.gz"
    mkdir -p "$MIHOMO_DIR"
    curl -fSL --progress-bar -o "${MIHOMO_BIN}.gz" "$url" || {
        warn "GitHub 下载失败,尝试备用地址..."
        url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-${OS}-${ARCH}-${MIHOMO_VERSION}.gz"
        curl -fSL --progress-bar -o "${MIHOMO_BIN}.gz" "$url" || err "下载失败: 请手动下载 mihomo 到 $MIHOMO_BIN"
    }
    gunzip -f "${MIHOMO_BIN}.gz"
    chmod +x "$MIHOMO_BIN"
    step "mihomo 安装完成"
}

# ── 写 mihomo 配置 ──
write_config() {
    if [ -f "$CONFIG_FILE" ]; then
        step "mihomo 配置已存在: $CONFIG_FILE"
        return
    fi
    step "写入 mihomo 配置..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'YAML'
mixed-port: 7897
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "VLESS-Vision-Direct"
    type: vless
    server: gatewaynode11.xyz
    port: 443
    uuid: baedd174-2b70-48af-aa30-7d6fe8032511
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: gatewaynode11.xyz
    client-fingerprint: chrome

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "VLESS-Vision-Direct"
      - "DIRECT"

rules:
  - DOMAIN,easytake.work,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - MATCH,Proxy
YAML
    chmod 600 "$CONFIG_FILE"
    step "配置写入完成"
}

# ── 检测桌面环境 ──
# 容器/Docker 环境不算桌面 (即使误设了 DISPLAY)
has_desktop() {
    [ -f /.dockerenv ] && return 1
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# ── 启动 mihomo ──
start_mihomo() {
    # 关键修复: 先杀掉所有旧 mihomo 释放 7897 端口
    pkill -9 -f "mihomo" 2>/dev/null || true
    sleep 0.5

    # 直接 curl 测端口最可靠, 不依赖 ss/netstat/pgrep
    if curl -s --max-time 1 -o /dev/null --proxy "http://127.0.0.1:7897" "http://127.0.0.1:7897" 2>/dev/null; then
        step "mihomo 已在运行 (端口 7897 可连通)"
        return
    fi

    step "启动 mihomo (mixed-port: 7897)..."
    nohup "$MIHOMO_BIN" -f "$CONFIG_FILE" > "$CONFIG_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$CONFIG_PID"

    # 关键修复: 等待端口真正监听, 最多 15 秒
    # mihomo 启动需要 1-3 秒 (初始化+geoip 加载)
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 1
        if curl -s --max-time 1 -o /dev/null --proxy "http://127.0.0.1:7897" "http://127.0.0.1:7897" 2>/dev/null; then
            step "mihomo 启动成功 (PID: $pid, 等待 ${i}s)"
            return
        fi
        # 检查进程是否还活着
        if ! kill -0 "$pid" 2>/dev/null; then
            err "mihomo 进程已退出, 日志: $CONFIG_LOG"
        fi
    done

    # 15 秒还没起来, 看日志判断原因
    err "mihomo 启动超时 (15s), 日志: $CONFIG_LOG"
}

# ── 检查代理 ──
check_proxy() {
    step "检测代理连通性 (VLess 握手约需 5-10 秒)..."
    local code
    for i in 1 2 3 4 5; do
        code=$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" --proxy "http://127.0.0.1:7897" "http://www.google.com" 2>/dev/null)
        code="${code:-000}"
        if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
            step "代理连通正常 ✓ (第 ${i} 次尝试, HTTP $code)"
            return
        fi
        [ "$i" -lt 5 ] && sleep 4
    done
    warn "代理暂不可达 (HTTP $code), 检查 mihomo 日志: $CONFIG_LOG"
}

# ── main ──
echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   mihomo 代理一键部署               ║"
echo "  ║   OS: $(uname -s) ($(uname -m))               ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

install_mihomo
write_config

if has_desktop; then
    warn "检测到桌面环境, 跳过 mihomo 内核启动"
    warn "请使用 Clash Verge 管理代理"
else
    start_mihomo
    check_proxy
    # 让当前 shell 和后续命令都用代理
    export http_proxy="http://127.0.0.1:7897" https_proxy="http://127.0.0.1:7897" all_proxy="http://127.0.0.1:7897"
    echo "  ℹ 代理环境变量已临时生效 (仅本脚本会话)"
fi

echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │  代理已就绪 (127.0.0.1:7897)        │"
echo "  │  接着跑 dotfiles 开荒:              │"
echo "  │  bash -c \"\$(curl -fsSL             │"
echo "  │    https://raw.githubusercontent.com│"
echo "  │    /luduihang/dotfiles/main/        │"
echo "  │    bootstrap.sh)\"                   │"
echo "  └─────────────────────────────────────┘"
echo ""
