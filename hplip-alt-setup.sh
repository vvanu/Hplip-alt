#!/bin/bash
# Автоматическая установка HPLIP и настройка подключённого принтера HP
# для ALT Linux 9 (p9).
#
#   su -   (или sudo)   bash ./hplip-alt-setup.sh [параметры]
#     --plugin          сразу поставить плагин HP (иначе - только если модели он нужен)
#     --no-plugin       не ставить плагин HP
#     --plugin-dir DIR  папка с заранее скачанным hplip-<версия>-plugin.run (+ .run.asc)
#     --ip АДРЕС        настроить сетевой принтер по IP (в дополнение к найденным)
#     --default         сделать принтер по умолчанию
#     --test            напечатать тестовую страницу без вопроса
#     --no-gui          не ставить графические пакеты (hplip-gui)
#
# Если шаг не удался, скрипт пробует альтернативы. Журнал: /var/log/hplip-alt-setup.log
set -u

HPLIP_VER="${HPLIP_VER:-3.24.4}"   # версия для запасной сборки из исходников
LOG=/var/log/hplip-alt-setup.log
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
PLUGIN=0; NOPLUGIN=0; DEFAULT=0; TEST=0; GUI=1; EXTRA_IP=""; PLUGIN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plugin)     PLUGIN=1 ;;
        --no-plugin)  NOPLUGIN=1 ;;
        --plugin-dir) shift; PLUGIN_DIR="${1:-}" ;;
        --default)    DEFAULT=1 ;;
        --test)       TEST=1 ;;
        --no-gui)     GUI=0 ;;
        --ip)         shift; EXTRA_IP="${1:-}" ;;
        -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Неизвестный параметр: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Вывод: всё, что видит пользователь, дублируется в журнал
# ---------------------------------------------------------------------------
exec 3>&1
[ "$(id -u)" -eq 0 ] || { echo "[x] Запустите от root: su -  (или sudo $0)"; exit 1; }
touch "$LOG" 2>/dev/null
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
say()  { echo -e "$*" >&3; echo -e "$*" | plain >>"$LOG"; }
log()  { say "\e[1;32m[+]\e[0m $*"; }
warn() { say "\e[1;33m[!]\e[0m $*"; }
die()  { say "\e[1;31m[x]\e[0m $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

WORK=$(mktemp -d) && STAGE=$(mktemp -d /var/tmp/hplip-plugin.XXXXXX) || die "Не удалось создать временные папки."
trap 'rm -rf "$WORK" "$STAGE"' EXIT
LAST_OUT=/dev/null

# --- Общий индикатор прогресса по шагам -------------------------------------
STEP=0; TOTAL=7
bar_str() { # $1 = сделано, $2 = всего, $3 = ширина
    local f=$(( $1 * $3 / $2 ))
    printf '%*s' "$f" '' | tr ' ' '#'; printf '%*s' $(( $3 - f )) '' | tr ' ' '-'
}
step() {
    local dn=$STEP; STEP=$((STEP+1))
    say ""
    say "\e[1;36m[$(bar_str "$dn" "$TOTAL" 30)] $(( dn * 100 / TOTAL ))%  Шаг $STEP из $TOTAL: $*\e[0m"
}

# --- Индикатор для долгих команд (бегущая полоса + таймер) ----------------------
fmt_time() { printf '%02d:%02d' $(($1/60)) $(($1%60)); }
# spin "Описание" команда аргументы...   -> код возврата команды; вывод команды в $LAST_OUT и журнал
spin() {
    local msg=$1; shift
    local out i=0 w=20 cycle=34 k pos start=$SECONDS cols line frames='|/-\'
    out=$(mktemp "$WORK/spin.XXXXXX")
    "$@" >"$out" 2>&1 </dev/null &
    local pid=$!
    cols=$(tput cols 2>/dev/null || echo 80)
    while kill -0 "$pid" 2>/dev/null; do
        if [ -t 3 ]; then
            k=$((i % cycle)); pos=$k; [ "$k" -gt $((w-3)) ] && pos=$((cycle-k))
            line=$(printf '  [%s###%s] %s %s  %s' \
                "$(printf '%*s' "$pos" '' | tr ' ' '-')" "$(printf '%*s' $((w-3-pos)) '' | tr ' ' '-')" \
                "${frames:$((i%4)):1}" "$(fmt_time $((SECONDS-start)))" "$msg")
            printf '\r\e[K%s' "${line:0:$((cols-1))}" >&3
        fi
        i=$((i+1)); sleep 0.25
    done
    wait "$pid"; local rc=$?
    [ -t 3 ] && printf '\r\e[K' >&3
    { echo "--- $msg (код $rc) ---"; cat "$out"; } >>"$LOG" 2>/dev/null
    LAST_OUT=$out
    return $rc
}
show_tail() { tail -n "${1:-5}" "$LAST_OUT" 2>/dev/null | tr -d '\r' | sed 's/^/      | /' >&3; }
retry() { local i; for i in 1 2 3; do "$@" && return 0; sleep 3; done; return 1; }

# Ставит из репозитория только существующие пакеты
install_pkgs() {
    local list=() p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then list+=("$p"); else warn "Пакет $p не найден, пропускаю."; fi
    done
    [ ${#list[@]} -gt 0 ] || return 1
    spin "Установка: ${list[*]}" apt-get install -y "${list[@]}" \
        || spin "Установка (с исправлением зависимостей): ${list[*]}" apt-get install -y --fix-broken "${list[@]}" \
        || { show_tail; return 1; }
}

say ""
log "Журнал: $LOG ($(date))"
have apt-get || die "apt-get не найден."
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *alt*) ;;
        *) warn "Система не похожа на ALT Linux (${PRETTY_NAME:-?}), продолжаю на свой риск." ;;
    esac
fi

# ===========================================================================
step "Обновление списков пакетов"
retry spin "apt-get update" apt-get update || { show_tail; warn "apt-get update не удался (проверьте сеть/репозитории: apt-repo list)."; }

# ===========================================================================
step "Установка CUPS и HPLIP"
install_pkgs cups cups-filters ghostscript libusb usbutils python3-module-dbus avahi \
    || warn "Часть базовых пакетов не установилась."

if ! have hp-setup; then
    install_pkgs hplip hplip-common hplip-ppds hplip-hpijs hplip-sane \
        || warn "Установка hplip из репозитория не удалась."
fi
# Подхватываем реальные имена пакетов hplip из репозитория (на случай, если названия отличаются)
EXTRA_PKGS=$(apt-cache search -n hplip 2>/dev/null | awk '{print $1}' \
    | grep -Ev 'debuginfo|devel|doc|gui|qt|^lib|^i586' | tr '\n' ' ')
# shellcheck disable=SC2086
[ -n "$EXTRA_PKGS" ] && install_pkgs $EXTRA_PKGS >/dev/null 2>&1
[ "$GUI" -eq 1 ] && { install_pkgs hplip-gui >/dev/null 2>&1 || true; }

# fallback 1: исправление зависимостей и повтор
if ! have hp-setup; then
    warn "Fallback: исправляю зависимости и пробую ещё раз..."
    spin "apt-get -f install" apt-get -f install -y
    retry spin "apt-get update" apt-get update
    spin "apt-get install hplip" apt-get install -y hplip
fi

# fallback 2: сборка из исходников
build_hplip() {
    cd "$WORK/hplip-$HPLIP_VER" &&
    ./configure --prefix=/usr --enable-hpcups-install --enable-cups-drv-install \
        --disable-qt4 --disable-qt5 --disable-fax-build --disable-doc-build \
        --disable-network-build &&
    make -j"$(nproc)" && make install
}
dl() { # dl URL FILE
    if have curl; then curl -fL --connect-timeout 15 --max-time 180 -o "$2" "$1"
    elif have wget; then wget -q -T 30 -O "$2" "$1"
    else return 1; fi
}
if ! have hp-setup; then
    warn "Fallback: сборка HPLIP $HPLIP_VER из исходников с SourceForge..."
    install_pkgs gcc gcc-c++ make libcups-devel libusb-devel libsane-devel libdbus-devel \
        python3-devel libnet-snmp-devel libssl-devel libjpeg-devel
    URL="https://downloads.sourceforge.net/project/hplip/hplip/$HPLIP_VER/hplip-$HPLIP_VER.tar.gz"
    if retry spin "Скачивание исходников HPLIP $HPLIP_VER" dl "$URL" "$WORK/hplip.tar.gz" \
       && tar -xzf "$WORK/hplip.tar.gz" -C "$WORK"; then
        spin "Сборка HPLIP (может занять несколько минут)" build_hplip \
            || { warn "Сборка не удалась, лог: /var/log/hplip-build.log"; cp "$LAST_OUT" /var/log/hplip-build.log 2>/dev/null; }
    else
        warn "Не удалось скачать исходники HPLIP."
    fi
fi

if have hp-setup; then HPLIP_OK=1; else
    HPLIP_OK=0
    warn "HPLIP установить не удалось - продолжаю без него (драйверы CUPS / IPP Everywhere)."
fi

# ===========================================================================
step "Запуск службы печати"
# Правила udev из hplip применяются только после перезагрузки udev
if have udevadm; then udevadm control --reload-rules 2>/dev/null; udevadm trigger --subsystem-match=usb 2>/dev/null; fi
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
have avahi-daemon && systemctl enable --now avahi-daemon.service >/dev/null 2>&1
log "CUPS запущен."

# ===========================================================================
step "Поиск принтера"
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
log "Убедитесь, что принтер включён и подключён."
{ lsusb 2>/dev/null | grep -i 'hewlett\|hp' || warn "В lsusb нет устройств HP (для сетевого принтера это нормально)."; } 2>&1 | tee -a "$LOG" >&3
URIS=""
for attempt in 1 2 3 4; do
    URIS=$(spin "Поиск принтеров (попытка $attempt из 4)" bash -c "$(declare -f find_uris); HPLIP_OK=$HPLIP_OK; find_uris" && cat "$LAST_OUT")
    URIS=$(echo "$URIS" | grep -E '^[a-z]+:/' )
    [ -n "$URIS" ] && break
    warn "Принтер не найден (попытка $attempt/4), перезапускаю CUPS и жду..."
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
log "Найдено:"; echo "$URIS" | sed 's/^/      /' | tee -a "$LOG" >&3

# Альтернативные URI тех же устройств (usb://, dnssd://, ipp://) для запасных способов
ALT_URIS=$(lpinfo -v 2>/dev/null | awk '{print $2}' | grep -E '^(usb|dnssd|ipp|socket)://' | grep -iE 'hp|hewlett' | sort -u)

# ===========================================================================
step "Плагин HP и настройка принтера"

# --- Плагин HP: версия должна точно совпадать с версией HPLIP -------------------
hplip_version() {
    local v
    v=$(rpm -q --qf '%{VERSION}' hplip 2>/dev/null | grep -E '^[0-9]+\.[0-9]+')
    [ -n "$v" ] || v=$(hp-setup --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    echo "$v"
}
plugin_installed() { # $1 = версия
    awk -v v="$1" '/^\[plugin\]/{s=1;next} /^\[/{s=0}
        s&&/^installed *=/{i=($0 ~ /= *1/)} s&&/^version *=/{ok=($0 ~ v)} END{exit !(i&&ok)}' /var/lib/hp/hplip.state 2>/dev/null
}
plugin_label() { head -n 30 "$1" 2>/dev/null | grep -a -o 'HPLIP [0-9][0-9.]* Plugin' | head -n1; }
run_hp_plugin() { yes | timeout 300 hp-plugin -i -p "$STAGE"; }
find_local_plugin() { # $1 = версия; печатает путь подходящего файла
    local f lbl dirs=()
    for f in "$PLUGIN_DIR" "$SCRIPT_DIR" "$PWD" /root /tmp /var/tmp /media /mnt /home; do [ -n "$f" ] && [ -d "$f" ] && dirs+=("$f"); done
    while IFS= read -r f; do
        lbl=$(plugin_label "$f")
        if [ "$lbl" = "HPLIP $1 Plugin" ]; then echo "$f"; return 0; fi
        warn "Файл $f не подходит: внутри '${lbl:-?}', а нужен HPLIP $1."
    done < <(find "${dirs[@]}" -maxdepth 3 -name "hplip-$1-plugin.run" 2>/dev/null)
    return 1
}
_ensure_plugin() {
    local ver run base
    ver=$(hplip_version); [ -n "$ver" ] || { warn "Не удалось определить версию HPLIP."; return 1; }
    if plugin_installed "$ver"; then log "Плагин HP $ver уже установлен."; return 0; fi
    log "Нужен плагин HP версии $ver (должна совпадать с установленным HPLIP)."
    run=$(spin "Поиск готового файла плагина на диске" find_local_plugin "$ver" && cat "$LAST_OUT" | tail -n1)
    run=$(echo "$run" | grep -E "hplip-$ver-plugin.run$" | tail -n1)
    if [ -z "$run" ]; then
        for base in "https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins" \
                    "https://downloads.sourceforge.net/project/hplip/hplip/$ver"; do
            if spin "Скачивание плагина HP $ver" dl "$base/hplip-$ver-plugin.run" "$STAGE/hplip-$ver-plugin.run" \
               && [ "$(plugin_label "$STAGE/hplip-$ver-plugin.run")" = "HPLIP $ver Plugin" ]; then
                spin "Скачивание подписи (.asc)" dl "$base/hplip-$ver-plugin.run.asc" "$STAGE/hplip-$ver-plugin.run.asc" || true
                run="$STAGE/hplip-$ver-plugin.run"; break
            fi
            rm -f "$STAGE/hplip-$ver-plugin.run"
        done
    else
        cp -f "$run" "$STAGE/"; [ -f "$run.asc" ] && cp -f "$run.asc" "$STAGE/"
        run="$STAGE/$(basename "$run")"
    fi
    if [ -z "$run" ]; then
        warn "Плагин HP $ver не найден и не скачался (нет доступа к серверам HP?)."
        say "      Скачайте В БРАУЗЕРЕ два файла (не переименовывая) и положите рядом со скриптом или в /root:"
        say "        https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-$ver-plugin.run"
        say "        https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-$ver-plugin.run.asc"
        say "      (или в папке https://sourceforge.net/projects/hplip/files/hplip/$ver/ ), затем запустите скрипт снова."
        return 1
    fi
    spin "Установка плагина HP $ver (и прошивки)" run_hp_plugin
    if plugin_installed "$ver"; then log "Плагин HP $ver установлен."; return 0; fi
    warn "Плагин не установился. Последние строки вывода:"; show_tail 8
    return 1
}
PLUGIN_TRIED=0; PLUGIN_RC=1
ensure_plugin() {
    [ "$NOPLUGIN" -eq 1 ] && return 1
    [ "$HPLIP_OK" -eq 1 ] || return 1
    if [ "$PLUGIN_TRIED" -eq 0 ]; then PLUGIN_TRIED=1; _ensure_plugin; PLUGIN_RC=$?; fi
    return "$PLUGIN_RC"
}

# --- Способы настройки очереди -----------------------------------------------
exists() { lpstat -p "$1" >/dev/null 2>&1; }
# Очередь считается рабочей, если она существует и не отключена
healthy() {
    exists "$1" || return 1
    cupsenable "$1" 2>/dev/null; cupsaccept "$1" 2>/dev/null
    ! lpstat -p "$1" 2>/dev/null | grep -qi 'disabled'
}
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
# В описании PPD из HPLIP есть пометка "requires proprietary plugin"
needs_plugin() {
    local ppd; ppd=$(find_ppd "$1"); [ -n "$ppd" ] || return 1
    lpinfo -m 2>/dev/null | awk -v p="$ppd" '$1==p' | grep -qi 'requires proprietary plugin'
}

HPSETUP_TO=300
run_hp_setup() { yes | timeout "$HPSETUP_TO" hp-setup -i -a $1; }
# способ 1: штатный мастер HPLIP (сам подбирает драйвер)
m_hp_setup() {   # $1 имя, $2 URI
    [ "$HPLIP_OK" -eq 1 ] && [[ "$2" == hp:* ]] || return 1
    local before after arg
    before=$(queues)
    if [[ "$2" == *"ip="* ]]; then arg=$(echo "$2" | sed -E 's/.*ip=([^&]+).*/\1/'); else arg="-b usb"; fi
    spin "Мастер hp-setup (до ${HPSETUP_TO} с)" run_hp_setup "$arg"
    after=$(queues)
    if [ "$before" = "$after" ] && grep -qi 'plugin' "$LAST_OUT" && ensure_plugin; then
        spin "Мастер hp-setup, повтор после установки плагина" run_hp_setup "$arg"
        after=$(queues)
    fi
    [ "$before" != "$after" ] || return 1
    NEWQ=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
    [ -n "$NEWQ" ] && healthy "$NEWQ"
}
# способ 2: драйвер HPLIP (PPD) по названию модели
m_hp_ppd()     { local p; p=$(find_ppd "$2"); [ -n "$p" ] && lpadmin -p "$1" -E -v "$2" -m "$p" 2>/dev/null && healthy "$1"; }
# способ 3: драйверы foomatic/foo2zjs (для моделей, где HPLIP требует плагин)
m_foomatic() {
    local p
    if [ -z "${FOOMATIC_TRIED:-}" ]; then
        FOOMATIC_TRIED=1
        install_pkgs foo2zjs foomatic-db foomatic-db-engine foomatic-filters foomatic-db-ppds >/dev/null 2>&1
    fi
    p=$(find_ppd "$2")
    [ -n "$p" ] && lpadmin -p "$1" -E -v "$2" -m "$p" 2>/dev/null && healthy "$1"
}
# способ 4: IPP Everywhere (драйверов не нужно, современные принтеры)
m_everywhere() { lpadmin -p "$1" -E -v "$2" -m everywhere 2>/dev/null && healthy "$1"; }
# способ 5: любой подходящий HP-драйвер
m_hp_generic() {
    local p
    p=$(lpinfo -m 2>/dev/null | awk '/hp-laserjet|hp-deskjet|hpcups|hpijs|laserjet/ {print $1; exit}')
    [ -n "$p" ] && lpadmin -p "$1" -E -v "$2" -m "$p" 2>/dev/null && healthy "$1"
}
# способ 6: универсальные драйверы
m_generic() {
    local m
    for m in drv:///cupsfilters.drv/pcl.ppd drv:///cupsfilters.drv/pwgrast.ppd drv:///sample.drv/generic.ppd raw; do
        lpadmin -p "$1" -E -v "$2" -m "$m" 2>/dev/null && healthy "$1" && return 0
        lpadmin -x "$1" 2>/dev/null
    done
    return 1
}

# --plugin: ставим плагин сразу
[ "$PLUGIN" -eq 1 ] && ensure_plugin

FIRST=""; NEWQ=""
while read -r URI; do
    [ -n "$URI" ] || continue
    # Принтер уже подключён к какой-то очереди (например, созданной системой) - не дублируем
    OLDQ=$(lpstat -v 2>/dev/null | grep -F "$URI" | head -n1 | sed -E 's/^device for ([^:]+):.*/\1/')
    if [ -n "$OLDQ" ] && exists "$OLDQ"; then
        log "Для этого принтера уже есть очередь $OLDQ, использую её."
        cupsenable "$OLDQ" 2>/dev/null; cupsaccept "$OLDQ" 2>/dev/null
        FIRST=${FIRST:-$OLDQ}; continue
    fi
    NAME=$(model_of "$URI" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+|_+$//g')
    [ -n "$NAME" ] || NAME="HP_Printer_$RANDOM"
    if exists "$NAME"; then log "Принтер $NAME уже настроен."; FIRST=${FIRST:-$NAME}; continue; fi

    # Модель требует плагин? Ставим его до настройки (без плагина hp-setup обычно виснет)
    if [[ "$URI" == hp:* ]] && [ "$HPLIP_OK" -eq 1 ] && needs_plugin "$URI"; then
        log "Этой модели нужен плагин HP."
        ensure_plugin || { HPSETUP_TO=60; warn "Продолжаю без плагина (печать может не работать, пока плагин не установлен)."; }
    fi

    DONE=0; NEWQ=""
    for method in m_hp_setup m_hp_ppd m_foomatic m_everywhere m_hp_generic m_generic; do
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

# ===========================================================================
step "Проверка и параметры"
if [ "$DEFAULT" -eq 1 ] || ! lpstat -d 2>/dev/null | grep -q ': *[A-Za-z]'; then
    lpoptions -d "$FIRST" >/dev/null 2>&1 && log "Принтер по умолчанию: $FIRST"
fi
if getent group lp >/dev/null && [ -n "${SUDO_USER:-}" ]; then usermod -aG lp "$SUDO_USER" 2>/dev/null; fi
cupsenable "$FIRST" 2>/dev/null; cupsaccept "$FIRST" 2>/dev/null
log "Очередь $FIRST готова."

# ===========================================================================
step "Тестовая печать"
ans=n
if [ "$TEST" -eq 1 ]; then ans=y; elif [ -t 0 ]; then read -r -p "Напечатать тестовую страницу на $FIRST? [y/N] " ans; fi
if [[ "$ans" =~ ^[YyДд] ]]; then
    T=""
    for f in /usr/share/cups/data/testprint /usr/share/cups/data/testprint.ps; do [ -f "$f" ] && { T=$f; break; }; done
    [ -n "$T" ] || { T="$WORK/test.txt"; echo "HPLIP test page: $(date)" > "$T"; }
    lp -d "$FIRST" "$T" >/dev/null || warn "Печать не удалась."
    spin "Ожидание результата печати" sleep 10
    # Печать упала из-за плагина -> ставим его и повторяем один раз
    if lpstat -p "$FIRST" 2>/dev/null | grep -qiE 'disabled|stopped' \
       || tail -n 30 /var/log/cups/error_log 2>/dev/null | grep -qi 'plugin'; then
        warn "Печать не прошла (возможно, нужен плагин HP)."
        if ensure_plugin; then
            cancel -a "$FIRST" 2>/dev/null; cupsenable "$FIRST" 2>/dev/null
            lp -d "$FIRST" "$T" >/dev/null && log "Тестовая страница отправлена повторно."
        else
            warn "Смотрите /var/log/cups/error_log; плагин см. подсказку выше или запустите: $0 --plugin"
        fi
    else
        log "Тестовая страница отправлена."
    fi
fi

say ""
say "\e[1;32m[$(bar_str 1 1 30)] 100%  Готово.\e[0m"
log "Состояние печати:"
lpstat -t 2>&1 | tee -a "$LOG" >&3
