#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Заливка usb.img на флешку. Работает на macOS и Linux.
#   macOS:  ./flash-usb.sh /dev/diskN   (номер смотри в diskutil list)
#   Linux:  ./flash-usb.sh /dev/sdX     (смотри в lsblk)
set -e
cd "$(dirname "$0")"

IMG=buildroot/output/images/usb.img
DISK="$1"
OS=$(uname -s)

if [ -z "$DISK" ]; then
    echo "Использование: $0 <устройство>"
    echo ""
    if [ "$OS" = "Darwin" ]; then
        diskutil list
    else
        lsblk -d -o NAME,SIZE,MODEL,TRAN
    fi
    exit 1
fi

[ -f "$IMG" ] || { echo "Нет $IMG — сначала ./build.sh"; exit 1; }

echo "!!! ВСЕ ДАННЫЕ НА $DISK БУДУТ УНИЧТОЖЕНЫ !!!"
if [ "$OS" = "Darwin" ]; then
    diskutil info "$DISK" | grep -E 'Device Node|Media Name|Disk Size' || true
else
    lsblk -d -o NAME,SIZE,MODEL "$DISK" || true
fi
printf "Продолжить? (yes/no): "
read -r answer
[ "$answer" = "yes" ] || { echo "Отменено"; exit 1; }

if [ "$OS" = "Darwin" ]; then
    RDISK=$(echo "$DISK" | sed 's|/dev/disk|/dev/rdisk|')
    diskutil unmountDisk "$DISK"
    sudo dd if="$IMG" of="$RDISK" bs=4m status=progress
    sync
    diskutil eject "$DISK"
else
    # отмонтировать всё, что автомонтировщик успел подцепить
    for part in "$DISK"?*; do
        [ -b "$part" ] && sudo umount "$part" 2>/dev/null || true
    done
    sudo dd if="$IMG" of="$DISK" bs=4M status=progress conv=fsync
    sudo eject "$DISK" 2>/dev/null || true
fi
echo ">>> Готово. Флешку можно вставлять в клиент."
