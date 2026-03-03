#!/usr/bin/env bash
set -e
#-----------------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------------
# sudo losetup -fP Orangepizero3_1.0.6_ubuntu_noble_server_linux6.1.31.img
# sudo ./customOS.sh
# sudo umount /media/xmrn/opi_root
# sudo losetup -d /dev/loopX
#-----------------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------------
ROOTFS="/media/xmrn/opi_root"
USERNAME="ha"
PASSWORD="ha"
HADIR="/opt/homeassistant"
HA_IMAGE="ghcr.io/home-assistant/home-assistant:stable"

# Проверки
if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт с sudo"
    exit 1
fi
if [[ ! -d "$ROOTFS" ]]; then
    echo "Ошибка: rootfs не найдена в $ROOTFS"
    exit 1
fi

echo "Монтируем /dev, /proc, /sys"
mountpoint -q "$ROOTFS/dev"  || mount --bind /dev  "$ROOTFS/dev"
mountpoint -q "$ROOTFS/proc" || mount --bind /proc "$ROOTFS/proc"
mountpoint -q "$ROOTFS/sys"  || mount --bind /sys  "$ROOTFS/sys"

echo "Настройка системы внутри chroot"
chroot "$ROOTFS" /bin/bash <<'EOF'
set -e

USERNAME="ha"
PASSWORD="ha"
HADIR="/opt/homeassistant"
HA_IMAGE="ghcr.io/home-assistant/home-assistant:stable"

# 0 ГЕНЕРАЦИЯ ЛОКАЛИ (УСТРАНЯЕМ PERL WARNING)
#-----------------------------------------------------------------------------------------
apt update
apt install -y locales
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# 1 СОЗДАЁМ ПОЛЬЗОВАТЕЛЯ
#-----------------------------------------------------------------------------------------
id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo,docker "$USERNAME"

# 2 КАТАЛОГ И DOCKER-COMPOSE.YML
#-----------------------------------------------------------------------------------------
mkdir -p "$HADIR"
chown -R "$USERNAME:$USERNAME" "$HADIR"

cat > "$HADIR/docker-compose.yml" <<'EOC'
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    network_mode: host
    privileged: true
    restart: unless-stopped
    volumes:
      - /opt/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
EOC

# 3 СКРИПТ ЗАПУСКА С ПРОВЕРКОЙ ОБРАЗА
#-----------------------------------------------------------------------------------------
cat > "$HADIR/start-ha.sh" <<'EOS'
#!/usr/bin/env bash
set -e
IMAGE="ghcr.io/home-assistant/home-assistant:stable"
HADIR="/opt/homeassistant"

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Home Assistant образ найден, запускаем контейнер..."
    docker compose -f "$HADIR/docker-compose.yml" up -d
else
    echo "Home Assistant образ отсутствует, пропускаем запуск (нет интернета?)"
    exit 0
fi
EOS
chmod +x "$HADIR/start-ha.sh"

# 4 SYSTEMD UNIT С БЕЗОПАСНЫМ ЗАПУСКОМ
#-----------------------------------------------------------------------------------------
cat > /etc/systemd/system/homeassistant.service <<EOS
[Unit]
Description=Home Assistant
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HADIR
ExecStart=$HADIR/start-ha.sh
RemainAfterExit=yes
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOS
systemctl enable homeassistant

# 5 НАСТРОЙКА SSH
#-----------------------------------------------------------------------------------------
apt install -y openssh-server
systemctl enable ssh
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

EOF

echo "Размонтируем временные файловые системы"
umount "$ROOTFS/dev"  || true
umount "$ROOTFS/proc" || true
umount "$ROOTFS/sys"  || true

echo "Готово!"
echo "Пользователь: ha / ha"
echo "SSH включен (логин+пароль)"
echo "Home Assistant запускается безопасно (образ проверяется перед стартом)"
