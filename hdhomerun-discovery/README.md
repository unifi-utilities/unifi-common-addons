# HDHomeRun discovery (hdhomerun-discovery)

This addon lets HDHomeRun ("HDHR") client apps find an HDHomeRun tuner on another network
(VLAN) of your UniFi gateway.

An HDHR client app tries to find tuners with a broadcast on its own network. A
router does not forward this broadcast, so when the app and the tuner are on
different VLANs, the app can't find a tuner, and firewall rules alone aren't enough to solve it. 

This addon runs a small proxy on the UniFi gateway, which sits on every VLAN.
The proxy receives the HDHR app's discovery request, asks the tuner's network,
and sends each tuner's answer back to the app. After that, the app talks
to the tuner directly.

## Contents

1. [Before you start](#before-you-start): what you need, and the words
   that this README uses
2. [Set up](#set-up): the required firewall rule and the guided setup
3. [Check that it works](#check-that-it-works)
4. [If something goes wrong](#if-something-goes-wrong)
5. [Update the addon](#update-the-addon) and
   [after a firmware update](#after-a-firmware-update)
6. [Remove the addon](#remove-the-addon)
7. [Reference](#reference): manual setup, the config file, commands, how
   it works, files
8. [Limits and support](#limits-and-support),
   [tested configurations](#tested-configurations), and
   [credits](#credits-and-license)

## Before you start

### What you need

- A UniFi gateway with
  [unifi-common](https://github.com/unifi-utilities/unifi-common)
  installed.
- SSH access to the gateway as `root`. See
  [Ubiquiti's SSH article](https://help.ui.com/hc/en-us/articles/204909374).
- An HDHR tuner on one network, and the HDHR apps (iOS, Apple TV, Android, etc.) on one or more other
  networks.
- Your firewall already lets the apps' networks reach the tuner. After this add-on fixes
  discovery, the apps will connect to the tuner directly. If your firewall blocks them, the apps will now find the tuner but may not actually play anything. See [Let the apps reach the tuner](#let-the-apps-reach-the-tuner).

### Words in this README

- **The gateway** is your UniFi device (UDM, UXG, UCG, or similar).
- **An app network** is a network with HDHomeRun client apps: mobile phones, TVs, and
  streaming devices.
- **The tuner network** is the network with the HDHomeRun tuner. Often it
  is an IoT network.
- **A bridge** is the gateway's interface for one network. On UniFi OS,
  `br0` is the default network, and `brNN` is the network of VLAN NN (for
  example `br30` for VLAN 30). The setup shows each bridge with its
  address, so you can tell them apart.

## Set up

1. **Add the firewall rule.** The add-on proxy asks the tuner network for tuners,
   and each tuner answers to the gateway. The gateway's firewall usually
   drops that answer, so this rule will allow it. In UniFi Network, add a firewall rule
   (or with the zone-based firewall, a policy):

   | Field | Value |
   |---|---|
   | Action | Allow |
   | Protocol | UDP |
   | Source zone | the zone of the tuner network |
   | Source | your HDHomeRun tuners (or the whole tuner network) |
   | Source port | `65001` |
   | Destination zone | Gateway |
   | Destination port | Any |

   With the older firewall (without zones), this is a rule in the
   "LAN Local" set. If your firewall already lets the tuner network reach
   the gateway, you do not need the new rule.

2. **Log in to the gateway.** On your computer, run:

   ```sh
   ssh root@<gateway-ip>
   ```

3. **Download the addon.** In that SSH session, run:

   ```sh
   cd /tmp
   curl -fsSL https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
     | tar -xz --strip-components=1 unifi-common-addons-main/hdhomerun-discovery
   ```

4. **Start the setup.** In that SSH session, run:

   ```sh
   cd hdhomerun-discovery
   ./hdhomerun-discovery setup
   ```

5. **Answer the setup questions.** The setup has four steps:

   | Step | What happens | What you do |
   |---|---|---|
   | 1. Install | Copies the addon to `/data`. Starts nothing. | Nothing |
   | 2. Networks | Lists each network with a number, its bridge, and its address. | Prompts to type the number of the tuner network, then type the numbers of the app networks, separated by spaces. |
   | 3. Tuners | Asks the tuner network for tuners, and lists each tuner that answers. If none answers, it shows the required firewall rule again. | Check the rule, then press Enter to try again. |
   | 4. Start | Asks before it starts the proxy. | Type `y` or press Enter. |

6. **Open the HDHomeRun client app** on a device on an app network. It should
   find the tuner. After the setup, the `hdhomerun-discovery` command
   works in any directory.

Prefer to type each command yourself? See [Manual setup](#manual-setup).

## Check that it works

In the SSH session on your gateway, run:

```sh
hdhomerun-discovery status
hdhomerun-discovery probe
journalctl -u hdhomerun-discovery
```

- `status` shows the networks in the config, and whether the proxy is
  enabled and running. It changes nothing.
- `probe` asks the tuner network for tuners and lists each one that
  answers the gateway, for example
  `tuner 192.168.30.100 on br30, device ID 1234ABCD`. It changes nothing.
- The journal shows one line when the proxy starts, and a line for each
  problem. The proxy logs nothing for each request.

## If something goes wrong

**`setup` or `probe` finds no tuner.**

1. Check the firewall rule from [Set up](#set-up), step 1. The rule's hit
   count in UniFi Network goes up each time a tuner answers.
2. Check that the tuner is on, and that it is on the network that you
   chose as the tuner network.

**The app finds the tuner, but it cannot play, or it says "request timed
out".** Discovery worked. The app's next step, a direct connection to the
tuner, failed.

- Turn off any VPN on the device with the app (such as Tailscale), then try again. A VPN can send the app's
  connection to the tuner through the VPN instead of the local network.
- Check that your firewall lets the app network reach the tuner. To test,
  open `http://<tuner-address>/discover.json` in a browser on the same
  device. It should show a short block of JSON. If it does not, see
  [Let the apps reach the tuner](#let-the-apps-reach-the-tuner).

**`enable` or the unit fails.** `precheck` runs before each start, and its
message names the cause:

- the config is missing or has an error (run `setup` again),
- an interface does not exist, is down, or has no IPv4 address,
- an interface faces the internet (it holds a default route),
- `ss` is missing or fails, so the port check cannot run,
- another program uses UDP 65001. Two programs on that port would share
  the requests. Stop the other program first.

The unit tries again after 30 seconds, so a fixed problem clears itself.

**The proxy stops after a network change.** UniFi OS can create a bridge
again when you change a network. The proxy checks every 10 seconds. When
a bridge changed, the proxy exits, and systemd starts it again on the new
bridge after 30 seconds. The journal shows
`interface br30 changed; exiting so that systemd starts the proxy again`.

### Let the apps reach the tuner

After discovery, each app connects to the tuner directly: web requests on
TCP port 80, and video on TCP port 5004. Some apps also use TCP port 65001.
This is separate from the discovery rule in [Set up](#set-up), which lets
the tuner answer the gateway.

One rule in one direction is enough, from the app networks to the tuner.
The firewall lets the tuner's replies come back on the same connection.

On a standard UniFi network this traffic is often allowed already. It is
usually blocked when the app network or the tuner network is a guest
network, has network isolation, or sits in a zone that blocks other zones.
If the test with `discover.json` above fails, add a rule (with the
zone-based firewall, a policy):

| Field | Value |
|---|---|
| Name | HDHomeRun apps to tuner |
| Action | Allow |
| Protocol | TCP |
| Source zone | the zone of the app networks (often Internal) |
| Source | the app networks |
| Destination zone | the zone of the tuner network |
| Destination | the tuner (its IP address, or the device) |
| Port | 80, 5004, 65001 (or Any) |

With the older firewall (without zones), this is a rule in the "LAN In"
set.

## Update the addon

Download the new version as in [Set up](#set-up), step 3. Then run:

```sh
cd hdhomerun-discovery
./hdhomerun-discovery install
hdhomerun-discovery disable
hdhomerun-discovery enable
```

`install` replaces the program files and keeps your config.

## After a firmware update

The addon is in `/data`, which a firmware update keeps. At the next boot,
the boot entry installs the unit again and starts the proxy. After an
update, run `hdhomerun-discovery status` and open the app once. If the
unit is missing, run `hdhomerun-discovery boot`.

## Remove the addon

- To stop the proxy but keep the config: `hdhomerun-discovery disable`.
- To remove everything: `hdhomerun-discovery uninstall`. It stops the
  proxy and removes the unit, the boot entry, and
  `/data/unifi-common-addons/hdhomerun-discovery/`. Nothing else on the
  gateway changes.

Then delete the firewall rule from [Set up](#set-up), step 1.

## Reference

### Manual setup

The same steps as the guided setup, one command at a time.

1. **Add the firewall rule** and **download the addon**, as in
   [Set up](#set-up), steps 1 to 3.

2. **Install.** In the `hdhomerun-discovery` directory that you
   downloaded, run:

   ```sh
   ./hdhomerun-discovery install
   ```

   This copies the addon to `/data/unifi-common-addons/hdhomerun-discovery`,
   adds the boot entry, and installs the unit. It starts nothing.

3. **Find the bridges.** Run:

   ```sh
   ip -4 -br addr
   ```

   Each line shows a bridge and its address, for example
   `br30  UP  192.168.30.1/24`. Note the bridge of the tuner network and
   the bridges of the app networks. The line of your internet port shows
   your public address: leave it out of anything that you post. (`setup`
   lists only the networks that you can choose, and never the internet
   port.)

4. **Write the config.** Run this, with your bridge names in place of
   `br0` and `br30`:

   ```sh
   cat > /data/unifi-common-addons/hdhomerun-discovery/hdhomerun-discovery.conf <<'EOF'
   # The networks with the apps (one or more, separated by spaces).
   CLIENTS="br0"
   # The networks with the tuners.
   TUNERS="br30"
   EOF
   ```

5. **Find the tuners.** Run `hdhomerun-discovery probe`. It must list
   your tuner. If it lists nothing, check the firewall rule.

6. **Start the proxy.** Run `hdhomerun-discovery enable`. It checks the
   config first, and starts the proxy only if every check passes.

To change the config later, edit the file, then run
`hdhomerun-discovery disable` and `hdhomerun-discovery enable`.

### The config file

`/data/unifi-common-addons/hdhomerun-discovery/hdhomerun-discovery.conf`
holds two settings. The addon reads it as data, never as a shell script.

| Key | Meaning |
|---|---|
| `CLIENTS` | The bridges of the app networks: one or more names, in quotes, separated by spaces. |
| `TUNERS` | The bridges of the tuner networks: one or more names. A bridge cannot be in both. |

### Commands

| Command | What it does |
|---|---|
| `setup` | Guided setup: install, choose the networks, find the tuners, start. Asks before each change. |
| `install` | Copy the addon to `/data`, write the boot entry and the unit. Starts nothing. |
| `enable` | Run `precheck`, then start the proxy now and after each boot. |
| `disable` | Stop the proxy. Keeps the config. |
| `uninstall` | Stop the proxy. Remove the unit, the boot entry, and the addon directory. |
| `status` | Show the config and the state of the proxy. Changes nothing. |
| `probe` | List the tuners that answer the gateway. Changes nothing. |
| `precheck` | Check the config, the interfaces (none may face the internet), and UDP 65001. Changes nothing. |
| `boot` | Install the unit again and start the proxy if it is enabled. The boot entry calls it. |
| `run` | Run the proxy in the foreground. The unit calls it. |

`setup`, `install`, `boot`, `enable`, `disable`, and `uninstall` take a
lock (`/run/hdhomerun-discovery.lock`), so that two of them never run at
the same time.

### How it works

1. An HDHR client app on an app network sends an HDHomeRun discovery request, a
   broadcast to UDP 65001.
2. The proxy receives it on the app network's bridge. It drops anything
   that is not a complete discovery request with a correct checksum.
3. The proxy sends the request as a broadcast on each tuner network, from
   a new port for each request.
4. Each tuner answers the gateway on that port. This is the answer that
   the new firewall rule allows. The proxy drops anything that is not a
   complete discovery answer from port 65001 on the tuner network.
5. The proxy sends each answer to the app that asked, and to no other.
6. The app reads the tuner's address from the answer, and connects to the
   tuner directly.

The proxy never sends a packet onto an app network except an answer to the
app that asked, so it cannot cause a loop or a broadcast storm. It limits
each app to 10 requests at once and 5 per second after that, and keeps at
most 32 requests waiting for answers.

The unit runs the proxy as a temporary user that systemd creates
(`DynamicUser=yes`), not as root. The proxy opens no raw socket. It gets
one capability, `CAP_NET_RAW`, because Linux before 5.7 needs it to bind a
socket to one interface.

### Files on the gateway

| Path | What |
|---|---|
| `/data/unifi-common-addons/hdhomerun-discovery/` | The addon home: the command, `proxy.pl`, the unit and boot entry sources |
| `<home>/hdhomerun-discovery.conf` | The config |
| `<home>/active` | Present while the proxy is enabled |
| `/data/on_boot.d/20-hdhomerun-discovery.sh` | The boot entry |
| `/etc/systemd/system/hdhomerun-discovery.service` | The unit. A firmware update removes it, and `boot` writes it again. |

## Limits and support

- **HDHomeRun only.** The proxy forwards HDHomeRun discovery requests and
  nothing else.
- **The answer comes from the gateway's address.** The HDHR apps take the tuner's address from inside the answer. An app that
  uses the sender's address instead would try to reach the tuner through
  the gateway, and fail.
- **IPv4 only.**
- **One firewall rule.** The tuner's answer to the gateway needs it (see
  [Set up](#set-up), step 1).
- The addon shares no file, unit, or directory with any other addon.

## Tested configurations

| Gateway | UniFi OS | Debian | Kernel | Test | Result |
|---|---|---|---|---|---|
| UDM Pro | 6.0.17 | 13 | 4.19 | HDHomeRun FLEX 4K on another VLAN; apps HDHomeRun (iOS, Apple TV), Channels DVR, Jellyfin; discovery and live TV; reboot; network edit (no new bridge) | pass |

Off the gateway:

- `tests/run.sh` tests the command on a fixture root, with stubs for
  `systemctl`, `ip`, `ss`, and `perl`. It passes as root and as a normal
  user.
- `tests/proxy-netns.sh` runs the real proxy in private network
  namespaces (`unshare`, no sudo), with a fake tuner. It checks the
  answer path, two apps at once, packets that must be dropped, the rate
  limit, `probe`, and the exit after a bridge is created again.
- `tests/mutate.sh` breaks the command and the proxy on purpose, one fault
  at a time, and checks that the tests catch each one.
- `tests/debian.sh` runs `tests/run.sh` as root in Debian 11, 12, and 13
  containers, and compiles `proxy.pl` with only the `perl-base` package.

Not tested yet: a firmware update, other gateway models, Debian 11 and 12
on a gateway, and other HDHomeRun models and apps.

## Compared with the archived `hdhomerun` script

The archived
[unifios-utilities `hdhomerun`](https://github.com/unifi-utilities/unifios-utilities-archived/tree/main/hdhomerun)
script solved the same problem with the same basic idea: it runs `socat`
on the gateway, which receives each discovery request and sends it on to
the tuner, and returns the answer. This addon keeps that idea and changes
the following:

| | Archived script | This addon |
|---|---|---|
| Program | A prebuilt `socat` binary in git. Its version strings say socat 1.7.4.3 with OpenSSL 1.0.1k (January 2015). Its Dockerfile downloads the sources with `curl -k`, over HTTP and FTP, with no checksum. | A Perl script of about 300 lines, in the addon, that anyone can read. It uses only the Perl that Debian always installs. |
| UniFi OS version | The script accepts only version numbers that start with 1 to 5. On UniFi OS 6.0.17 it stops before it starts `socat`. | No version check. Tested on Debian 11, 12, and 13 userlands, the base of UniFi OS 4.x and later. |
| Tuners | One tuner address, written in the script. | Every tuner on the tuner network. No address to configure. |
| What it forwards | Any packet to UDP 65001, from any interface, to the tuner. | Only complete HDHomeRun discovery requests, only from the app networks, with a rate limit. |
| Answers | `socat` returns each answer through a child process. | Each answer goes only to the app that asked. |
| Runs as | root | A temporary user with one capability |
| Start and restart | The boot script starts `socat` in the background. Nothing starts it again after it exits. | A systemd unit, with `precheck` before each start. It starts again after an exit and after a bridge is created again. |
| Setup | Edit the script. | A guided `setup`, which also checks the firewall rule. |
| Log | `socat -d -d -v` writes the content of each packet to the log. | One line at start, and one line for each problem. |

## Credits and license

- The archived
  [unifios-utilities `hdhomerun`](https://github.com/unifi-utilities/unifios-utilities-archived/tree/main/hdhomerun)
  script solved this problem first, with a `socat` proxy.
- The packet format (types, tags, and the CRC) is from Silicondust's
  [libhdhomerun](https://github.com/Silicondust/libhdhomerun). The addon
  contains no code from it.
- The addon has the license of this repository.
