# NFSv4 Support For UniFi Drive

Enables clients to mount shares exported by UniFi Drive using NFSv4.

## Installation

1. [on_boot.d](https://github.com/unifi-utilities/unifi-common)
2. Copy
   - `11-nfsv4-compat.sh` to `/data/on_boot.d/`
   - the systemd unit files to `/data/unifi-common-addons/nfsv4-compat/systemd/`
   - the main `nfsv4-compat` script to `/data/unifi-common-addons/nfsv4-compat/scripts/`
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
            └── nfsv4-compat
        └── systemd/
            ├── nfsv4-compat.path
            ├── nfsv4-compat.service
            └── nfsv4-compat.timer
└── ...
```

4. Run `/data/on_boot.d/11-nfsv4-compat.sh` (or reboot)

5. Check that everything is correct:

- `systemctl list-timers nfsv4-compat.timer`
- `systemctl status nfsv4-compat.path nfsv4-compat.service`
