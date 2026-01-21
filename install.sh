#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 仓库信息
GITHUB_REPO="olaria01/hpp"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_system() {
    info "检查系统环境..."

    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [ "$OS" != "linux" ]; then
        error "当前脚本仅支持 Linux 系统"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            ARCH="amd64"
            ;;
        *)
            error "不支持的架构: $ARCH (仅支持 x86_64)"
            ;;
    esac

    info "系统: $OS, 架构: $ARCH"
}

check_dependencies() {
    info "检查必要工具..."

    local missing_tools=()

    for tool in curl wget; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "缺少必要工具: ${missing_tools[*]}。请先安装: sudo apt-get install ${missing_tools[*]}"
    fi
}

get_latest_version() {
    info "获取最新版本..."

    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        error "无法获取最新版本信息"
    fi

    info "最新版本: $LATEST_VERSION"
}

download_binaries() {
    info "下载二进制文件..."

    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    info "下载 jiuselu-crawler..."
    wget -q --show-progress \
        "https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/jiuselu_crawler_linux_amd64" \
        || error "下载 crawler 失败"

    info "下载 jiuselu-server..."
    wget -q --show-progress \
        "https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/jiuselu_server_linux_amd64" \
        || error "下载 server 失败"

    info "下载 checksums..."
    wget -q \
        "https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/checksums.txt" \
        || warn "下载 checksums 失败，跳过校验"

    DOWNLOAD_DIR="$tmp_dir"
}

verify_checksums() {
    if [ ! -f "$DOWNLOAD_DIR/checksums.txt" ]; then
        warn "checksums 文件不存在，跳过校验"
        return
    fi

    info "验证文件完整性..."

    cd "$DOWNLOAD_DIR"

    if ! sha256sum -c checksums.txt --ignore-missing 2>/dev/null; then
        error "文件校验失败"
    fi

    info "文件校验成功"
}

install_binaries() {
    info "安装二进制文件到 $INSTALL_DIR..."

    cd "$DOWNLOAD_DIR"

    if [ ! -w "$INSTALL_DIR" ]; then
        warn "需要 sudo 权限安装到 $INSTALL_DIR"
        SUDO="sudo"
    else
        SUDO=""
    fi

    $SUDO mv jiuselu_crawler_linux_amd64 "$INSTALL_DIR/jiuselu-crawler"
    $SUDO chmod +x "$INSTALL_DIR/jiuselu-crawler"
    info "已安装 jiuselu-crawler"

    $SUDO mv jiuselu_server_linux_amd64 "$INSTALL_DIR/jiuselu-server"
    $SUDO chmod +x "$INSTALL_DIR/jiuselu-server"
    info "已安装 jiuselu-server"
}

cleanup() {
    if [ -n "$DOWNLOAD_DIR" ] && [ -d "$DOWNLOAD_DIR" ]; then
        rm -rf "$DOWNLOAD_DIR"
        info "已清理临时文件"
    fi
}

restart_services() {
    info "检查运行中的服务..."
    
    # 检查是否有 Docker
    if ! command_exists docker; then
        warn "未检测到 Docker，跳过服务重启"
        return
    fi
    
    # 查找 jiuselu 相关的容器
    local containers=$(docker ps --filter "name=jiuselu" --format "{{.Names}}" 2>/dev/null)
    
    if [ -z "$containers" ]; then
        warn "未检测到运行中的 jiuselu 容器"
        return
    fi
    
    info "检测到以下容器："
    echo "$containers" | while read container; do
        echo "  - $container"
    done
    
    # 询问是否重启
    if [ -t 0 ]; then
        echo ""
        read -p "$(echo -e ${YELLOW}[PROMPT]${NC} 是否重启这些容器以应用更新？ [y/N]: )" -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "跳过服务重启"
            return
        fi
    else
        # 非交互模式下，如果设置了环境变量则自动重启
        if [ "$AUTO_RESTART" != "true" ]; then
            info "非交互模式，跳过服务重启（设置 AUTO_RESTART=true 自动重启）"
            return
        fi
    fi
    
    # 重启容器
    info "重启服务中..."
    echo "$containers" | while read container; do
        if docker restart "$container" >/dev/null 2>&1; then
            info "✓ 已重启: $container"
        else
            warn "✗ 重启失败: $container"
        fi
    done
    
    info "服务重启完成"
}

show_completion() {
    echo ""
    info "============================================"
    info "安装完成！"
    info "============================================"
    echo ""
    info "已安装以下命令:"
    echo "  - jiuselu-crawler: 爬虫程序"
    echo "  - jiuselu-server:  API 服务器"
    echo ""
    info "使用方法:"
    echo "  jiuselu-crawler full    # 运行全量爬取"
    echo "  jiuselu-crawler incr    # 运行增量爬取"
    echo "  jiuselu-server          # 启动 API 服务器"
    echo ""
    info "更新提示:"
    echo "  # 重新运行此脚本即可更新到最新版本"
    echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | bash"
    echo ""
    echo "  # 自动重启服务（非交互模式）"
    echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | AUTO_RESTART=true bash"
    echo ""
}

main() {
    info "酒色鹿爬虫项目 - 一键安装脚本"
    echo ""

    check_system
    check_dependencies
    get_latest_version
    download_binaries
    verify_checksums
    install_binaries
    cleanup
    restart_services
    show_completion
}

trap cleanup EXIT

main "$@"
