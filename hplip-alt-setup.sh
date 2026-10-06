#!/bin/bash
# Автоматическая установка HPLIP и настройка подключённого принтера HP
# для ALT Linux 9 (p9). Запуск: sudo ./hplip-alt-setup.sh [--plugin] [--default]
#   --plugin   дополнительно скачать и поставить проприетарный плагин HP (hp-plugin)
#   --default  сделать найденный принтер принтером по умолчанию
set -u

PLUGIN=0
DEFAULT=0
for a in "$@"; do
    case "$a" in
        --plugin)  PLUGIN=1 ;;
        --default) DEFAULT=1 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "Неизвестный параметр: $a"; exit 1 ;;
    esac
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *altlinux*|*alt*) ;;
        *) warn "Система не похожа на ALT Linux (${PRETTY_NAME:-?}), продолжаю на свой риск." ;;
    esac
fi
command -v apt-get >/dev/null || die "apt-get не найден."

# --- 1. Установка пакетов -------------------------------------------------
log "Обновление списков пакетов..."
apt-get update || warn "apt-get update завершился с ошибкой (проверьте сеть/репозитории)."

# Устанавливаем только те пакеты, что есть в репозитории
install_pkgs() {
    local list=()
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then list+=("$p"); else warn "Пакет $p не найден, пропускаю."; fi
    done
    [ ${#list[@]} -gt 0 ] && apt-get install -y "${list[@]}"
}

log "Установка HPLIP, CUPS и зависимостей..."
install_pkgs cups cups-filters ghostscript hplip hplip-common hplip-ppds \
             hplip-hpijs hplip-sane hplip-gui hplip-doc python3-module-dbus \
             libusb usbutils
command -v hp-setup >/dev/null || die "HPLIP не установился (hp-setup не найден)."

# --- 2. Служба печати -----------------------------------------------------
log "Включение и запуск CUPS..."
systemctl enable --now cups.service 2>/dev/null || systemctl enable --now cupsd.service 2>/dev/null \
    || warn "Не удалось запустить cups через systemctl."
sleep 2

# --- 3. Плагин (по желанию) -----------------------------------------------
if [ "$PLUGIN" -eq 1 ]; then
    log "Скачивание и установка плагина HP (нужен интернет, лицензия принимается автоматически)..."
    hp-plugin -i --required --accept 2>&1 || warn "Установка плагина не удалась (повторите: hp-plugin -i)."
fi

# --- 4. Поиск принтера ----------------------------------------------------
log "Поиск подключённых принтеров HP..."
lsusb 2>/dev/null | grep -i 'hewlett\|hp' || true
URIS=$(hp-makeuri -l 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
[ -z "$URIS" ] && URIS=$(lpinfo -v 2>/dev/null | awk '$2 ~ /^hp:\// {print $2}' | sort -u)
[ -z "$URIS" ] && URIS=$(hp-probe -b usb 2>/dev/null | grep -Eo 'hp:/[^ ]+' | sort -u)
[ -n "$URIS" ] || die "Принтер HP не найден. Проверьте USB-кабель/питание принтера и запустите скрипт снова."

# --- 5. Настройка ---------------------------------------------------------
FIRST=""
while read -r URI; do
    [ -n "$URI" ] || continue
    NAME=$(echo "$URI" | sed -E 's#^hp:/[^/]*/##; s#\?.*##; s#[^A-Za-z0-9_-]#_#g')
    [ -n "$NAME" ] || NAME="HP_Printer"
    if lpstat -p "$NAME" >/dev/null 2>&1; then
        log "Принтер $NAME уже настроен, пропускаю."
        FIRST=${FIRST:-$NAME}; continue
    fi
    log "Настройка $NAME ($URI) через hp-setup..."
    if hp-setup -i -a -x -p "$NAME" "$URI" >/dev/null 2>&1 && lpstat -p "$NAME" >/dev/null 2>&1; then
        :
    else
        warn "hp-setup не справился, пробую lpadmin + подбор PPD..."
        MODEL=$(echo "$URI" | sed -E 's#^hp:/[^/]*/##; s#\?.*##; s#_# #g')
        PPD=$(lpinfo -m 2>/dev/null | awk -v m="$MODEL" 'BEGIN{IGNORECASE=1} index($0,m){print $1; exit}')
        [ -n "$PPD" ] || PPD=$(lpinfo -m 2>/dev/null | awk '/drv:\/\/\/hp\.drv\/hp-laserjet|hp-deskjet/ {print $1; exit}')
        [ -n "$PPD" ] || PPD="drv:///sample.drv/generic.ppd"
        lpadmin -p "$NAME" -E -v "$URI" -m "$PPD" || { warn "Не удалось добавить $NAME"; continue; }
    fi
    cupsenable "$NAME" 2>/dev/null; cupsaccept "$NAME" 2>/dev/null
    FIRST=${FIRST:-$NAME}
    log "Принтер $NAME добавлен."
done <<< "$URIS"

[ -n "$FIRST" ] || die "Ни один принтер настроить не удалось."
if [ "$DEFAULT" -eq 1 ] || ! lpstat -d 2>/dev/null | grep -q ':.*[A-Za-z]'; then
    lpoptions -d "$FIRST" >/dev/null 2>&1 && log "Принтер по умолчанию: $FIRST"
fi

# --- 6. Доступ для пользователей -----------------------------------------
getent group lp >/dev/null && [ -n "${SUDO_USER:-}" ] && usermod -aG lp "$SUDO_USER" 2>/dev/null

# --- 7. Тестовая страница -------------------------------------------------
read -r -p "Напечатать тестовую страницу на $FIRST? [y/N] " ans
if [[ "$ans" =~ ^[YyДд] ]]; then
    for f in /usr/share/cups/data/testprint /usr/share/cups/data/testprint.ps; do
        [ -f "$f" ] && { lp -d "$FIRST" "$f"; break; }
    done
fi

log "Готово. Состояние:"
lpstat -t
