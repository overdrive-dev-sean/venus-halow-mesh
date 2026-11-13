#!/usr/bin/env bash
# Build the userspace a Venus OS GX needs for HaLow, plus the libraries Venus does not ship.
#
#   build/build-userspace.sh OUTDIR
#
# Environment:
#   REF   Morse release tag for hostap and morse_cli (default mm8108-2.2.3, keep it equal to DRIVER_REF)
#
# Writes OUTDIR/bin and OUTDIR/lib:
#   bin/wpa_supplicant_s1g, wpa_cli_s1g   Morse's hostap fork with CONFIG_MESH. Stock wpa_supplicant has no 802.11ah.
#   bin/hostapd_s1g, hostapd_cli_s1g      same fork, access point side (not used by the mesh setup)
#   bin/morse_cli                         chip control over netlink
#   bin/babeld                            Debian trixie armhf babeld 1.13.1. Building from source fails today:
#                                         its rfc6234 submodule upstream (github.com/massar/rfc6234) is gone.
#   lib/libnl-route-3.so.200              wpa_supplicant_s1g needs it, Venus OS does not have it
#   lib/libb2.so.1, lib/libgomp.so.1      babeld needs them, Venus OS does not have them
#
# Binaries are built against Debian bookworm armhf (glibc 2.36). The trixie babeld needs GLIBC_2.34 and its
# libgomp GLIBC_2.38. Venus OS v3.85 on a Cerbo GX has glibc 2.39, libssl.so.3, libnl-3 and libnl-genl-3.
set -euo pipefail
OUT="${1:?OUTDIR}"; REF="${REF:-mm8108-2.2.3}"
case "$REF" in *[!A-Za-z0-9._-]*|"") echo "build: bad REF" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "build: docker is required" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'docker run --rm -v "$WORK:/w" debian:bookworm rm -rf /w/out /w/build.log >/dev/null 2>&1; rm -rf "$WORK"' EXIT

cat > "$WORK/build.sh" <<INNER
set -e
exec > /work/build.log 2>&1
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture armhf
apt-get update -qq
apt-get install -y -qq --no-install-recommends git make ca-certificates crossbuild-essential-armhf pkgconf file \
  libnl-3-dev:armhf libnl-genl-3-dev:armhf libnl-route-3-dev:armhf libssl-dev:armhf libdbus-1-dev:armhf \
  libusb-1.0-0-dev:armhf
export CC=arm-linux-gnueabihf-gcc PKG_CONFIG=arm-linux-gnueabihf-pkg-config
mkdir -p /work/out/bin /work/out/lib
git clone -q --depth 1 --branch "$REF" https://github.com/MorseMicro/hostap.git /hostap
cd /hostap/wpa_supplicant && cp defconfig .config && sed -i 's/^#CONFIG_MESH=y/CONFIG_MESH=y/' .config
make -j"\$(nproc)" CC=\$CC PKG_CONFIG=\$PKG_CONFIG EXTRA_CFLAGS="-Wno-error"
cp wpa_supplicant_s1g wpa_cli_s1g /work/out/bin/
cd /hostap/hostapd && cp defconfig .config
make -j"\$(nproc)" CC=\$CC PKG_CONFIG=\$PKG_CONFIG EXTRA_CFLAGS="-Wno-error"
cp hostapd_s1g hostapd_cli_s1g /work/out/bin/
git clone -q --depth 1 --branch "$REF" https://github.com/MorseMicro/morse_cli.git /cli
cd /cli && make CC=\$CC PKG_CONFIG=\$PKG_CONFIG CONFIG_MORSE_TRANS_NL80211=1 all
cp morse_cli /work/out/bin/
cp -L /usr/lib/arm-linux-gnueabihf/libnl-route-3.so.200 /work/out/lib/
arm-linux-gnueabihf-strip /work/out/bin/* || true
chown -R $(id -u):$(id -g) /work/out /work/build.log
INNER

cat > "$WORK/babeld.sh" <<INNER
set -e
exec >> /work/build.log 2>&1
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture armhf
apt-get update -qq
cd /tmp && apt-get download -qq babeld:armhf libb2-1:armhf libgomp1:armhf
for p in *.deb; do dpkg -x \$p x; done
cp x/usr/sbin/babeld /work/out/bin/
cp -L x/usr/lib/arm-linux-gnueabihf/libb2.so.1 x/usr/lib/arm-linux-gnueabihf/libgomp.so.1 /work/out/lib/
chown -R $(id -u):$(id -g) /work/out /work/build.log
for f in /work/out/bin/* /work/out/lib/*; do echo "BUILT \$(basename \$f)"; done
INNER

echo "build: userspace at Morse $REF, plus babeld. This takes about 10 minutes."
docker run --rm -v "$WORK:/work" debian:bookworm bash /work/build.sh \
  && docker run --rm -v "$WORK:/work" debian:trixie bash /work/babeld.sh \
  || { echo "build: failed. Last log lines:" >&2; tail -n 60 "$WORK/build.log" >&2; exit 1; }
grep "^BUILT" "$WORK/build.log"
mkdir -p "$OUT" && cp -r "$WORK/out/." "$OUT/"
echo "build: wrote $OUT"
