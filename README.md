# hplip-alt

Скрипт `hplip-alt-setup.sh` для ALT Linux 9: ставит HPLIP + CUPS из репозитория (`apt-get`),
запускает службу печати, находит подключённый принтер HP (USB/сеть) и настраивает его.

```
sudo ./hplip-alt-setup.sh            # установка и настройка
sudo ./hplip-alt-setup.sh --plugin   # + плагин HP (hp-plugin), нужен для части моделей
sudo ./hplip-alt-setup.sh --default  # + сделать принтер по умолчанию
```

Скрипт не тестировался на реальном железе ALT Linux 9: имена пакетов, которых нет
в репозитории, пропускаются с предупреждением.
