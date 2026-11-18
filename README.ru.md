# Aigo AGS21: бэкап стока и OpenWrt одним скриптом из Windows

[English](README.md) | **Русский**

Скрипт для роутера Aigo AGS21 (aigo S21, MediaTek MT7981B, 1 ГиБ DDR4, eMMC 64 ГиБ).
Сам доводит роутер от стоковой прошивки до работающего OpenWrt:

1. загружает OpenWrt U-Boot в RAM по UART (`mtk_uartboot` + универсальный
   MT7981 DDR4 RAM BL2 + AGS21 bl31-uboot FIP); до снятия бэкапа во флеш
   ничего не пишется;
2. этот U-Boot сам забирает OpenWrt initramfs по TFTP с ПК, так что роутер
   работает в OpenWrt initramfs целиком из RAM;
3. по SSH важные разделы стока копируются на ПК и проверяются sha256 —
   сырые 5 МиБ с сектора 0 (GPT, область BL2, u-boot-env, factory с MAC-ами
   и калибровкой Wi-Fi), boot-раздел BL2, стоковый FIP, kernel и rootfs.
   Раздел данных `permanent_config` на 56 ГиБ **не** бэкапится (только
   пользовательские файлы, установка его не трогает);
4. после подтверждения пишутся GPT OpenWrt, затем BL2 (в boot-раздел eMMC),
   bl31-uboot FIP и sysupgrade FIT (в том production). Каждая запись
   проверяется чтением обратно по md5, затем роутер перезагружается в OpenWrt.

Есть также режимы **Backup** (шаги 1-3, потом перезагрузка в сток) и
**Restore** (запись разделов стока обратно из бэкапа).

## Что нужно из железа

- Адаптер USB-UART (TTL 3.3 В). Пады UART — у правого края платы, подписаны
  `TX GND RX` (J4, у выреза антенны); подключение крест-накрест: TX платы →
  RX адаптера, RX платы → TX адаптера, GND → GND. VCC не подключать. 115200 8N1.
- Адаптер USB Gigabit Ethernet, подключённый к одному из LAN-портов роутера.

## Использование

```
ags21-flash.cmd                      # Install: бэкап + запись OpenWrt
ags21-flash.cmd -Mode Backup         # только бэкап, затем перезагрузка в сток
ags21-flash.cmd -Mode Restore -BackupDir .\backup\<дата-время>   # вернуть сток
```

Опции: `-ComPort COM5`, `-Lang en`, `-Firmware <ваш sysupgrade.itb>`,
`-BackupDir <папка>`, `-Yes`. Скрипт спрашивает язык, COM-порт и сетевой
адаптер, поднимает свой TFTP-сервер и временно переводит выбранный адаптер
на 192.168.1.254/24 (при выходе всё возвращается). Держите LAN-порт роутера
соединённым с этим адаптером и терминал на UART открытым: скрипт скажет,
когда включить/выключить питание роутера.

`Install` требует прав администратора (netsh + правило брандмауэра для TFTP).

## Что оказывается на eMMC

| GPT OpenWrt | Сектора | Содержимое |
|-------------|---------|------------|
| ubootenv    | 8192-9215    | окружение U-Boot (на месте стокового) |
| factory     | 9216-13311   | MAC-и + калибровка Wi-Fi (сохраняется, не перезаписывается) |
| fip         | 13312-21503  | bl31 + OpenWrt U-Boot |
| recovery    | 24576-90111  | (свободно; recovery-образы грузятся по TFTP) |
| production  | 131072-...   | sysupgrade FIT (fitblk: kernel + rootfs + overlay) |

Стоковый `permanent_config` (p6, 56 ГиБ) Install и Restore не трогают; сток
при первой загрузке после Restore может его переформатировать.

## Прошивки в `firmware/`

Собраны из [akorshun/openwrt](https://github.com/akorshun/openwrt), тег
`aigo-ags21-25.12.5-r1` (OpenWrt 25.12.5, mediatek/filogic, aigo_ags21):

- `mt7981-ram-ddr4-bl2.bin` — универсальный MT7981 DDR4 RAM BL2 (UART download),
  тот же файл, что публикуется в
  [снапшотах OpenWrt](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/);
- `openwrt-mediatek-filogic-aigo_ags21-emmc-preloader.bin` — OpenWrt BL2 для
  boot-раздела eMMC;
- `openwrt-mediatek-filogic-aigo_ags21-emmc-bl31-uboot.fip` — bl31 + OpenWrt
  U-Boot (bootmenu, TFTP recovery);
- `openwrt-mediatek-filogic-aigo_ags21-emmc-gpt.bin` — GPT OpenWrt;
- `...-initramfs-recovery.itb` / `...-squashfs-sysupgrade.itb` — образы OpenWrt
  (recovery отдаётся по TFTP под именем из дефолтного окружения U-Boot);
- `tools/mtk_uartboot.exe` — [981213/mtk_uartboot](https://github.com/981213/mtk_uartboot) v0.1.1.

## Известные особенности

- Оффсеты MAC в factory проверены на железе: WAN 0x24 = MAC с наклейки,
  LAN 0x2a, Wi-Fi 2.4 ГГц 0x04, Wi-Fi 5 ГГц 0x30.
- В прошивке r1 разводка WLAN-LED описана неверно (WiFi LED управляется
  аппаратно пинами wmac; см. коммит LED-фикса в openwrt-репо). Используйте
  прошивку с LED-фиксом.
