# venus-halow-mesh

Wi-Fi HaLow (802.11ah) 802.11s mesh on a Victron Cerbo GX, with Babel routing. A Morse Micro USB radio plugs
into the GX, the GX joins an existing HaLow mesh as a full mesh point, and Babel routes between it and the other
members. The GX can also offer its own uplink (Ethernet, Wi-Fi or LTE modem) to the mesh as an internet exit.

Everything installs under `/data/halow` and starts from `/data/rc.local`, so a Venus OS firmware update leaves it in
place. The stock Venus OS kernel is not replaced. Three kernel modules are added and loaded at runtime.

This is a bench result from one unit, not a product. Read [Status](#status) before you rely on it.

## Why you might want this

Wi-Fi HaLow runs below 1 GHz (902 to 928 MHz in the US). Signals at those frequencies travel further and get through
walls, trees and terrain better than ordinary 2.4 or 5 GHz Wi-Fi. They also work with simple omnidirectional
antennas, so nobody has to aim a dish. A mesh adds the rest: the radios find each other, and traffic hops
through whichever units are in range.

Some ways that helps a GX owner:

- **A GX far from the network.** A battery bank in a barn, a pump house, a cabin down the hill, a boat on a mooring.
  If one HaLow radio near your router can hear one at the GX, the GX is online. There is no cable to run and no
  point-to-point link to line up.
- **No SIM card for every site.** Several GX devices can share one internet connection over the mesh instead of
  each paying for LTE data.
- **Equipment that moves.** A mesh needs no fixed infrastructure. Units join as they arrive and the routes adjust
  as they move, which suits temporary and mobile power: events, construction, emergency response, RV parks.
- **Any unit can be the uplink.** A GX that has its own Ethernet, Wi-Fi or LTE connection can offer it to the rest
  of the mesh. Babel picks the cheapest working uplink, so LTE is used only when nothing else is left.
- **One place to reach everything.** From a laptop on the mesh, or through any unit with internet, you can reach the
  remote console, SSH and MQTT of every GX on it.

We use it to centrally monitor fleets of GX devices that move between sites, without depending on LTE.

This repo has only been tested at bench range. Measure range at your own site before you rely on it.

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

The stock kernel loads the Morse driver's dependencies, but five things stop a working mesh, and one has no workaround yet.

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

4. **connman claims the radio and Venus OS's wpa_supplicant scans it.** mac80211 creates a radio's first
   interface as `wlan0`, and connman sees it before udev can rename it. connman then hands it to Venus OS's own
   `wpa_supplicant`, which runs a scheduled scan on it about every 14 seconds. Each scan stops mesh traffic for
   about 4 seconds, so pings show 4-second stalls and some loss. Two changes fix it.
   `build/build-kernel-modules.sh` patches the rebuilt mac80211 to name a radio's first interface `halow%d`
   instead of `wlan%d`. `gx/connman-ignore-halow.sh` runs from `/data/rcS.local`, before connman starts, and adds
   `halow` to connman's `NetworkInterfaceBlacklist`. `/etc` is read-only, so it bind-mounts an edited copy from
   `/run`. The Morse driver's own `wlan%d` (in `wiphy.c`) is on its cfg80211-only path and is not used here.
   Side effect: any other mac80211-based USB Wi-Fi adapter on the same GX would also be named `halow*`, and
   connman would ignore it. The Cerbo GX's built-in Wi-Fi drivers do not use mac80211.

5. **No DNS when the mesh is the only uplink.** Venus OS's `/usr/sbin/resolv-watch` points the local dnsmasq at
   connman's resolver file when it has a server, otherwise at pppd's (`/run/ppp/resolv.conf`). With no Ethernet,
   Wi-Fi or modem, both are empty, so the GX routes over the mesh but cannot resolve names.
   `gx/service/halow-watch` writes `FALLBACK_DNS` (default `1.1.1.1 8.8.8.8`) into pppd's file while the internet
   route is on `halow0`, connman has no server and pppd is not running. resolv-watch then picks it up by its own
   rules. A modem connection overwrites the file, and the watcher clears its entries when the mesh stops being the
   route. An earlier version re-pointed the symlink itself, and resolv-watch put it back every 10 to 30 seconds.
   The same watcher restarts the mesh and Babel services when the radio is unplugged or resets, because
   `wpa_supplicant_s1g` neither exits nor reattaches when its interface goes away.

**Known limitation: do not switch Wi-Fi off on a HaLow GX.** Venus OS's Wi-Fi off switch soft-blocks every Wi-Fi
radio through rfkill, including the HaLow radio, so the mesh drops. Unblocking the HaLow radio behind connman's back
was tried and rejected: connman then believes Wi-Fi is back on, and the built-in Wi-Fi cannot be switched on again.
To stop using a Wi-Fi uplink, forget the network instead. If you are locked out, switch Wi-Fi on from the GX screen
or plug in Ethernet.

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
  connman-ignore-halow.sh   keeps connman off the radio (run from /data/rcS.local)
  zz-venus-halow.rules      the udev fix above
  halow.env.example         country, driver options, addresses, exit costs
  halow-mesh.conf.example   wpa_supplicant_s1g mesh config
  service/halow-mesh/       daemontools service: mesh point
  service/halow-babel/      daemontools service: Babel on halow0
  service/halow-watch/     daemontools service: DNS fallback when the mesh is the only uplink
  service/halow-exit/      daemontools service: uplink guard (tests each uplink, steers own traffic, gates the exit)
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
   ln -s /data/halow/service/halow-watch /service/halow-watch
   ln -s /data/halow/service/halow-exit /service/halow-exit
   ```

**Country is a compliance setting.** The Morse driver's built-in default is `AU` (915 to 928 MHz). `load.sh`
refuses to load without `HALOW_COUNTRY`.

## Routing

Babel runs on `halow0` only. It uses the same policy as the peer nodes on our mesh:

- The GX announces its loopback address (`BABEL_ADDR`).
- With `HALOW_EXIT=1`, it also offers its best working uplink as an internet exit, at a cost per uplink type:
  `eth0` 256, `wifi0` 512, `ppp0` (LTE modem) 4096. One good radio hop costs about 256. Lower wins, so a mesh
  member uses LTE only when nothing else is left. Mesh traffic is NATed out of any non-mesh interface.
- It accepts only member loopbacks (`LOOPBACK_PREFIX`, default `10.200.0.0/16`) and a default route from peers. Any other prefix is
  refused, so a peer cannot pull a LAN range or a cloud address onto the mesh with a more specific route.
  The prefixes are `LOOPBACK_PREFIX` and `NAT_NETS` in `halow.env`.
- Routes learned from Babel go into the kernel at metric 900, so a unit's own uplink always beats a mesh route.
  A GX that loses its own uplink falls back to the mesh.

### The uplink guard (`halow-exit`)

Venus OS keeps one default route, on the first connected of Ethernet, Wi-Fi and modem, and never tests it. A cable
into a router whose own internet is down still counts as connected. Measured: with the upstream router's WAN
unplugged, the GX stayed on Ethernet with no internet while its Wi-Fi sat connected and unused. On a mesh that is
worse than a dead link. If that router is a mesh member, the GX offers the member its own dead uplink back, and
traffic loops between the two.

`gx/service/halow-exit` tests every uplink and acts on the result:

- **Probe.** Each uplink has its own routing table, so all of them are tested at the same time, whichever one
  Venus OS prefers. The probe is a ping to `PROBE_TARGETS`, then a TCP connect for networks that drop ping. An
  uplink is down after 3 failures in a row and up after 3 passes in a row. One that was down waits
  `EXIT_HOLD_SECONDS` (20) before it is used again.
- **Own traffic.** The cheapest healthy uplink's default route goes into table 220, which is looked up before
  connman's default route. With no healthy uplink, the default route learned from Babel goes there, so the mesh
  beats a dead cable. connman also pins each uplink's DNS servers to that uplink with host routes. The guard
  re-points those while the uplink is down.
- **Mesh exit.** The same route goes into table 210, and babeld announces only what is in that table. An uplink is
  offered to the mesh only while it passes the probe.
- **No probe crosses the mesh.** The GX refuses to forward mesh traffic to the probe targets. Without that, a
  probe sent into a mesh member with a dead uplink comes back over the radio, leaves through the GX's other
  uplink, and passes. So choose probe targets that nothing on the mesh needs. The defaults are `1.0.0.1` and
  `8.8.4.4`. Every exit on a mesh should drop the same targets.
- **Fail-safe.** When the service stops it removes its rules, tables and firewall entries. The GX then routes as
  stock Venus OS and offers no exit.

`cat /run/halow-exit/state` shows the current choice and each uplink's state.

## Check it

```
svstat /service/halow-mesh /service/halow-babel /service/halow-watch /service/halow-exit
iw phy $(cat /sys/class/net/halow0/phy80211/name) info | grep -A8 'interface modes'   # expect: mesh point
iw dev halow0 station dump | grep -E 'Station|mesh plink'                             # expect: ESTAB
LD_LIBRARY_PATH=/data/halow/lib /data/halow/bin/morse_cli -i halow0 version
ip route | grep 'proto babel'
cat /sys/module/morse/parameters/country
udevadm test --action=add /sys/class/net/halow0 2>&1 | grep -E '^RUN|run:'           # expect: only /bin/true runs
```

## Tailscale

Tailscale, if you run it on the GX, keeps working alongside this setup, which was tested with it installed.
Without the connman fix, the network-manager restart Venus OS performs when a new radio appears also takes
`tailscale0` down.

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
| Mesh as the only uplink (Wi-Fi disconnected, Ethernet out) | VRM stayed live, Tailscale worked, fresh DNS lookups resolved through `halow-watch` |
| Dongle unplugged and plugged back in while running | mesh and Babel back 29 s after the replug, via `halow-watch` |
| Reboot with no dongle, then dongle plugged in | clean boot; mesh up within about 30 s of plugging in |
| Uplink returns, Wi-Fi then Ethernet | route, DNS and mesh switched back with no help; Ethernet preferred over Wi-Fi |
| Upstream router's WAN unplugged, GX cabled to that router (a mesh member), GX Wi-Fi connected | guard moved the GX to Wi-Fi in about 20 s; the router came back online through the GX (10 of 10 pings); no loop |
| That WAN plugged back in | GX back on Ethernet 24 s later; the router back on its own uplink |
| Guard stopped | every rule, table and firewall entry removed; routing as stock |
| Mesh pings with connman kept off the radio | 660 of 660 replies, worst 128 ms, no scans on `halow0` |
| Mesh pings while connman managed the radio | 4-second stalls about every 14 s, up to 32% loss |

Not tested yet:

- **Range.** All results are at bench distance.
- **A Venus OS update that changes the kernel.** The modules are stamped for one kernel release. `load.sh` then
  refuses to load them and the GX runs on without HaLow, but this path has not been exercised. Rebuild for the new
  release.
- **Ekrano GX and other GX models.** Only the Cerbo GX was tested. The build is armv7 only.
- **The GX LTE modem (`ppp0`) as an uplink or exit.** The guard handles it by the same rules, with no modem on the bench.
- **An uplink that drops ping and TCP 443 to the probe targets.** The guard treats it as down.
- **More than two mesh members.**

## Power save

`halow.env.example` sets `enable_ps=0`, which turns off the driver's power save (its build default is `2`, fully
enabled). All the clean results above ran with it off on both ends. Its effect on its own is not measured yet:
early tests that seemed to show it causing the stalls were really showing connman's scans. 802.11 power save
cannot be changed at runtime (`iw dev halow0 set power_save off` returns `Operation not supported`), so the
module option is the only switch.

## Sources and licenses

The scripts in this repo are MIT licensed (see `LICENSE`). The repo holds scripts only. The build fetches everything else at build time:

- Victron kernel: [victronenergy/linux](https://github.com/victronenergy/linux), GPL-2.0
- Morse Micro driver, hostap fork, morse_cli, firmware: [github.com/MorseMicro](https://github.com/MorseMicro).
  The firmware has its own license, which `package.sh` copies into the package.
- babeld: Debian's `babeld` package ([jech/babeld](https://github.com/jech/babeld))

No binaries are committed.

## How this was made

The scripts and this README were written with an AI coding assistant (Claude). Every result in
[Status](#status) was measured on real hardware: a Cerbo GX and a HaLow peer on the bench.
