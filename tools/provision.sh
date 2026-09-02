#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Заливка usb.img на устройство + засев конфигов площадки на FAT-раздел.
# Инструмент для ТИРАЖА: без интерактивного подтверждения (в отличие от
# flash-usb.sh) — чтобы гонять в цикле. Проверяй устройство сам!
#
#   ./tools/provision.sh /dev/diskN [каталог-конфига]
#
# В каталоге-конфига могут лежать servers.conf, tc.conf, shell.pass — они
# копируются на флешку поверх дефолтных. Массовая заливка:
#   for d in disk4 disk5 disk6; do ./tools/provision.sh /dev/$d sites/buh; done
set -e
cd "$(dirname "$0")/.."

DISK="$1"
CFGDIR="$2"
OS=$(uname -s)
IMG=buildroot/output/images/usb.img

[ -n "$DISK" ] || { echo "Использование: $0 <устройство> [каталог-конфига]"; exit 1; }
[ -f "$IMG" ]  || { echo "Нет $IMG — сначала ./build.sh"; exit 1; }

echo ">>> Заливаю $IMG на $DISK (данные будут стёрты!) ..."
if [ "$OS" = Darwin ]; then
    RDISK=$(echo "$DISK" | sed 's|/dev/disk|/dev/rdisk|')
    diskutil unmountDisk "$DISK" || true
    sudo dd if="$IMG" of="$RDISK" bs=4m
    sync
else
    for p in "$DISK"?*; do [ -b "$p" ] && sudo umount "$p" 2>/dev/null || true; done
    sudo dd if="$IMG" of="$DISK" bs=4M conv=fsync
fi

if [ -n "$CFGDIR" ]; then
    echo ">>> Засеваю конфиги из $CFGDIR ..."
    if [ "$OS" = Darwin ]; then
        diskutil mountDisk "$DISK" >/dev/null 2>&1 || true
        MP=/Volumes/THINCLIENT
        n=0; while [ ! -d "$MP" ] && [ "$n" -lt 10 ]; do n=$((n+1)); sleep 1; done
    else
        MP=$(mktemp -d)
        sudo mount "${DISK}1" "$MP" 2>/dev/null || sudo mount "${DISK}p1" "$MP"
    fi
    for f in servers.conf tc.conf shell.pass; do
        [ -f "$CFGDIR/$f" ] && cp "$CFGDIR/$f" "$MP/$f" && echo "  + $f"
    done
    sync
    if [ "$OS" = Darwin ]; then
        diskutil eject "$DISK"
    else
        sudo umount "$MP"; rmdir "$MP"; sudo eject "$DISK" 2>/dev/null || true
    fi
else
    if [ "$OS" = Darwin ]; then diskutil eject "$DISK" 2>/dev/null || true
    else sudo eject "$DISK" 2>/dev/null || true; fi
fi
echo ">>> Готово: $DISK"
