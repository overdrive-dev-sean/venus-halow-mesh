#!/usr/bin/env bash
# Build the kernel modules a Venus OS GX needs for a Morse Micro HaLow USB radio in 802.11s mesh mode.
#
#   build/build-kernel-modules.sh KREL KERNEL_CONFIG OUTDIR
#
#   KREL           `uname -r` on the GX, for example 6.12.90-venus-6
#   KERNEL_CONFIG  the GX's running config:  ssh root@GX 'zcat /proc/config.gz' > venus.config
#   OUTDIR         where crc7.ko, mac80211.ko and morse.ko go
#
# Environment:
#   DRIVER_REF     Morse driver tag (default mm8108-2.2.3)
#
# What it builds, and why:
#   crc7.ko       The Venus kernel has CONFIG_CRC7 off, and morse.ko needs crc7_be_syndrome_table.
#   mac80211.ko   The Venus kernel has CONFIG_MAC80211_MESH off. Without it the radio offers no mesh point mode.
#                 This rebuilds mac80211 from the same Victron kernel tag with mesh on. On a Cerbo GX nothing
#                 else uses mac80211 (the built-in Wi-Fi drivers are cfg80211-only), so swapping it is contained.
#                 Patched to name a radio's first interface halow%d instead of wlan%d (see below).
#   morse.ko      The Morse Micro driver, built against that same tree. From 2.2.x it includes dot11ah.
#
# Victron builds kernels with module signing and MODVERSIONS off, so only the vermagic string has to match.
# LOCALVERSION= stops the build from stamping "<KREL>+". KBUILD_MODPOST_WARN=1 lets single-module builds link
# without a full Module.symvers; the running kernel resolves the symbols at load time.
# armv7 only for now (Cerbo GX family).
set -euo pipefail
KREL="${1:?KREL}"; CONFIG="${2:?KERNEL_CONFIG}"; OUT="${3:?OUTDIR}"
DRIVER_REF="${DRIVER_REF:-mm8108-2.2.3}"
case "$KREL" in *[!A-Za-z0-9._-]*|"") echo "build: '$KREL' is not a plain kernel release" >&2; exit 2 ;; esac
case "$DRIVER_REF" in *[!A-Za-z0-9._-]*|"") echo "build: bad DRIVER_REF" >&2; exit 2 ;; esac
[ -s "$CONFIG" ] || { echo "build: kernel config '$CONFIG' is missing or empty" >&2; exit 2; }
command -v docker >/dev/null || { echo "build: docker is required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'docker run --rm -v "$WORK:/w" debian:bookworm rm -rf /w/out /w/build.log >/dev/null 2>&1; rm -rf "$WORK"' EXIT
cp "$CONFIG" "$WORK/kernel.config"
cat > "$WORK/build.sh" <<INNER
set -e
exec > /work/build.log 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git make gcc libc6-dev gcc-arm-linux-gnueabihf bc bison flex \
  libssl-dev libelf-dev ca-certificates kmod python3 file
git clone -q --depth 1 --branch "v$KREL" https://github.com/victronenergy/linux /src
cd /src
cp /work/kernel.config .config
scripts/config --module CONFIG_CRC7
scripts/config --enable CONFIG_MAC80211_MESH
M="make -s ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION="
\$M olddefconfig
[ "\$(\$M kernelrelease)" = "$KREL" ] || { echo "kernelrelease \$(\$M kernelrelease) != $KREL"; exit 3; }
grep -q "^CONFIG_MAC80211_MESH=y" .config || { echo "CONFIG_MAC80211_MESH did not stick"; exit 4; }
# mac80211 creates a radio's first interface as "wlan%d" (net/mac80211/main.c). connman sees that name before
# udev can rename it, claims the radio as ordinary Wi-Fi, and Venus OS's wpa_supplicant then scans it. This
# mac80211 serves only the HaLow radio, so name the first interface halow%d instead, which connman ignores once
# gx/connman-ignore-halow.sh has added "halow" to its blacklist.
[ "\$(grep -c '"wlan%d"' net/mac80211/main.c)" = 1 ] || { echo "net/mac80211/main.c: expected exactly one \"wlan%d\""; exit 6; }
sed -i 's/"wlan%d"/"halow%d"/' net/mac80211/main.c
\$M -j"\$(nproc)" modules_prepare
\$M -j"\$(nproc)" KBUILD_MODPOST_WARN=1 lib/crc7.ko net/mac80211/mac80211.ko
mkdir -p /work/out
cp lib/crc7.ko net/mac80211/mac80211.ko /work/out/
git clone -q --depth 1 --recurse-submodules --branch "$DRIVER_REF" https://github.com/MorseMicro/morse_driver.git /morse
cd /morse
make -j"\$(nproc)" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KERNEL_SRC=/src LOCALVERSION= KBUILD_MODPOST_WARN=1 \
  CONFIG_WLAN_VENDOR_MORSE=m CONFIG_MORSE_USB=y CONFIG_MORSE_SDIO=n CONFIG_MORSE_SPI=n \
  CONFIG_MORSE_USER_ACCESS=y CONFIG_MORSE_VENDOR_COMMAND=y
find /morse -name '*.ko' -exec cp {} /work/out/ \;
for k in /work/out/*.ko; do
  v=\$(modinfo -F vermagic \$k)
  case "\$v" in "$KREL "*) ;; *) echo "BAD vermagic \$(basename \$k): \$v"; exit 5 ;; esac
  echo "BUILT \$(basename \$k): \$v"
done
chown -R $(id -u):$(id -g) /work/out /work/build.log
INNER
echo "build: kernel modules for $KREL, Morse $DRIVER_REF. This takes 10 to 20 minutes."
if ! docker run --rm -v "$WORK:/work" debian:bookworm bash /work/build.sh; then
  echo "build: failed. Last log lines:" >&2; tail -n 60 "$WORK/build.log" >&2; exit 1
fi
grep "^BUILT" "$WORK/build.log"
mkdir -p "$OUT" && cp "$WORK"/out/*.ko "$OUT/"
echo "build: wrote $OUT"
