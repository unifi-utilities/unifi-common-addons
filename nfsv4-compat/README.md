# NFSv4 Support For UniFi Drive

Enables clients to mount shares exported by UniFi Drive using NFSv4.

It installs two halves that run independently:

- `nfsv4-compat` mirrors each exported share into a symlink-free tree under a read-only `fsid=0`
  root, because v4 clients walk the export path through the server's namespace and cannot follow
  the symlinks UniFi Drive exports. Clients mount `<nas>:/var/nfs/shared/v4/<name>`, i.e. UniFi's
  displayed path with `/v4` inserted before the share name. v3 clients are unaffected.
- `nfsv4-enable` keeps NFSv4 turned on in `/etc/nfs.conf`. UniFi Drive's config daemon writes
  `vers4=n` into that file every time the app pushes its NFS configuration, which leaves even a
  correctly mirrored share failing with `mount.nfs: Protocol not supported`.

## Installation

1. [on_boot.d](https://github.com/unifi-utilities/unifi-common)
2. Copy
   - `11-nfsv4-compat.sh` to `/data/on_boot.d/`
   - the systemd unit files to `/data/unifi-common-addons/nfsv4-compat/systemd/`
   - the `nfsv4-compat` and `nfsv4-enable` scripts to `/data/unifi-common-addons/nfsv4-compat/scripts/`
3. You _should_ end up with:

```text
/data
├── ...
├── on_boot.d/
    ├── ...
    ├── 11-nfsv4-compat.sh
    └── ...
├── unifi-common-addons/
    └── nfsv4-compat/
        ├── scripts/
            ├── nfsv4-compat
            └── nfsv4-enable
        └── systemd/
            ├── nfsv4-compat.path
            ├── nfsv4-compat.service
            ├── nfsv4-compat.timer
            ├── nfsv4-enable.path
            ├── nfsv4-enable.service
            └── nfsv4-enable.timer
└── ...
```

4. Run `/data/on_boot.d/11-nfsv4-compat.sh` (or reboot)

5. Check that everything is correct:

- `systemctl list-timers nfsv4-compat.timer nfsv4-enable.timer`
- `systemctl status nfsv4-compat.path nfsv4-compat.service`
- `systemctl status nfsv4-enable.path nfsv4-enable.service`
- `cat /proc/fs/nfsd/versions` (expect `+4 +4.1 +4.2`)
- `exportfs -v` (expect `/run/nfs` with `fsid=0`, and a `/run/nfs/var/nfs/shared/v4/<name>` line per share)
