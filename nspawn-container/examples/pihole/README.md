# Pi-Hole

## How to Install Pi-Hole in a Container

This guide assumes you have already created and started an nspawn container as instructed in the [main README](../../README.md), and have configured an isolated macvlan network for your container.

To install Pi-Hole, we run the automated install as instructed in the [Pi-Hole documentation](https://docs.pi-hole.net/main/basic-install/) and follow the prompts.


1. Spawn a shell to your container.

    ```sh
    machinectl shell debian-custom
    ```

2. Run the automated install command from the Pi-Hole documentation and follow the prompts. Refer to the Pi-Hole documentation for more details.

    ```sh
    apt -y install curl
    curl -sSL https://install.pi-hole.net | PIHOLE_SKIP_OS_CHECK=true bash
    ```

    * You must use `PIHOLE_SKIP_OS_CHECK=true` so Pi-Hole can be installed on Debian unstable.
    * After installation, the debian-custom container has a size of 611 MB after running `apt clean` to delete the package cache.

3. When the installer says a static IP is needed, press Continue.
4. Select an upstream DNS provider on the next page, or add your custom DNS provider. Note that all these options can be changed later in the admin panel, so you don't need to be perfect here.
5. On the next page, choose "Yes" to include the default list or "No" to not include any block lists at install (you will have to install your own later in that case).
6. On the next page, choose "Yes" to install the Admin web interface, then "Yes" on the next page to install the default web server that Pi-Hole uses (lighthttpd). It's also possible to use nginx instead of lighthttpd, but this isn't covered in this tutorial.
7. On the next two pages, click Yes to enable Query Logging, and enable "Show everything". You can turn off query logging or hide information from the log if you prefer.
8. Once the install is finished, it will tell you what your Pi-Hole IP and admin password are.
9. You can either use the current admin password the installation gave you, or run `pihole -a -p` to update the password.
10. You should now be able to access the Pi-Hole admin page at https://10.0.5.3/admin if you used the default container IP.
11. As a final step, you need to set "Permit all origins" in the Pi-Hole Admin to allow requests from more than one hop away (i.e., your LAN clients). Go to Pi-Hole Admin -> Settings -> DNS -> Permit all origins -> Save.
12. Now you can set your LAN clients to use the Pi-Hole IP 10.0.5.3 as the DNS, or use dig to test DNS resolution from a client (e.g., `dig @10.0.5.3 google.com A`).

## How to Update or Reconfigure Pi-Hole.

To update Pi-Hole, run the following from within the container.

  ```sh
  PIHOLE_SKIP_OS_CHECK=true pihole -up
  ```

In case there is a configuration error and Pi-Hole is having trouble, you can reconfigure it from scratch by running:


  ```sh
  PIHOLE_SKIP_OS_CHECK=true pihole -r
  ```
