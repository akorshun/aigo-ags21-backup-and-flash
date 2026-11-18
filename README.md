# Aigo AGS21: stock backup and OpenWrt, from Windows in one script

**English** | [Русский](README.ru.md)

A script for the Aigo AGS21 (aigo S21, MediaTek MT7981B, 1 GiB DDR4, 64 GiB eMMC).
It takes the router from the stock firmware to a working OpenWrt by itself:

1. loads the OpenWrt U-Boot into RAM over UART (`mtk_uartboot` + the generic
   MT7981 DDR4 RAM BL2 + the AGS21 bl31-uboot FIP); nothing is written to flash
   before the backup is on the PC;
2. that U-Boot picks up the OpenWrt initramfs over TFTP from the PC on its own,
   so the router runs an OpenWrt initramfs completely from RAM;
3. over SSH the important stock partitions are copied to the PC and checked with
   sha256 - the raw 5 MiB at sector 0 (GPT, BL2 area, u-boot-env, factory with
   the MACs and Wi-Fi calibration), the BL2 boot partition, the stock FIP,
   kernel and rootfs. The 56 GiB `permanent_config` data partition is **not**
   backed up (user files only, and the install does not touch it);
4. after confirmation the OpenWrt GPT is written, then BL2 (to the eMMC boot
   partition), the bl31-uboot FIP and the sysupgrade FIT (to the production
   volume). Every write is read back and verified with md5, then the router
   reboots into OpenWrt.

There are also **Backup** (steps 1-3, then reboot to stock) and **Restore**
(write the stock partitions back from a backup) modes.

## Hardware needed

- USB-UART (TTL 3.3 V) adapter. The UART pads are on the right edge of the
  board, labelled `TX GND RX` (J4, next to the antenna cutout); connect
  crossed: board TX to adapter RX, board RX to adapter TX, GND to GND. Do not
  connect VCC. 115200 8N1.
- A USB gigabit Ethernet adapter wired to one of the router's LAN ports.

## Usage

```
ags21-flash.cmd                      # Install: backup + write OpenWrt
ags21-flash.cmd -Mode Backup         # backup only, reboot to stock afterwards
ags21-flash.cmd -Mode Restore -BackupDir .\backup\<date-time>   # back to stock
```

Options: `-ComPort COM5`, `-Lang ru`, `-Firmware <your sysupgrade.itb>`,
`-BackupDir <dir>`, `-Yes`. The script asks for the language, the COM port and
the network adapter, starts its own TFTP server and temporarily re-addresses
the chosen adapter to 192.168.1.254/24 (put back on exit). Keep the router's
LAN port wired to that adapter and a terminal open on the UART while it runs:
the script tells you when to power-cycle the router.

`Install` requires admin rights (netsh + firewall rule for the TFTP port).

## What ends up on the eMMC

| OpenWrt GPT | Sectors | Content |
|-------------|---------|---------|
| ubootenv    | 8192-9215    | U-Boot environment (kept from stock location) |
| factory     | 9216-13311   | MACs + Wi-Fi calibration (kept, never overwritten) |
| fip         | 13312-21503  | bl31 + OpenWrt U-Boot |
| recovery    | 24576-90111  | (free; recovery images can be TFTP-booted) |
| production  | 131072-...   | sysupgrade FIT (fitblk: kernel + rootfs + overlay) |

Stock `permanent_config` (p6, 56 GiB) is untouched by Install and Restore; the
stock firmware may reformat it on the first boot after a Restore.

## Firmware in `firmware/`

Built from [akorshun/openwrt](https://github.com/akorshun/openwrt), tag
`aigo-ags21-25.12.5-r1` (OpenWrt 25.12.5, mediatek/filogic, aigo_ags21):

- `mt7981-ram-ddr4-bl2.bin` - generic MT7981 DDR4 RAM BL2 (UART download), the
  same file [OpenWrt snapshots](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/)
  publish;
- `openwrt-mediatek-filogic-aigo_ags21-emmc-preloader.bin` - OpenWrt BL2 for
  the eMMC boot partition;
- `openwrt-mediatek-filogic-aigo_ags21-emmc-bl31-uboot.fip` - bl31 + OpenWrt
  U-Boot (bootmenu, TFTP recovery);
- `openwrt-mediatek-filogic-aigo_ags21-emmc-gpt.bin` - the OpenWrt GPT;
- `...-initramfs-recovery.itb` / `...-squashfs-sysupgrade.itb` - the OpenWrt
  images (the recovery one is served over TFTP with the file name the U-Boot
  default environment asks for);
- `tools/mtk_uartboot.exe` - [981213/mtk_uartboot](https://github.com/981213/mtk_uartboot) v0.1.1.

## Known issues

- The factory partition MAC offsets are verified: WAN 0x24 = label MAC,
  LAN 0x2a, 2.4 G Wi-Fi 0x04, 5 G Wi-Fi 0x30.
- In the r1 firmware the WLAN LED wiring is wrong (the WiFi LEDs are driven by
  the SoC wmac LED pads; see the LED fix commit in the repo). Use a firmware
  with the LED fix or fix `white:wlan` handling manually.
