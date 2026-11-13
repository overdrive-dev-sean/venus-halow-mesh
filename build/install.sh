#!/usr/bin/env bash
# Copy a package to a GX and hook it into boot. Run from a machine with root SSH access to the GX.
#
#   build/install.sh PKG_DIR GX_HOST MESH_CONF
#
#   MESH_CONF   your wpa_supplicant_s1g mesh config (see gx/halow-mesh.conf.example). It holds the mesh
#               password, so it is copied with mode 0600 and never printed.
#
# Writes /data/halow on the GX, keeps an existing halow.env, and adds two lines to /data/rc.local that link the
# supervised services into /service at boot. Everything lives on /data, so a Venus OS firmware update keeps it.
# Nothing loads until the services start: run `svc -u` or reboot (the script prints the commands).
set -euo pipefail
PKG="${1:?PKG_DIR}"; GX="${2:?GX_HOST}"; CONF="${3:?MESH_CONF}"
[ -r "$CONF" ] || { echo "install: cannot read $CONF" >&2; exit 2; }
SSH=(ssh -o BatchMode=yes "root@$GX")
WANT=$(modinfo -F vermagic "$PKG/modules/morse.ko" | cut -d' ' -f1)
HAVE=$("${SSH[@]}" uname -r)
[ "$WANT" = "$HAVE" ] || { echo "install: the package is built for kernel $WANT but $GX runs $HAVE. Rebuild for $HAVE." >&2; exit 2; }
"${SSH[@]}" 'rm -rf /data/halow.new && mkdir -p /data/halow.new'
scp -q -r -o BatchMode=yes "$PKG/." "root@$GX:/data/halow.new/"
"${SSH[@]}" 'umask 077; cat > /data/halow.new/halow-mesh.conf' < "$CONF"
"${SSH[@]}" 'set -e
# Stop running services before swapping the tree: daemontools keeps its supervise state inside the service
# directory, so moving it under a running supervisor would orphan the processes.
for s in halow-watch halow-babel halow-mesh; do
  if [ -e /service/$s ]; then svc -dx /service/$s /service/$s/log 2>/dev/null || true; rm -f /service/$s; fi
done
sleep 3
for p in $(pidof wpa_supplicant_s1g babeld 2>/dev/null); do kill $p 2>/dev/null || true; done
[ -f /data/halow/halow.env ] && cp /data/halow/halow.env /data/halow.new/halow.env
[ -f /data/halow.new/halow.env ] || cp /data/halow.new/halow.env.example /data/halow.new/halow.env
chmod 600 /data/halow.new/halow-mesh.conf
[ -d /data/halow ] && rm -rf /data/halow.prev && mv /data/halow /data/halow.prev
mv /data/halow.new /data/halow
[ -f /data/rc.local ] || printf "#!/bin/sh\nexit 0\n" > /data/rc.local
chmod 755 /data/rc.local
[ -f /data/rcS.local ] || printf "#!/bin/sh\nexit 0\n" > /data/rcS.local
chmod 755 /data/rcS.local
grep -q connman-ignore-halow /data/rcS.local || sed -i "s|^exit 0|# HaLow: keep connman away from the radio, before connman starts (venus-halow-mesh)\n/data/halow/connman-ignore-halow.sh\nexit 0|" /data/rcS.local
grep -q /service/halow-mesh /data/rc.local || sed -i "s|^exit 0|# HaLow mesh + Babel (venus-halow-mesh)\n[ -e /service/halow-mesh ] \|\| ln -s /data/halow/service/halow-mesh /service/halow-mesh\n[ -e /service/halow-babel ] \|\| ln -s /data/halow/service/halow-babel /service/halow-babel\n[ -e /service/halow-watch ] \|\| ln -s /data/halow/service/halow-watch /service/halow-watch\nexit 0|" /data/rc.local
grep -q /service/halow-watch /data/rc.local || sed -i "s|^exit 0|[ -e /service/halow-watch ] \|\| ln -s /data/halow/service/halow-watch /service/halow-watch\nexit 0|" /data/rc.local
echo "install: done. Edit /data/halow/halow.env (addresses, exit costs), then start:"
echo "  ln -s /data/halow/service/halow-mesh /service/halow-mesh; sleep 30; ln -s /data/halow/service/halow-babel /service/halow-babel; ln -s /data/halow/service/halow-watch /service/halow-watch"'
