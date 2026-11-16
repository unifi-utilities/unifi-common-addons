# AT&T fiber bypass (att-wpa-supplicant)

This addon lets your UniFi gateway connect straight to the AT&T fiber ONT
(optical network terminal, the box where the fiber ends). The AT&T box then
leaves the traffic path, and the gateway gets the public IP address
directly.

AT&T must authorize the connection with 802.1X (port authentication)
before it gives an address. The AT&T box normally does this. The addon
does it instead, with EAP-TLS (authentication with certificates) and the
certificates from your own AT&T box.

**You can go back at any time.** Connect the AT&T box again, and the
internet works as before. See [Go back to the RG](#go-back-to-the-rg).

## Contents

1. [Before you start](#before-you-start): what you need, and the words
   that this README uses
2. [Set up](#set-up): the guided setup
3. [Check the connection](#check-the-connection)
4. [Before a firmware update](#before-a-firmware-update)
5. [Update the addon](#update-the-addon)
6. [If something goes wrong](#if-something-goes-wrong): go back to the
   RG, troubleshooting, messages
7. [Remove the addon](#remove-the-addon)
8. [Reference](#reference): manual setup, move from another bypass,
   commands, how it works, files
9. [Limits and support](#limits-and-support),
   [tested configurations](#tested-configurations), and
   [credits](#credits)

## Before you start

### What you need

- An AT&T fiber line with a separate ONT box. If you use an SFP+ (fiber
  module) ONT stick instead, you do not need this addon.
- The AT&T box, kept nearby. The setup uses its internet access until the
  last step. It is also your fallback.
- A UniFi gateway with
  [unifi-common](https://github.com/unifi-utilities/unifi-common)
  installed.
- SSH access to the gateway as `root`. See
  [Ubiquiti's SSH article](https://help.ui.com/hc/en-us/articles/204909374).
- The certificates from your AT&T box, in a folder on your computer.
  This addon does not extract them, and this README does not tell you
  how. Search for a current guide for your model. Keep a backup of the
  folder off the gateway. The folder must hold four files with these
  names:

  | File | Accepted names |
  |---|---|
  | CA certificate | `CA_*.pem` or `CA.pem` |
  | Client certificate | `Client_*.pem` or `Client.pem` |
  | Private key | `PrivateKey_PKCS1_*.pem` or `PrivateKey*.pem` |
  | Config | `wpa_supplicant.conf`, with an `identity="…"` line (the MAC address of the RG) |

### Words in this README

- **The gateway** is always your UniFi device (UDM, UXG, UCG, or
  similar).
- **The RG** is always the box that AT&T supplied. AT&T calls it a
  residential gateway. Examples are the BGW210, BGW320, NVG589, and
  Pace 5268AC. The addon uses only its certificates, so the model does
  not matter.
- **The WAN port** is the gateway port for the internet connection. Its
  name is an interface name such as `eth8`.
- **The supplicant** is the program (`wpa_supplicant`) that answers the
  802.1X request from AT&T.
- **A bundle** holds the Debian packages of the supplicant and of most
  of its libraries, stored on the gateway. UniFi OS is built on Debian.
  Each Debian version (11 "bullseye", 12 "bookworm", 13 "trixie") needs
  its own bundle. The addon runs the supplicant from the bundle and
  installs no package.

## Set up

> [!IMPORTANT]
> Does another guide already run `wpa_supplicant` on your gateway? The
> setup finds it and asks before it replaces it. First read
> [If you already have a bypass](#if-you-already-have-a-bypass).

The guided setup will be sufficient for most standard setups. It asks you
questions and does most of the work. It asks permission before it
changes the WAN. If it stops, it says why and what to do, and on retry
it skips the steps that are finished. It hides IP addresses, MAC addresses,
and the identity in its output, so you can share if you ask for help.

1. **Log in to the gateway.** On your computer, run:

   ```sh
   ssh root@<gateway-ip>
   ```

2. **Download the addon.** In that SSH session, run:

   ```sh
   cd /tmp
   curl -fsSL https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
     | tar -xz --strip-components=1 unifi-common-addons-main/att-wpa-supplicant
   ```

3. **Start setup.** In that SSH session, run:

   ```sh
   cd att-wpa-supplicant
   ./att-wpa-supplicant setup
   ```

> [!CAUTION]
> In step 6 of the setup, internet access stops when you move the cable.
> It comes back when AT&T accepts the gateway. If AT&T does not accept
> it, the setup tells you how to connect the RG again. If setup stops
> after you moved the cable but before it finished, connect the RG again
> yourself: see [Go back to the RG](#go-back-to-the-rg).

4. **Answer the questions.** The setup has six steps:

   | Step | What happens | What you do |
   |---|---|---|
   | 1. Install | Copies the addon to `/data`. Starts nothing. | Nothing |
   | 2. WAN port | Suggests the port that the internet uses now. | Confirm it, or type the correct name. See [WAN port names](#wan-port-names) if unsure. |
   | 3. Certificates | Looks in `/data/att-certs`. If it finds nothing, it shows an example `scp` command. | Copy your certificate folder from your computer, in a second terminal. If there is more than one folder, choose one. |
   | 4. Download | Downloads the bundle for this Debian version. Offers the other versions, for a later firmware update. | Answer yes (recommended) or no. |
   | 5. Check | Checks the files and that the supplicant loads. Looks for an older bypass. | Nothing |
   | 6. Connect | Tells you to move the ONT cable from the RG to the WAN port. Then waits a few minutes for AT&T. | Move the cable, then type `yes`. |

5. **Done.** The setup ends with
   `Done. The gateway now connects to AT&T directly on <port>.` After
   that, the `att-wpa-supplicant` command works in any directory.

Prefer to type each command yourself? See
[Manual setup](#manual-setup).

### If you already have a bypass

The addon recognizes setups from other guides: the units
`wpa_supplicant-wired@<iface>`, `wpa_supplicant@<iface>`,
`reinstall-wpa`, `setup-att-bypass`, and the stock `wpa_supplicant` with
an override, and the boot scripts `0-att-bypass.sh` and
`10-wpa_supplicant.sh`.

This assumes your current bypass gives internet access, so you do not
need the RG for the setup. Keep it nearby in case you must go back.

The setup suggests the WAN port from the internet route. The unit name or
config file name of your current setup usually contains the port name
too, for example `wpa_supplicant-wired@eth8`.

1. Before you start the setup, put your four certificate files in
   `/data/att-certs` on the gateway:

   - **From `0-att-bypass.sh`:** the files are already together in
     `/data/wpa_supplicant`. Run:

     ```sh
     install -d -m 700 -o root -g root /data/att-certs
     cp /data/wpa_supplicant/*.pem /data/wpa_supplicant/wpa_supplicant.conf /data/att-certs/
     ```

   - **From the [evie-lau guide](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant):**
     that guide names the config file after the interface. Run:

     ```sh
     install -d -m 700 -o root -g root /data/att-certs
     cp /etc/wpa_supplicant/certs/*.pem /data/att-certs/
     cp /etc/wpa_supplicant/wpa_supplicant-wired-<iface>.conf /data/att-certs/wpa_supplicant.conf
     ```

   - **From other setups:** copy the four files the same way. The config
     file must have the name `wpa_supplicant.conf`.

2. Run the setup. In step 5 it lists the parts of the old setup. In
   step 6 it explains the takeover. It asks whether the ONT cable is
   already in the WAN port. If not, it tells you to move the cable
   first. Then it asks you to type `yes`.

   - During the takeover, internet access can stop for a few minutes.
   - If AT&T does not accept the addon, the addon tries to start your old
     setup again. The old setup may take more time to reconnect.
   - If the setup says that it cannot tell who owns the interface
     (`unknown` or `ambiguous`), **stop**. The addon cannot replace that
     setup safely. Do not remove parts that you do not understand.

After a takeover:

- The addon does not change MAC address settings, for example the
  `changemac` script of the evie-lau guide. Keep them if your setup needs
  them.
- To go back to your old setup, run
  `att-wpa-supplicant deactivate <iface> --restore-legacy`.
- If a log shows `ROLLBACK INCOMPLETE`, run that same command to finish
  the restore.

If the takeover fails, check that exactly one supplicant runs on the WAN
port and that the internet works:

```sh
ps -eo pid,args | grep '[w]pa_supplicant.*-i *<iface>'
ping -c 3 1.1.1.1
```

## Check the connection

On the gateway, run:

```sh
att-wpa-supplicant check
```

Example output with interface `eth8`:

```
OK eth8: unit att-wpa-supplicant@eth8.service active
OK eth8: 802.1X authorized
INFO eth8: runtime at start: wpa_supplicant v2.10 from bundle trixie-arm64 (...)
OK eth8: client certificate matches private key
OK eth8: client certificate valid until ...
INFO eth8: interface has an IPv4 address
INFO eth8: IPv4 route to the internet goes out on eth8
INFO bundles: bookworm-arm64, bullseye-arm64, trixie-arm64 (this release: trixie-arm64)
```

- `OK` and `FAIL` lines decide the result. The exit status is 0 only
  when every activated interface is authorized. `WARN` and `INFO` lines
  do not change it.
- `check` sends no traffic, so it does not prove internet access. To test
  the internet, run `ping -c 3 1.1.1.1`. If the `OK` lines are present
  and the ping fails, look at DHCP and the WAN settings in UniFi. The
  address line covers only this interface, and the route line covers only
  traffic from the gateway itself.
- A `WARN bundles` line, or a hint to run `fetch --all`: see
  [Before a firmware update](#before-a-firmware-update).
- `check` never prints the identity, the key, or the WAN address.

The supplicant needs no regular work. systemd starts it at boot and
starts it again 30 seconds after any exit. To read its log, run
`journalctl -u att-wpa-supplicant@<iface> -b`.

**Caution:** a restart stops internet access for a short time. To restart
the supplicant by hand, run `systemctl restart att-wpa-supplicant@<iface>`.

## Before a firmware update

Each Debian version needs its own bundle. A UniFi firmware update may move
the gateway to a newer Debian version. Without a bundle for that version,
internet access stops after the update.

### Before each update

1. Keep the RG nearby.
2. Run `att-wpa-supplicant check`.
3. If its `bundles` line does not list `bullseye`, `bookworm`, and
   `trixie`, run:

   ```sh
   att-wpa-supplicant fetch --all
   ```

   It downloads a bundle for Debian 11, 12, and 13 (about 2 MB each)
   from Debian's servers. It must end with
   `att-wpa-supplicant: fetch: done. Bundles ready for: bullseye bookworm trixie`.

The gateway cannot test a bundle for another Debian version. After the
update, the supplicant tests it at each start.

### If internet access stops after an update

1. [Go back to the RG](#go-back-to-the-rg).
2. On the gateway, run `att-wpa-supplicant fetch`.
3. Connect the ONT cable to the WAN port of the gateway again. systemd
   will try to start the supplicant every 30 seconds.
4. After a few minutes, run `att-wpa-supplicant check`.

## Update the addon

Do this at a quiet time, with the RG nearby as a fallback. On the
gateway:

1. Download the new version as in [Set up](#set-up), step 2. Then run
   `cd att-wpa-supplicant` and `./att-wpa-supplicant install` (not
   `setup`). If the supplicant from the bundle does not load, `install`
   stops and says that nothing changed. `install` does not restart the
   supplicant.
2. Run `att-wpa-supplicant fetch`, or import a bundle that you built with
   the new version. An older bundle holds only `wpasupplicant` and
   `libpcsclite1`. It still works, because the firmware supplies the
   other libraries.
3. Run `att-wpa-supplicant validate <iface>`. It must print
   `att-wpa-supplicant: validate: OK`.
4. **Caution:** internet access stops for a short time. Run
   `systemctl restart att-wpa-supplicant@<iface>`. The new version runs
   from now on.
5. Run `att-wpa-supplicant check`.

Your certificates, instances, and bundles stay in place.

## If something goes wrong

### Go back to the RG

Use this when internet access is down and you need it back now. It
changes only the cables, and VLAN 0 if you set it.

1. At the RG, connect the ONT cable to the **ONT** port of the RG.
2. Connect a LAN port of the RG to the WAN port of the gateway.
3. Wait for the broadband light of the RG to turn green. This can take
   several minutes.
4. On the gateway, run `ping -c 3 1.1.1.1`.

If you set VLAN ID 0 on the WAN for the addon and the ping fails, remove
that setting.

To use the addon again:

1. Set VLAN ID 0 again if you removed it.
2. Connect the ONT cable to the WAN port of the gateway.
3. After a few minutes, run `att-wpa-supplicant check`.
4. If it does not show `802.1X authorized`, restart the supplicant:
   `systemctl restart att-wpa-supplicant@<iface>`. If the setup or
   `activate` failed before, the supplicant does not run: run
   `att-wpa-supplicant setup` again.

### Troubleshooting

If internet access is down, first [go back to the RG](#go-back-to-the-rg).

#### AT&T does not accept the gateway

If the setup or `activate` fails, or `check` shows `802.1X not authorized`:

1. Make sure that the ONT cable is in the WAN port that the setup used.
2. Read the log of the attempt:
   `journalctl -u att-wpa-supplicant@<iface> -b`. If it shows an error,
   fix that error first. After a failed activation, the supplicant is
   stopped on purpose.
3. If the supplicant ran for at least one minute and the log shows no
   `CTRL-EVENT-EAP-` lines, AT&T probably does not answer the gateway.
   Some gateways need one or both of these WAN settings in UniFi:
   - **MAC address clone:** set the WAN MAC address to the `identity`
     value in your `wpa_supplicant.conf`. Try this first.
   - **VLAN ID `0`** on the WAN.

   The [evie-lau guide](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant)
   shows both, in "Spoof MAC address" and "Set Unifi network settings".

### Messages

| Message | Cause and action |
|---|---|
| `scp` prints an error that names `sftp` | Run the `scp` command again with `-O` after `scp`. |
| `ca md too weak`, then a request for a key passphrase | The config file needs the line `openssl_ciphers=DEFAULT@SECLEVEL=0` before the `network={` block. `add-instance` writes it there. Keep it there if you edit `instances/<iface>/wpa_supplicant.conf`. Then run `validate <iface>`. |
| `runtime: wpa_supplicant does not start: error while loading shared libraries: <library>` | The firmware does not supply a library that the supplicant needs. Go back to the RG. If the bundle holds only `wpasupplicant` and `libpcsclite1` (see its `MANIFEST`), run `fetch` (it needs the internet), then `validate`. Otherwise, report the firmware version and the library name. |
| `runtime: cannot execute files in <directory>. Is <mount> mounted noexec?` | The addon must run programs from `/data`. Check the mount options with `mount`. Report the model and the firmware version. |
| `runtime: bundle <bundle> has no unpacked runtime` | Run `fetch`, or import the bundle again. |
| `fetch` or `import-bundle` ends with `Existing bundle kept` | The download, the bundle check, or the runtime test failed. The lines above name the cause. The bundle in use did not change. |
| `fetch` fails on Debian 11 (bullseye) | Debian moved bullseye to `archive.debian.org`, and the package sources of the gateway still use the old address. Run `att-wpa-supplicant fetch bullseye` instead. |
| `runtime: wpa_supplicant has no wired driver` | Use a bundle from `fetch` or `tools/build-bundle.sh`. |
| `runtime: no bundle at ...` after a firmware update | See [Before a firmware update](#before-a-firmware-update). |
| `check` says `no runtime chosen` | The unit did not start, or activation failed and stopped it. Read the log. |
| `check` says `system clock looks wrong` | Certificates fail with a wrong clock. Check the time settings of the gateway. |

## Remove the addon

1. [Go back to the RG](#go-back-to-the-rg). Without the supplicant, the
   ONT gives the gateway no internet access.
2. On the gateway, run `att-wpa-supplicant uninstall`. This removes the
   units, the boot entry, and the command. It keeps
   `/data/unifi-common-addons/att-wpa-supplicant`, with your certificates.
   After a takeover, `uninstall` refuses unless you add
   `--restore-legacy`, which puts the old setup back.
3. To delete the certificates and the bundles too, run
   `rm -r /data/unifi-common-addons/att-wpa-supplicant`.

## Reference

### WAN port names

The WAN port is the gateway port that the ONT cable goes into. Common
names:

| Gateway | WAN port |
|---|---|
| UDM Pro, UDM SE | `eth8` (RJ45 WAN), `eth9` (SFP+ WAN) |
| UXG Pro | `eth0` (RJ45 WAN), `eth2` (SFP+ WAN) |
| UXG Lite, UX | `eth1` |
| UCG Ultra, UXG Max, UDR, UDM | `eth4` |

UniFi lets you move the WAN to another port. To confirm, find the WAN
port in UniFi Network, then use the table. While the RG gives internet
access, `ip -br addr` on the gateway shows an address on the WAN port.

### Manual setup

The same steps as [the guided setup](#set-up), one command at a time.
Every command shows `<iface>`. Type your WAN port name in its place, for
example `eth8`. If you leave `<iface>` in a command, the shell stops with
an error and runs nothing. Keep the RG connected until step 6.

1. **Install the addon.** Download it as in [Set up](#set-up), step 2.
   Then run `cd att-wpa-supplicant` and `./att-wpa-supplicant install`.
   This copies the addon to
   `/data/unifi-common-addons/att-wpa-supplicant`, adds a boot entry, and
   installs the systemd units. It starts nothing. After this step, the
   `att-wpa-supplicant` command works in any directory.

2. **Copy the certificates.** On the gateway, make a folder that only
   `root` can read:

   ```sh
   install -d -m 700 -o root -g root /data/att-certs
   ```

   On your computer, open a second terminal. Copy the certificate folder:

   ```sh
   scp -r <path-to-your-certificate-folder> root@<gateway-ip>:/data/att-certs/
   ```

3. **Find the WAN port name.** See [WAN port names](#wan-port-names).

4. **Import the certificates.** On the gateway, run:

   ```sh
   att-wpa-supplicant add-instance <iface> /data/att-certs/<certificate-folder>
   ```

   `add-instance` keeps its own copy, readable only by `root`.

5. **Download the bundle and check the setup.** On the gateway, run:

   ```sh
   att-wpa-supplicant fetch
   att-wpa-supplicant validate <iface>
   att-wpa-supplicant plan <iface>
   ```

   - `fetch` should print a line like
     `att-wpa-supplicant: fetch: bundle trixie-arm64 ready: libpcsclite1 2.3.3-1 wpasupplicant 2:2.10-24`.
     On Debian 11, run `att-wpa-supplicant fetch bullseye` instead.
   - `validate` should print `att-wpa-supplicant: validate: OK`.
   - `plan` changes nothing. Its last line starts with `next:` and shows
     the command for step 7. With an older bypass, that command has
     `--takeover` (see [If you already have a bypass](#if-you-already-have-a-bypass)).
     If a line starts with `blocked`, fix what it names first.

   Then you may remove the copy that you sent: `rm -r /data/att-certs`.

> [!CAUTION]
> Step 6 takes the RG out of the signal path, so internet access stops.
> It comes back when step 7 succeeds.

6. **Move the ONT cable from the RG to the gateway.** Skip this step if
   you replace an older bypass.

   1. Disconnect the ethernet cable between the RG and the WAN port
      of the gateway.
   2. At the RG, disconnect the ethernet cable that comes from the ONT.
   3. Connect the ONT cable to the WAN port of the gateway.

7. **Activate.** On the gateway, run the command that `plan` showed,
   usually:

   ```sh
   att-wpa-supplicant activate <iface>
   ```

   The command tests the supplicant for a few seconds. Then it waits a
   few minutes at most for AT&T. It must print
   `att-wpa-supplicant: <iface>: authorized. Activation complete`.

   If activation fails, the addon stops the supplicant and does not try
   again. [Go back to the RG](#go-back-to-the-rg) to get internet access.
   Then see [Troubleshooting](#troubleshooting).

To stop the supplicant for a time, run
`att-wpa-supplicant deactivate <iface>`. After a takeover, your old
setup stays stopped, so `<iface>` has no supplicant until you run
`att-wpa-supplicant activate <iface>`. `activate` needs no `--takeover`
then. It keeps `takeover.state`, the record that `--restore-legacy` uses.
If a part of the old setup was enabled or started again in the meantime,
`activate` stops and names it.

### Build a bundle on your computer

Do this if the gateway cannot download a bundle itself, for example
because it has no internet access. You need a computer with Docker,
`sh`, `tar`, `sha256sum`, and a `readlink` that supports `-f`. It does
not need to be arm64.

1. On your computer, download the addon:

   ```sh
   curl -fsSL https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
     | tar -xz --strip-components=1 unifi-common-addons-main/att-wpa-supplicant
   cd att-wpa-supplicant
   ```

2. On the gateway, find the Debian codename and the architecture:

   ```sh
   grep CODENAME /etc/os-release
   dpkg --print-architecture
   ```

3. On your computer, build one bundle for each codename. Use the
   architecture from step 2. For example:

   ```sh
   tools/build-bundle.sh bullseye,bookworm,trixie arm64
   ```

   The command writes one `<codename>-<arch>.tgz` file for each codename.
   If one codename fails, it builds the others and exits with an error.

4. On your computer, copy the files to the gateway:

   ```sh
   scp *.tgz root@<gateway-ip>:/tmp/
   ```

5. On the gateway, import them:

   ```sh
   att-wpa-supplicant import-bundle /tmp/*.tgz
   ```

   The command stops at the first file that fails. The files before it
   stay imported.

### Commands

| Command | Changes the system |
|---|---|
| `setup [iface]` | yes: runs the commands below in order. Asks before it changes the WAN. |
| `install` | yes: files and units. Starts nothing. |
| `add-instance <iface> <dir>` | yes: the instance files |
| `validate [iface]` | no |
| `plan <iface>` | no |
| `fetch` | bundles, and the APT package lists. Installs no package. |
| `fetch <codename>...`, `fetch --all` | bundles only. Uses its own temporary APT setup and changes no APT file of the firmware. |
| `import-bundle <file.tgz>...` | bundles only |
| `activate <iface> [--takeover]` | yes |
| `deactivate <iface> [--restore-legacy]` | yes |
| `check [iface]` | no |
| `uninstall [--restore-legacy]` | yes. Keeps `/data`. |

`fetch` and `import-bundle` do not restart the supplicant. A new bundle
takes effect at the next start. Restart in a quiet hour, with the RG
nearby.

### How it works

- `att-wpa-supplicant@<iface>.service` runs `wpa_supplicant -D wired`
  with `instances/<iface>/wpa_supplicant.conf`, only if
  `instances/<iface>/active` exists.
- `fetch` and `import-bundle` check a bundle and unpack its packages
  into `bundles/<codename>-<arch>/root`. They install nothing. Before each
  start, the unit tests that runtime. If the test fails, the unit tries
  the previous bundle (`.prev`) once. A start writes nothing on `/data`.
- `fetch` downloads with the APT sources of the firmware.
  `fetch <codename>` and `fetch --all` download from Debian's servers
  (`deb.debian.org`, and `archive.debian.org` for bullseye). APT checks
  the signatures with the Debian keys in `keys/debian-archive.asc`, and
  with no other key. `tools/update-keys.sh` makes that file again and
  prints the fingerprints. Compare them with
  [Debian's list](https://ftp-master.debian.org/keys.html).
- A bundle holds `wpasupplicant`, `libpcsclite1`, `libnl` (3 packages),
  `libdbus-1`, and `libreadline`. The firmware supplies the rest: `libc`,
  OpenSSL, `libsystemd`, and `libtinfo`. OpenSSL security fixes come with
  the firmware. Fixes for the packages in the bundle come from Debian in a
  new bundle.
- `activate --takeover` checks everything before it stops the old setup.
  It records the old units in `instances/<iface>/takeover.state` and moves
  the old boot scripts to `instances/<iface>/quarantine/`. The addon
  never starts a second supplicant on an interface. The stock
  `wpa_supplicant.service` of Debian names no interface. It counts as an
  old setup only if it runs a supplicant on `<iface>`. The takeover code
  is in `legacy.sh`. Keep it next to the main script.

### Files on the gateway

```
/data/on_boot.d/01-att-wpa-supplicant.sh   the boot entry
/data/unifi-common-addons/att-wpa-supplicant/
  att-wpa-supplicant  legacy.sh  systemd/  on_boot.d/
  keys/debian-archive.asc           the Debian keys for fetch <codename>
  bundles/<codename>-<arch>/        *.deb, SHA256SUMS, MANIFEST
    root/                           the packages, unpacked
  bundles/<codename>-<arch>.prev/   the previous bundle, kept as a fallback
  instances/<iface>/
    wpa_supplicant.conf             0600
    certs/                          0700: CA.pem Client.pem PrivateKey.pem
    active                          present = activated
    takeover.state, quarantine/     only after --takeover
/data/att-certs/                    your copy, for the setup. You may remove it.
```

## Limits and support

- AT&T does not support this setup. If you call AT&T, reconnect the RG
  first.
- The author tests on one UDM Pro (see the table below). Other models
  and versions can work, but have not been tested by the author. Dual WAN
  interfaces on one gateway are not tested. Please report your results in
  the
  [unifi-utilities discussions](https://github.com/orgs/unifi-utilities/discussions).
- Debian 11 (bullseye) gets no more security updates. Debian moved it to
  `archive.debian.org`. `fetch bullseye` and `tools/build-bundle.sh`
  download it from there.
- If a firmware update removes the unifi-common boot service, no addon
  runs at boot. All unifi-common addons share this limit.
- A launcher that the addon does not recognize can start a second
  supplicant.
- Recovery is not tested for a WAN interface that UniFi deletes and makes
  again while the supplicant runs.

## Tested configurations

| Model | UniFi OS | Debian | Libraries |
|---|---|---|---|
| UDM Pro | 6.0.17 | 13 (trixie) | bundled |
| UDM Pro | 5.1.34 and 5.1.35 | 11 (bullseye) | firmware's |

"Libraries" tells where `libnl`, `libdbus-1`, and `libreadline` came
from on the gateway. The 5.1.x tests ran before the bundle held these
libraries. `tests/eap-tls.sh` tests the bundled libraries on Debian 11,
12, and 13 in a container.

## Credits

- [unifi-common](https://github.com/unifi-utilities/unifi-common) and its
  predecessor
  [unifios-utilities](https://github.com/unifi-utilities/unifios-utilities-archived),
  which started `on_boot.d`. Its `10-wpa_supplicant.sh` example is one of
  the setups that the takeover recognizes.
- [pbrah/wpa_supplicant-udmpro](https://github.com/pbrah/wpa_supplicant-udmpro),
  an early supplicant for the UDM Pro, in a container.
- [evie-lau/Unifi-gateway-wpa-supplicant](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant),
  the manual setup, the interface table, and the MAC clone and VLAN 0
  steps.
