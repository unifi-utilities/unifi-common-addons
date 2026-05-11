# SoundCork

Run [SoundCork](https://github.com/deborahgu/soundcork) on a UniFi OS
gateway using `unifi-common`'s `/data/on_boot.d` hook.

SoundCork emulates the discontinued Bose SoundTouch cloud endpoints used for
account data, internet radio, and some speaker-managed music-provider flows.
Speakers still need a local `/mnt/nv/OverrideSdkPrivateCfg.xml` that points at
this SoundCork instance. DNS hijacking Bose HTTPS hostnames alone may not be
enough on firmware that validates TLS certificates.

## Requirements

- `unifi-common` installed and `udm-boot.service` enabled.
- A stable speaker-facing DNS name or address for the UniFi host. The default
  is `http://unifi:8001`, which works when `unifi` resolves from the speaker
  LAN.
- Docker or Podman on the UniFi OS host, or a prepared rootfs for the direct
  `systemd-nspawn` launcher. If no container runtime is available, the runtime
  hook can try `apt-get install docker.io` when `apt-get` is present and
  `SOUNDCORK_RUNTIME_AUTO_INSTALL=1`.
- Existing private SoundCork account data, if you are migrating an existing
  SoundCork installation.

## Files

- `05-soundcork-runtime.sh` checks or installs a container runtime and restores
  an optional Docker daemon config from `/data`.
- `20-soundcork.sh` starts the host-networked SoundCork container and waits for
  the local registry endpoint.
- `soundcork-provision-rootfs.sh` optionally builds a Debian rootfs for the
  direct nspawn launcher from package repositories and SoundCork source.
- `soundcork-nspawn.sh` starts SoundCork from a prepared rootfs through
  rootful `systemd-nspawn`, for gateways where Docker or Podman is not usable.
- `soundcork.env.example` is the controller-side environment template.
- `soundcork-healthcheck.sh` checks SoundCork, optional Spotify account
  support.
- `docker-daemon.json.example` is an optional conservative Docker daemon config
  for UniFi hosts.

## Installation

Copy the addon files to the UniFi host and create persistent directories:

```sh
mkdir -p /data/on_boot.d /data/soundcork/data /data/soundcork/logs
cp soundcork.env.example /data/soundcork/soundcork.env
cp docker-daemon.json.example /data/soundcork/docker-daemon.json
cp 05-soundcork-runtime.sh /data/on_boot.d/05-soundcork-runtime.sh
cp 20-soundcork.sh /data/on_boot.d/20-soundcork.sh
cp soundcork-provision-rootfs.sh /data/soundcork/soundcork-provision-rootfs.sh
cp soundcork-nspawn.sh /data/soundcork/soundcork-nspawn.sh
cp soundcork-healthcheck.sh /data/soundcork/soundcork-healthcheck.sh
chmod +x /data/on_boot.d/05-soundcork-runtime.sh
chmod +x /data/on_boot.d/20-soundcork.sh
chmod +x /data/soundcork/soundcork-provision-rootfs.sh
chmod +x /data/soundcork/soundcork-nspawn.sh
chmod +x /data/soundcork/soundcork-healthcheck.sh
```

To disable an on-boot hook, move it out of `/data/on_boot.d`, or rename it to
a suffix other than `.sh` and remove its execute bit. Some `unifi-common`
dispatchers run every executable file in that directory regardless of suffix,
and source non-executable `*.sh` files.

Edit `/data/soundcork/soundcork.env` and set `SOUNDCORK_HOST` or `BASE_URL` to
the LAN name or address reachable by SoundTouch speakers. The default derives:

```text
BASE_URL=http://${SOUNDCORK_HOST}:${SOUNDCORK_PORT}
```

If you have existing private SoundCork account data, copy it to:

```text
/data/soundcork/data/
```

Start or restart SoundCork without rebooting:

```sh
/data/on_boot.d/05-soundcork-runtime.sh
/data/on_boot.d/20-soundcork.sh
```

`20-soundcork.sh` recreates the SoundCork container and waits for:

```text
http://127.0.0.1:${SOUNDCORK_PORT}/bmx/registry/v1/services
```

If the endpoint does not become ready within `SOUNDCORK_READY_TIMEOUT`, the
script exits nonzero and prints a redacted tail of the container logs.

## Direct nspawn Fallback

Use `soundcork-nspawn.sh` on UniFi gateways where Docker or Podman cannot
start containers, or where you prefer a rootfs under `/data` over a host
container runtime. The launcher expects a prepared rootfs with Python,
SoundCork source, and a virtualenv containing Gunicorn and SoundCork's runtime
dependencies.

The optional provisioner builds that rootfs manually; do not place it in
`/data/on_boot.d`:

```sh
/data/soundcork/soundcork-provision-rootfs.sh
```

By default it creates `/data/soundcork/nspawn-rootfs` with Debian `trixie`,
clones `https://github.com/deborahgu/soundcork.git`, checks out `main`, creates
`/opt/soundcork-venv`, installs SoundCork dependencies when standard Python
metadata is present, and installs Gunicorn. It refuses rootfs targets outside
`/data` unless `SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA=1` is set.

If `debootstrap` is missing on the UniFi host, install it yourself or run the
provisioner with explicit host package installation enabled. This installs only
the provisioning tool; provide `systemd-nspawn` separately for the launcher, or
set `SOUNDCORK_NSPAWN` to an extracted binary under `/data`:

```sh
SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS=1 \
SOUNDCORK_ROOTFS_APT_UPDATE=1 \
/data/soundcork/soundcork-provision-rootfs.sh
```

Set `SOUNDCORK_ROOTFS_SUITE`, `SOUNDCORK_ROOTFS_MIRROR`, `SOUNDCORK_REPO_URL`,
and `SOUNDCORK_REPO_REF` before running the provisioner if you need a pinned
Debian suite, mirror, fork, tag, or commit. The default Python compatibility
check requires Python `>=3.12`; adjust `SOUNDCORK_ROOTFS_MIN_PYTHON` only when
you have selected a SoundCork ref that supports an older Python version.

Expected defaults inside the rootfs:

```text
/opt/soundcork/soundcork
/opt/soundcork-venv/bin/gunicorn
```

The launcher bind-mounts the controller's persistent data and logs into the
rootfs:

```text
/data/soundcork/data -> /soundcork/data
/data/soundcork/logs -> /soundcork/logs
```

Set nspawn-specific variables in `/data/soundcork/soundcork.env` or in a small
wrapper under `/data/on_boot.d`:

```sh
SOUNDCORK_ROOTFS=/data/soundcork/nspawn-rootfs
SOUNDCORK_NSPAWN=/usr/bin/systemd-nspawn
SOUNDCORK_APP_DIR=/opt/soundcork/soundcork
SOUNDCORK_PYTHONPATH=/opt/soundcork
SOUNDCORK_VENV=/opt/soundcork-venv
SOUNDCORK_GUNICORN=/opt/soundcork-venv/bin/gunicorn
DATA_DIR=/data/soundcork/data
LOG_DIR=/data/soundcork/logs
```

Example boot wrapper:

```sh
mkdir -p /data/soundcork/disabled-hooks
for hook in 05-soundcork-runtime.sh 20-soundcork.sh; do
    if [ -e "/data/on_boot.d/${hook}" ]; then
        mv "/data/on_boot.d/${hook}" "/data/soundcork/disabled-hooks/${hook}"
    fi
done

cat >/data/on_boot.d/20-soundcork-nspawn.sh <<'EOF'
#!/bin/sh
set -eu
exec env \
  SOUNDCORK_ROOTFS=/data/soundcork/nspawn-rootfs \
  SOUNDCORK_NSPAWN=/usr/bin/systemd-nspawn \
  /data/soundcork/soundcork-nspawn.sh
EOF
chmod +x /data/on_boot.d/20-soundcork-nspawn.sh
```

Do not enable both `/data/on_boot.d/20-soundcork.sh` and the nspawn wrapper on
the same port. Keep the Docker/Podman hooks moved out of `/data/on_boot.d`, or
renamed to a non-`.sh` suffix with no execute bit, until the new runtime has
passed readiness checks and a controller reboot test.

## Log Retention

The Docker path applies per-container log limits by default:

```sh
SOUNDCORK_CONTAINER_LOG_DRIVER=local
SOUNDCORK_CONTAINER_LOG_MAX_SIZE=10m
SOUNDCORK_CONTAINER_LOG_MAX_FILE=3
```

The included `docker-daemon.json.example` uses the same host-wide defaults.

The direct nspawn launcher writes Gunicorn output through a rotating file
logger. By default it keeps `/data/soundcork/logs/soundcork-nspawn.log` plus
three 10 MiB rotated files:

```sh
SOUNDCORK_LOG_MAX_BYTES=10485760
SOUNDCORK_LOG_ROTATIONS=3
```

## Optional Docker Daemon Config

The included `docker-daemon.json.example` is only for Docker installs that need
a conservative UniFi host configuration. It moves Docker storage to
`/data/docker` and disables Docker's default bridge and iptables management,
which are unnecessary for this host-networked SoundCork container.

If you do not want the runtime hook to manage Docker configuration, omit
`/data/soundcork/docker-daemon.json` or set `DOCKER_DAEMON_SOURCE` to an absent
path.

## Private Data Handling

Treat these paths as private operational data, not addon source:

- `/data/soundcork/data/` contains SoundCork account data and may contain
  speaker account credentials.
- `/data/soundcork/data/spotify/accounts.json` contains Spotify access and
  refresh tokens after Spotify account linking.
- `/data/soundcork/soundcork.env` can contain `SPOTIFY_CLIENT_SECRET` and other
  deployment-specific secrets.
- Backups and exported runtime logs may contain the same private data.

Do not commit or attach private data, token files, OAuth callback `code` values,
or filled-in `soundcork.env` files. This addon ignores common local export
folders such as `soundcork-data/`, `soundcork-logs/`, `backups/`, and
`runtime/`.

## Speaker Configuration

Configure each SoundTouch speaker to use the local SoundCork endpoints. The
speaker override should contain the local `marge` endpoint and registry URL:

```text
http://unifi:8001/marge
http://unifi:8001/bmx/registry/v1/services
```

Use your normal SoundTouch service or recovery access method to write
`/mnt/nv/OverrideSdkPrivateCfg.xml`, then reboot the speaker. Update one test
speaker first and keep the previous SoundCork instance available until the
test speaker has survived a reboot.

Custom radio presets can contain absolute SoundCork URLs. Update preset
locations when moving SoundCork to a new host, name, or port.

## Verification

From a normal LAN client or from the UniFi host:

```sh
getent hosts unifi
command curl -sS http://unifi:8001/
command curl -sS http://unifi:8001/bmx/registry/v1/services
/data/soundcork/soundcork-healthcheck.sh
```

If `unifi` resolves to multiple addresses, confirm that every returned address
is on the same UniFi host and reachable from the speaker LAN before writing it
into a speaker override or preset URL.

When Spotify support is configured, the healthcheck runs the accounts endpoint
in `auto` mode. You can force or skip that check explicitly:

```sh
/data/soundcork/soundcork-healthcheck.sh --spotify
/data/soundcork/soundcork-healthcheck.sh --no-spotify
```

The healthcheck logs status through `logger` and does not print response
bodies, Spotify client secrets, access tokens, refresh tokens, or OAuth
callback codes.

After updating and rebooting a test speaker, verify through the speaker API
that `/info` reports the expected `margeURL` and that `/sources` reports
`TUNEIN` and `LOCAL_INTERNET_RADIO` as `READY`.

## Spotify Presets

Spotify Connect can work without SoundCork Spotify credentials because the
speaker is selected directly from the Spotify app. Spotify presets started by
the speaker after a cold boot are different: the speaker asks SoundCork for a
fresh Spotify token.

To enable that path, create a Spotify Developer app with both `Web API` and
`Web Playback SDK` enabled. Spotify requires HTTPS redirect URIs except for
loopback IP addresses, so use this loopback redirect URI for account linking:

```text
http://127.0.0.1:18001/callback
```

Then uncomment the Spotify lines in `/data/soundcork/soundcork.env` and add
the private app values:

```sh
SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
SPOTIFY_REDIRECT_URI=http://127.0.0.1:18001/callback
```

If your selected SoundCork image supports Spotify ZeroConf priming, configure its documented primer environment variables in `soundcork.env`.

Leave the primer device allowlist empty only if you are ready for SoundCork to
prime every device it knows about. After linking a Spotify account, verify only
redacted or account-safe output from:

```sh
command curl -sS http://unifi:8001/mgmt/spotify/accounts
```

## Address Binding

The published SoundCork image starts Gunicorn on `0.0.0.0:8000` by default.
This addon overrides that command and binds to
`0.0.0.0:${SOUNDCORK_PORT}`, defaulting to port `8001`. The alternate default
avoids UniFi services that may already listen on `127.0.0.1:8000` on some
gateways.

With the direct Docker/Podman setup in this addon, `--network host` means that
the selected port is bound on all IPv4 addresses of the UniFi host. In that
case, a multi-address `unifi` DNS answer is fine as long as every returned
address is on the same UniFi host and reachable from the speaker LAN.

If SoundCork runs inside an isolated nspawn/macvlan container, `0.0.0.0` means
all addresses inside that container, not the UniFi host addresses. In that
layout, point `BASE_URL` at the container's stable address and port, or add a
host-level proxy/port-forward from the UniFi host address to the container.
