#!/usr/bin/env bash
# Assemble the /data/halow tree for a GX from the build outputs, the Morse firmware and gx/.
#
#   build/package.sh MODULES_DIR USERSPACE_DIR PKG_DIR
#
# Environment:
#   FIRMWARE_REF   morse-firmware branch (default 2.2, which matches driver mm8108-2.2.3; there is no 2.2 tag)
#
# The firmware repo installs every .bin into one flat directory (its Makefile targets /lib/firmware/morse).
# On a GX the root filesystem is read-only, so load.sh points the kernel's firmware search path at
# /data/halow/firmware instead, and the files go in /data/halow/firmware/morse/.
set -euo pipefail
MODS="${1:?MODULES_DIR}"; USR="${2:?USERSPACE_DIR}"; PKG="${3:?PKG_DIR}"
FIRMWARE_REF="${FIRMWARE_REF:-2.2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in crc7.ko mac80211.ko morse.ko; do [ -s "$MODS/$f" ] || { echo "package: missing $MODS/$f" >&2; exit 2; }; done
[ -x "$USR/bin/wpa_supplicant_s1g" ] || { echo "package: missing $USR/bin/wpa_supplicant_s1g" >&2; exit 2; }

rm -rf "$PKG"; mkdir -p "$PKG/modules" "$PKG/firmware/morse"
cp "$MODS"/crc7.ko "$MODS"/mac80211.ko "$MODS"/morse.ko "$PKG/modules/"
cp -r "$USR/bin" "$USR/lib" "$PKG/"
FW="$(mktemp -d)"; trap 'rm -rf "$FW"' EXIT
git clone -q --depth 1 --branch "$FIRMWARE_REF" https://github.com/MorseMicro/morse-firmware.git "$FW/fw"
find "$FW/fw/bcf" "$FW/fw/firmware" -name '*.bin' -exec cp {} "$PKG/firmware/morse/" \;
cp "$FW/fw/LICENSE" "$PKG/firmware/morse/LICENSE.morse-firmware"
cp -r "$HERE/gx/." "$PKG/"
chmod 755 "$PKG/load.sh" "$PKG/connman-ignore-halow.sh" "$PKG"/service/*/run "$PKG"/service/*/log/run "$PKG"/bin/*
echo "package: $(find "$PKG" -type f | wc -l) files, $(du -sh "$PKG" | cut -f1) in $PKG"
