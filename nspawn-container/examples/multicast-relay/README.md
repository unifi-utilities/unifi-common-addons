# Multicast Relay

## Create the filesystem overlay

If you're going to create several nspawn containers, you can save some disk space by using overlayfs to use a common base. Follow the instructions in the unifi-common-addons [documentation](https://github.com/unifi-utilities/unifi-common-addons/blob/main/nspawn-container/README.md) for UniFi OS containers. I called my container `debian-base`.

Next, we need an `upperdir` to save file changes and a `workdir` to save temporary file changes. I'm going to create a container for multicast-relay to replace the [podman container](https://github.com/scyto/multicast-relay) I used before 3.x. An important note: upperdir and workdir must not be on the overlayfs used by UniFi OS. I opted to store this data on the hard drive that I use for video storage at `/volume1`.

So, we have the following directories, which you need to create:

- `/var/lib/machines/multicast-relay`: This will be the root directory of
  our new container.
- `/volume1/machines/multicast-relay/upper`: This stores the differences from
  the base container.
- `/volume1/machines/multicast-relay/work`: This is a temporary directory for
  changes before they're saved to `upper`. This could be on a `tmpfs.`
  mount, but I didn't want to mess with available memory.
- `/data/custom/machines/debian-base`: This is the base container directory
  created by following the README linked above.

Do it:

```shell
mkdir -p /var/lib/machines/multicast-relay /volume1/machines/multicast-relay/{upper,work}
```

Now add the matching entry to your fstab. I'm not 100% sure how permanent this is, but I'll find out when I either reboot or upgrade the firmware.

Append this to `/etc/fstab`

```
overlay /var/lib/machines/multicast-relay overlay noauto,x-systemd.automount,lowerdir=/data/custom/machines/debian-base,upperdir=/volume1/machines/multicast-relay/upper,workdir=/volume1/machines/multicast-relay/work 0 0
```

If everything is good, you can `mount /var/lib/machines/multicast-relay`. If there's any error from that, you have some homework to do. It should automount on reboot, but I haven't tested it by rebooting my UDM Pro yet. We'll see 🤞.

## Configure the container

With your overlay in place, you can start the container and install your stuff.

```
systemd-nspawn -M multicast-relay -D /var/lib/machines/multicast-relay
```

You should now be at a root shell inside the container. I configured this all manually, but you can use the [script](./configure-container.sh) I created during my trial and error to save yourself some time. Minimal Debian doesn't have `curl` or `wget`, so you can install one of them and download the script, or copy and paste it into `vi` or something. This is left as an exercise to the reader.

To escape this container, you'll have to press the cheat code given at the start of your session. (HINT: Press <kbd>Ctrl</kbd> + <kbd>]</kbd> 3 times.)

NOTE: I didn't set the root password, which you will see in many tutorials. It isn't needed. The host can bypass any login prompt using `machinectl shell <container>`. You might want to set a root password and/or other user if you are using the container as a lightweight VM.

## Run the container

If this is your first systemd-nspawn service, you'll need to create the config directory.

```
mkdir -p /etc/systemd/nspawn
```

Now create the container launch configuration in the file indicated. `multicast-relay` requires the ability to open raw sockets, so we grant that capability and strip the rest. Be sure you specify the interfaces you wish to use in the `Environment=` line.

Optionally, you can specify additional `multicast-relay` options in `OPTS`

```
# /etc/systemd/nspawn/multicast-relay.nspawn
[Exec]
Boot=on
Capability=CAP_NET_RAW
ResolvConf=off
Environment=INTERFACES="br0 br50"
Environment=OPTS=

[Network]
Private=off
VirtualEthernet=off
```

Once that file is in place, you're ready to enable the container on boot and run it.

```
machinectl enable multicast-relay
machinectl start multicast-relay
```

## Troubleshooting

You can view the container's stdout in the host journal.

```
journalctl -xe
```

Output from multicast-relay itself won't be found here, though. You _should_ be able to view a container's journal from the host, but I got an error when I tried to access the Debian container's journal, suggesting it uses a newer journal format than the UniFi OS host.

No matter, you can enter the container and get a root shell (no login required).

```
machinectl shell multicast-relay
```

Now, we're setting the interface and options via environment variables set on the host. If you want to double-check that it's working correctly, check the systemd environment from within the container.

```
cat /proc/1/environ | tr '\0' '\n'
```

output:

```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
container=systemd-nspawn
HOME=/root
USER=root
LOGNAME=root
container_uuid=c05b41ce-0995-412d-bd2d-338759b24e54
NOTIFY_SOCKET=/run/host/notify
container_host_version_id=11
container_host_id=debian
INTERFACES=br0 br50
```

You could use the same command to view our service's environment. In this case, we can use the PID of `dash`, the shell script interpreter from `start.sh`.

```
root@DreamMachinePro:~# cat /proc/$(pidof dash)/environ | tr '\0' '\n'
LANG=C.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
INVOCATION_ID=d1cfaf43a00b4e79bcddca6a1595837c
JOURNAL_STREAM=8:51317778
SYSTEMD_EXEC_PID=47
INTERFACES=br0 br50
```
