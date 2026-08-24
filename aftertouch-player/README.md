# AfterTouch Player

Run the standalone
[`soundtouch-player`](https://github.com/gesellix/Bose-SoundTouch) binary on a
UniFi OS gateway using
[`unifi-common`](https://github.com/unifi-utilities/unifi-common)'s
`/data/on_boot.d` hook.

This addon packages only the stateless LAN player and its web UI. It does not
install the stateful `soundtouch-service`, configure speakers, alter firewall
rules, or expose the API outside networks already able to reach the selected
gateway address.

> [!WARNING]
> The player API has no authentication. Bind it to one trusted LAN IPv4
> address, never `0.0.0.0` or `::`, and do not expose its port to untrusted
> routed networks.

## Requirements

- `unifi-common` installed and `udm-boot.service` enabled;
- root access to the gateway;
- `systemd`, `flock`, `sha256sum`, `cmp`, `ss`, and either `curl` or `wget`;
- a stable, non-wildcard IPv4 address on the gateway;
- either explicitly listed SoundTouch speaker addresses or a deliberately
  selected discovery interface.

## Files And Persistent Layout

Copy this directory to `/data/aftertouch-player`. The installer maintains
immutable artifact directories and replaces the `current` symlink atomically:

```text
/data/aftertouch-player/
  install.sh
  run.sh
  aftertouch-player-healthcheck.sh
  aftertouch-player.service
  config.env
  .operation.lock
  releases/<artifact-id>/
    soundtouch-player
    manifest
  current -> releases/<artifact-id>
  verified -> releases/<last-verified-artifact-id>
  previous -> releases/<previous-artifact-id>
/data/on_boot.d/26-aftertouch-player.sh
```

The systemd unit always executes the selected `current` path. The boot hook
moves `verified` only after the checksum, listener, HTTP, inventory, and systemd
checks pass. `previous` therefore tracks the verified generation before it,
not merely the last artifact downloaded. Official releases and local
development builds use the same runtime and rollback path. The installer and
boot hook serialize state changes with `.operation.lock`; a concurrent command
fails without changing the selected artifact and can be retried afterward.

The `udm-boot` hook is the sole owner of boot-time startup. Each activation
reinstalls the unit, removes any direct `multi-user.target` enablement left by
an earlier addon revision, and then restarts the service. The unit is therefore
expected to be active but disabled; do not enable it separately, because that
would race the validated hook path during boot.

## First Installation And Configuration

Copy the addon to persistent storage and create `config.env` directly from the
example before running an activating install:

```sh
mkdir -p /data/aftertouch-player
cp -a aftertouch-player/. /data/aftertouch-player/
cd /data/aftertouch-player
if [ ! -e config.env ]; then
  install -m 0640 aftertouch-player.env.example config.env
fi
vi config.env
```

Replace the example addresses and review the complete file. Then download,
verify, install, and activate an explicit release:

```sh
./install.sh --release v0.129.0 --activate
```

The installer also creates `config.env` from the example when it is missing,
but it deliberately preserves any existing file instead of guessing whether it
is operator-managed configuration. Do not create an empty `config.env`.

The conservative default disables UPnP and mDNS and requires
`SOUNDTOUCH_DEVICES`. To enable discovery, explicitly enable at least one
protocol and set `DISCOVERY_INTERFACE` to an interface with a usable IPv4
address.

`SERVICE_URL` and `SERVICE_CA` must remain empty. A SoundCork endpoint is not an
AfterTouch `soundtouch-service` endpoint.

## Install An Official Release

Run the installer manually. It maps the gateway architecture to the official
Linux asset, downloads that asset and its `.sha256` file over HTTPS, verifies
the digest, and installs it under `/data`. On an already configured addon,
activate the verified artifact in the same operation:

```sh
cd /data/aftertouch-player
./install.sh --release v0.129.0 --activate
```

The release tag is always explicit. The installer never resolves `latest`, and
the boot hook never downloads or updates anything. A non-default
`AFTERTOUCH_RELEASE_BASE_URL` is recorded as `release-mirror`, not as an
official release source.

> [!NOTE]
> Releases `v0.128.0` and `v0.129.0` predate the upstream
> [configured-device retry fix](https://github.com/gesellix/Bose-SoundTouch/pull/644).
> They do not retry an explicitly configured speaker that was offline during
> player startup. After such a speaker comes online, restart
> `aftertouch-player.service`, or use the first later release that contains the
> fix once it is available.

Omitting `--activate` selects the artifact without restarting the service. On a
first installation it also leaves the boot hook uninstalled. On an existing
installation, however, the existing hook remains and will use the selected
artifact after a reboot; do not treat this mode as persistent staging across a
reboot.

## Install A Local Development Build

Build on a workstation from a clean commit. AfterTouch's production binaries
are pure Go and can be cross-compiled on x86_64 without an ARM toolchain:

```sh
commit=$(git rev-parse HEAD)
version="dev-$(git rev-parse --short=12 HEAD)"
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath \
  -ldflags="-s -w -X main.version=${version} -X main.commit=${commit} -X main.date=${build_date}" \
  -o soundtouch-player-linux-arm64 ./cmd/soundtouch-player

scp soundtouch-player-linux-arm64 root@unifi:/tmp/
```

For an ARMv7 gateway use `GOARCH=arm GOARM=7`; for x86_64 use
`GOARCH=amd64`. Then install the exact uploaded file with a meaningful,
shell-safe version identifier. Replace the example below with the `version`
value from the build shell:

```sh
cd /data/aftertouch-player
./install.sh \
  --local /tmp/soundtouch-player-linux-arm64 \
  --version dev-245032e00537 \
  --activate
```

Local mode performs no network request. Its manifest records the supplied
version, architecture, original filename, and computed SHA-256. Keep the source
commit and Go toolchain version in the deployment worklog.

## Local Validation

Run the focused shell checks before copying the addon to a gateway:

```sh
shellcheck -x aftertouch-player/*.sh aftertouch-player/tests/*.sh
shfmt -d aftertouch-player/*.sh aftertouch-player/tests/*.sh
aftertouch-player/tests/test-addon.sh
```

The test uses local fixtures and a fake service manager. It does not contact a
gateway or mutate speakers.

## Verification

The boot hook verifies the active binary against its manifest before every
start, restores the intentionally disabled unit, starts the service, and waits
for the healthcheck. Run the same checks manually with:

```sh
/data/aftertouch-player/aftertouch-player-healthcheck.sh
systemctl status --no-pager aftertouch-player.service
systemctl is-enabled aftertouch-player.service || true
readlink /data/aftertouch-player/current
cat /data/aftertouch-player/current/manifest
```

The healthcheck verifies the checksum, exact listener, `/health`, the running
build version against the active manifest, and the device inventory endpoint.
Optional `EXPECTED_DEVICE_IDS` values in
`config.env` must all appear in the inventory; leave it empty if speakers may
be powered off while the gateway boots. This confirms discovery and process
health only; it does not authorize playback, volume, preset, or zone changes.

## Rollback And Removal

If `current` has not passed activation, rollback selects the last `verified`
player artifact. Otherwise it selects `previous`, the verified player artifact
preceding it. Restart through the same offline hook:

```sh
cd /data/aftertouch-player
./install.sh --rollback --activate
```

This rolls back the `soundtouch-player` binary and its manifest. It does not
restore an older revision of the addon's shared `install.sh`, `run.sh`,
healthcheck, systemd unit, or boot hook. Before copying a newer revision of the
addon itself over an existing installation, preserve those control files and
the hook outside `/data/on_boot.d`. Restore that copy first if the addon-code
upgrade fails, then use the artifact rollback above if needed. This distinction
does not apply when only changing between official or local player artifacts
with an unchanged addon revision.

To disable the addon permanently, move or rename the hook outside
`/data/on_boot.d` before stopping the service:

```sh
mkdir -p /data/aftertouch-player/disabled-hooks
mv /data/on_boot.d/26-aftertouch-player.sh \
  /data/aftertouch-player/disabled-hooks/26-aftertouch-player.sh.disabled
systemctl disable --now aftertouch-player.service
rm -f /etc/systemd/system/aftertouch-player.service
systemctl daemon-reload
```

Do not merely remove the hook's executable bit. `unifi-common` dispatchers may
source non-executable files whose names still end in `.sh`.

Keep `/data/aftertouch-player/releases` until rollback and removal have been
verified. The installer deliberately does not prune old development builds;
after validation, remove only release directories not referenced by `current`
or the `verified` and `previous` rollback markers.
