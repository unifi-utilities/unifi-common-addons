# AfterTouch Service

Run the complete
[`soundtouch-service`](https://github.com/gesellix/Bose-SoundTouch) backend and
its embedded web player on a UniFi OS gateway. The addon uses
[`unifi-common`](https://github.com/unifi-utilities/unifi-common)'s persistent
`/data/on_boot.d` hook and supports both verified upstream releases and local
development builds.

This is separate from the smaller `aftertouch-player` addon. The full service
stores account, device, preset, OAuth, certificate, and settings data and can
emulate Bose endpoints when an operator deliberately configures speakers to
use it.

> [!WARNING]
> Several setup and player routes assume a trusted LAN and are not all covered
> by the Management API credentials. Bind AfterTouch to one trusted IPv4
> address, never `0.0.0.0`, and restrict routed access with the UniFi firewall.
> Installing this addon does not migrate or reconfigure a speaker by itself.

## Safe Defaults

The example configuration is a side-by-side canary:

- HTTP listens only on `127.0.0.1:18000` and HTTPS on `127.0.0.1:18443`;
- speaker discovery, interaction recording, and update checks are disabled;
- the embedded DNS server is disabled and the launcher refuses to start if it
  is enabled in either `config.env` or persisted `settings.json`;
- persistent state lives under `/data/aftertouch-service/data`;
- the published default management password is rejected.

Before a canary that will later become LAN-accessible, set `SERVER_URL` and
`HTTPS_SERVER_URL` to the final trusted LAN address while keeping `BIND_ADDR`
on loopback. AfterTouch persists the URLs in `settings.json` on first start.

UniFi already owns port 53. DNS interception and automatic speaker migration
are therefore outside this addon's scope.

## Requirements

- `unifi-common` installed and `udm-boot.service` enabled;
- root access to the gateway;
- `systemd`, `setpriv`, `flock`, `sha256sum`, `cmp`, `ss`, `cp`, `chown`, and
  either `curl` or `wget`;
- a supported `arm64`, `armv7`, or `amd64` gateway;
- enough space under `/data` for the binary, persistent state, and deliberate
  state snapshots.

The root-owned launcher verifies the artifact and configuration, then uses
`setpriv` to execute the service as fixed non-root UID and GID `65532`, matching
the upstream container image. The systemd capability bounding set permits only
that one-time UID/GID drop. The installer assigns only the persistent data
directory to the service identity. Control files, releases, configuration, and
state snapshots remain root-owned.

The systemd unit remains disabled. The executable `/data/on_boot.d` hook is the
single owner of boot ordering: it restores the unit, removes any legacy
enablement, starts the service, and promotes an artifact only after health
verification succeeds.

## Persistent Layout

```text
/data/aftertouch-service/
  config.env                         # root-only secrets and startup defaults
  data/                              # UID 65532; live mutable state
    settings.json
    certs/                           # generated CA and private keys
    ...
  state-snapshots/                   # root-only explicit state snapshots
  releases/<artifact-id>/
    soundtouch-service
    manifest
  current -> releases/<artifact-id>
  verified -> releases/<last-verified-artifact-id>
  previous -> releases/<previous-artifact-id>
  install.sh
  run.sh
  aftertouch-service-healthcheck.sh
  aftertouch-service-state.sh
  aftertouch-service.service
  .operation.lock
/data/on_boot.d/27-aftertouch-service.sh
```

Artifact rollback and state restore are intentionally independent. Switching
the binary does not overwrite `data`, and restoring a state snapshot does not
change the selected binary.

## First Installation

Copy this addon directory to the gateway, then stage an explicit upstream
release without activating it:

```sh
mkdir -p /data/aftertouch-service
cp -a aftertouch-service/. /data/aftertouch-service/
cd /data/aftertouch-service
./install.sh --release v0.129.0
```

The installer creates a root-only `config.env` when none exists. Generate a
unique password on a trusted machine, edit the file, and keep the value out of
shell history and Git:

```sh
openssl rand -hex 24
vi /data/aftertouch-service/config.env
```

Keep `BIND_ADDR=127.0.0.1`, but set `SERVER_URL` and `HTTPS_SERVER_URL` to the
final trusted LAN address if this canary will later serve that LAN. Keep the
same HTTP and HTTPS ports in both phases. Then perform the first activation:

```sh
cd /data/aftertouch-service
./install.sh --activate
./aftertouch-service-healthcheck.sh
```

The boot hook verifies the selected binary and its manifest, restores the
systemd unit, starts the service, and promotes the artifact to `verified` only
after the complete healthcheck succeeds.

## Bind To A Trusted LAN

For example, a first canary intended to become available at `192.0.2.1` uses:

```sh
BIND_ADDR=127.0.0.1
PORT=18000
HTTPS_PORT=18443
SERVER_URL=http://192.0.2.1:18000
HTTPS_SERVER_URL=https://192.0.2.1:18443
```

After that loopback canary passes, change only the bind address:

```sh
BIND_ADDR=192.0.2.1
```

Then restart through the persistent hook and rerun the healthcheck:

```sh
/data/on_boot.d/27-aftertouch-service.sh
/data/aftertouch-service/aftertouch-service-healthcheck.sh
```

Do not expose these ports to the Internet or unrelated routed networks.
Discovery remains off until explicitly enabled. It may be preferable to add
known devices through AfterTouch rather than enabling broad discovery on a
multi-interface gateway.

On first start, AfterTouch writes effective settings to `data/settings.json`.
For several options, including the service URLs, persisted settings then take
precedence over environment defaults. Do not start with loopback URLs and
expect a later env-only edit to replace them. Subsequent changes made in the
web settings page are intentional persistent configuration, not deployment
drift. The launcher still rejects persisted DNS enablement because it conflicts
with UniFi.

The optional Stockholm frontend is not distributed by AfterTouch. To supply a
separately obtained and reviewed tree, place it below
`/data/aftertouch-service/stockholm` and set `STOCKHOLM_DIR` accordingly.

## Official Releases

The installer maps the gateway architecture to the matching upstream asset,
downloads the binary and `.sha256` sidecar over HTTPS, verifies the digest, and
records provenance in an immutable release directory:

```sh
cd /data/aftertouch-service
./aftertouch-service-state.sh snapshot
./install.sh --release v0.129.0 --activate
```

The tag is always explicit. The installer never resolves `latest`, and the
boot hook performs no downloads. A custom `AFTERTOUCH_RELEASE_BASE_URL` is
recorded as `release-mirror`, not as an official release.

Omitting `--activate` changes the `current` selection without restarting. If a
boot hook is already installed, a reboot will use that selection, so this is
not persistent staging across reboots.

## Local Development Builds

The full service is pure Go and can be cross-compiled on an `amd64` workstation
without an ARM toolchain:

```sh
commit=$(git rev-parse HEAD)
version="dev-$(git rev-parse --short=12 HEAD)"
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath \
  -ldflags="-s -w -X main.version=${version} -X main.commit=${commit} -X main.date=${build_date}" \
  -o soundtouch-service-linux-arm64 ./cmd/soundtouch-service
```

Use `GOARCH=arm GOARM=7` for ARMv7 or `GOARCH=amd64` for x86-64. Install the
exact uploaded file through the same validation path:

```sh
./install.sh \
  --local /tmp/soundtouch-service-linux-arm64 \
  --version dev-424631b93a7f \
  --activate
```

Local mode performs no network request. Record the source commit and Go
toolchain version in the deployment worklog.

## State Snapshots

State snapshots contain secrets, OAuth data, and private keys. They are stored
root-only under `/data` and must not be committed or copied to an untrusted
host.

```sh
cd /data/aftertouch-service
./aftertouch-service-state.sh snapshot
./aftertouch-service-state.sh list
./aftertouch-service-state.sh restore 20260823T120000Z --yes
```

For a coherent snapshot, the helper briefly stops an active service and starts
it again through the healthcheck. Restore automatically keeps a `pre-restore`
snapshot and rolls the live directory back if the selected state does not pass
validation. An intentionally inactive service remains inactive.

## Verification

```sh
/data/aftertouch-service/aftertouch-service-healthcheck.sh
systemctl status --no-pager aftertouch-service.service
readlink /data/aftertouch-service/current
cat /data/aftertouch-service/current/manifest
```

The healthcheck verifies:

- the active binary checksum, reported build version, and effective data path;
- exact HTTP and HTTPS listener addresses;
- `/health`, the embedded `/app/`, and the device inventory endpoint;
- HTTPS using the persistent generated CA;
- the presence of settings and private-key state.

Optional comma-separated `EXPECTED_DEVICE_IDS` values must all appear in the
inventory. Leave the value empty if speakers may be powered off during boot.
This is a read-only service check; it does not authorize playback, volume,
preset, zone, account, or speaker migration changes.

## Artifact Rollback

Rollback selects the last healthy artifact and activates it through the same
offline boot hook:

```sh
cd /data/aftertouch-service
./install.sh --rollback --activate
```

This changes only the binary and manifest. Use `aftertouch-service-state.sh`
for state recovery. The installer does not prune old releases or snapshots.

The artifact rollback does not restore an older revision of the addon's own
shell scripts or systemd unit. Preserve those control files separately before
replacing them with an untested addon revision.

## Disable Or Remove

Move the executable hook out of `/data/on_boot.d` before stopping the service:

```sh
mkdir -p /data/aftertouch-service/disabled-hooks
mv /data/on_boot.d/27-aftertouch-service.sh \
  /data/aftertouch-service/disabled-hooks/27-aftertouch-service.sh.disabled
systemctl disable --now aftertouch-service.service
rm -f /etc/systemd/system/aftertouch-service.service
systemctl daemon-reload
```

Do not merely clear the hook's executable bit. `unifi-common` dispatchers may
source non-executable files whose names still end in `.sh`.

Keep `data`, `state-snapshots`, and all releases until removal and any required
recovery have been verified.

## Local Validation

```sh
shellcheck -x aftertouch-service/*.sh aftertouch-service/tests/*.sh
shfmt -d aftertouch-service/*.sh aftertouch-service/tests/*.sh
aftertouch-service/tests/test-addon.sh
```

The focused tests use local fixtures and a fake service manager. They do not
contact a gateway or mutate speakers.
