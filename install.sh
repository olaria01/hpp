#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 仓库信息
GITHUB_REPO="olaria01/hpp"

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

    info "下载 docker-compose.yml..."
    wget -q --show-progress \
        "https://raw.githubusercontent.com/$GITHUB_REPO/main/docker-compose.yml" \
        -O docker-compose.yml \
        || warn "下载 docker-compose.yml 失败，跳过"

    info "下载 .env.example..."
    wget -q \
        "https://raw.githubusercontent.com/$GITHUB_REPO/main/.env.example" \
        -O .env.example \
        || warn "下载 .env.example 失败，跳过"

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
    cd "$DOWNLOAD_DIR"

    # 检测是否在项目部署目录
    if [ -f "$ORIGINAL_DIR/jiuselu_server" ] || [ -f "$ORIGINAL_DIR/docker-compose.yml" ]; then
        info "检测到项目部署目录，正在原地更新文件..."
        IS_UPDATE="true"
    else
        info "初始化项目部署目录..."
        IS_UPDATE="false"
    fi
    
    # 更新/安装 Server
    info "安装 $ORIGINAL_DIR/jiuselu_server"
    rm -f "$ORIGINAL_DIR/jiuselu_server"
    mv jiuselu_server_linux_amd64 "$ORIGINAL_DIR/jiuselu_server"
    chmod +x "$ORIGINAL_DIR/jiuselu_server"
    
    # 更新/安装 Crawler（统一使用 jiuselu_crawler 文件名）
    info "安装 $ORIGINAL_DIR/jiuselu_crawler"
    rm -f "$ORIGINAL_DIR/jiuselu_crawler" "$ORIGINAL_DIR/jiuselu_crawler_bin" "$ORIGINAL_DIR/jiuselu-crawler" 2>/dev/null || true
    mv jiuselu_crawler_linux_amd64 "$ORIGINAL_DIR/jiuselu_crawler"
    chmod +x "$ORIGINAL_DIR/jiuselu_crawler"
    
    # 更新/创建 docker-compose.yml
    if [ -f "docker-compose.yml" ]; then
        if [ -f "$ORIGINAL_DIR/docker-compose.yml" ]; then
            info "更新 $ORIGINAL_DIR/docker-compose.yml"
        else
            info "创建 $ORIGINAL_DIR/docker-compose.yml"
        fi
        cp docker-compose.yml "$ORIGINAL_DIR/docker-compose.yml"
    fi
    
    # 创建 .env 文件（如果不存在）
    if [ -f ".env.example" ]; then
        if [ ! -f "$ORIGINAL_DIR/.env" ]; then
            info "创建 $ORIGINAL_DIR/.env"
            cp .env.example "$ORIGINAL_DIR/.env"
            warn "请编辑 .env 文件修改数据库密码等敏感信息"
        else
            info ".env 文件已存在，跳过创建"
        fi
    fi
    
    info "✅ 文件安装完成"
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
    
    # 查找 jiuselu 相关容器（排除 mysql）
    local containers=$(docker ps --filter "name=jiuselu" --format "{{.Names}}" 2>/dev/null | grep -v "jiuselu_mysql")
    
    if [ -z "$containers" ]; then
        warn "未检测到运行中的 jiuselu 服务容器"
        return
    fi
    
    info "检测到以下容器："
    echo "$containers" | while read container; do
        echo "  - $container"
    done
    
    # 自动重启容器
    echo ""
    info "自动重启服务中（跳过 MySQL）..."
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
    
    if [ "$IS_UPDATE" = "true" ]; then
        info "更新完成！"
        info "============================================"
        info "当前版本: $LATEST_VERSION"
        info "已更新二进制文件和配置"
        info "服务已自动重启"
    else
        info "安装完成！"
        info "============================================"
        info "当前版本: $LATEST_VERSION"
        echo ""
        info "已安装文件："
        echo "  - jiuselu_server:       API 服务器"
        echo "  - jiuselu_crawler:      爬虫程序"
        echo "  - docker-compose.yml:   Docker 编排配置"
        echo "  - .env:                 环境变量配置"
        echo ""
        info "下一步操作："
        echo "  1. 编辑 .env 文件，修改数据库密码等配置"
        echo "  2. 编辑 config.yaml 文件，配置应用参数"
        echo "  3. 启动服务: docker-compose up -d"
        echo "  4. 查看日志: docker-compose logs -f"
        echo ""
        info "更新提示："
        echo "  重新运行此脚本即可更新到最新版本（自动重启服务）"
        echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | bash"
    fi
    echo ""
}

main() {
    ORIGINAL_DIR=$(pwd)
    IS_UPDATE="false"
    
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
