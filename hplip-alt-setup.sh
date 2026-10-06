#!/bin/bash
# Автоматическая установка HPLIP и настройка подключённого принтера HP
# для ALT Linux 9 (p9). Запуск: sudo ./hplip-alt-setup.sh [--plugin] [--default]
#   --plugin   дополнительно скачать и поставить проприетарный плагин HP (hp-plugin)
#   --default  сделать найденный принтер принтером по умолчанию
# Если какой-то шаг не удался, скрипт пробует альтернативные способы (см. "fallback").
set -u

HPLIP_VER="${HPLIP_VER:-3.24.4}"   # версия для запасной сборки из исходников
PLUGIN=0
DEFAULT=0
for a in "$@"; do
    case "$a" in
        --plugin)  PLUGIN=1 ;;
        --default) DEFAULT=1 ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "Неизвестный параметр: $a"; exit 1 ;;
    esac
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0"
have apt-get || die "apt-get не найден."
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *alt*) ;;
        *) warn "Система не похожа на ALT Linux (${PRETTY_NAME:-?}), продолжаю на свой риск." ;;
    esac
fi

WORK=$(mktemp -d) && trap 'rm -rf "$WORK"' EXIT

# Повтор команды до 3 раз (сеть бывает нестабильной)
retry() { local i; for i in 1 2 3; do "$@" && return 0; sleep 3; done; return 1; }

# Ставит из репозитория только существующие пакеты
install_pkgs() {
    local list=() p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then list+=("$p"); else warn "Пакет $p не найден, пропускаю."; fi
    done
    [ ${#list[@]} -gt 0 ] || return 1
    apt-get install -y "${list[@]}" || apt-get install -y --fix-broken "${list[@]}"
}

# --- 1. Установка пакетов -------------------------------------------------
log "Обновление списков пакетов..."
retry apt-get update || warn "apt-get update не удался (проверьте сеть/репозитории)."

log "Установка CUPS и зависимостей..."
install_pkgs cups cups-filters ghostscript libusb usbutils python3-module-dbus avahi cups-browsed \
    || warn "Часть базовых пакетов не установилась."

if ! have hp-setup; then
    log "Установка HPLIP из репозитория..."
    install_pkgs hplip hplip-common hplip-ppds hplip-hpijs hplip-sane hplip-gui hplip-doc \
        || warn "Установка hplip из репозитория не удалась."
fi

# fallback 1: полная пересинхронизация и повтор
if ! have hp-setup; then
    warn "Fallback: исправляю зависимости и пробую ещё раз..."
    apt-get -f install -y; retry apt-get update; apt-get install -y hplip
fi

# fallback 2: сборка HPLIP из исходников
if ! have hp-setup; then
    warn "Fallback: сборка HPLIP $HPLIP_VER из исходников с SourceForge..."
    install_pkgs gcc gcc-c++ make libcups-devel libusb-devel libsane-devel libdbus-devel \
        python3-devel python3-module-pip libnet-snmp-devel libssl-devel libcups libjpeg-devel
    URL="https://downloads.sourceforge.net/project/hplip/hplip/$HPLIP_VER/hplip-$HPLIP_VER.tar.gz"
    if retry curl -fsSL -o "$WORK/hplip.tar.gz" "$URL" || retry wget -q -O "$WORK/hplip.tar.gz" "$URL"; then
        tar -xzf "$WORK/hplip.tar.gz" -C "$WORK" &&
        ( cd "$WORK/hplip-$HPLIP_VER" &&
          ./configure --prefix=/usr --enable-hpcups-install --enable-cups-drv-install \
              --disable-qt4 --disable-qt5 --disable-fax-build --disable-doc-build \
              --disable-network-build >"$WORK/conf.log" 2>&1 &&
          make -j"$(nproc)" >"$WORK/make.log" 2>&1 && make install >>"$WORK/make.log" 2>&1 ) \
            || { warn "Сборка не удалась. Логи: /var/log/hplip-build-*.log"
                 cp "$WORK/conf.log" /var/log/hplip-build-configure.log 2>/dev/null
                 cp "$WORK/make.log" /var/log/hplip-build-make.log 2>/dev/null; }
    else
        warn "Не удалось скачать исходники HPLIP."
    fi
fi

if have hp-setup; then
    HPLIP_OK=1
else
    HPLIP_OK=0
    warn "HPLIP установить не удалось — дальше попробую печать без него (драйверы CUPS/IPP Everywhere)."
fi

# --- 2. Служба печати -----------------------------------------------------
log "Запуск CUPS..."
start_cups() {
    systemctl enable --now cups.service 2>/dev/null && return 0
    systemctl enable --now cupsd.service 2>/dev/null && return 0
    service cups start 2>/dev/null && return 0
    service cupsd start 2>/dev/null && return 0
    have cupsd && { cupsd 2>/dev/null; return 0; }   # fallback: запуск напрямую
    return 1
}
start_cups || die "Не удалось запустить CUPS."
for _ in 1 2 3 4 5; do lpstat -r 2>/dev/null | grep -q 'is running' && break; sleep 1; done
have avahi-daemon && systemctl enable --now avahi-daemon.service 2>/dev/null

# --- 3. Плагин (по желанию) -----------------------------------------------
if [ "$PLUGIN" -eq 1 ] && [ "$HPLIP_OK" -eq 1 ]; then
    log "Установка плагина HP (нужен интернет)..."
    hp-plugin -i --required --accept 2>&1 \
        || hp-plugin -i --required -g 2>&1 \
        || warn "Плагин не установился (повторите вручную: hp-plugin -i)."
fi

# --- 4. Поиск принтера ----------------------------------------------------
log "Поиск подключённых принтеров..."
lsusb 2>/dev/null | grep -i 'hewlett\|hp' || true
find_uris() {
    local u=""
    [ "$HPLIP_OK" -eq 1 ] && u=$(hp-makeuri -l 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    [ -z "$u" ] && u=$(lpinfo -v 2>/dev/null | awk '$2 ~ /^hp:\// {print $2}' | sort -u)
    [ -z "$u" ] && [ "$HPLIP_OK" -eq 1 ] && u=$(hp-probe -b usb 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    [ -z "$u" ] && [ "$HPLIP_OK" -eq 1 ] && u=$(hp-probe -b net 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    # fallback: стандартные бэкенды CUPS (usb://, dnssd://, ipp://, socket://) с маркой HP
    [ -z "$u" ] && u=$(lpinfo -l -v 2>/dev/null | awk '/^Device:/{uri=$3} /make-and-model/ && tolower($0) ~ /hp|hewlett/ {print uri}' | sort -u)
    [ -z "$u" ] && u=$(lpinfo -v 2>/dev/null | awk '$2 ~ /^(usb|dnssd|ipp|socket):\// && tolower($2) ~ /hp|hewlett/ {print $2}' | sort -u)
    echo "$u"
}
URIS=$(find_uris)
if [ -z "$URIS" ]; then
    warn "Принтер не найден, перезапускаю CUPS и пробую ещё раз..."
    systemctl restart cups.service 2>/dev/null || service cups restart 2>/dev/null
    sleep 4; URIS=$(find_uris)
fi
[ -n "$URIS" ] || die "Принтер HP не найден. Проверьте USB-кабель/питание/сеть и запустите скрипт снова."

# --- 5. Настройка (цепочка запасных способов) ---------------------------
exists() { lpstat -p "$1" >/dev/null 2>&1; }

setup_hp_setup() { [ "$HPLIP_OK" -eq 1 ] && [[ "$2" == hp:* ]] && hp-setup -i -a -x -p "$1" "$2" >/dev/null 2>&1 && exists "$1"; }
setup_hp_ppd() {  # PPD из HPLIP по названию модели
    local model ppd
    model=$(echo "$2" | sed -E 's#^[a-z]+:/+[^/]*/##; s#\?.*##; s#[_%20]# #g')
    ppd=$(lpinfo -m 2>/dev/null | awk -v m="$model" 'BEGIN{IGNORECASE=1} index($0,m){print $1; exit}')
    [ -n "$ppd" ] && lpadmin -p "$1" -E -v "$2" -m "$ppd" 2>/dev/null && exists "$1"
}
setup_everywhere() { lpadmin -p "$1" -E -v "$2" -m everywhere 2>/dev/null && exists "$1"; }
setup_hp_generic() {
    local ppd
    ppd=$(lpinfo -m 2>/dev/null | awk '/hp-laserjet|hp-deskjet|hpcups|laserjet/ {print $1; exit}')
    [ -n "$ppd" ] && lpadmin -p "$1" -E -v "$2" -m "$ppd" 2>/dev/null && exists "$1"
}
setup_generic() {  # последний вариант: универсальные драйверы
    local m
    for m in drv:///cupsfilters.drv/pcl.ppd drv:///sample.drv/generic.ppd drv:///cupsfilters.drv/pwgrast.ppd raw; do
        lpadmin -p "$1" -E -v "$2" -m "$m" 2>/dev/null && exists "$1" && return 0
    done
    return 1
}

FIRST=""
while read -r URI; do
    [ -n "$URI" ] || continue
    NAME=$(echo "$URI" | sed -E 's#^[a-z]+:/+[^/]*/?##; s#\?.*##; s#[^A-Za-z0-9_-]#_#g')
    [ -n "$NAME" ] || NAME="HP_Printer_$RANDOM"
    if exists "$NAME"; then log "Принтер $NAME уже настроен."; FIRST=${FIRST:-$NAME}; continue; fi
    DONE=0
    for method in setup_hp_setup setup_hp_ppd setup_everywhere setup_hp_generic setup_generic; do
        log "Настройка $NAME ($URI): способ $method"
        if $method "$NAME" "$URI"; then DONE=1; log "Успешно: $method"; break; fi
        lpadmin -x "$NAME" 2>/dev/null
    done
    [ "$DONE" -eq 1 ] || { warn "Не удалось настроить $URI ни одним способом."; continue; }
    cupsenable "$NAME" 2>/dev/null; cupsaccept "$NAME" 2>/dev/null
    FIRST=${FIRST:-$NAME}
done <<< "$URIS"

[ -n "$FIRST" ] || die "Ни один принтер настроить не удалось."
if [ "$DEFAULT" -eq 1 ] || ! lpstat -d 2>/dev/null | grep -q ': *[A-Za-z]'; then
    lpoptions -d "$FIRST" >/dev/null 2>&1 && log "Принтер по умолчанию: $FIRST"
fi

# --- 6. Доступ для пользователя ------------------------------------------
if getent group lp >/dev/null && [ -n "${SUDO_USER:-}" ]; then usermod -aG lp "$SUDO_USER" 2>/dev/null; fi

# --- 7. Тестовая страница (с запасным вариантом) -------------------------
read -r -p "Напечатать тестовую страницу на $FIRST? [y/N] " ans
if [[ "$ans" =~ ^[YyДд] ]]; then
    TEST=""
    for f in /usr/share/cups/data/testprint /usr/share/cups/data/testprint.ps; do [ -f "$f" ] && { TEST=$f; break; }; done
    if [ -z "$TEST" ]; then TEST="$WORK/test.txt"; echo "HPLIP test page: $(date)" > "$TEST"; fi
    lp -d "$FIRST" "$TEST" || warn "Печать не удалась. Проверьте: lpstat -t; tail /var/log/cups/error_log"
fi

log "Готово. Состояние:"
lpstat -t
