#!/bin/sh
# Load the HaLow stack: crc7, mesh-capable mac80211, morse. Idempotent. Lives in /data/halow so firmware
# updates keep it. Called by service/halow-mesh/run.
H=/data/halow
[ -r $H/halow.env ] && . $H/halow.env

# 1. Install the udev rule BEFORE the radio gets a network interface. Without it, Venus OS's
#    /etc/udev/rules.d/wlan.rules treats the radio as an external Wi-Fi adapter and disables the built-in wifi0.
mkdir -p /run/udev/rules.d
cp $H/zz-venus-halow.rules /run/udev/rules.d/zz-venus-halow.rules
udevadm control --reload 2>/dev/null

lsusb | grep -q "325b:" || { echo "halow: no Morse Micro radio on USB"; exit 1; }
lsmod | grep -q "^morse " && exit 0

# 2. Modules must match the running kernel exactly.
K=$(uname -r)
if ! modinfo -F vermagic $H/modules/morse.ko 2>/dev/null | grep -q "^$K "; then
  echo "halow: modules in $H/modules are not built for kernel $K, not loading"; exit 1
fi

# 3. The rootfs is read-only, so point the firmware loader at /data. This is a runtime setting, so it is set on every load.
printf %s $H/firmware > /sys/module/firmware_class/parameters/path

# 4. A stock mac80211 (built without mesh) must not be loaded. On a Cerbo GX nothing else uses it.
if lsmod | grep -q "^mac80211 "; then
  grep -q " mesh_path_" /proc/kallsyms 2>/dev/null || rmmod mac80211 || { echo "halow: stock mac80211 is in use"; exit 1; }
fi
modprobe cfg80211
modprobe libarc4 2>/dev/null
lsmod | grep -q "^crc7 " || insmod $H/modules/crc7.ko
lsmod | grep -q "^mac80211 " || insmod $H/modules/mac80211.ko

# 5. country is safety-critical. The driver's built-in default is AU (915 to 928 MHz). Set it for where you operate.
insmod $H/modules/morse.ko country=${HALOW_COUNTRY:?set HALOW_COUNTRY in halow.env} ${MORSE_OPTS:-}

for _ in $(seq 1 30); do [ -e /sys/class/net/halow0 ] && exit 0; sleep 1; done
echo "halow: halow0 did not appear"; exit 1
