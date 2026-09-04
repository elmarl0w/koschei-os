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

IMG_BYTES=$(wc -c < "$IMG")

if [ "$OS" = "Darwin" ]; then
    RDISK=$(echo "$DISK" | sed 's|/dev/disk|/dev/rdisk|')
    diskutil unmountDisk "$DISK"
    sudo dd if="$IMG" of="$RDISK" bs=4m status=progress
    sync
    VDISK=$RDISK
else
    # отмонтировать всё, что автомонтировщик успел подцепить
    for part in "$DISK"?*; do
        [ -b "$part" ] && sudo umount "$part" 2>/dev/null || true
    done
    sudo dd if="$IMG" of="$DISK" bs=4M status=progress conv=fsync
    VDISK=$DISK
fi

# ВЕРИФИКАЦИЯ: dd пишет вслепую — сбойная или подсевшая флешка молча примет
# запись, а прочитается мусор -> "Boot error" на клиенте. Читаем образ обратно
# с носителя и сравниваем побайтово. Дороже, но ловит битую запись сразу.
echo ">>> Проверка записи (чтение обратно и сравнение)..."
if sudo dd if="$VDISK" bs=4M count=$(( (IMG_BYTES + 4194303) / 4194304 )) 2>/dev/null \
     | head -c "$IMG_BYTES" | cmp -s - "$IMG"; then
    echo ">>> Проверка ОК: флешка содержит ровно образ."
    VERIFY_OK=1
else
    echo "!!! ПРОВЕРКА НЕ ПРОШЛА: на флешке НЕ то, что записывали."
    echo "!!! Это битая запись или подсевшая флешка (её и надо менять)."
    echo "!!! НЕ грузи её — будет Boot error. Перезапиши или возьми другую."
    VERIFY_OK=0
fi

if [ "$OS" = "Darwin" ]; then
    diskutil eject "$DISK" 2>/dev/null || true
else
    sudo eject "$DISK" 2>/dev/null || true
fi

[ "${VERIFY_OK:-0}" = 1 ] || exit 2
echo ">>> Готово. Флешку можно вставлять в клиент."
