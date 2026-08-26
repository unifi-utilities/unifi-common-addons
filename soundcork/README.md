# SoundCork

Run [SoundCork](https://github.com/deborahgu/soundcork) on a UniFi OS
gateway using [`unifi-common`](https://github.com/unifi-utilities/unifi-common)'s
`/data/on_boot.d` hook.

SoundCork emulates the discontinued Bose SoundTouch cloud endpoints used for
account data, internet radio, and some speaker-managed music-provider flows.
Speakers still need a local `/mnt/nv/OverrideSdkPrivateCfg.xml` that points at
this SoundCork instance. DNS hijacking Bose HTTPS hostnames alone may not be
enough on firmware that validates TLS certificates.

## Requirements

- [`unifi-common`](https://github.com/unifi-utilities/unifi-common) installed
  and `udm-boot.service` enabled.
- A stable speaker-facing DNS name or address for the UniFi host. The default
  is `http://unifi:8001`, which works when `unifi` resolves from the speaker
  LAN.
- [Docker](https://docs.docker.com/engine/) or
  [Podman](https://podman.io/) on the UniFi OS host, or a prepared rootfs for
  the direct [`systemd-nspawn`](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html)
  launcher. If no container runtime is available, the runtime hook can try
  `apt-get install docker.io` when `apt-get` is present and
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
- `soundcork-nspawn.service` owns the nspawn process cgroup so a later failing
  `/data/on_boot.d` hook cannot terminate an already started SoundCork process.
- `20-soundcork-nspawn.sh` installs that unit and starts it from the normal
  `udm-boot` hook sequence.
- `30-soundtouch-remux.sh` optionally starts a helper that remuxes selected
  Ogg-FLAC radio streams to native FLAC for SoundTouch internet radio playback.
- `remux_stream_endpoint.py` is the small HTTP remux helper used by
  `30-soundtouch-remux.sh`.
- `soundcork.env.example` is the controller-side environment template.
- `soundcork-healthcheck.sh` checks SoundCork, optional Spotify account
  support.
- `docker-daemon.json.example` is an optional conservative Docker daemon config
  for UniFi hosts.

## Installation

Copy the addon files to the UniFi host and create persistent directories:

```sh
mkdir -p \
  /data/on_boot.d \
  /data/soundcork/data \
  /data/soundcork/logs
cp soundcork.env.example /data/soundcork/soundcork.env
cp docker-daemon.json.example /data/soundcork/docker-daemon.json
cp 05-soundcork-runtime.sh /data/on_boot.d/05-soundcork-runtime.sh
cp 20-soundcork.sh /data/on_boot.d/20-soundcork.sh
cp 30-soundtouch-remux.sh /data/on_boot.d/30-soundtouch-remux.sh
cp remux_stream_endpoint.py /data/soundcork/remux_stream_endpoint.py
cp soundcork-provision-rootfs.sh /data/soundcork/soundcork-provision-rootfs.sh
cp soundcork-nspawn.sh /data/soundcork/soundcork-nspawn.sh
cp soundcork-nspawn.service /data/soundcork/soundcork-nspawn.service
cp soundcork-healthcheck.sh /data/soundcork/soundcork-healthcheck.sh
chmod +x /data/on_boot.d/05-soundcork-runtime.sh
chmod +x /data/on_boot.d/20-soundcork.sh
chmod +x /data/on_boot.d/30-soundtouch-remux.sh
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

This direct launcher is separate from the more general
[`nspawn-container`](../nspawn-container) addon. Use that addon when you want a
generic managed container. Use `soundcork-nspawn.sh` when you want the smallest
SoundCork-specific runtime surface under `/data/soundcork`.

The optional provisioner builds that rootfs manually; do not place it in
`/data/on_boot.d`:

```sh
/data/soundcork/soundcork-provision-rootfs.sh
```

By default it creates `/data/soundcork/nspawn-rootfs` with
[Debian trixie](https://www.debian.org/releases/trixie/), clones
[`deborahgu/soundcork`](https://github.com/deborahgu/soundcork), checks out
`main`, creates `/opt/soundcork-venv`, installs SoundCork dependencies when
standard Python metadata is present, and installs Gunicorn. It refuses rootfs
targets outside `/data` unless `SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA=1` is set.

If [`debootstrap`](https://wiki.debian.org/Debootstrap) is missing on the
UniFi host, install it yourself or run the provisioner with explicit host
package installation enabled. This installs only the provisioning tool; provide
`systemd-nspawn` separately for the launcher, or set `SOUNDCORK_NSPAWN` to an
extracted binary under `/data`:

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
/data/soundtouch-registry -> /soundtouch-registry (read-only)
```

The registry mount is optional application input. Set both
`SOUNDTOUCH_REGISTRY_DIR` and `SOUNDTOUCH_REGISTRY_FILE` to let a compatible
SoundCork fork read an exported inventory. The launcher creates the controller
directory when needed and never grants the application write access to it.

Set nspawn-specific variables in `/data/soundcork/soundcork.env`:

```sh
SOUNDCORK_ROOTFS=/data/soundcork/nspawn-rootfs
# Use /usr/bin/systemd-nspawn when the host provides it, or the extracted
# systemd-container payload under /data/soundcork/nspawn-tools.
SOUNDCORK_NSPAWN=/data/soundcork/nspawn-tools/usr/bin/systemd-nspawn
SOUNDCORK_APP_DIR=/opt/soundcork/soundcork
SOUNDCORK_PYTHONPATH=/opt/soundcork
SOUNDCORK_VENV=/opt/soundcork-venv
SOUNDCORK_GUNICORN=/opt/soundcork-venv/bin/gunicorn
DATA_DIR=/data/soundcork/data
LOG_DIR=/data/soundcork/logs
SOUNDTOUCH_REGISTRY_DIR=/data/soundtouch-registry
SOUNDTOUCH_REGISTRY_FILE=/soundtouch-registry/site.json
```

Install the supplied boot hook after moving the Docker/Podman hooks aside:

```sh
mkdir -p /data/soundcork/disabled-hooks
for hook in 05-soundcork-runtime.sh 20-soundcork.sh; do
    if [ -e "/data/on_boot.d/${hook}" ]; then
        mv "/data/on_boot.d/${hook}" "/data/soundcork/disabled-hooks/${hook}"
    fi
done

cp 20-soundcork-nspawn.sh /data/on_boot.d/20-soundcork-nspawn.sh
chmod +x /data/on_boot.d/20-soundcork-nspawn.sh
/data/on_boot.d/20-soundcork-nspawn.sh
```

`soundcork-nspawn.service` is static and is not pulled in by a boot target. The
normal boot path starts it through the hook, leaving boot ordering with
`udm-boot.service`, while systemd owns the running nspawn process in a separate
service cgroup. A failure in a later boot hook can therefore fail the dispatcher
without killing SoundCork. Use the boot hook, not `soundcork-nspawn.sh`
directly, for later deployments and manual restarts.

To return to the Docker or Podman path, first move the nspawn hook out of the
dispatcher and stop its active service. Only then restore the Docker/Podman
hooks:

```sh
mkdir -p /data/soundcork/disabled-hooks
mv /data/on_boot.d/20-soundcork-nspawn.sh \
  /data/soundcork/disabled-hooks/20-soundcork-nspawn.sh
systemctl stop soundcork-nspawn.service
rm -f /etc/systemd/system/soundcork-nspawn.service
systemctl daemon-reload
for hook in 05-soundcork-runtime.sh 20-soundcork.sh; do
    mv "/data/soundcork/disabled-hooks/${hook}" "/data/on_boot.d/${hook}"
    chmod +x "/data/on_boot.d/${hook}"
done
/data/on_boot.d/05-soundcork-runtime.sh
/data/on_boot.d/20-soundcork.sh
/data/soundcork/soundcork-healthcheck.sh --no-spotify --no-remux
```

The unit is static and cannot be enabled through `systemctl enable`. Stopping
it is still required during rollback because `disabled` or `static` does not
mean that an already running service has stopped. The restored `20` hook waits
for the registry endpoint before the final healthcheck runs.

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

## Optional FLAC Remux Helper

Some radio stations publish FLAC audio inside an Ogg container. Tested
SoundTouch firmware can fetch those streams but rejects the Ogg-FLAC framing in
the internet-radio path, while the same audio remuxed to native FLAC plays.

The optional `30-soundtouch-remux.sh` hook starts a small host-networked HTTP
helper on port `8768`. It serves:

```text
GET  /healthz
GET  /metrics
HEAD /flac
GET  /flac
GET  /remux/flac
```

`/flac` runs ffmpeg in remux-only mode:

```text
Ogg-FLAC input -> native FLAC output
```

It does not transcode audio, so quality is preserved. Each playback client owns
one ffmpeg process; the helper terminates that process when the client
disconnects. Upstream hosts are allowlisted by the Python helper.

In `auto` mode, the hook first tries to reuse the direct SoundCork rootfs with
`chroot` when that rootfs contains Python and a usable `ffmpeg` executable. If
that rootfs is not available, it falls back to the original Docker/Podman
sidecar path. A separate `nspawn` mode is available only for a separate rootfs;
a second `systemd-nspawn` process cannot reuse a busy rootfs already used by
SoundCork.

Enable it explicitly in `/data/soundcork/soundcork.env`:

```sh
SOUNDTOUCH_REMUX_ENABLED=1
SOUNDTOUCH_REMUX_PORT=8768
SOUNDTOUCH_REMUX_RUNTIME=auto
SOUNDTOUCH_REMUX_UPSTREAM=https://amp.cesnet.cz:8443/cro3.flac
# Optional command name or absolute path inside the selected runtime. A
# portable build such as BtbN's FFmpeg builds can be installed into the rootfs
# as ffmpeg-btbn; this addon does not download or verify it.
# Prefer a command name available in SOUNDTOUCH_REMUX_RUNTIME_PATH for rootfs mode.
# SOUNDTOUCH_REMUX_FFMPEG=ffmpeg-btbn
# SOUNDTOUCH_REMUX_RUNTIME_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Optional comma- or whitespace-separated upstream host allowlist.
SOUNDTOUCH_REMUX_ALLOW_HOSTS="amp.cesnet.cz radio.cesnet.cz"
# Optional ffmpeg concurrency cap. 0 or unset means unlimited.
SOUNDTOUCH_REMUX_MAX_ACTIVE_PROCESSES=4
# Optional rootfs paths; defaults match the direct SoundCork nspawn launcher.
# SOUNDTOUCH_REMUX_ROOTFS=/data/soundcork/nspawn-rootfs
# Only used with SOUNDTOUCH_REMUX_RUNTIME=nspawn and a separate, non-busy rootfs.
# SOUNDTOUCH_REMUX_NSPAWN=/data/soundcork/nspawn-tools/usr/bin/systemd-nspawn
# Set to 1 only when remux should be a hard udm-boot dependency.
SOUNDTOUCH_REMUX_REQUIRED=0
```

For rootfs/chroot remux, either install `ffmpeg` from the rootfs package
repositories or place a portable build such as
[BtbN's FFmpeg builds](https://github.com/BtbN/FFmpeg-Builds) under
`/usr/local/bin/ffmpeg-btbn` inside the rootfs and set
`SOUNDTOUCH_REMUX_FFMPEG=ffmpeg-btbn`. Keep binary downloads and checksum
verification outside this addon for now; a future release workflow can publish
or pin a prepared rootfs artifact.

Start or restart it without rebooting:

```sh
/data/on_boot.d/30-soundtouch-remux.sh
```

Then verify from the UniFi host and from the speaker LAN:

```sh
command curl -fsS http://127.0.0.1:8768/healthz
command curl -fsS http://unifi:8768/healthz
command curl -I http://unifi:8768/flac
/data/soundcork/soundcork-healthcheck.sh --remux
```

Point a SoundCork `LOCAL_INTERNET_RADIO` stream URL at
`http://unifi:8768/flac`, or pass a percent-encoded upstream URL for individual
stations:

```text
http://unifi:8768/flac?url=https%3A%2F%2Famp.cesnet.cz%3A8443%2Fcro3.flac
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
