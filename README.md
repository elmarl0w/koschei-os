# Thin Client OS

Минимальный Linux для тонких клиентов: загружается с флешки, целиком живёт
в RAM и умеет ровно одно — показать список серверов и открыть полноэкранную
RDP-сессию к выбранному. Работает практически на любом x86 — от 32-битных
нетбуков 2008 года до современных ПК с UEFI без CSM (см. «Поддерживаемое
железо»).

Стек: Buildroot 2025.08 · ядро 6.12 LTS · busybox init · собственный
ncurses-лаунчер · Xorg (поднимается только на время сессии) · FreeRDP 2.11.

## Возможности

- **Загрузка с флешки**: гибридные образы — legacy BIOS (syslinux) и UEFI
  x64/ia32 (grub-efi); вся система распаковывается в RAM, флешку после
  загрузки можно вынуть.
- **Любое x86-железо**: от 32-битных Atom (N270/N280, Cedar Trail) до
  современных десктопов — нативная графика на Intel/NVIDIA/старых AMD,
  VESA-fallback на остальном, широкая поддержка сетевых карт.
- **Интерфейс**: тёмный ncurses-лаунчер — список серверов по центру,
  снизу три кнопки (Settings / Reboot / PowerOff), hostname и IP в углу.
  Главный экран — для пользователя: выбрал сервер, нажал Enter → RDP. Всё
  админское (управление серверами, сеть/RDP, принтер, диагностика, консоль)
  собрано под пунктом **Settings**, который админ может запаролить целиком.
- **RDP**: FreeRDP 2.11 — Windows Server 2008 R2 … 2022 (RDP 7–10, NLA,
  TLS 1.2), нативное разрешение монитора, динамическая смена разрешения,
  буфер обмена. Проброс сетевого принтера (`/printer`): укажи `PRINTER=` в
  `tc.conf` — клиент создаст очередь и пробросит её в сессию (см. ниже).
- **Сеть**: DHCP на всех интерфейсах, hostname `tc-<mac без разделителей>`
  (виден в DHCP leases и в RDP-сессии), самовосстановление — интерфейс,
  появившийся после загрузки, подхватывается без перезагрузки.
- **Загрузочная заставка**: тёмный экран с прогресс-баром (psplash),
  служебный вывод спрятан на tty2.
- **Консоль**: полноценный bash (промпт `root@tc-…:путь#`), доступен из
  Settings → Console. По умолчанию **без пароля**; админ может запаролить весь
  раздел Settings (вместе с консолью) файлом `shell.pass` на флешке (см.
  «Использование»). На борту iproute2, ping, ethtool, tcpdump, lsusb, htop,
  mc, nano, vim, vi.
- **SSH**: sshd (dropbear) слушает 22-й порт с загрузки. Пароль root
  задаётся **при сборке** (`TC_ROOT_PASSWORD='...' ./build.sh`), а не зашит
  в репозиторий — дефолт из defconfig помечен как небезопасная заглушка
  «CHANGE THIS». Тот же пароль — у логина на tty2. Система в RAM → host-ключ
  sshd генерится на каждую загрузку (ssh-клиент предупредит о смене ключа).
  Подробно — раздел «Пароль root и SSH».
- **Персистентность**: список серверов хранится на FAT-разделе флешки и
  переживает перезагрузки (в варианте usb.img).

## Быстрый старт

Готовые образы лежат в [Releases](../../releases):

| Образ | Для чего | Как записать | Список серверов |
|---|---|---|---|
| `thinclient.iso` | флешка (основной вариант) и виртуалки | balenaEtcher / CD в VM | на флешке — редактируемый (раздел `TCDATA` создаётся при первой загрузке); с CD в VM — read-only |
| `usb.img` | альтернатива для флешки | `dd` / `./flash-usb.sh` | редактируется из меню |

1. Записать образ на флешку (≥512 МБ): ISO — балена-этчером как есть,
   img — `sudo dd if=usb.img of=/dev/sdX bs=4M conv=fsync status=progress`.
2. В BIOS клиента выставить загрузку с USB (boot-меню: обычно F11/F12/Esc).
3. Готово: заставка → меню → Enter на сервере → RDP.

## Использование

- **Меню**: стрелки вверх/вниз ходят по кругу «серверы → Settings → Reboot →
  PowerOff», Enter выполняет. Enter на сервере — сразу подключение. Кнопки
  продублированы F-клавишами (F5 Settings, F6 Reboot, F7 PowerOff).
- **Settings** — единый админ-раздел (при желании под паролем, см. ниже).
  Навигация стрелками и Enter, как на главном экране (`q`/Esc — назад).
  Разбит на секции:
  - **Серверы** → *Manage servers*: добавить, изменить, удалить (ncurses-экран
    с клавишами `a`/`e`/`Enter`/`d`/`q`). Пишется на флешку; на read-only
    носителе (ISO/CD) изменить нельзя.
  - **Система**: *Console* (root-bash) и *Diagnostics* (интерфейсы/IP,
    маршруты, DNS, ping до шлюза, последние ошибки RDP-сессии — без ухода в
    шелл).
  - **Сеть и RDP**: *Network* (переключить DHCP ↔ статический IP/шлюз/DNS),
    *RDP defaults* (логин/домен/автоподключение), *Printer* (URI сетевого
    принтера + имя очереди). Пишется в `tc.conf` безопасным `tc-setconf`; на
    ISO экран честно сообщает, что сохранять некуда. Сетевые изменения
    применяются после перезагрузки.
- **Управление серверами** (Settings → Manage servers): отдельный экран —
  добавить (`a` или `+ Add server`), править (`e` или Enter на
  сервере; пустое поле оставляет старое значение), удалить (`d`,
  подтверждение `y`), `q` — назад. При add/edit задаётся **протокол этого
  сервера** (`rdp`/`tls`/`nla`, пусто = авто-согласование) — виден в списке
  как `[rdp]`. Протокол привязан к серверу, глобальной настройки нет.
  Пишется на флешку; на read-only носителе (CD в VM) изменить нельзя.
- **Конфиг-раздел `TCDATA` (флешка с ISO)**: сам ISO9660 — формат
  компакт-диска, только для чтения, поэтому при **первой загрузке**
  система сама создаёт в свободном месте флешки FAT-раздел `TCDATA` и
  переносит туда стартовый `servers.conf`. Дальше и меню пишет туда, и
  руками правится: воткни флешку в комп (Linux, macOS, Windows 10+ —
  старые Windows видят только первый раздел) и отредактируй
  `servers.conf` на разделе `TCDATA` (формат `имя;ip`, `#` — комментарии).
  Повторная прошивка Этчером стирает раздел — он пересоздастся со
  стартовым списком. На usb.img конфиг лежит на его собственном
  FAT-разделе — правится так же.
- **Стартовый список** (что окажется в образе и на свежем `TCDATA`):
  `board/thinclient/servers.conf.sample`, фиксируется при сборке.
- **Конфиг `tc.conf`** (необязательный): рядом с `servers.conf` на флешке.
  Формат `KEY=значение`, файл **не исполняется** (только чтение известных
  ключей). Шаблон лежит на флешке как `tc.conf.sample` — скопируй в
  `tc.conf` и раскомментируй нужное. Ключи сейчас:
  - `RDP_USER`, `RDP_DOMAIN` — предзаполнить логин/домен в окне входа RDP
    (пароль пользователь вводит сам);
  - `RDP_EXTRA` — доп. флаги xfreerdp через пробел (напр. `/sound:sys:alsa`,
    `/bpp:32`);
  - `AUTOCONNECT=<ip|имя>` (или список через запятую — failover, пробует по
    порядку до первого живого) — киоск: при загрузке один раз сразу
    подключиться, после выхода из сессии — обычное меню.
  - `HOSTNAME=<имя>` — имя хоста вместо `tc-<mac>`.
  - `STATIC_IP=<ip/prefix>` + `GATEWAY` + `DNS` — статический адрес вместо
    DHCP (задавай тройку вместе). Пусто → DHCP на всех интерфейсах.
  - `NTP_SERVER=<ip>` — синхронизация времени (нужна для RDP-логина: NLA
    падает при кривых часах). `KEYMAP=<us|ru|…>` — раскладка консоли для
    tty2 (RDP-раскладку задавай через `RDP_EXTRA`, напр. `/kbd:...`).
  - `PRINTER=<uri>` + `PRINTER_NAME=<имя>` — **сетевой** принтер, пробрасы­
    ваемый в RDP-сессию. Клиент создаёт RAW-очередь CUPS и отдаёт её через
    `/printer`; печатает Windows своим драйвером. URI: `socket://ip:9100`
    (JetDirect, самый частый), `lpd://ip/queue`, `ipp://host/ipp/print`
    (`ipps://` — с TLS). USB-принтер со своим драйвером так не настроить —
    подключай его через принт-сервер как сетевой либо ставь драйвер на
    RDP-сервере. Все ключи `tc.conf` правятся из экрана **Settings** — файл
    руками трогать не обязательно.
- **Консоль Linux**: Settings → Console — root-шелл (bash).
- **Пароль на Settings** (опционально): по умолчанию весь раздел **без
  пароля**. Чтобы закрыть его целиком (управление серверами, сеть/RDP,
  принтер, диагностику и консоль), положи на флешку файл `shell.pass` с
  sha256-хэшем — тогда вход в Settings спросит пароль (забыл — удали файл):
  `printf '%s' 'пароль' | shasum -a 256 | cut -c1-64 > shell.pass`
- **Отладка**: tty2 (Ctrl+Alt+F2 из меню, не из RDP-сессии) — логин-консоль
  (root, тот же пароль) и весь вывод загрузки. Полный раннбук по сбоям —
  [docs/RUNBOOK.md](docs/RUNBOOK.md).
- **RDP из консоли (отладка)**: `tc-rdp <ip[:порт]> [флаги xfreerdp]` —
  собирает ту же команду, что и меню (дефолты из `tc.conf`, протокол из
  строки сервера), показывает её и TCP-проверку порта, подключается и после
  выхода печатает код возврата и хвост лога (`/tmp/tc-rdp.log`).
  `tc-rdp -n <ip>` — dry-run (только показать команду/проверки),
  `tc-rdp -v <ip>` — подробный лог FreeRDP. Запускать с локальной консоли
  (Settings → Console).
- **Правка файлов на флешке из консоли**: `tc-edit` (servers.conf) или
  `tc-edit <файл>` — сам перемонтирует rw и вернёт read-only после
  сохранения; голый nano упрётся в read-only.
- **Параметры RDP** (цветность, звук, принтеры): `tc-session` в overlay,
  см. «Структура».

## Сборка из исходников

Сборка идёт в Docker (на macOS — обязательно, Buildroot собирается только
под Linux; на Linux Docker опционален). Первый прогон 1–3 часа, дальше
инкрементально.

```sh
git clone https://github.com/Voyager305/thinclient-os && cd thinclient-os
./build.sh                 # клонирует Buildroot и собирает оба образа
./build.sh menuconfig      # покрутить конфиг Buildroot
NATIVE=1 ./build.sh        # Linux: нативная сборка без Docker
```

Результат: `buildroot/output/images/{thinclient.iso,usb.img}`.
Заливка: `./flash-usb.sh <устройство>` (macOS `/dev/diskN`, Linux `/dev/sdX`).

### Единый конфиг `site.env` — всё в одном файле

Чтобы не править конфиг по десятку файлов, есть **один** файл `site.env`:
пароли (root/user), имя пользователя, сеть, RDP-дефолты, принтер, пароль на
Settings и список серверов — всё там. `./build.sh` запекает его в образ.

```sh
cp site.env.example site.env    # шаблон со всеми ключами и комментариями
nano site.env                   # правишь ТОЛЬКО этот файл
./build.sh                      # всё уходит в образ
```

`site.env` в `.gitignore` (не коммитится). Что он задаёт:

| Ключ | Что | Куда запекается |
|---|---|---|
| `ROOT_PASSWORD` | пароль root | `/etc/shadow` |
| `USER_NAME`, `USER_PASSWORD` | юзер для SSH (+ sudo) | `/etc/shadow` |
| `SETTINGS_PASSWORD` | пароль на раздел Settings | `shell.pass` на флешке |
| `STATIC_IP`, `GATEWAY`, `DNS`, `NTP_SERVER`, `KEYMAP` | сеть/время/раскладка | `tc.conf` на флешке |
| `WAIT_FOR_IP` | ждать IP (секунды) перед показом меню; клавиша — скип | `tc.conf` на флешке |
| `RDP_USER`, `RDP_DOMAIN`, `RDP_EXTRA`, `AUTOCONNECT` | RDP-дефолты, автоконнект | `tc.conf` на флешке |
| `SERVERS` третье поле | протокол RDP сервера: `Имя=адрес;rdp` (`rdp` = без NLA/TLS, `tls`, `nla`; пусто = авто) | `servers.conf` на флешке |
| `PRINTER`, `PRINTER_NAME` | сетевой принтер | `tc.conf` на флешке |
| `SERVERS` | список серверов (`Имя=адрес`) | `servers.conf` на флешке |

Пароли — **открытым текстом** (система сама зашифрует) **или готовым хэшем**
(`$6$…` для root/user — `mkpasswd -m sha-512`; 64-hex sha256 для Settings).
Без `site.env` собирается дефолт: `user`/`1234`, стартовый сервер из
`servers.conf.sample`, root — небезопасная заглушка. Флеш-файлы (`servers.conf`,
`tc.conf`, `shell.pass`) остаются правимыми на месте — из меню Settings или
руками на флешке, `site.env` лишь задаёт стартовые значения.

Пароль root можно задать и переменной окружения (приоритетнее `site.env`):

```sh
TC_ROOT_PASSWORD='свой-пароль' ./build.sh
```

Пакеты для нативной сборки на Linux (сборочные + утилиты для post-image):

```sh
# Debian / Ubuntu
sudo apt install build-essential bc bzip2 cpio file git libncurses-dev \
    make patch perl python3 rsync unzip wget \
    dosfstools mtools parted syslinux syslinux-common isolinux xorriso

# Fedora (isolinux входит в syslinux)
sudo dnf install gcc gcc-c++ make bc bzip2 cpio file git ncurses-devel \
    patch perl python3 rsync unzip wget dosfstools mtools parted syslinux xorriso

# Arch (isolinux входит в syslinux)
sudo pacman -S --needed base-devel bc cpio file git ncurses rsync unzip wget \
    dosfstools mtools parted syslinux xorriso
```

Нюансы: не собирать под root; ~15–20 ГБ места; `-j` не указывать (Buildroot
параллелит сам); повторные чистые сборки ускоряет `BR2_CCACHE=y`. На Apple
Silicon сборка идёт в docker-томе (bind-mount VirtioFS роняет Docker Desktop
на глубоких каталогах configure-тестов), а `usb.img` дособирается коротким
amd64-шагом — всё это `build.sh` делает сам.

## Проверка без железа

- **UTM (Apple Silicon)**: Create VM → **Emulate** → Other → i386, RAM
  1024 МБ, `thinclient.iso` как CD. Сетевую карту выбрать **e1000** или
  **rtl8139** (режим Shared Network). VirtualBox на M-маках x86-гостей не
  умеет — только UTM/QEMU.
- **QEMU**: `qemu-system-i386 -m 1024 -cdrom thinclient.iso`
- **VirtualBox (x86-хост)**: VM «Other Linux (32-bit)», EFI выключен, ISO в
  CD-привод.

## Пароль root и SSH

Пароль root (SSH + логин на tty2) **не зашит** в репозиторий. Задавай при
сборке:

```sh
TC_ROOT_PASSWORD='свой-пароль' ./build.sh
```

Он впишется в образ (durable). Если переменную не задать — сборка
предупредит и оставит небезопасную заглушку из defconfig; для боевого
образа задавай пароль обязательно.

- **Сменить без пересборки**: `passwd` — эфемерно (система в RAM, сбросится
  при ребуте). **Durable-смена на флешке**: положи `root.pass` c sha512-хэшем
  (`$6$…`) на флешку — он применяется к `/etc/shadow` при каждой загрузке.
  Хэш: `openssl passwd -6` или `mkpasswd -m sha-512`.
- **Host-ключ SSH персистится** на флешке (`/mnt/flash/dropbear/`) — больше
  нет предупреждения «host key changed» на каждую загрузку. На CD (read-only)
  ключ по-прежнему в RAM (с предупреждением).
- **SSH по умолчанию парольный** на `0.0.0.0:22` — допустимо только в
  доверенной сети. **Вход по ключу**: положи `authorized_keys` на флешку.
  Чтобы выключить пароль совсем (только ключи), overlay-файл
  `etc/default/dropbear` со строкой `DROPBEAR_ARGS="-s -g"` — но у нас dropbear
  запускается своим `S53ssh`, так что проще отредактировать его.

### Непривилегированный пользователь для SSH

Для входа по SSH в образ вшит пользователь (по умолчанию **`user`**/**`1234`**)
с правом **sudo** (`/etc/sudoers.d/thinclient`). Логин: `ssh user@<ip>` →
`sudo -i` для root-прав. Имя и пароль задаются в **`site.env`**
(`USER_NAME`/`USER_PASSWORD`; см. «Единый конфиг `site.env`»), откуда `build.sh`
генерит таблицу пользователей.

> ⚠️ Дефолт `user`/`1234` — **слабый пароль**, к тому же с полным sudo это
> фактически root по SSH. Для боевого парка задай свой в `site.env` (текстом
> или хэшем) и пересобери, либо `passwd user` в рантайме (эфемерно — система в
> RAM), либо сузь права в `sudoers.d`. Не оставляй `1234` в проде.

Полноценные `useradd`/`usermod`/`userdel`/`groupadd` (пакет `shadow`) есть в
образе — админ может завести ещё юзеров в рантайме (тоже эфемерно, до ребута).

## Структура репозитория

```
site.env.example                   ЕДИНЫЙ конфиг образа (шаблон; правишь site.env)
configs/thinclient_defconfig       конфиг Buildroot (пакеты, ядро, initramfs)
package/tc-launcher/               ncurses-лаунчер (C, пакет BR2_EXTERNAL):
                                   Config.in, tc-launcher.mk, src/tc-launcher.c
patches/psplash/                   тёмная тема заставки, без логотипа
Config.in, external.mk, external.desc   объявление BR2_EXTERNAL-дерева
board/thinclient/
  linux.fragment                   конфиг ядра: графика (i915/gma500/virt),
                                   сетевухи, USB, vfat/iso9660, usblp
  syslinux.cfg                     загрузчик BIOS (NOESCAPE), консоль на tty2
  grub-efi.cfg                     загрузчик UEFI (встраивается в bootX.efi)
  servers.conf.sample              стартовый список серверов (дефолт без site.env)
  post-build.sh                    чистка target (автозапуск X и т.п.), права sudoers.d
  post-image.sh                    сборка usb.img (MBR+FAT32) и hybrid ISO+EFI
  rootfs-overlay/
    etc/inittab                    tc-menu на tty1, getty на tty2
    etc/sudoers.d/thinclient       user -> sudo (0440 root:root)
    etc/X11/xorg.conf.d/10-video.conf  X через modesetting(KMS) + DontVTSwitch/DontZap
    etc/init.d/S00splash           заставка psplash
    etc/init.d/S02watchdog         сторож /dev/watchdog (если есть)
    etc/init.d/S35console          консольные шрифты (кириллица)
    etc/init.d/S50flash            носитель конфигов: поиск/создание TCDATA
    etc/init.d/S51network          сеть: hostname, DHCP/статика (tc-netup)
    etc/init.d/S52tcconf           tc.conf: раскладка, NTP, durable-пароль
    etc/init.d/S53ssh              dropbear: host-key/ключи на TCDATA
    etc/init.d/S82printer          сетевой принтер из tc.conf (RAW CUPS)
    etc/init.d/S98splashdone       гасит заставку перед меню
    etc/profile.d/tc-prompt.sh     промпт user@host:cwd
    root/.bash_profile, .bashrc, .vimrc   окружение root-консоли
    usr/bin/tc-menu                обёртка: исполняет выбор, весь раздел Settings
    usr/bin/tc-edit                правка файлов на флешке (rw→edit→ro)
    usr/bin/tc-rdp                 RDP из консоли для отладки (-n dry, -v verbose)
    usr/bin/tc-getconf             безопасное чтение ключа tc.conf (без eval)
    usr/bin/tc-setconf             безопасная запись ключа tc.conf (экран Settings)
    usr/bin/tc-netup               идемпотентный подъём сети
    usr/bin/tc-session             запуск xfreerdp внутри X
build.sh                           сборка (Docker/нативно), TC_ROOT_PASSWORD
flash-usb.sh                       заливка usb.img на флешку (macOS/Linux)
tools/provision.sh                 тираж: залить + засеять конфиг площадки
.github/workflows/ci.yml           CI: sh -n скриптов + компиляция лаунчера
Dockerfile                         окружение сборки (Buildroot + host-утилиты)
docs/RUNBOOK.md                    инструкции по всем сбоям/отказам
LICENSE                            MIT
```

## Поддерживаемое железо

Примерный список того, что работает нативно. Система собрана под i686 и
запускается на любом x86-процессоре — и 32-, и 64-битном (переключение
сборки на `BR2_x86_64=y` выигрыша почти не даёт).

**Загрузка**
| Способ | Чем | Примечание |
|---|---|---|
| Legacy BIOS / CSM | syslinux, isolinux | любые машины с 2000-х |
| UEFI x64 | grub-efi (bootx64) | современные ПК, CSM не нужен |
| UEFI ia32 | grub-efi (bootia32) | планшетно-неттопные Atom (Bay Trail и т.п.) |

**Видео (нативное разрешение через KMS)**
| Семейство | Драйвер | Примеры |
|---|---|---|
| Intel встройка | i915 | GMA 900/950/3100/3150/4500, HD Graphics — атомные неттопы и десктопные чипсеты (в т.ч. Atom D525/Pineview) |
| Intel Poulsbo/Cedar Trail | gma500 | GMA 500/600/3600/3650 (N2600/N2800/D2500/D2700), без ускорения |
| NVIDIA | nouveau | GeForce 6xxx … GTX 7xx полноценно; новее — вывод без ускорения |
| AMD (старые) | radeon | Radeon от R300 до HD 8xxx (до GCN 1-го поколения) |
| Виртуалки | bochs/cirrus/vmwgfx/virtio | QEMU/UTM, VirtualBox, VMware |
| Всё остальное | VESA 1024x768 | fallback на BIOS; под UEFI — GOP в нативном разрешении |

**Сеть (проводная)**: Intel (e100, e1000/e1000e, igb, igc), Realtek
(RTL8139, RTL8169/8168 + прошивки), Broadcom (tg3), Atheros/Qualcomm
(atl1c, atl1e, alx), Marvell (sky2, skge), VIA Rhine, nForce (forcedeth),
AMD PCnet, virtio-net. **USB-ethernet**: Realtek r8152/8153, ASIX
(AX88172…AX88179), CDC Ethernet — типовые «свистки».

**Прочее**: USB 1.1/2.0/3.x (OHCI/UHCI/EHCI/XHCI), встроенные SD-ридеры
(SDHCI), USB-принтеры (usblp + CUPS), клавиатуры PS/2 и USB. RAM — от
512 МБ. Wi-Fi нет сознательно — тонкий клиент живёт на проводе.

Если железки нет в списке — скорее всего она всё равно заведётся через
VESA-fallback; если не завелась сеть — воткни USB-ethernet свисток из
списка выше.

## Тонкости

- **Secure Boot не поддержан.** Загрузчик (grub-efi) не подписан — на ПК с
  включённым Secure Boot образ не загрузится. Отключи SB в прошивке или
  используй legacy/CSM. Подпись shim — в планах.
- **RDP только в доверенной LAN.** В `tc-session` стоит `/cert:ignore`
  (серт сервера не проверяется), а ответам DHCP система доверяет как есть —
  в недоверенной сети возможен перехват учёток (rogue DHCP + подмена
  сервера). Строгий режим (CA-серт + проверка DHCP) — в планах. 2008 R2 …
  2022 работают из коробки; голому 2008 (не R2) без апдейтов нужен TLS 1.2
  на сервере (KB4019276).
- **Загрузчик заперт.** `NOESCAPE 1` в syslinux убирает интерактивный
  `boot:` (иначе можно было набрать `init=/bin/sh` и получить root). Побочно
  исчезла правка cmdline на лету — recovery чёрного экрана теперь только
  редактированием `syslinux.cfg` на загрузочном разделе с другого
  компьютера (см. Траблшутинг / RUNBOOK).

## Траблшутинг

Топ-частых ниже. **Полный раннбук (~40+ сценариев, включая молчаливые
сбои) — [docs/RUNBOOK.md](docs/RUNBOOK.md).** Две диагностические
поверхности: **tty2** (Ctrl+Alt+F2 из меню) для boot/init и
`/var/log/xsession.log` для RDP-сессии.

| Симптом | Причина / решение |
|---|---|
| BIOS не видит флешку | Режим USB-HDD в BIOS, отключить «USB legacy floppy» |
| Чёрный экран после загрузчика | Воткни флешку в другой комп и убери `vga=791` из APPEND в `syslinux.cfg` на загрузочном разделе (правка на лету отключена `NOESCAPE`) |
| В углу `thinclient  no ip` | Нет сетевухи/драйвера или молчит DHCP: в VM выбери e1000/rtl8139; на железе `ip a` и `udhcpc -i eth0 -nq` на tty2 |
| Меню не появилось | Ctrl+Alt+F2 → логи загрузки на tty2 |
| ssh предупреждает о смене host-ключа | Норма: система в RAM, ключ генерится на каждую загрузку |
| RDP не подключается | Экран ошибки показывает причину; на tty2: `ping <сервер>`, `tcpdump -i eth0 port 3389`; лог `/var/log/xsession.log` |

## Лицензия

[MIT](LICENSE). Патчи в `patches/` наследуют лицензии патчуемых пакетов;
состав лицензий собранного образа — `make legal-info` в Buildroot.
