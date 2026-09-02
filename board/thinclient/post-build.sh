#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Запускается Buildroot'ом после установки всех пакетов в target.
set -e

# Версия образа (из git, передаётся build.sh) — показывается в углу меню.
printf '%s\n' "${TC_VERSION:-dev}" > "$TARGET_DIR/etc/tc-release"

# Пакет xserver_xorg-server ставит автозапуск X демоном при загрузке.
# У нас X живёт только внутри RDP-сессии (xinit из tc-menu) — убираем,
# иначе пустой X перехватывает экран и меню на tty1 не видно.
rm -f "$TARGET_DIR/etc/init.d/S40xorg"

# Overlay не удаляет из target файлы, которые из него исчезли:
# S40dhcp — хвост переименования, tc-logo — убранный ASCII-логотип
rm -f "$TARGET_DIR/etc/init.d/S40dhcp"
rm -f "$TARGET_DIR/etc/tc-logo"

# Сеть переехала на S51network (после S50flash, чтобы читать tc.conf).
# Убираем скелетный/старый S40network, иначе сеть поднимется дважды.
rm -f "$TARGET_DIR/etc/init.d/S40network"

# dialog больше не используется (UI на tc-launcher) — чистим бинарь и конфиг,
# если остались от прошлой сборки с BR2_PACKAGE_DIALOG=y
rm -f "$TARGET_DIR/usr/bin/dialog" "$TARGET_DIR/etc/dialogrc"

# SSH переехал на S53ssh (после флешки, host-key персистится на TCDATA).
# Убираем скелетный dropbear-автостарт, иначе стартует рано с ключом в RAM.
rm -f "$TARGET_DIR/etc/init.d/S50dropbear"

# Драйвер X переехал с fbdev на modesetting (10-video.conf). Старый
# 10-fbdev.conf overlay сам не удалит — иначе он остаётся в target и снова
# форсит Driver "fbdev" ("no screens found" на реальном Intel/KMS).
rm -f "$TARGET_DIR/etc/X11/xorg.conf.d/10-fbdev.conf"

# sudo: наш sudoers.d-файл должен быть 0440 root:root, иначе sudo его молча
# игнорирует (проверка прав). Каталог — не world-writable. И гарантируем, что
# /etc/sudoers подключает каталог (у пакета sudo это обычно уже есть).
if [ -f "$TARGET_DIR/etc/sudoers.d/thinclient" ]; then
    chown 0:0  "$TARGET_DIR/etc/sudoers.d/thinclient" 2>/dev/null || true
    chmod 0440 "$TARGET_DIR/etc/sudoers.d/thinclient"
fi
[ -d "$TARGET_DIR/etc/sudoers.d" ] && chmod 0750 "$TARGET_DIR/etc/sudoers.d"
if [ -f "$TARGET_DIR/etc/sudoers" ] && \
   ! grep -q '^#includedir /etc/sudoers.d' "$TARGET_DIR/etc/sudoers"; then
    echo '#includedir /etc/sudoers.d' >> "$TARGET_DIR/etc/sudoers"
fi
