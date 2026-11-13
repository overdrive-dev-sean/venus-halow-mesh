# venus-halow-mesh

Wi-Fi HaLow (802.11ah) 802.11s mesh on a Victron Cerbo GX, with Babel routing. A Morse Micro USB radio plugs
into the GX, the GX joins an existing HaLow mesh as a full mesh point, and Babel routes between it and the other
members. The GX can also offer its own uplink (Ethernet, Wi-Fi or LTE modem) to the mesh as an internet exit.

Everything installs under `/data/halow` and starts from `/data/rc.local`, so a Venus OS firmware update leaves it in
place. The stock Venus OS kernel is not replaced. Three kernel modules are added and loaded at runtime.

This is a bench result from one unit, not a product. Read [Status](#status) before you rely on it.

## Tested with

| Item | Version |
|---|---|
| GX | Cerbo GX (armv7) |
| Venus OS | v3.85, kernel `6.12.90-venus-6` |
| Radio | Morse Micro MM8108 USB dongle, USB ID `325b:8100`, board type `0x804` |
| Morse release | driver, firmware, hostap fork and morse_cli all at `mm8108-2.2.3` (firmware branch `2.2`) |
| Routing | babeld 1.13.1 |
| Mesh peer | a Debian x86 node with the same Morse release, also running babeld 1.13.1 |

## What Venus OS needed

The stock kernel loads the Morse driver's dependencies, but three things stop a working mesh.

1. **No mesh support in mac80211.** The kernel is built with `CONFIG_MAC80211_MESH` off, so the radio offers no
   mesh point mode. `build/build-kernel-modules.sh` rebuilds `mac80211.ko` from the matching
   `victronenergy/linux` tag with mesh on. On a Cerbo GX nothing else uses mac80211 (the built-in Wi-Fi drivers
   are cfg80211-only), so the swap affects only the HaLow radio.
2. **No CRC7.** The kernel has `CONFIG_CRC7` off. `morse.ko` then fails with
   `Unknown symbol crc7_be_syndrome_table`. The same script builds `lib/crc7.ko`.
3. **The Wi-Fi udev rule disables the built-in Wi-Fi.** `/etc/udev/rules.d/wlan.rules` treats any USB Wi-Fi that
   is not the built-in adapter as an external replacement. Its `wlan-update` script renames the built-in `wifi0`
   to `disabled-wifi0` and kills `connmand`. The GX drops off Wi-Fi, and the connman restart also takes
   `tailscale0` down. This looks like a kernel hang from the outside, but it is not. `gx/zz-venus-halow.rules`
   fixes it. It sorts after `wlan.rules` and replaces the `RUN` list for vendor `325b` on add and on remove.
   It also names the radio `halow0`. udev refuses to rewrite `DEVTYPE`, which was the first thing tried.

Victron builds kernels without module signing or `MODVERSIONS`, so modules built from the same tag load as long as
the vermagic string matches.

The userspace also needs Morse's hostap fork (`wpa_supplicant_s1g`, because stock wpa_supplicant has no 802.11ah),
`morse_cli`, `babeld`, and three libraries Venus OS does not ship: `libnl-route-3`, `libb2` and `libgomp`.

## Layout

```
build/
  build-kernel-modules.sh   crc7.ko, mac80211.ko (mesh on), morse.ko, cross-built in Docker
  build-userspace.sh        wpa_supplicant_s1g, hostapd_s1g, morse_cli, babeld, and the extra libraries
  package.sh                assembles the /data/halow tree, including the Morse firmware and board files
  install.sh                copies a package to a GX over SSH and adds the boot hook
gx/                         files that go in /data/halow on the GX
  load.sh                   loads the stack (idempotent), installs the udev rule first
  zz-venus-halow.rules      the udev fix above
  halow.env.example         country, driver options, addresses, exit costs
  halow-mesh.conf.example   wpa_supplicant_s1g mesh config
  service/halow-mesh/       daemontools service: mesh point
  service/halow-babel/      daemontools service: Babel on halow0
```

## Build and install

You need Docker on the build machine and root SSH access to the GX.

1. Read the GX kernel release and config:
   ```
   ssh root@GX uname -r
   ssh root@GX 'zcat /proc/config.gz' > venus.config
   ```
2. Build the kernel modules for that exact release. It takes 10 to 20 minutes.
   ```
   build/build-kernel-modules.sh 6.12.90-venus-6 venus.config out/modules
   ```
3. Build the userspace (about 10 minutes):
   ```
   build/build-userspace.sh out/userspace
   ```
4. Assemble the package:
   ```
   build/package.sh out/modules out/userspace pkg
   ```
5. Copy `gx/halow-mesh.conf.example` to `halow-mesh.conf`. Set the `ssid`, `channel` and `sae_password` of your
   mesh. Every member must match.
6. Install. The script refuses a GX whose kernel does not match the modules.
   ```
   build/install.sh pkg GX halow-mesh.conf
   ```
7. On the GX, edit `/data/halow/halow.env`. Set `HALOW_COUNTRY` for where you operate, and pick a unique
   `HALOW_ADDR` and `BABEL_ADDR`.
8. Start the services, or reboot:
   ```
   ln -s /data/halow/service/halow-mesh /service/halow-mesh
   sleep 30
   ln -s /data/halow/service/halow-babel /service/halow-babel
   ```

**Country is a compliance setting.** The Morse driver's built-in default is `AU` (915 to 928 MHz). `load.sh`
refuses to load without `HALOW_COUNTRY`.

## Routing

Babel runs on `halow0` only. It uses the same policy as the peer nodes on our mesh:

- The GX announces its loopback address (`BABEL_ADDR`).
- With `HALOW_EXIT=1`, it also announces its own default routes, each at a cost per uplink type: `eth0` 128,
  `wifi0` 192, `ppp0` (LTE modem) 1024. Lower wins, so a mesh member uses LTE only when nothing else is left.
  Mesh traffic is NATed out of any non-mesh interface.
- Routes learned from Babel go into the kernel at metric 900, so a unit's own uplink always beats a mesh route.
  A GX that loses its own uplink falls back to the mesh.

## Check it

```
svstat /service/halow-mesh /service/halow-babel
iw phy $(cat /sys/class/net/halow0/phy80211/name) info | grep -A8 'interface modes'   # expect: mesh point
iw dev halow0 station dump | grep -E 'Station|mesh plink'                             # expect: ESTAB
LD_LIBRARY_PATH=/data/halow/lib /data/halow/bin/morse_cli -i halow0 version
ip route | grep 'proto babel'
cat /sys/module/morse/parameters/country
udevadm test --action=add /sys/class/net/halow0 2>&1 | grep -E '^RUN|run:'           # expect: only /bin/true runs
```

## Status

What was tested, on one Cerbo GX and one peer, at bench range (about 1 m):

| Test | Result |
|---|---|
| Driver load with mesh-capable mac80211 | `mesh point` offered, firmware and board file load |
| Mesh join | link ESTAB on both ends, -22 to -24 dBm |
| Ping between mesh addresses, GX to peer and back | 0% loss in most runs, see the delay note below |
| Babel | each end learns the other's loopback route, and the GX learns the peer's default route |
| GX as an internet exit | a test route on the peer through the GX reached the internet through the GX's Wi-Fi uplink |
| Reboot | everything returned with no help: built-in Wi-Fi, Tailscale, driver, mesh, Babel, NAT |
| Driver unload | the built-in Wi-Fi and Tailscale stayed up |
| Mixed releases | a GX on Morse 2.0.0 formed a mesh with a 2.2.3 peer |

Not tested yet:

- **Range.** All results are at bench distance.
- **Power save.** With the driver default (`enable_ps=2`, fully enabled), ping delay spiked to 4.2 s. With it off on
  the GX only, one run showed a worst case of 126 ms, but a later run averaged 936 ms with the peer still in power
  save. The comparison with power save off on both ends is not finished. `halow.env.example` sets `enable_ps=0`
  on the GX. 802.11 power save cannot be changed at runtime (`iw ... set power_save off` returns
  `Operation not supported`), so the driver option is the only switch.
- **A Venus OS update that changes the kernel.** The modules are stamped for one kernel release. `load.sh` then
  refuses to load them and the GX runs on without HaLow, but this path has not been exercised. Rebuild for the new
  release.
- **Ekrano GX and other GX models.** Only the Cerbo GX was tested. The build is armv7 only.
- **More than two mesh members.**

## Sources and licenses

The repo holds scripts only. The build fetches everything else at build time:

- Victron kernel: [victronenergy/linux](https://github.com/victronenergy/linux), GPL-2.0
- Morse Micro driver, hostap fork, morse_cli, firmware: [github.com/MorseMicro](https://github.com/MorseMicro).
  The firmware has its own license, which `package.sh` copies into the package.
- babeld: Debian's `babeld` package ([jech/babeld](https://github.com/jech/babeld))

No binaries are committed.
