#!/bin/bash
# Cross-distro Docker + LibreNMS Installer
# Supports Debian, Ubuntu, CentOS, Alpine

set -e
trap 'echo "发生错误，安装终止。" >&2' ERR

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "请以 root 身份运行此脚本（或使用 sudo）"
    exit 1
fi

echo ">> 检测系统类型..."
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法识别系统类型，退出..."
    exit 1
fi
echo "系统识别为: $OS"

# 安装前置依赖
echo ">> 安装依赖..."
case "$OS" in
    ubuntu|debian)
        apt update
        apt install -y curl wget unzip ca-certificates gnupg lsb-release
        ;;
    centos|rhel)
        yum install -y curl wget unzip ca-certificates gnupg lsb-release
        ;;
    alpine)
        apk update
        apk add curl wget unzip bash ca-certificates gnupg docker openrc
        ;;
    *)
        echo "当前系统未被支持: $OS"
        exit 1
        ;;
esac

# 检查 Docker 是否已安装
if command -v docker &>/dev/null; then
    echo ">> 已检测到 Docker，跳过安装"
    docker_installed=true
else
    docker_installed=false
fi

# 检查 docker-compose 是否已安装
if command -v docker-compose &>/dev/null; then
    echo ">> 已检测到 docker-compose，跳过安装"
    compose_installed=true
else
    compose_installed=false
fi

# 安装 Docker（如未安装）
if [ "$docker_installed" = false ]; then
    echo ">> 安装 Docker..."
    if [ "$OS" = "alpine" ]; then
        rc-update add docker boot
        service docker start
    else
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
fi

# 安装 docker-compose（如未安装）
if [ "$compose_installed" = false ]; then
    echo ">> 获取最新 docker-compose 版本..."
    COMPOSE_LATEST=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_LATEST}/docker-compose-$(uname -s)-$(uname -m)"

    echo ">> 安装 docker-compose $COMPOSE_LATEST ..."
    curl -L "$COMPOSE_URL" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
fi

echo ">> Docker 版本:"
docker --version
echo ">> Docker Compose 版本:"
docker-compose --version

# 创建目录并下载 LibreNMS Docker 项目
echo ">> 创建 LibreNMS 工作目录..."
mkdir -p /opt/docker/librenms
cd /opt/docker/librenms

if [ ! -f master.zip ]; then
    echo ">> 下载 LibreNMS Docker 项目..."
    wget https://github.com/librenms/docker/archive/refs/heads/master.zip
fi

unzip -o master.zip
rm -f master.zip
cd ./docker-master/examples/compose

# 启动容器
echo ">> 启动 LibreNMS 容器..."
docker-compose up -d

# 获取本机 IP 并提示用户访问
IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
echo
echo ">> LibreNMS 安装完成！"
echo "请访问: http://$IP:8000 进行初始设置"
