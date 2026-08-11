# AT&T IPv6 PD acquisition

This addon runs the installed `odhcp6c` only as a DHCPv6 prefix-delegation
client. It does not assign LAN addresses or routes, update DNS, invoke vendor
network scripts, or write UniFi-owned runtime files. A separate reconciler
applies complete delegated-prefix state through the UniFi Integration API.
This keeps delegated prefixes visible in UniFi Network, retains native
DHCPv6, router-advertisement, and DNS controls, and associates IPv6 traffic
with the correct network for zone-based firewall classification.

## Prerequisites

- The [`on_boot.d`](https://github.com/unifi-utilities/unifi-common) persistence
  mechanism used by this addon repository.
- A UniFi gateway with `python3`, `odhcp6c`, and systemd.
- The AT&T residential gateway configured for IP Passthrough.
- Gateway firewall rules permitting DHCPv6 server UDP/547 to client UDP/546
  and ICMPv6 router advertisements on the AT&T WAN.
- A dedicated UniFi Network Integration API key.
- Exclusive ownership of DHCPv6 client port UDP/546 during acquisition.

Create the dedicated Integration API key in the UniFi Network application and
download it as `integration-api.key` alongside the addon installer. Before
activation, set the IPv6 interface type to `None` on the AT&T WAN and each
managed LAN in the UniFi Network application so its DHCPv6 client releases
UDP/546.

## Green-field installation

Download the complete addon directory to the gateway:

```sh
workdir="$(mktemp -d)"
curl -fsSL \
  https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
  | tar -xz -C "$workdir"
cd "$workdir/unifi-common-addons-main/att-ipv6"
```

Copy the downloaded Integration API key into this directory as
`integration-api.key`. With no existing `/data/att-ipv6/config.json`, run:

```sh
sudo ./install
```

The installer discovers a conservative common configuration and writes it with
`active=false`. It selects the single UniFi site, the Ethernet interface used
by the default IPv4 route, and enabled gateway-managed client LANs that have
DHCP configuration and an unambiguous live bridge. It excludes transit,
disabled, non-gateway, and ambiguous networks. It creates a stable DUID-LL from
the selected WAN MAC and assigns deterministic IAIDs.

Review `/data/att-ipv6/config.json` before any DHCPv6 traffic is sent. In
particular, verify the WAN, DUID, network names, VLAN IDs, bridge names, and
IAID-to-network mapping. Once an identity has been used, do not regenerate its
DUID or reorder its IAIDs.

After review, run `sudo ./install --activate`. The installer validates and
activates the installed configuration without requiring a manual JSON edit. For
a fully understood green-field gateway, the same command permits the newly
discovered configuration to start immediately.

The installer accepts only named options:

```text
--config PATH        default: /data/att-ipv6/config.json
--api-key-file PATH  explicit Integration API key source
--activate            activate the installed configuration
```

For example, an explicit configuration and key can be installed with:

```sh
sudo ./install \
  --config /secure/staging/att-ipv6.json \
  --api-key-file /secure/staging/integration-api.key
```

Without `--api-key-file`, the installer reuses the key named by an existing
configuration, then the installed default key, then `./integration-api.key`.
For an upgrade, run `sudo ./install`; the existing configuration, key, and
activation state are preserved.

## Manual configuration

Automatic discovery intentionally skips unusual topologies, including multiple
sites or WANs, IPv6-only LANs, static-only LANs, and nonstandard bridges. Copy
`config.json.example`, add a delegation object for every intended client LAN,
and provide the resulting file with `--config`.

Important fields are:

- `active`: permits acquisition and reconciliation when true.
- `wan_interface`: interface on which odhcp6c sends DHCPv6 messages.
- `duid`: hexadecimal DHCPv6 client identity; colons are accepted.
- `api_key_path`: installed path used for Integration API calls.
- `site`: unique UniFi site name or internal reference.
- `delegations`: the authoritative IAID-to-network mapping.
- `id`: stable local key used in acquisition and health output.
- `iaid`: unique unsigned 32-bit IA_PD identity association.
- `network`, `vlan_id`, and `bridge`: values that must resolve to the same
  UniFi network and live Linux bridge.
- `ra_priority`, `dhcpv6_suffix_range`, and `dhcpv6_lease_seconds`: static LAN
  IPv6 settings sent through the Integration API.
- `minimum_valid_lifetime`: minimum remaining prefix lifetime accepted for
  promotion.

## Runtime behavior

`att-ipv6 acquire` loads `config.json`, constructs the odhcp6c command, and
replaces itself with the foreground client. The hook reads the same config and
writes atomic observations only to `/run/att-ipv6/acquisition.json`. A config
digest binds each observation to the configuration used when the client
started. If config changes while acquisition is running, the hook refuses new
observations and health fails until an operator performs a controlled restart.

Partial state remains `acquiring=N/M`, where `M` is derived from configured
delegations. It is never applied. Complete state requires a fresh, unique,
unexpired `/64` for every configured IAID and no unexpected IAID. Renew and
Rebind timing remains internal to odhcp6c.

The reconciler maps acquired IAIDs to configured UniFi networks, writes static
IPv6 network configuration through the Integration API, verifies API readback,
and verifies exact bridge addresses and kernel-connected routes. It never
edits resolver, dnsmasq, interface, or UniFi runtime configuration files.

Useful read-only checks are:

```sh
/data/att-ipv6/att-ipv6 status
systemctl status att-ipv6-acquire.service
journalctl -u att-ipv6-acquire.service
```

If a gateway remains partial through normal Renew/Rebind processing, an
operator may perform one controlled stop, short wait, and start of
`att-ipv6-acquire.service`. Preserve the DUID, confirm UDP/546 becomes free,
never overlap acquisition clients, and observe the provider cooldown between
attempts.
