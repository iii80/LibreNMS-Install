#!/bin/bash
set -e

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
fi

# 检测系统版本
. /etc/os-release
DISTRO=$ID
VERSION_ID=${VERSION_ID%%.*}

SUPPORTED=false
case "$DISTRO" in
    ubuntu)
        case "$VERSION_ID" in
            20|22|24) SUPPORTED=true ;;
        esac
        ;;
    debian)
        case "$VERSION_ID" in
            10|11|12) SUPPORTED=true ;;
        esac
        ;;
esac

if [ "$SUPPORTED" != true ]; then
    echo "不支持的系统版本: $DISTRO $VERSION_ID，仅支持 Ubuntu 20/22/24 和 Debian 10/11/12。"
    exit 1
fi

# 更新系统并安装依赖
apt update
apt install -y curl wget gnupg2 software-properties-common apt-transport-https lsb-release ca-certificates unzip \
    python3-pymysql python3-dotenv python3-setuptools python3-pip git acl composer net-tools

# 添加 PHP 源
PHP_VERSION=8.2
if [[ "$DISTRO" == "ubuntu" ]]; then
    add-apt-repository ppa:ondrej/php -y
elif [[ "$DISTRO" == "debian" ]]; then
    echo "deb https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/php.list
    wget -qO - https://packages.sury.org/php/apt.gpg | gpg --dearmor | tee /etc/apt/trusted.gpg.d/php.gpg > /dev/null
fi
apt update
apt install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-gd php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-bcmath php${PHP_VERSION}-zip php${PHP_VERSION}-curl php${PHP_VERSION}-snmp php${PHP_VERSION}-intl php${PHP_VERSION}-ldap php${PHP_VERSION}-pgsql php${PHP_VERSION}-fpm

# 设置 PHP 时区
sed -i "s/^;*date.timezone *=.*/date.timezone = Asia\/Shanghai/" /etc/php/${PHP_VERSION}/fpm/php.ini
sed -i "s/^;*date.timezone *=.*/date.timezone = Asia\/Shanghai/" /etc/php/${PHP_VERSION}/cli/php.ini

# 安装 MariaDB
apt install -y mariadb-server
systemctl enable --now mariadb

# 安装 Nginx
apt install -y nginx
systemctl enable --now nginx

# 创建 librenms 用户
if ! id librenms >/dev/null 2>&1; then
    useradd librenms -d /opt/librenms -M -r -s /bin/bash
else
    echo "用户 librenms 已存在，跳过创建。"
fi

# 强制清理并克隆最新版 LibreNMS
rm -rf /opt/librenms
cd /opt
git clone https://github.com/librenms/librenms.git
chown -R librenms:librenms /opt/librenms
cd /opt/librenms
sudo -u librenms ./scripts/composer_wrapper.php install --no-dev

# 设置权限
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms
setfacl -R -m g::rwx /opt/librenms

# 删除并重新创建数据库
DB_PASS=$(openssl rand -base64 12)
mysql -u root <<EOF
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF
echo "$DB_PASS" > /opt/librenms/db_password.txt
chmod 600 /opt/librenms/db_password.txt

# 配置 PHP-FPM
PHP_FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/librenms.conf"
cat > "$PHP_FPM_CONF" <<EOF
[librenms]
user = librenms
group = librenms
listen = /run/php-fpm-librenms.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[error_log] = /var/log/php-fpm-librenms.log
php_admin_flag[log_errors] = on
EOF

systemctl enable --now php${PHP_VERSION}-fpm

# 配置 Nginx
NGINX_CONF="/etc/nginx/sites-available/librenms"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;
    root /opt/librenms/html;
    index index.php;

    access_log /var/log/nginx/librenms_access.log;
    error_log /var/log/nginx/librenms_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/librenms
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# 安装 cron 与 logrotate 配置（必须克隆完后执行）
cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

# 显示完成信息
IP_ADDR=$(hostname -I | awk '{print $1}')
echo
echo "✅ LibreNMS 安装完成，请访问：http://${IP_ADDR} 完成网页配置。"
echo "数据库信息："
echo "  数据库名: librenms"
echo "  用户名: librenms"
echo "  密码: ${DB_PASS}"
