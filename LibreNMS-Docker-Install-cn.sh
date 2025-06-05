#!/bin/bash
# LibreNMS Docker Installer - CN Optimized
# Supports Ubuntu, Debian, CentOS, Alpine in China mainland

set -e

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
        yum install -y curl wget unzip ca-certificates gnupg redhat-lsb-core
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

# 安装 Docker（Alpine 特殊处理）
if [ "$OS" = "alpine" ]; then
    echo ">> 使用 apk 安装 Docker"
    rc-update add docker boot
    service docker start
else
    echo ">> 使用国内代理安装 Docker"
    # 设置国内 Docker 镜像源
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}

EOF
    curl -fsSL https://gh-proxy.com/https://get.docker.com | bash -s -- --mirror Aliyun
    systemctl enable docker
    systemctl start docker
fi

# 安装 docker-compose
echo ">> 获取最新 docker-compose 版本（通过 gh-proxy 加速）"
COMPOSE_LATEST=$(curl -s https://gh-proxy.com/https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
COMPOSE_URL="https://gh-proxy.com/https://github.com/docker/compose/releases/download/${COMPOSE_LATEST}/docker-compose-$(uname -s)-$(uname -m)"

echo ">> 安装 docker-compose $COMPOSE_LATEST ..."
curl -L "$COMPOSE_URL" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

echo ">> Docker 版本:"
docker --version
echo ">> Docker Compose 版本:"
docker-compose --version

# 创建目录并下载 LibreNMS Docker 项目（使用代理）
echo ">> 创建 LibreNMS 工作目录..."
mkdir -p /opt/docker/librenms
cd /opt/docker/librenms

if [ ! -f master.zip ]; then
    echo ">> 使用代理下载 LibreNMS Docker 项目..."
    wget https://gh-proxy.com/https://github.com/librenms/docker/archive/refs/heads/master.zip
fi

unzip -o master.zip
rm -f master.zip
cd ./docker-master/examples/compose

# 启动容器
echo ">> 启动 LibreNMS 容器..."
docker-compose up -d

# 获取本机 IP 并提示用户访问
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || ip addr show docker0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
echo
echo ">> LibreNMS 安装完成！"
echo "请访问: http://$IP:8000 进行初始设置"
