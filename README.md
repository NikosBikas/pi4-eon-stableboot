# Pi 4 Warm-Reboot Reliability Hardening (Argon EON + USB/SATA SSD)

This script applies a set of fixes and workarounds to address the Raspberry Pi 4 reboot hang issue when using Argon EON cases and booting from USB/SATA SSDs. It ensures reliable warm reboots, proper USB bridge resets, and persistent logging for troubleshooting.

## Features

- **Automatic package installation:** Installs all required tools (`sg3-utils`, `uhubctl`, `rpi-eeprom`, etc).
- **EEPROM (BIOS) update:** Checks for and applies the latest Raspberry Pi EEPROM firmware.
- **Persistent journald logs:** Enables persistent system logs with sensible limits for easier debugging.
- **Firmware config tweaks:** Ensures `boot_delay=1` and `dtparam=i2c_arm=on` in `/boot/firmware/config.txt`.
- **Kernel cmdline patch:** Adds USB quirks and `reboot=hard` to `/boot/firmware/cmdline.txt`.
- **EEPROM boot order and timeout:** Sets `BOOT_ORDER=0xf41` and `USB_MSD_TIMEOUT=20000` for reliable USB boot.
- **Pre-shutdown disk spin-down:** Installs a service to safely spin down USB disks before reboot/poweroff.
- **USB hub power-cycle at shutdown:** Uses `uhubctl` to fully reset USB bridges on shutdown.
- **Hardware watchdog:** Enables a 30s watchdog to auto-recover if reboot hangs.
- **Idempotent:** Safe to run multiple times.

## Usage

1. **Clone this repository:**
   ```sh
   git clone https://github.com/yourusername/pi4-eon-stableboot.git
   cd pi4-eon-stableboot
   ```

2. **Run the script as root:**
   ```sh
   sudo bash fix-pi4-reboot.sh
   ```

3. **Reboot your Pi:**
   ```sh
   sudo reboot
   ```

4. **(Recommended) Reboot twice more to confirm stability.**

## Troubleshooting

- **Check previous boot spin-down logs:**
  ```sh
  journalctl -b -1 -u pre-reboot-usb-reset.service --no-pager
  tail -n 40 /var/log/pre-usb-reset.log
  ```

- **Verify UAS is ignored:**
  ```sh
  dmesg | grep -i 'UAS is ignored'
  ```

- **(Optional) Reduce USB_MSD_TIMEOUT to 12000 in EEPROM config to speed up boot once stable.**

## Notes

- The script will abort if `/boot/firmware/config.txt` or `/boot/firmware/cmdline.txt` are missing.
- All changes are backed up with timestamps.
- You can adjust the USB hub location in `/usr/lib/systemd/system-shutdown/30-uhubctl-poweroff` if needed.

## License

MIT License. See [LICENSE](LICENSE) for details.

Maintainer: **Nikolaos Bikas**
