#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

echo "== Pi 4 warm-reboot reliability hardening (Argon EON + USB/SATA SSD) =="

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

# ---------------------------
# 0) Install required packages
# ---------------------------
echo "--- Installing packages (sg3-utils, uhubctl, EEPROM tools, vcgencmd) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Detect distro codename to choose the correct userland packages
. /etc/os-release || true
CODENAME="${VERSION_CODENAME:-}"
USERLAND_PKGS=""

# Hard-block legacy userland on Bookworm and newer
install -d /etc/apt/preferences.d
cat >/etc/apt/preferences.d/99-rpi-userland-split.pref <<'EOF'
Package: libraspberrypi*
Pin: release *
Pin-Priority: -1
EOF

apt-get update -y

case "$CODENAME" in
  bookworm|trixie|forky)
    # Always use new split packages on Bookworm+
    USERLAND_PKGS="raspi-utils raspi-utils-core raspi-utils-dt"
    ;;
  bullseye|buster|stretch)
    # Older releases expect the legacy meta
    USERLAND_PKGS="libraspberrypi-bin"
    ;;
  *)
    # Fallback: prefer new split if present, else legacy
    if apt-cache show raspi-utils-core >/dev/null 2>&1; then
      USERLAND_PKGS="raspi-utils raspi-utils-core raspi-utils-dt"
    else
      USERLAND_PKGS="libraspberrypi-bin"
    fi
    ;;
esac

# Remove any stray legacy bits first (ignore errors)
apt-get purge -y 'libraspberrypi*' || true

# Now install the rest
apt-get install -y --no-install-recommends \
  sg3-utils uhubctl rpi-eeprom rpi-eeprom-images ca-certificates \
  $USERLAND_PKGS

# ---------------------------
# 0b) Check and update Raspberry Pi EEPROM (firmware/BIOS)
# ---------------------------
echo "--- Checking for latest Raspberry Pi EEPROM (firmware/BIOS) ..."
if command -v rpi-eeprom-update >/dev/null; then
  rpi-eeprom-update
  if rpi-eeprom-update | grep -q "UPDATE REQUIRED"; then
    echo ">>> EEPROM update required. Applying update ..."
    rpi-eeprom-update -a
    echo ">>> EEPROM update applied. Please reboot to complete the update."
  else
    echo ">>> EEPROM is already up to date."
  fi
else
  echo "WARNING: rpi-eeprom-update not found. Skipping EEPROM firmware check."
fi

# ---------------------------
# 1) Persistent journald (for debugging) with sane caps
# ---------------------------
echo "--- Enabling persistent journald with limits ..."
mkdir -p /var/log/journal
chown root:systemd-journal /var/log/journal
chmod 2755 /var/log/journal
if grep -q '^Storage=' /etc/systemd/journald.conf; then
  sed -i 's/^Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
else
  echo 'Storage=persistent' >> /etc/systemd/journald.conf
fi
grep -q '^SystemMaxUse=' /etc/systemd/journald.conf || echo 'SystemMaxUse=200M' >> /etc/systemd/journald.conf
grep -q '^SystemMaxFileSize=' /etc/systemd/journald.conf || echo 'SystemMaxFileSize=50M' >> /etc/systemd/journald.conf
grep -q '^MaxRetentionSec=' /etc/systemd/journald.conf || echo 'MaxRetentionSec=30day' >> /etc/systemd/journald.conf
systemctl restart systemd-journald || true

# Ensure config files exist before editing
for f in /boot/firmware/config.txt /boot/firmware/cmdline.txt; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f does not exist. Aborting."
    exit 1
  fi
done

# ---------------------------
# 2) Firmware config niceties
# ---------------------------
CFG=/boot/firmware/config.txt
echo "--- Tweaking $CFG (boot_delay=1, ensure i2c on) ..."
cp -an "$CFG"{,.bak.$(date +%Y%m%d%H%M%S)}
grep -q '^boot_delay=' "$CFG" && sed -i 's/^boot_delay=.*/boot_delay=1/' "$CFG" || echo 'boot_delay=1' >> "$CFG"
if grep -q '^dtparam=i2c_arm' "$CFG"; then
  sed -i 's/^dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "$CFG"
else
  echo 'dtparam=i2c_arm=on' >> "$CFG"
fi

# ---------------------------
# 3) Kernel cmdline: USB quirks + strong reboot
# ---------------------------
CMD=/boot/firmware/cmdline.txt
echo "--- Patching $CMD (usb-storage quirks for Pinas bridges + reboot=hard) ..."
cp -an "$CMD"{,.bak.$(date +%Y%m%d%H%M%S)}
# remove any existing reboot= option
sed -i 's/\breboot=[^ ]*//g' "$CMD"
# append quirks and reboot=hard if missing (keep ONE line)
grep -q 'usb-storage\.quirks=1741:1156:u,174e:1155:u' "$CMD" || sed -i 's/$/ usb-storage.quirks=1741:1156:u,174e:1155:u/' "$CMD"
grep -q 'reboot=' "$CMD" || sed -i 's/$/ reboot=hard/' "$CMD"
sed -i 's/  \+/ /g' "$CMD"

echo ">>> cmdline now:"
cat "$CMD"
echo

# ---------------------------
# 4) EEPROM: USB-first + timeout
# ---------------------------
echo "--- Ensuring EEPROM has BOOT_ORDER=0xf41 and USB_MSD_TIMEOUT=20000 ..."
TMP=$(mktemp)
if command -v rpi-eeprom-config >/dev/null 2>&1; then
  rpi-eeprom-config > "$TMP" || true
  grep -q '^BOOT_ORDER=' "$TMP" && sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf41/' "$TMP" || echo 'BOOT_ORDER=0xf41' >> "$TMP"
  grep -q '^USB_MSD_TIMEOUT=' "$TMP" && sed -i 's/^USB_MSD_TIMEOUT=.*/USB_MSD_TIMEOUT=20000/' "$TMP" || echo 'USB_MSD_TIMEOUT=20000' >> "$TMP"
  if rpi-eeprom-config --apply "$TMP" >/dev/null 2>&1; then
    echo "EEPROM config applied."
    rpi-eeprom-update -a || true
  else
    echo "NOTE: Your rpi-eeprom-config may not support --apply."
    echo "      Run: sudo -E rpi-eeprom-config --edit"
    echo "      Set: BOOT_ORDER=0xf41  and  USB_MSD_TIMEOUT=20000"
  fi
else
  echo "NOTE: rpi-eeprom-config not available. Skipping EEPROM edit."
fi
rm -f "$TMP"

# ---------------------------
# 5) Pre-shutdown spin-down service (journald-visible)
# ---------------------------
echo "--- Installing pre-reboot spin-down service ..."
cat >/usr/local/sbin/pre-reboot-usb-reset.sh <<'SH'
#!/bin/sh
LOG=/var/log/pre-usb-reset.log
stamp(){ date '+%F %T'; }
say(){ echo "$(stamp) $*"; logger -t pre-usb-reset -- "$*"; echo "$(stamp) $*" >>"$LOG"; }

say "BEGIN: sync+flush"
sync
for dev in /dev/sd?; do
  [ -e "$dev" ] || continue
  blockdev --flushbufs "$dev" 2>/dev/null || true
done
for dev in /dev/sd?; do
  [ -e "$dev" ] || continue
  say "spin down $dev"
  /usr/bin/sg_start --stop "$dev" >/dev/null 2>&1 || say "note: sg_start failed on $dev"
done
say "sleep 3s to let bridges settle"
sleep 3
say "END (spin-down complete)"
exit 0
SH
chmod +x /usr/local/sbin/pre-reboot-usb-reset.sh

cat >/etc/systemd/system/pre-reboot-usb-reset.service <<'UNIT'
[Unit]
Description=Spin down USB disks before reboot/poweroff
DefaultDependencies=no
Before=shutdown.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pre-reboot-usb-reset.sh
TimeoutSec=20
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=shutdown.target
UNIT

systemctl daemon-reload
systemctl enable pre-reboot-usb-reset.service

# ---------------------------
# 6) Final power-cycle of USB3 hub ports at shutdown (uhubctl)
# ---------------------------
echo "--- Installing system-shutdown hub power-off hook (uhubctl) ..."
# auto-detect hub location (fallback to 2-2 which is common on Pi 4)
HUB_LOC="2-2"
if command -v uhubctl >/dev/null; then
  DETECT=$(uhubctl 2>/dev/null | awk '/^Current status for hub/ {gsub(":","");print $5}' | head -n1)
  [[ -n "${DETECT:-}" ]] && HUB_LOC="$DETECT"
fi

UHUBCTL_BIN="$(command -v uhubctl || echo /usr/sbin/uhubctl)"

cat >/usr/lib/systemd/system-shutdown/30-uhubctl-poweroff <<SH
#!/bin/sh
# Called with \$1 = halt|poweroff|reboot|kexec
HUB="$HUB_LOC"
PORTS="all"
"$UHUBCTL_BIN" -l \$HUB -p \$PORTS -a off >/dev/null 2>&1 || true
sleep 3
exit 0
SH
chmod +x /usr/lib/systemd/system-shutdown/30-uhubctl-poweroff

echo ">>> uhubctl will power OFF hub at location: $HUB_LOC (adjust later if needed via editing the script)."

# ---------------------------
# 7) Hardware watchdog safety net (auto-reset if reboot wedges)
# ---------------------------
echo "--- Enabling hardware watchdog auto-recover (30s) ..."
if grep -q '^RuntimeWatchdogSec=' /etc/systemd/system.conf; then
  sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=30s/' /etc/systemd/system.conf
else
  echo 'RuntimeWatchdogSec=30s' >> /etc/systemd/system.conf
fi
if grep -q '^RebootWatchdogSec=' /etc/systemd/system.conf; then
  sed -i 's/^RebootWatchdogSec=.*/RebootWatchdogSec=30s/' /etc/systemd/system.conf
else
  echo 'RebootWatchdogSec=30s' >> /etc/systemd/system.conf
fi
systemctl daemon-reexec || true

# ---------------------------
# Summary
# ---------------------------
echo
echo "== Done. Applied fixes =="
echo " - Packages: sg3-utils, uhubctl, rpi-eeprom(-images), Raspberry Pi userland tools"
echo " - Journald: persistent (200M/50M, 30 days)"
echo " - /boot/firmware/config.txt : boot_delay=1, dtparam=i2c_arm=on"
echo " - /boot/firmware/cmdline.txt : usb-storage.quirks=1741:1156:u,174e:1155:u reboot=hard"
echo " - EEPROM (best-effort): BOOT_ORDER=0xf41, USB_MSD_TIMEOUT=20000"
echo " - Service: pre-reboot-usb-reset.service (spins disks down)"
echo " - Shutdown hook: 30-uhubctl-poweroff (hub=$HUB_LOC) to truly reset bridges"
echo " - Watchdog: auto-recover in 30s if a reboot wedges"
echo
echo "Next:"
echo " 1) Reboot now: sudo reboot"
echo " 2) Then reboot twice more to confirm stability."
echo " 3) Check previous boot spin-down logs:"
echo "      journalctl -b -1 -u pre-reboot-usb-reset.service --no-pager"
echo "      tail -n 40 /var/log/pre-usb-reset.log"
echo " 4) Verify no UAS:"
echo "      dmesg | grep -i 'UAS is ignored'"
echo " 5) (Optional) Later, reduce USB_MSD_TIMEOUT to 12000 to speed boot."
