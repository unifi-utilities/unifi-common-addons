# AT&T fiber bypass (att-wpa-supplicant)

This addon lets your UniFi gateway connect straight to the AT&T fiber ONT
(optical network terminal, the box where the fiber ends). The AT&T box then
leaves the traffic path, and the gateway gets the public IP address
directly.

AT&T must authorize the connection with 802.1X (port authentication)
before it gives an address. The AT&T box normally does this. The addon
does it instead, with EAP-TLS (authentication with certificates) and the
certificates from your own AT&T box.

This README uses two names:

- **The gateway** is always your UniFi device (UDM, UXG, UCG, or similar).
- **The RG** is always the box that AT&T supplied. AT&T calls it a
  residential gateway. Examples are the BGW210, BGW320, NVG589, and
  Pace 5268AC. The addon uses only the certificates from the RG, so the
  model does not matter.

Each step says where you do it: on the gateway, on your computer, or at
the RG.

**You can go back at any time.** If a step fails, or if you want to start
again, connect the RG again. See [Go back to the RG](#go-back-to-the-rg).
Internet access will drop temporarily in step 6 of the install.

## The short version

1. Install the addon on the gateway. This starts nothing.
2. Copy the certificates from your computer to the gateway.
3. Find the name of the WAN (internet) port of the gateway.
4. Import the certificates into the addon.
5. Download the bundle and check the setup.
6. Move the ONT ethernet cable from the RG to the gateway.
7. Activate. AT&T authorizes the gateway in up to 2 minutes.

Two more words:

- **Supplicant:** the program (`wpa_supplicant`) that answers the 802.1X
  request from AT&T.
- **Bundle:** the two Debian packages of the supplicant, stored in `/data`
  on the gateway. UniFi OS is built on Debian. Each Debian major version
  (11 "bullseye", 12 "bookworm", 13 "trixie") needs its own bundle. The
  addon runs the supplicant from the bundle and installs no package.

## Requirements

- An AT&T fiber line with a separate ONT box. If you use an SFP+ (fiber
  module) ONT stick instead, you do not need this addon.
- The RG, kept nearby. Steps 1 to 5 use its internet access. It is also
  your fallback.
- A UniFi gateway with
  [unifi-common](https://github.com/unifi-utilities/unifi-common)
  installed. unifi-common needs UniFi OS 4.x or later.
- SSH access to the gateway as `root`, and some comfort with a shell. See
  [Ubiquiti's SSH article](https://help.ui.com/hc/en-us/articles/204909374).
- The certificates from your RG, in a folder on your computer. This
  addon does not extract them, and this README does not tell you how.
  Search for a current guide for your RG model. The folder must hold four
  files with the names below. Keep a backup of this folder off the gateway.

  | File | Accepted names |
  |---|---|
  | CA certificate | `CA_*.pem` or `CA.pem` |
  | Client certificate | `Client_*.pem` or `Client.pem` |
  | Private key | `PrivateKey_PKCS1_*.pem` or `PrivateKey*.pem` |
  | Config | `wpa_supplicant.conf`, with an `identity="…"` line (the MAC address of the RG) |

## Install

> [!IMPORTANT]
> If a setup from another guide already runs `wpa_supplicant` on your
> gateway, see [Move from an existing bypass](#move-from-an-existing-bypass).

Keep the RG connected until step 6.

Every command below shows `<iface>`. Type your WAN interface name (from
step 3) in its place, for example `eth8`. If you leave `<iface>` in a
command, the shell stops with an error and runs nothing.

1. **Install the addon.** Log in to the gateway:

   ```sh
   ssh root@<gateway-ip>
   ```

   Keep this session open. Use it to run:

   ```sh
   cd /tmp
   curl -fsSL https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
     | tar -xz --strip-components=1 unifi-common-addons-main/att-wpa-supplicant
   cd att-wpa-supplicant
   ./att-wpa-supplicant install
   ```

   `install` copies the addon to
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

   The files are now in `/data/att-certs/<certificate-folder>` on the
   gateway.

3. **Find the WAN interface name.** This is the gateway port that the ONT
   cable goes into. Common names:

   | Gateway | WAN interface |
   |---|---|
   | UDM Pro, UDM SE | `eth8` (RJ45 WAN), `eth9` (SFP+ WAN) |
   | UXG Pro | `eth0` (RJ45 WAN), `eth2` (SFP+ WAN) |
   | UXG Lite, UX | `eth1` |
   | UCG Ultra, UXG Max, UDR, UDM | `eth4` |

   UniFi lets you move the WAN to another port. To confirm, find the WAN
   port in UniFi Network, then use the table. `ip -br addr` on the gateway
   usually shows the address from the RG on the WAN interface.

4. **Import the certificates.** On the gateway, run:

   ```sh
   att-wpa-supplicant add-instance <iface> /data/att-certs/<certificate-folder>
   ```

   `add-instance` keeps its own copy, readable only by `root`.

5. **Download the bundle and check the setup.** On the gateway, run:

   ```sh
   att-wpa-supplicant fetch
   att-wpa-supplicant validate <iface>
   ```

   `fetch` should print a line like
   `att-wpa-supplicant: fetch: bundle trixie-arm64 ready: libpcsclite1 2.3.3-1 wpasupplicant 2:2.10-24`.
   `validate` should print `att-wpa-supplicant: validate: OK`. Then you may remove
   the copy that you sent with `scp`:

   ```sh
   rm -r /data/att-certs
   ```

   On Debian 11 (bullseye), `fetch` usually fails. Debian moved bullseye
   to `archive.debian.org`, and the package sources of the gateway still
   use the old address. Build the bundle on your computer instead. See
   [Build a bundle on your computer](#build-a-bundle-on-your-computer).

6. **Move the ONT ethernet cable from the RG to the gateway.**

   > [!CAUTION]
   > This step takes the RG out of the signal path, so internet access
   > stops. It comes back when step 7 succeeds.

   1. Disconnect the ethernet cable between the RG and the WAN port
      of the gateway.
   2. At the RG, disconnect the ethernet cable that comes from the ONT.
   3. Connect the ONT cable to the WAN port of the gateway.

7. **Activate.** On the gateway, run:

   ```sh
   att-wpa-supplicant activate <iface>
   ```

   The command tests the supplicant for a few seconds. Then it waits up to
   2 minutes for AT&T. It must print
   `att-wpa-supplicant: <iface>: authorized. Activation complete`.

   If activation fails, the addon stops the supplicant and does not try
   again. [Go back to the RG](#go-back-to-the-rg) to get internet access.
   Then see [Troubleshooting](#troubleshooting). After you fix the cause,
   try steps 6 and 7 again.

## Move from an existing bypass

Use this section if a setup from another guide already runs
`wpa_supplicant` on the gateway. The addon recognizes the units
`wpa_supplicant-wired@<iface>`, `wpa_supplicant@<iface>`,
`reinstall-wpa`, `setup-att-bypass`, and the stock `wpa_supplicant` with
an override. It also recognizes the boot scripts `0-att-bypass.sh` and
`10-wpa_supplicant.sh`.

Your current bypass gives internet access, so you do not need the RG for
the install. Keep it nearby in case you must go back.

1. **Install the addon** as in [Install](#install), step 1. Do all the
   steps below on the gateway, in that SSH session.
2. **Find the WAN interface name** that your current setup uses. Its unit
   name or config file name usually contains it, for example
   `wpa_supplicant-wired@eth8`.
3. **Put the four certificate files in one folder.**
   - If setup with `0-att-bypass.sh`: the files are already together in
     `/data/wpa_supplicant`. In step 4, type that folder in place of
     `/data/att-certs`.
   - If setup from the
     [evie-lau guide](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant):
     run these commands. That guide names the config file after the
     interface.

     ```sh
     install -d -m 700 -o root -g root /data/att-certs
     cp /etc/wpa_supplicant/certs/*.pem /data/att-certs/
     cp /etc/wpa_supplicant/wpa_supplicant-wired-<iface>.conf /data/att-certs/wpa_supplicant.conf
     ```

   - Other setups: copy the four files the same way. The config file must
     have the name `wpa_supplicant.conf`.
4. **Import the certificates, download the bundle, and check.** Use your
   folder from step 3:

   ```sh
   att-wpa-supplicant add-instance <iface> /data/att-certs
   att-wpa-supplicant fetch
   att-wpa-supplicant validate <iface>
   ```

   `validate` must print `att-wpa-supplicant: validate: OK`. If you made
   `/data/att-certs`, you may remove it: `rm -r /data/att-certs`.

   If `fetch` fails on Debian 11 (bullseye), build the bundle on your
   computer and import it. See
   [Build a bundle on your computer](#build-a-bundle-on-your-computer).
   Then run `validate` again.
5. **Preview the takeover.** This command changes nothing and does not
   stop your current setup:

   ```sh
   att-wpa-supplicant plan <iface>
   ```

   - It lists the parts that a takeover replaces. The last line starts
     with `next:` and shows the command for step 6. If `plan` finds no old
     setup, that command has no `--takeover`.
   - If a line starts with `blocked`, or a line says `unknown` or
     `ambiguous`, stop. The addon cannot replace that setup safely.
     Do not remove parts that you do not understand.
6. **Take over.**

   **Caution:** internet access can stop for up to 2 minutes. If AT&T
   does not authorize the addon, the addon tries to restore your old setup.
   The old setup will take additional time to connect. If the internet does not
   come back, [go back to the RG](#go-back-to-the-rg).

   Run the command that `plan` showed after `next:`. Usually it is:

   ```sh
   att-wpa-supplicant activate <iface> --takeover
   ```

   The command must print
   `att-wpa-supplicant: <iface>: authorized. Activation complete`.

   If the takeover fails, check that exactly one supplicant runs and that
   the internet works:

   ```sh
   ps -eo pid,args | grep '[w]pa_supplicant'
   ping -c 3 1.1.1.1
   ```

   If the log shows `ROLLBACK INCOMPLETE`, run
   `att-wpa-supplicant deactivate <iface> --restore-legacy` to finish the
   restore.

The takeover does not change MAC address settings, for example the
`changemac` script from the [evie-lau guide](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant).
Keep them if your setup needs them. To go back to your old setup later, run
`att-wpa-supplicant deactivate <iface> --restore-legacy`.

## Check the connection

On the gateway, run:

```sh
att-wpa-supplicant check
```

The output looks like this, for the interface `eth8`:

```
OK eth8: unit att-wpa-supplicant@eth8.service active
OK eth8: 802.1X authorized
INFO eth8: runtime at start: wpa_supplicant v2.10 from bundle trixie-arm64 (...)
OK eth8: client certificate matches private key
OK eth8: client certificate valid until ...
INFO eth8: interface has an IPv4 address
INFO eth8: IPv4 route to the internet goes out on eth8
INFO bundles: bullseye-arm64, trixie-arm64 (this release: trixie-arm64)
```

- The exit status is 0 only when every activated interface is
  authorized. `OK` and `FAIL` lines decide it. `WARN` and `INFO` lines do
  not.
- `check` sends no traffic, so it does not prove internet access. To test
  the internet, run `ping -c 3 1.1.1.1`. If the `OK` lines are present
  and the ping fails, look at DHCP and the WAN settings in UniFi. The
  address line covers only this interface, and the route line covers only
  traffic from the gateway itself.
- `WARN bundles: ... None for this release` means that the gateway has
  no bundle for its Debian release. See
  [Before a firmware update](#before-a-firmware-update).
- `check` never prints the identity, the key, or the WAN address.

To read the logs, run `journalctl -u att-wpa-supplicant@<iface> -b`.

The supplicant needs no regular work. systemd starts it at boot and
starts it again 30 seconds after any exit.

**Caution:** a restart stops internet access for a short time. To restart
the supplicant by hand, run `systemctl restart att-wpa-supplicant@<iface>`.

## Update the addon

Do this at a quiet time, with the RG nearby as a fallback. On the gateway:

1. Download the new version as in [Install](#install), step 1. Run
   `./att-wpa-supplicant install`. If the supplicant from the bundle does
   not load, `install` stops and says that nothing changed. `install` does
   not restart the supplicant.
2. Run `att-wpa-supplicant validate <iface>`. It must print
   `att-wpa-supplicant: validate: OK`.
3. **Caution:** internet access stops for a short time. Run
   `systemctl restart att-wpa-supplicant@<iface>`. The new version runs
   from now on.
4. Run `att-wpa-supplicant check`.

Your certificates, instances, and bundles stay in place.

## Before a firmware update

Install step 5 put a bundle on the gateway for its current Debian version.
A firmware update that keeps that version needs nothing more. A firmware
update that moves the gateway to a newer Debian version needs a new
bundle. Without it, internet access stops after the update until you run
`fetch` again.

**Before each update:** keep the RG nearby. Run `att-wpa-supplicant check`.

**If internet access stops after an update:**

1. [Go back to the RG](#go-back-to-the-rg).
2. On the gateway, run `att-wpa-supplicant fetch`.
3. Connect the ONT cable to the WAN port of the gateway again. systemd
   tries to start the supplicant every 30 seconds.
4. After 2 minutes, run `att-wpa-supplicant check`.

**To avoid the outage:** if you know that the new firmware uses a newer
Debian version, put a bundle for that version on the gateway before you
update. `fetch` can only download a bundle for the version that the
gateway runs now, so
[build the bundle on your computer](#build-a-bundle-on-your-computer)
and import it. The `bundles` line of `att-wpa-supplicant check` then
lists it.

## Go back to the RG

Use this when internet access is down and you need it back now. It
changes only the cables, and VLAN 0 if you set it.

1. At the RG, connect the ONT cable to the **ONT** port of the RG.
2. Connect a LAN port of the RG to the WAN port of the gateway.
3. Wait for the broadband light of the RG to turn green. This can take
   several minutes.
4. On the gateway, run `ping -c 3 1.1.1.1`.

If you set VLAN ID 0 on the WAN for the addon and the ping fails, remove
that setting.

To use the addon again, set VLAN ID 0 again if you removed it. Connect the
ONT cable to the WAN port of the gateway. After 2 minutes, run
`att-wpa-supplicant check`. If it does not show `802.1X authorized`,
restart the supplicant (see
[Check the connection](#check-the-connection)). If activation failed
before, the supplicant does not run: do [Install](#install) steps 6 and 7
again.

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

## Troubleshooting

If internet access is down, first [go back to the RG](#go-back-to-the-rg).

**Activation fails, or `check` shows `802.1X not authorized`:**

1. Make sure that the ONT cable is in the WAN port that you gave to
   `add-instance`.
2. Check the log of the attempt:
   `journalctl -u att-wpa-supplicant@<iface> -b`. If it shows an error,
   fix that error first. After a failed activation, the unit is stopped on
   purpose.
3. If the unit ran for at least one minute and the log shows no `CTRL-EVENT-EAP-`
   lines, AT&T probably does not answer the gateway. Some gateways need one or
   both of these WAN settings in UniFi:
   - **MAC address clone:** set the WAN MAC address to the `identity`
     value in `wpa_supplicant.conf`. Try this first.
   - **VLAN ID `0`** on the WAN.

   The evie-lau guide shows both, in "Spoof MAC address" and "Set Unifi
   network settings". The UDM Pro in
   [Tested configurations](#tested-configurations) needed neither.

**Messages:**

| Message | Cause and action |
|---|---|
| `scp` prints an error that names `sftp` | Run the `scp` command again with `-O` after `scp`. |
| `ca md too weak`, then a request for a key passphrase | The config file needs the line `openssl_ciphers=DEFAULT@SECLEVEL=0` before the `network={` block. `add-instance` writes it there. Keep it there if you edit `instances/<iface>/wpa_supplicant.conf`. Then run `validate <iface>`. |
| `runtime: wpa_supplicant does not start: error while loading shared libraries: <library>` | The firmware does not supply a library that the supplicant needs. Go back to the RG. Report the firmware version and the library name. |
| `runtime: cannot execute files in <directory>. Is <mount> mounted noexec?` | The addon must run programs from `/data`. Check the mount options with `mount`. Report the model and the firmware version. |
| `runtime: bundle <bundle> has no unpacked runtime` | Run `fetch`, or import the bundle again. |
| `fetch` or `import-bundle` ends with `Existing bundle kept` | The download, the bundle check, or the runtime test failed. The lines above name the cause. The bundle in use did not change. |
| `runtime: wpa_supplicant has no wired driver` | Use a bundle that `tools/build-bundle.sh` built from Debian. |
| `runtime: no bundle at ...` after a firmware update | See [Before a firmware update](#before-a-firmware-update). |
| `check` says `no runtime chosen` | The unit did not start, or activation failed and stopped it. Read the log. |
| `check` says `system clock looks wrong` | Certificates fail with a wrong clock. Check the time settings of the gateway. |

## Build a bundle on your computer

Do this if the gateway cannot run `fetch` (no internet, or Debian 11).
Also do this to put bundles for other Debian releases on the gateway. You need a
computer with Docker, `sh`, `tar`, `sha256sum`, and a `readlink` that
supports `-f`. It does not need to be arm64.

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
   stay imported. Then go back to the step that sent you here.

## Reference

### Commands

| Command | Changes the system |
|---|---|
| `install` | yes: files and units. Starts nothing. |
| `add-instance <iface> <dir>` | yes: the instance files |
| `validate [iface]` | no |
| `plan <iface>` | no |
| `fetch` | bundles, and the APT package lists. Installs no package. |
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
- `fetch` and `import-bundle` check a bundle and unpack its two packages
  into `bundles/<codename>-<arch>/root`. They install nothing. Before each
  start, the unit tests that runtime. If the test fails, the unit tries
  the previous bundle (`.prev`) once. A start writes nothing on `/data`.
- The firmware supplies all other libraries (`libc`, OpenSSL, `libnl`,
  `libdbus-1`, `libreadline`). OpenSSL security fixes come with the
  firmware. Fixes for `wpasupplicant` come from Debian in a new bundle.
- `activate --takeover` checks everything before it stops the old setup.
  It records the old units in `instances/<iface>/takeover.state` and moves
  the old boot scripts to `instances/<iface>/quarantine/`. It never starts
  a second supplicant on an interface. The takeover code is in
  `legacy.sh`. Keep it next to the main script.

### Files on the gateway

```
/data/on_boot.d/01-att-wpa-supplicant.sh   the boot entry
/data/unifi-common-addons/att-wpa-supplicant/
  att-wpa-supplicant  legacy.sh  systemd/  on_boot.d/
  bundles/<codename>-<arch>/        *.deb, SHA256SUMS, MANIFEST
    root/                           the two packages, unpacked
  bundles/<codename>-<arch>.prev/   the previous bundle, kept as a fallback
  instances/<iface>/
    wpa_supplicant.conf             0600
    certs/                          0700: CA.pem Client.pem PrivateKey.pem
    active                          present = activated
    takeover.state, quarantine/     only after --takeover
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
  `archive.debian.org`. `tools/build-bundle.sh` downloads it from there.
- If a firmware update removes the unifi-common boot service, no addon
  runs at boot. All unifi-common addons share this limit.
- A launcher that the addon does not recognize can start a second
  supplicant.
- Recovery is not tested for a WAN interface that UniFi deletes and makes
  again while the supplicant runs.

## Tested configurations

| Model | UniFi OS | Debian |
|---|---|---|
| UDM Pro | 6.0.17 | 13 (trixie) |
| UDM Pro | 5.1.34 and 5.1.35 | 11 (bullseye) |

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
