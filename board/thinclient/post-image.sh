#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Запускается Buildroot'ом после сборки образов (внутри Linux-контейнера),
# либо отдельно: BINARIES_DIR=... ./post-image.sh
# Собирает два артефакта в $BINARIES_DIR:
#   usb.img        — боевой образ флешки (MBR + FAT32 + syslinux), список
#                    серверов записываемый; нужен бинарник `syslinux` (x86-only
#                    пакет — на arm64-хосте шаг пропускается, см. build.sh)
#   thinclient.iso — hybrid ISO для VirtualBox (как CD) и balenaEtcher;
#                    файловая система только для чтения
set -e

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
PART_MB=256

# ---- Флеш-конфиг из единого site.env (шаблон — site.env.example) ----
# Готовит файлы для FAT-раздела/ISO: servers.conf и tc.conf.sample — всегда;
# активные tc.conf/servers.conf/shell.pass — если задан site.env в корне репо.
# Так один файл site.env запекает и rootfs-часть (build.sh), и флеш-часть.
SITE_ENV="$BOARD_DIR/../../site.env"
SEED="$BINARIES_DIR/site-seed"
gen_seed() {
    rm -rf "$SEED"; mkdir -p "$SEED"
    cp "$BOARD_DIR/servers.conf.sample" "$SEED/servers.conf"
    cp "$BOARD_DIR/tc.conf.sample"      "$SEED/tc.conf.sample"
    # syslinux.cfg тоже через seed: site.env может переключить DEFAULT (kms|safe)
    cp "$BOARD_DIR/syslinux.cfg"        "$SEED/syslinux.cfg"
    [ -f "$SITE_ENV" ] || return 0
    echo ">>> site.env: запекаю конфиг площадки в образ" >&2
    (
        # shellcheck disable=SC1090
        . "$SITE_ENV"
        # серверы: строки "Имя=адрес[:порт]" -> "Имя;адрес"
        if [ -n "${SERVERS:-}" ]; then
            printf '%s\n' "$SERVERS" | {
                first=1
                while IFS= read -r ln; do
                    ln=$(printf '%s' "$ln" | tr -d '\r')
                    case "$ln" in ''|\#*) continue ;; esac
                    nm=$(printf '%s' "${ln%%=*}" | sed 's/^ *//;s/ *$//')
                    ad=$(printf '%s' "${ln#*=}"  | sed 's/^ *//;s/ *$//')
                    [ -n "$nm" ] && [ -n "$ad" ] || continue
                    [ "$first" = 1 ] && { : > "$SEED/servers.conf"; first=0; }
                    printf '%s;%s\r\n' "$nm" "$ad" >> "$SEED/servers.conf"
                done
            }
        fi
        # tc.conf (активный) — только непустые ключи
        : > "$SEED/tc.conf"
        # HOSTNAME намеренно не запекаем — имя хоста присваивается само (tc-<mac>)
        # протокол/логин сервера не глобальные — поля 3/4 в строке SERVERS;
        # RDP_USER здесь лишь дефолт-фолбэк; домена нет (пишется в логине)
        for k in STATIC_IP GATEWAY DNS NTP_SERVER KEYMAP WAIT_FOR_IP \
                 RDP_USER RDP_EXTRA AUTOCONNECT \
                 PRINTER PRINTER_NAME XDRIVER; do
            eval "v=\${$k:-}"
            [ -n "$v" ] && printf '%s=%s\r\n' "$k" "$v" >> "$SEED/tc.conf"
        done
        [ -s "$SEED/tc.conf" ] || rm -f "$SEED/tc.conf"
        # режим ядра: VIDEO_MODE=safe -> DEFAULT safe в syslinux.cfg (nomodeset)
        case "${VIDEO_MODE:-}" in
            safe|kms) sed -i "s/^DEFAULT .*/DEFAULT $VIDEO_MODE/" "$SEED/syslinux.cfg"
                      echo ">>> site.env: VIDEO_MODE=$VIDEO_MODE (DEFAULT в syslinux.cfg)" >&2 ;;
            '') ;;
            *)  echo "!!! site.env: VIDEO_MODE='$VIDEO_MODE' не kms|safe — игнорирую" >&2 ;;
        esac
        # shell.pass (пароль на Settings): готовый sha256 (64 hex) или текст
        if [ -n "${SETTINGS_PASSWORD:-}" ]; then
            if printf '%s' "$SETTINGS_PASSWORD" | grep -qiE '^[0-9a-f]{64}$'; then
                printf '%s\n' "$SETTINGS_PASSWORD" > "$SEED/shell.pass"
            else
                printf '%s' "$SETTINGS_PASSWORD" | sha256sum | cut -c1-64 > "$SEED/shell.pass"
            fi
        fi
    )
}

# UEFI: bootx64/bootia32 генерятся grub-mkstandalone (конфиг вшивается
# внутрь образа загрузчика). Buildroot тут не помощник: на i686 он не
# собирает x86_64-efi. Нет grub-утилит в системе — тихо живём BIOS-only.
EFI_DIR="$BINARIES_DIR/efi-gen"
# минимальный набор: без него mkstandalone тащит ВСЕ модули (~9 МБ на образ)
EFI_MODULES="boot linux normal fat iso9660 part_msdos part_gpt search search_fs_file efi_gop echo"
gen_efi() {
    command -v grub-mkstandalone >/dev/null 2>&1 || return 1
    rm -rf "$EFI_DIR"
    mkdir -p "$EFI_DIR"
    [ -d /usr/lib/grub/x86_64-efi ] && grub-mkstandalone -O x86_64-efi \
        --install-modules="$EFI_MODULES" \
        --locales="" --fonts="" --themes="" \
        -o "$EFI_DIR/bootx64.efi" \
        "boot/grub/grub.cfg=$BOARD_DIR/grub-efi.cfg" 2>/dev/null
    [ -d /usr/lib/grub/i386-efi ] && grub-mkstandalone -O i386-efi \
        --install-modules="$EFI_MODULES" \
        --locales="" --fonts="" --themes="" \
        -o "$EFI_DIR/bootia32.efi" \
        "boot/grub/grub.cfg=$BOARD_DIR/grub-efi.cfg" 2>/dev/null
    [ -f "$EFI_DIR/bootx64.efi" ] || [ -f "$EFI_DIR/bootia32.efi" ]
}

# докладывает EFI/BOOT/boot*.efi в FAT-образ $1 (через mtools)
add_efi_to_fat() {
    gen_efi || return 0
    mmd -i "$1" ::/EFI ::/EFI/BOOT 2>/dev/null || true
    [ -f "$EFI_DIR/bootx64.efi" ]  && mcopy -o -i "$1" "$EFI_DIR/bootx64.efi"  ::/EFI/BOOT/
    [ -f "$EFI_DIR/bootia32.efi" ] && mcopy -o -i "$1" "$EFI_DIR/bootia32.efi" ::/EFI/BOOT/
    true
}

# отдельный FAT для El Torito EFI-загрузки ISO; размер — по факту + запас
build_efiboot_img() {
    gen_efi || return 1
    EFIBOOT="$BINARIES_DIR/efiboot.img"
    SZ_MB=$(( $(du -cm "$EFI_DIR"/*.efi 2>/dev/null | tail -1 | cut -f1) + 4 ))
    dd if=/dev/zero of="$EFIBOOT" bs=1M count="$SZ_MB" status=none
    mkfs.vfat -n EFIBOOT "$EFIBOOT" >/dev/null
    add_efi_to_fat "$EFIBOOT"
    # убедиться, что загрузчик реально лёг внутрь (а не молча не влез)
    mdir -i "$EFIBOOT" ::/EFI/BOOT 2>/dev/null | grep -qi 'boot.*efi'
}

build_img() {
    IMG="$BINARIES_DIR/usb.img"
    PART="$BINARIES_DIR/part.img"

    # 1. FAT32-раздел с ядром, initramfs, конфигом syslinux и списком серверов
    # -g 255/63 и -h 2048 КРИТИЧНЫ для старых BIOS без EDD (USB в CHS-режиме):
    # загрузочный сектор syslinux считает адреса по геометрии из BPB, и с
    # дефолтной (16 голов/32 sect у 256МБ-файла) чтение уходит мимо ->
    # "Boot error" на железе, хотя в qemu (EDD/LBA) образ грузится нормально.
    # 255/63 совпадает с тем, как BIOS маппит USB-HDD; hidden=2048 = смещение
    # раздела (1 МиБ) от начала диска.
    dd if=/dev/zero of="$PART" bs=1M count=$PART_MB status=none
    mkfs.vfat -F 32 -g 255/63 -h 2048 -n THINCLIENT "$PART" >/dev/null
    mcopy -i "$PART" "$BINARIES_DIR/bzImage"          ::/bzImage
    mcopy -i "$PART" "$BINARIES_DIR/rootfs.cpio.gz"   ::/initrd.gz
    mcopy -i "$PART" "$SEED/syslinux.cfg"        ::/syslinux.cfg
    mcopy -i "$PART" "$SEED/servers.conf"             ::/servers.conf
    mcopy -i "$PART" "$SEED/tc.conf.sample"           ::/tc.conf.sample
    [ -f "$SEED/tc.conf" ]    && mcopy -i "$PART" "$SEED/tc.conf"    ::/tc.conf
    [ -f "$SEED/shell.pass" ] && mcopy -i "$PART" "$SEED/shell.pass" ::/shell.pass
    add_efi_to_fat "$PART"
    syslinux --install "$PART"

    # 2. Диск целиком: MBR-разметка, раздел с отступом 1 МиБ, boot-флаг
    dd if=/dev/zero of="$IMG" bs=1M count=$((PART_MB + 1)) status=none
    parted -s "$IMG" mklabel msdos mkpart primary fat32 1MiB 100% set 1 boot on

    # 3. Загрузочный код syslinux в MBR
    MBR_BIN=""
    for p in /usr/lib/syslinux/mbr/mbr.bin /usr/lib/syslinux/bios/mbr.bin \
             /usr/lib/SYSLINUX/mbr.bin /usr/share/syslinux/mbr.bin; do
        [ -f "$p" ] && MBR_BIN="$p" && break
    done
    [ -n "$MBR_BIN" ] || { echo "mbr.bin не найден — установи syslinux-common"; exit 1; }
    dd if="$MBR_BIN" of="$IMG" bs=440 count=1 conv=notrunc status=none

    # 4. Кладём раздел на место
    dd if="$PART" of="$IMG" bs=1M seek=1 conv=notrunc status=none
    rm -f "$PART"

    echo ">>> Готово: $IMG ($(du -h "$IMG" | cut -f1))"
}

build_iso() {
    ISOLINUX_BIN=""
    for p in /usr/lib/ISOLINUX/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/syslinux/bios/isolinux.bin; do
        [ -f "$p" ] && ISOLINUX_BIN="$p" && break
    done
    ISOHDPFX=""
    for p in /usr/lib/ISOLINUX/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin /usr/lib/syslinux/bios/isohdpfx.bin; do
        [ -f "$p" ] && ISOHDPFX="$p" && break
    done
    LDLINUX=""
    for p in /usr/lib/syslinux/modules/bios/ldlinux.c32 /usr/share/syslinux/ldlinux.c32 /usr/lib/syslinux/bios/ldlinux.c32; do
        [ -f "$p" ] && LDLINUX="$p" && break
    done

    if ! command -v xorriso >/dev/null 2>&1 || [ -z "$ISOLINUX_BIN" ] || [ -z "$ISOHDPFX" ]; then
        echo ">>> ISO пропущен: нужны xorriso и isolinux (см. README)" >&2
        return 0
    fi

    ISO="$BINARIES_DIR/thinclient.iso"
    ISO_DIR="$BINARIES_DIR/iso-root"
    rm -rf "$ISO_DIR"
    mkdir -p "$ISO_DIR/isolinux"
    cp "$BINARIES_DIR/bzImage"          "$ISO_DIR/bzImage"
    cp "$BINARIES_DIR/rootfs.cpio.gz"   "$ISO_DIR/initrd.gz"
    cp "$SEED/servers.conf"             "$ISO_DIR/servers.conf"
    cp "$SEED/tc.conf.sample"           "$ISO_DIR/tc.conf.sample"
    [ -f "$SEED/tc.conf" ]    && cp "$SEED/tc.conf"    "$ISO_DIR/tc.conf"
    [ -f "$SEED/shell.pass" ] && cp "$SEED/shell.pass" "$ISO_DIR/shell.pass"
    cp "$SEED/syslinux.cfg"        "$ISO_DIR/isolinux/isolinux.cfg"
    cp "$ISOLINUX_BIN"                  "$ISO_DIR/isolinux/"
    [ -n "$LDLINUX" ] && cp "$LDLINUX"  "$ISO_DIR/isolinux/"

    # UEFI-запись добавляется, только если grub-efi собрался
    EFI_OPTS=""
    if build_efiboot_img; then
        cp "$BINARIES_DIR/efiboot.img" "$ISO_DIR/efiboot.img"
        EFI_OPTS="-eltorito-alt-boot -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
    fi

    xorriso -as mkisofs -quiet -o "$ISO" \
        -isohybrid-mbr "$ISOHDPFX" \
        -b isolinux/isolinux.bin -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        $EFI_OPTS \
        -V THINCLIENT "$ISO_DIR"
    rm -rf "$ISO_DIR"
    echo ">>> Готово: $ISO ($(du -h "$ISO" | cut -f1))"
}

gen_seed                       # подготовить servers.conf/tc.conf/shell.pass из site.env

if command -v syslinux >/dev/null 2>&1; then
    build_img
else
    # пакет syslinux есть только под x86; на arm64-хосте (Apple Silicon)
    # usb.img дособерёт build.sh отдельным amd64-контейнером
    echo ">>> usb.img пропущен: нет утилиты syslinux (соберётся amd64-шагом)" >&2
fi
build_iso
