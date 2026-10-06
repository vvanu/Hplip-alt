#!/bin/bash
# Автоматическая установка HPLIP и настройка подключённого принтера HP
# для ALT Linux 9 (p9).
#
#   sudo ./hplip-alt-setup.sh [параметры]
#     --plugin       сразу поставить проприетарный плагин HP (иначе он ставится
#                    автоматически, только если без него настройка не удалась)
#     --ip АДРЕС     настроить сетевой принтер по IP (в дополнение к найденным)
#     --default      сделать принтер по умолчанию
#     --test         напечатать тестовую страницу без вопроса
#     --no-gui       не ставить графические пакеты (hplip-gui)
#
# Если шаг не удался, скрипт пробует альтернативы. Журнал: /var/log/hplip-alt-setup.log
set -u

HPLIP_VER="${HPLIP_VER:-3.24.4}"   # версия для запасной сборки из исходников
LOG=/var/log/hplip-alt-setup.log
PLUGIN=0; DEFAULT=0; TEST=0; GUI=1; EXTRA_IP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plugin)  PLUGIN=1 ;;
        --default) DEFAULT=1 ;;
        --test)    TEST=1 ;;
        --no-gui)  GUI=0 ;;
        --ip)      shift; EXTRA_IP="${1:-}" ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Неизвестный параметр: $1"; exit 1 ;;
    esac
    shift
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0"
exec > >(tee -a "$LOG") 2>&1
log "Журнал: $LOG ($(date))"

have apt-get || die "apt-get не найден."
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *alt*) ;;
        *) warn "Система не похожа на ALT Linux (${PRETTY_NAME:-?}), продолжаю на свой риск." ;;
    esac
fi

WORK=$(mktemp -d) && trap 'rm -rf "$WORK"' EXIT
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
log "Проверка сети и обновление списков пакетов..."
retry apt-get update || warn "apt-get update не удался (проверьте сеть/репозитории: apt-repo list)."

log "Установка CUPS и зависимостей..."
install_pkgs cups cups-filters ghostscript libusb usbutils python3-module-dbus avahi cups-browsed \
    || warn "Часть базовых пакетов не установилась."

if ! have hp-setup; then
    log "Установка HPLIP из репозитория..."
    install_pkgs hplip hplip-common hplip-ppds hplip-hpijs hplip-sane \
        || warn "Установка hplip из репозитория не удалась."
fi
# Подхватываем реальные имена пакетов hplip из репозитория (на случай, если названия отличаются)
if have apt-cache; then
    EXTRA_PKGS=$(apt-cache search -n hplip 2>/dev/null | awk '{print $1}' \
        | grep -Ev 'debuginfo|devel|doc|gui|qt|^lib' | tr '\n' ' ')
    # shellcheck disable=SC2086
    [ -n "$EXTRA_PKGS" ] && apt-get install -y $EXTRA_PKGS >/dev/null 2>&1
fi
[ "$GUI" -eq 1 ] && install_pkgs hplip-gui >/dev/null 2>&1

# fallback 1: исправление зависимостей и повтор
if ! have hp-setup; then
    warn "Fallback: исправляю зависимости и пробую ещё раз..."
    apt-get -f install -y; retry apt-get update; apt-get install -y hplip
fi

# fallback 2: сборка из исходников
if ! have hp-setup; then
    warn "Fallback: сборка HPLIP $HPLIP_VER из исходников с SourceForge..."
    install_pkgs gcc gcc-c++ make libcups-devel libusb-devel libsane-devel libdbus-devel \
        python3-devel libnet-snmp-devel libssl-devel libjpeg-devel
    URL="https://downloads.sourceforge.net/project/hplip/hplip/$HPLIP_VER/hplip-$HPLIP_VER.tar.gz"
    if retry curl -fsSL -o "$WORK/hplip.tar.gz" "$URL" || retry wget -q -O "$WORK/hplip.tar.gz" "$URL"; then
        tar -xzf "$WORK/hplip.tar.gz" -C "$WORK" &&
        ( cd "$WORK/hplip-$HPLIP_VER" &&
          ./configure --prefix=/usr --enable-hpcups-install --enable-cups-drv-install \
              --disable-qt4 --disable-qt5 --disable-fax-build --disable-doc-build \
              --disable-network-build >"$WORK/conf.log" 2>&1 &&
          make -j"$(nproc)" >"$WORK/make.log" 2>&1 && make install >>"$WORK/make.log" 2>&1 ) \
            || { warn "Сборка не удалась, логи: /var/log/hplip-build-*.log"
                 cp "$WORK/conf.log" /var/log/hplip-build-configure.log 2>/dev/null
                 cp "$WORK/make.log" /var/log/hplip-build-make.log 2>/dev/null; }
    else
        warn "Не удалось скачать исходники HPLIP."
    fi
fi

if have hp-setup; then HPLIP_OK=1; else
    HPLIP_OK=0
    warn "HPLIP установить не удалось — продолжаю без него (драйверы CUPS / IPP Everywhere)."
fi

# --- 2. Права на USB и служба печати ------------------------------------
# Правила udev из hplip применяются только после перезагрузки udev
if have udevadm; then udevadm control --reload-rules 2>/dev/null; udevadm trigger --subsystem-match=usb 2>/dev/null; fi

log "Запуск CUPS..."
start_cups() {
    systemctl enable --now cups.service 2>/dev/null && return 0
    systemctl enable --now cupsd.service 2>/dev/null && return 0
    service cups start 2>/dev/null && return 0
    service cupsd start 2>/dev/null && return 0
    have cupsd && { cupsd 2>/dev/null; return 0; }
    return 1
}
start_cups || die "Не удалось запустить CUPS."
for _ in 1 2 3 4 5 6 7 8; do lpstat -r 2>/dev/null | grep -q 'is running' && break; sleep 1; done
have avahi-daemon && systemctl enable --now avahi-daemon.service 2>/dev/null

# --- 3. Плагин HP ------------------------------------------------------
PLUGIN_DONE=0
install_plugin() {
    [ "$HPLIP_OK" -eq 1 ] && [ "$PLUGIN_DONE" -eq 0 ] || return 1
    log "Скачивание и установка плагина HP (нужен интернет)..."
    # плагин интерактивно спрашивает согласие с лицензией -> отвечаем «y»
    if yes | timeout 600 hp-plugin -i --required >"$WORK/plugin.log" 2>&1 \
       || yes | timeout 600 hp-plugin -i >"$WORK/plugin.log" 2>&1; then
        PLUGIN_DONE=1; log "Плагин установлен."; return 0
    fi
    warn "Плагин не установился: $(tail -n 3 "$WORK/plugin.log" | tr '\n' ' ')"
    return 1
}
[ "$PLUGIN" -eq 1 ] && install_plugin

# --- 4. Поиск принтера (с ожиданием) ------------------------------------
find_uris() {
    local u=""
    [ "$HPLIP_OK" -eq 1 ] && u=$(hp-makeuri -l 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    [ -z "$u" ] && u=$(lpinfo -v 2>/dev/null | awk '$2 ~ /^hp:\// {print $2}' | sort -u)
    [ -z "$u" ] && [ "$HPLIP_OK" -eq 1 ] && u=$(hp-probe -b usb 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    [ -z "$u" ] && [ "$HPLIP_OK" -eq 1 ] && u=$(hp-probe -b net 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
    # fallback: стандартные бэкенды CUPS
    [ -z "$u" ] && u=$(lpinfo -v 2>/dev/null | awk '$2 ~ /^(usb|dnssd|ipp|socket):\// && tolower($2) ~ /hp|hewlett/ {print $2}' | sort -u)
    echo "$u"
}

log "Поиск принтеров (убедитесь, что принтер включён и подключён)..."
lsusb 2>/dev/null | grep -i 'hewlett\|hp' || warn "В lsusb нет устройств HP (для сетевого принтера это нормально)."
URIS=""
for attempt in 1 2 3 4; do
    URIS=$(find_uris); [ -n "$URIS" ] && break
    warn "Принтер не найден (попытка $attempt/4), жду и перезапускаю CUPS..."
    systemctl restart cups.service 2>/dev/null || service cups restart 2>/dev/null
    sleep 5
done
# Принтер указан вручную по IP: пробуем разные протоколы
if [ -n "$EXTRA_IP" ]; then
    URIS="$URIS
hp:/net/HP_Network_Printer?ip=$EXTRA_IP
ipp://$EXTRA_IP/ipp/print
socket://$EXTRA_IP:9100"
fi
URIS=$(echo "$URIS" | sed '/^$/d' | awk '!s[$0]++')
[ -n "$URIS" ] || die "Принтер не найден. Проверьте кабель/питание/сеть или укажите --ip АДРЕС. Подробности: $LOG"

# Альтернативные URI тех же устройств (usb://, dnssd://, ipp://) для запасных способов
ALT_URIS=$(lpinfo -v 2>/dev/null | awk '{print $2}' | grep -E '^(usb|dnssd|ipp|socket)://' | grep -iE 'hp|hewlett' | sort -u)

# --- 5. Настройка (цепочка запасных способов) ---------------------------
exists() { lpstat -p "$1" >/dev/null 2>&1; }
# Очередь считается рабочей, если она существует и не отключена
healthy() { exists "$1" && cupsenable "$1" 2>/dev/null; cupsaccept "$1" 2>/dev/null; exists "$1" && ! lpstat -p "$1" 2>/dev/null | grep -qi 'disabled'; }
queues() { lpstat -v 2>/dev/null | awk '{print $3}' | tr -d ':' | sort; }

model_of() { echo "$1" | sed -E 's#^[a-z]+:/+[^/]*/?##; s#\?.*##; s/%20/ /g; s/_/ /g'; }
# Подбор PPD по названию модели
find_ppd() {
    local m ppd
    m=$(model_of "$1"); [[ "${m,,}" == hp* ]] || m="HP $m"
    ppd=$(lpinfo --make-and-model "$m" -m 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ppd" ] && ppd=$(lpinfo -m 2>/dev/null | awk -v m="${m#HP }" 'BEGIN{IGNORECASE=1} index($0,m){print $1; exit}')
    echo "$ppd"
}

# способ 1: штатный мастер HPLIP (сам подбирает драйвер); при отказе — ставит плагин и повторяет
m_hp_setup() {   # $1 имя, $2 URI
    [ "$HPLIP_OK" -eq 1 ] && [[ "$2" == hp:* ]] || return 1
    local before after arg
    before=$(queues)
    if [[ "$2" == *"ip="* ]]; then arg=$(echo "$2" | sed -E 's/.*ip=([^&]+).*/\1/'); else arg="-b usb"; fi
    # shellcheck disable=SC2086
    yes | timeout 300 hp-setup -i -a $arg >"$WORK/hpsetup.log" 2>&1
    after=$(queues)
    if [ "$before" = "$after" ] && grep -qi 'plugin' "$WORK/hpsetup.log" && install_plugin; then
        # shellcheck disable=SC2086
        yes | timeout 300 hp-setup -i -a $arg >"$WORK/hpsetup.log" 2>&1
        after=$(queues)
    fi
    [ "$before" != "$after" ] || return 1
    NEWQ=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
    [ -n "$NEWQ" ] && healthy "$NEWQ"
}
# способ 2: драйвер HPLIP (PPD) по названию модели
m_hp_ppd()     { local p; p=$(find_ppd "$2"); [ -n "$p" ] && lpadmin -p "$1" -E -v "$2" -m "$p" 2>/dev/null && healthy "$1"; }
# способ 3: IPP Everywhere (драйверов не нужно, современные принтеры)
m_everywhere() { lpadmin -p "$1" -E -v "$2" -m everywhere 2>/dev/null && healthy "$1"; }
# способ 4: любой подходящий HP-драйвер
m_hp_generic() {
    local p
    p=$(lpinfo -m 2>/dev/null | awk '/hp-laserjet|hp-deskjet|hpcups|hpijs|laserjet/ {print $1; exit}')
    [ -n "$p" ] && lpadmin -p "$1" -E -v "$2" -m "$p" 2>/dev/null && healthy "$1"
}
# способ 5: универсальные драйверы
m_generic() {
    local m
    for m in drv:///cupsfilters.drv/pcl.ppd drv:///cupsfilters.drv/pwgrast.ppd drv:///sample.drv/generic.ppd raw; do
        lpadmin -p "$1" -E -v "$2" -m "$m" 2>/dev/null && healthy "$1" && return 0
        lpadmin -x "$1" 2>/dev/null
    done
    return 1
}

FIRST=""; NEWQ=""
while read -r URI; do
    [ -n "$URI" ] || continue
    NAME=$(model_of "$URI" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+|_+$//g')
    [ -n "$NAME" ] || NAME="HP_Printer_$RANDOM"
    if exists "$NAME"; then log "Принтер $NAME уже настроен."; FIRST=${FIRST:-$NAME}; continue; fi
    DONE=0; NEWQ=""
    # Для каждого способа пробуем исходный URI, а затем альтернативные (usb://, dnssd://, ipp://)
    for method in m_hp_setup m_hp_ppd m_everywhere m_hp_generic m_generic; do
        for U in "$URI" $ALT_URIS; do
            [ "$method" = m_hp_setup ] && [ "$U" != "$URI" ] && continue
            log "Настройка $NAME ($U): $method"
            if $method "$NAME" "$U"; then DONE=1; break 2; fi
            lpadmin -x "$NAME" 2>/dev/null
        done
    done
    [ "$DONE" -eq 1 ] || { warn "Не удалось настроить $URI ни одним способом."; continue; }
    Q=${NEWQ:-$NAME}
    log "Готово: очередь $Q"
    FIRST=${FIRST:-$Q}
done <<< "$URIS"

[ -n "$FIRST" ] || die "Ни один принтер настроить не удалось. Смотрите журнал $LOG и /var/log/cups/error_log"
if [ "$DEFAULT" -eq 1 ] || ! lpstat -d 2>/dev/null | grep -q ': *[A-Za-z]'; then
    lpoptions -d "$FIRST" >/dev/null 2>&1 && log "Принтер по умолчанию: $FIRST"
fi
if getent group lp >/dev/null && [ -n "${SUDO_USER:-}" ]; then usermod -aG lp "$SUDO_USER" 2>/dev/null; fi

# --- 6. Тестовая печать и проверка результата ---------------------------
ans=n
if [ "$TEST" -eq 1 ]; then ans=y; elif [ -t 0 ]; then read -r -p "Напечатать тестовую страницу на $FIRST? [y/N] " ans; fi
if [[ "$ans" =~ ^[YyДд] ]]; then
    T=""
    for f in /usr/share/cups/data/testprint /usr/share/cups/data/testprint.ps; do [ -f "$f" ] && { T=$f; break; }; done
    [ -n "$T" ] || { T="$WORK/test.txt"; echo "HPLIP test page: $(date)" > "$T"; }
    lp -d "$FIRST" "$T" || warn "Печать не удалась."
    sleep 8
    if lpstat -p "$FIRST" 2>/dev/null | grep -qiE 'disabled|stopped'; then
        warn "Очередь отключилась после печати — вероятно, проблема с драйвером или нужен плагин."
        warn "Попробуйте: sudo $0 --plugin   (и посмотрите /var/log/cups/error_log)"
    fi
fi

log "Готово. Состояние:"
lpstat -t
