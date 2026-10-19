#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Релиз KoscheiOS одной командой: чистая сборка (без site.env), проверка, что в
# образе нет секретов площадки, legal-info, тег, GitHub Release с ассетами.
#
#   tools/release.sh v1.4.1            # полноценный релиз
#   tools/release.sh v1.4.1-rc2 --pre  # pre-release
#   NOTES=notes.md tools/release.sh ...# свои release notes (иначе — из git log)
#
# В релиз кладётся ТОЛЬКО usb.img (+ SHA256SUMS, legal-manifest.csv,
# legal-licenses.tar.gz). ISO — локальный артефакт для виртуалок.
# Авторизация — GitHub device flow: скрипт печатает код, ты вводишь его на
# https://github.com/login/device; токен живёт в памяти процесса и нигде не
# сохраняется. Пароли в argv не передаются.
set -eu
cd "$(dirname "$0")/.."

VER=${1:-}; PRE=false
[ -n "$VER" ] || { echo "usage: tools/release.sh vX.Y.Z[-rcN] [--pre]"; exit 1; }
[ "${2:-}" = "--pre" ] && PRE=true
REPO=${REPO:-elmarl0w/koschei-os}
CLIENT_ID=178c6fc778ccc68e1d6a    # GitHub CLI public client id (device flow)
IMG=buildroot/output/images
REL="${TMPDIR:-/tmp}/koschei-release-$VER"

say() { printf '>>> %s\n' "$*"; }
die() { printf '!!! %s\n' "$*" >&2; exit 1; }
json() { python3 -c "import sys,json; d=json.loads(sys.stdin.buffer.read().decode('utf-8'),strict=False); print($1)"; }

# --- 0. дерево чистое, тег свободен
[ -z "$(git status --short)" ] || die "рабочее дерево не чистое — закоммить или stash"
git rev-parse -q --verify "refs/tags/$VER" >/dev/null && die "тег $VER уже есть"
BRANCH=$(git rev-parse --abbrev-ref HEAD); say "ветка $BRANCH, коммит $(git rev-parse --short HEAD)"

# --- 1. чистая сборка: site.env на время убираем (trap вернёт при любом исходе)
restore() { [ -f "$REL.site.env" ] && mv "$REL.site.env" site.env && say "site.env восстановлен"; }
trap restore EXIT INT TERM
mkdir -p "$(dirname "$REL")"
if [ -f site.env ]; then mv site.env "$REL.site.env"; say "site.env отложен — сборка чистая"; fi
git tag -a "$VER" -m "$VER"       # до сборки: версия в образе берётся из git describe
say "сборка..."; ./build.sh >"$REL.build.log" 2>&1 || { tail -20 "$REL.build.log"; git tag -d "$VER"; die "сборка упала (лог: $REL.build.log)"; }
restore; trap - EXIT INT TERM

# --- 2. проверка чистоты образа
say "проверка образа"
command -v mtype >/dev/null 2>&1 || die "нужен mtools (brew install mtools)"
export MTOOLS_SKIP_CHECK=1
mtype -i "$IMG/usb.img@@1M" ::/tc.conf    >/dev/null 2>&1 && die "в образе tc.conf — сборка не чистая"
mtype -i "$IMG/usb.img@@1M" ::/shell.pass >/dev/null 2>&1 && die "в образе shell.pass — сборка не чистая"
W=$(mktemp -d "${TMPDIR:-/tmp}/kos.XXXX"); gunzip -c "$IMG/rootfs.cpio.gz" | ( cd "$W" && cpio -idm --quiet 2>/dev/null )
IMGVER=$(cat "$W/etc/tc-release"); [ "$IMGVER" = "$VER" ] || die "версия в образе $IMGVER != $VER"
[ -f site.env ] && for v in $(grep -hE '^(RDP_USER|USER_NAME|NTP_SERVER)=' site.env | cut -d= -f2 | tr -d '"' | grep -vE '^(tcadmin|)$'); do
    grep -rq -- "$v" "$W/etc" && die "в образе значение из site.env: $v"; done
rm -rf "$W"; say "образ чистый, версия $IMGVER"

# --- 3. ассеты + legal-info
rm -rf "$REL"; mkdir -p "$REL"; cp "$IMG/usb.img" "$REL/"
( cd "$REL" && shasum -a 256 usb.img > SHA256SUMS.txt )
say "legal-info..."
docker run --rm -v "$PWD:/src" -v thinclient-output:/build -w /src/buildroot thinclient-build \
  sh -c 'make -C /src/buildroot O=/build BR2_EXTERNAL=/src legal-info >/dev/null 2>&1 && mkdir -p /src/buildroot/output/images/legal && cp /build/legal-info/manifest.csv /src/buildroot/output/images/legal/ && tar -C /build/legal-info -czf /src/buildroot/output/images/legal/licenses.tar.gz licenses' \
  || die "legal-info не собрался"
cp "$IMG/legal/manifest.csv" "$REL/legal-manifest.csv"; cp "$IMG/legal/licenses.tar.gz" "$REL/legal-licenses.tar.gz"
ls -la "$REL"

# --- 4. release notes
if [ -n "${NOTES:-}" ]; then cp "$NOTES" "$REL/notes.md"
else
  PREV=$(git describe --tags --abbrev=0 "$VER^" 2>/dev/null || true)
  { printf '## %s\n\n' "$VER"; $PRE && printf '_pre-release_\n\n'
    [ -n "$PREV" ] && printf 'Изменения с %s:\n\n' "$PREV"
    git log --no-merges --format='- %s' "${PREV:+$PREV..}$VER"
    printf '\n**Состав:** `usb.img` + SHA256 + legal-info. ISO в релизы не входит.\n'; } > "$REL/notes.md"
fi

# --- 5. тег в origin, затем GitHub Release
git push origin "$VER"
say "авторизация GitHub (device flow)"
DF=$(curl -sf -X POST -H "Accept: application/json" -d "client_id=$CLIENT_ID&scope=repo" https://github.com/login/device/code)
DC=$(printf '%s' "$DF" | json "d['device_code']"); UC=$(printf '%s' "$DF" | json "d['user_code']")
printf '\n   Открой https://github.com/login/device и введи код:  %s\n\n' "$UC"
TOKEN=""
while [ -z "$TOKEN" ]; do
  sleep 5
  R=$(curl -s -X POST -H "Accept: application/json" -d "client_id=$CLIENT_ID&device_code=$DC&grant_type=urn:ietf:params:oauth:grant-type:device_code" https://github.com/login/oauth/access_token)
  TOKEN=$(printf '%s' "$R" | json "d.get('access_token','')")
  printf '%s' "$R" | grep -q expired_token && die "код истёк — запусти снова"
done
AUTH="Authorization: token $TOKEN"
BODY=$(python3 - "$REL/notes.md" "$VER" "$PRE" <<'PY'
import json,sys; print(json.dumps({"tag_name":sys.argv[2],"name":sys.argv[2]+(" (pre-release)" if sys.argv[3]=="true" else ""),"body":open(sys.argv[1]).read(),"draft":False,"prerelease":sys.argv[3]=="true"}))
PY
)
RID=$(printf '%s' "$BODY" | curl -s -X POST -H "$AUTH" -H "Accept: application/vnd.github+json" -d @- "https://api.github.com/repos/$REPO/releases" | json "d.get('id','') or d.get('message','')")
case "$RID" in ''|*[!0-9]*) die "release не создан: $RID" ;; esac
say "release id $RID, заливаю ассеты"
for f in usb.img SHA256SUMS.txt legal-manifest.csv legal-licenses.tar.gz; do
  st=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" --data-binary @"$REL/$f" \
       "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$f" | json "d.get('state', d.get('message','?'))")
  printf '    %-24s %s\n' "$f" "$st"
done
curl -s -H "$AUTH" "https://api.github.com/repos/$REPO/releases/$RID" | json "d['html_url']"
TOKEN=""; AUTH=""
say "готово"
