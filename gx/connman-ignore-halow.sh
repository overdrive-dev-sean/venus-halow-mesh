#!/bin/sh
# Keep connman away from the HaLow radio. Run from /data/rcS.local, which Venus OS runs at the end of early boot
# (/etc/rcS.d/S99custom-rc-early.sh), before connman starts (/etc/rc5.d/S70connman).
#
# Why: connman manages every Wi-Fi interface it is not told to ignore. It hands the HaLow radio to Venus OS's own
# wpa_supplicant, which then runs a scheduled scan on it about every 14 seconds. Each scan stops mesh traffic for
# about 4 seconds. connman ignores interfaces whose names start with an entry in NetworkInterfaceBlacklist, so this
# adds "halow" to that list. /etc is read-only, so the edited copy goes in /run and is bind-mounted over the original.
# It is rebuilt from the current main.conf at every boot, so a firmware update that changes main.conf is respected.
SRC=/etc/connman/main.conf
DST=/run/venus-halow-connman.conf
[ -f $SRC ] || exit 0
grep -q "^NetworkInterfaceBlacklist=.*halow" $SRC && exit 0
if grep -q "^NetworkInterfaceBlacklist=" $SRC; then
  sed 's/^\(NetworkInterfaceBlacklist=.*\)$/\1,halow/' $SRC > $DST
else
  sed 's/^\[General\]$/[General]\nNetworkInterfaceBlacklist=halow/' $SRC > $DST
fi
grep -q "^NetworkInterfaceBlacklist=.*halow" $DST || { echo "halow: could not add halow to the connman blacklist"; exit 1; }
mount --bind $DST $SRC
