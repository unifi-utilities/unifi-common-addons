# unifi-common-addons

A collection of addons to enhance the capabilities of your UniFi products.

## Requirements

### on_boot.d

Do this first. Enables init.d style scripts to run on every boot. This is required for all addons below.

<https://github.com/unifi-utilities/unifi-common>

## Addons

### att-ipv6

Enables receiving up to 8 Prefix Delegations on AT&T connections.

### att-static-ips

Enables emulation of a Cascaded Router setup and allows full use of your CIDR on AT&T connections.

### nspawn-container

Enables Containers - replacing Podman.

### persist-changes

Persist changes to your device's configurations and prevent them from being overwritten by UniFi.

### tailscale-unifi

Miscellaneous scripts to help with Tailscale and UniFi integration from [tailscale-unifi by @SierraSoftworks](https://github.com/SierraSoftworks/tailscale-unifi)

## Missing something?

We have moved the old addons to a new repository to make it easier to maintain and add new addons. If you have an addon that you would like to see added, please open an issue or submit a pull request.

<https://github.com/unifi-utilities/unifios-utilities-archived>
