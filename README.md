# *apcupsd-master-slave*
This is a Debian-based Docker container with <code>apcupsd</code> installed. It manages/monitors one or more connected UPS devices and has the ability to gracefully shut down the host computer, and the UPS itself, in the event of a prolonged power outage.  This is done with no customization to the host whatsoever, there's no need for cron jobs on the host, or trigger files and scripts.  Everything is done within the container.

Postfix is also present to support Email and SMS notifications of power events, via Gmail's SMTP service.  A custom version of WoLweb is also supported, which allows you to wake systems shutdown during the power outage, once power is restored.  A possible sequence of events then is that the power goes out, an Email or SMS will be sent to your desired address, one or more slave systems are shutdown, then the master (connected to the UPS) is shutdown, and finally the UPS is turned off. Proxmox nodes can also be shut down gracefully via the PVE API as part of this sequence.

When power is restored the UPS comes back on by itself, the master will power up (most SBCs do this automatically, other systems need to be set for this to happen in the BIOS), and finally Magic Packets will be sent to one or more systems to wake them up.  None of this requires you to be present, and the UPS battery life can be extended by not running it down to zero in an extended outage.

### *Use Cases:*
Use this image if your UPS is connected to your docker host by USB Cable and you don't want to run <code>apcupsd</code> in the physical host OS.

Equally, this container can be run on any other host (SLAVE) to monitor another instance of this container running on a host (MASTER) connected to the UPS for power status messages from the UPS, and take action to gracefully shut down the non-UPS connected host. Shutdowns of systems running Linux, Windows and Proxmox are all possible.

The purpose of this image is to containerize the APC UPS monitoring daemon so that it is separated from the OS, yet still has access to the UPS via USB Cable.  

### *Configuration:*

Minimal configuration is currently required for this image to work, though you may be required to tweak the USB device that is passed through to your container by docker.

Portainer is the recommended tool here, and makes maintaining and updating this container substantially easier -- particularly if you have multiple APC UPS units, and multiple other systems you wish to be shutdown when power is lost.

### *Events log:*

All apcupsd events and container startup messages are written to `/etc/apcupsd/apcupsd.events` inside the container, which maps to `<HOST_DIR>/apcupsd/apcupsd.events` on the host (e.g. `/data/apcupsd/apcupsd.events`). This file persists across container restarts and provides a full history of power events, startup sequences, and shutdown attempts.

Portainer-Logs streams this file in real time -- startup messages appear immediately as the container initialises, followed by live apcupsd events as they occur. The log is capped at `EVENTSFILEMAX` kilobytes (default 10KB, 1024KB recommended), with older entries removed automatically when the limit is reached.

## *apcupsd-master-slave:*

### Here's the minimum docker-compose configuration required, if you want to do some quick testing. The full stack below is recommended though:

```yml
services:
  apcupsd:
    image: bnhf/apcupsd:latest
    container_name: apcupsd
    hostname: ${HOSTNAME} # Set a unique hostname per instance -- used in apcupsd-cgi and email notifications.
    devices:
      - ${APC_USB:-/dev/null} # Set APC_USB to your device path on masters (e.g. /dev/usb/hiddev0). Defaults to /dev/null on slaves.
    ports:
      - 3551:3551
    environment:
      - UPSNAME=${UPSNAME} # Sets a name for the UPS (1 to 8 chars), that will be used by System Tray notifications, apcupsd-cgi and Grafana dashboards.
      - TZ=${TZ}
    volumes:
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket # Required to support host shutdown from the container.
      - ${HOST_DIR:-/data}/apcupsd:/etc/apcupsd # /etc/apcupsd can be bound to a directory or a docker volume.
    restart: unless-stopped
```

### *Complete, annotated, apcupsd-master-slave stack (Portainer-Stacks recommended):*

```yml
services:
  apcupsd: # This docker-compose typically requires no editing. Use the Environment variables section of Portainer to set your values.
    # 2026.06.01
    # GitHub home for this project: https://github.com/bnhf/apcupsd-admin-plus.
    # Docker container home for this project with setup instructions: https://hub.docker.com/r/bnhf/apcupsd.
    image: bnhf/apcupsd:${TAG:-latest} # Add the tag like latest or test to the environment variables below.
    container_name: apcupsd
    hostname: ${HOSTNAME} # Set a unique hostname per instance -- used in apcupsd-cgi and email notifications.
    dns_search: ${DOMAIN:-localdomain} # LAN domain for hostname resolution (e.g. local, localdomain). Optionally append a Tailnet domain space-separated.
    devices:
      - ${APC_USB:-/dev/null} # USB device for the connected UPS. Set APC_USB to your device path on masters (e.g. /dev/usb/hiddev0). Defaults to /dev/null on slaves.
    ports:
      - ${HOST_PORT:-3551}:3551 # Use the standard apcupsd port number of 3551, or optionally change it if it's in use on your Docker host. Default=3551.
    environment:
      - APCUPSD_COMPOSE=2026.06.01 # Do not change this value.
      # ── Identity ────────────────────────────────────────────────────────────
      - UPSNAME=${UPSNAME} # Sets a name for the UPS (1 to 8 chars), that will be used by System Tray notifications, apcupsd-cgi and Grafana dashboards.
      - TZ=${TZ} # Timezone, e.g. America/Denver.
      # ── UPS connectivity ────────────────────────────────────────────────────
      # On slaves set UPSCABLE=ether, UPSTYPE=net, DEVICE=masterhost:3551. No need to modify the devices section.
      - UPSCABLE=${UPSCABLE:-usb} # Cable type: usb, ether, etc. (default=usb).
      - UPSTYPE=${UPSTYPE:-usb} # UPS type: usb, net, etc. (default=usb).
      - DEVICE=${DEVICE} # Leave blank for USB masters. On slaves set to masterhost:3551.
      # ── Shutdown thresholds ─────────────────────────────────────────────────
      - POLLTIME=${POLLTIME:-60} # Interval (in seconds) at which apcupsd polls the UPS for status (default=60).
      - ONBATTERYDELAY=${ONBATTERYDELAY:-6} # Sets the time in seconds from when a power failure is detected until an onbattery event is initiated (default=6).
      - BATTERYLEVEL=${BATTERYLEVEL:-5} # Sets the daemon to send the poweroff signal when the UPS reports a battery level of x% or less (default=5).
      - MINUTES=${MINUTES:-5} # Sets the daemon to send the poweroff signal when the UPS has x minutes or less remaining power (default=5).
      - TIMEOUT=${TIMEOUT:-0} # Sets the daemon to send the poweroff signal when the UPS has been ON battery power for x seconds (default=0).
      - KILLDELAY=${KILLDELAY:-0} # If non-zero, sets the daemon to attempt to turn the UPS off x seconds after sending a shutdown request (default=0).
      # ── Maintenance ──────────────────────────────────────────────────────────
      - BATTDATE=${BATTDATE} # Date of last battery replacement in mm/dd/yy format, e.g. 06/01/26.
      - SELFTEST=${SELFTEST:-336} # UPS self-test interval in hours, e.g. 336 (2 weeks) (default=336).
      - EVENTSFILEMAX=${EVENTSFILEMAX:-10} # Sets the maximum size of the events file in kilobytes. 1024 is recommended. (default=10).
      - UPDATE_SCRIPTS=${UPDATE_SCRIPTS:-true} # Set to true if you'd like all the apcupsd scripts and .conf file to be overwritten with the latest versions (default=true).
      # ── Multi-UPS monitoring ────────────────────────────────────────────────
      - APCUPSD_HOSTS=${APCUPSD_HOSTS} # If this is the MASTER, then enter the APCUPSD_HOSTS list here, including this system (space separated).
      - APCUPSD_NAMES=${APCUPSD_NAMES} # Match the order of this list one-to-one to APCUPSD_HOSTS list, including this system (space separated).
      # ── Email notifications via Gmail SMTP ──────────────────────────────────
      - SMTP_GMAIL=${SMTP_GMAIL} # Gmail account (with 2FA enabled) to use for SMTP.
      - GMAIL_APP_PASSWD=${GMAIL_APP_PASSWD} # App password for apcupsd from Gmail account being used for SMTP.
      - NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL} # The Email account to receive on/off battery messages and other notifications.
      - POWER_RESTORED_EMAIL=${POWER_RESTORED_EMAIL} # Set to true if you'd like an Email notification when power is restored after UPS shutdown.
      # ── Wake-on-LAN via WoLweb ──────────────────────────────────────────────
      - WOLWEB_HOSTNAMES=${WOLWEB_HOSTNAMES} # Space-separated list of hostnames to send WoL Magic Packets to on startup.
      - WOLWEB_PATH_BASE=${WOLWEB_PATH_BASE} # Everything after http:// and before the /hostname required to wake a system with WoLweb e.g. raspberrypi6:8089/wolweb/wake.
      - WOLWEB_DELAY=${WOLWEB_DELAY:-0} # Seconds to delay before sending WoL Magic Packets to WOLWEB_HOSTNAMES (default=0).
      # ── Proxmox shutdown via API ─────────────────────────────────────────────
      - PVE_SHUTDOWN_HOSTS=${PVE_SHUTDOWN_HOSTS} # Ordered list of pve hostnames (or IPs) to be used for API shutdown. Used with matching lists of PVE_SHUTDOWN_NODES and PVE_SHUTDOWN_TOKENS.
      - PVE_SHUTDOWN_NODES=${PVE_SHUTDOWN_NODES} # Ordered list of pve nodes. Used with matching lists of PVE_SHUTDOWN_HOSTS and PVE_SHUTDOWN_TOKENS.
      - PVE_SHUTDOWN_TOKENS=${PVE_SHUTDOWN_TOKENS} # Ordered list of pve API tokens with secrets in the form <username>@<realm>!<tokenid>=<secret>.
    healthcheck:
      test: ["CMD-SHELL", "apcaccess | grep -E 'ONLINE' >> /dev/null"] # Command to check health.
      interval: ${HC_INTERVAL:-30s} # Interval between health checks. Default=30s.
      timeout: ${HC_TIMEOUT:-5s} # Timeout for each health check. Default=5s.
      retries: ${HC_RETRIES:-3} # How many times to retry. Default=3.
      start_period: ${HC_START_PERIOD:-15s} # Estimated time to boot. Default=15s.
    volumes:
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket # Required to support host shutdown from the container.
      - ${HOST_DIR:-/data}/apcupsd:/etc/apcupsd # /etc/apcupsd can be bound to a directory or a docker volume.
    restart: unless-stopped

# If you prefer to use Docker Volumes instead of directory bindings, uncomment below as required.
# volumes: # Use this section for volume bindings only
#   config: # The name of the stack will be appended to the beginning of this volume name, if the volume doesn't already exist
#     external: true # Use this directive if you created the docker volume in advance
```

### *All environment variables:*

The full list of environment variables to paste into the Portainer-Stacks "Environment variables" section. Replace values as needed -- variables with a default in the compose can be omitted if the default is acceptable. Delete those you're not going to use.

```console
TAG=latest
HOSTNAME=myhost_ups
DOMAIN=localdomain
APC_USB=/dev/usb/hiddev0
HOST_PORT=3551
HOST_DIR=/data
UPSNAME=MyUPS
TZ=America/Denver
UPSCABLE=usb
UPSTYPE=usb
DEVICE=
POLLTIME=60
ONBATTERYDELAY=6
BATTERYLEVEL=5
MINUTES=5
TIMEOUT=0
KILLDELAY=0
BATTDATE=01/01/25
SELFTEST=336
EVENTSFILEMAX=1024
UPDATE_SCRIPTS=true
APCUPSD_HOSTS=192.168.1.10 192.168.1.11
APCUPSD_NAMES=Closet Office
SMTP_GMAIL=myaccount@gmail.com
GMAIL_APP_PASSWD=xxxx xxxx xxxx xxxx
NOTIFICATION_EMAIL=alerts@example.com
POWER_RESTORED_EMAIL=true
WOLWEB_HOSTNAMES=server1 server2
WOLWEB_PATH_BASE=raspberrypi6:8089/wolweb/wake
WOLWEB_DELAY=30
PVE_SHUTDOWN_HOSTS=pve1 pve2
PVE_SHUTDOWN_NODES=pve1 pve2
PVE_SHUTDOWN_TOKENS=shutdown@pve!token1=secret1 shutdown@pve!token2=secret2
```

### *Validating connectivity before a real power event:*

Once the container is running, you can verify that the Proxmox API and dbus connections are working without triggering an actual shutdown:

```console
docker exec apcupsd /etc/apcupsd/testshutdown
```

Results are written to both the terminal and `/etc/apcupsd/apcupsd.events`. A passing run looks like:

```console
2026-06-01 10:00:01 -0600  testshutdown: Starting dry-run connectivity checks
2026-06-01 10:00:01 -0600  testshutdown: Testing Proxmox API for node pve1 via 192.168.1.10
2026-06-01 10:00:02 -0600  testshutdown: OK - pve1 reachable at 192.168.1.10, PVE version 8.2.1, token valid
2026-06-01 10:00:02 -0600  testshutdown: Testing dbus connectivity
2026-06-01 10:00:02 -0600  testshutdown: OK - dbus login1 is responding
2026-06-01 10:00:02 -0600  testshutdown: All checks passed
```

If any check fails, the error message will identify whether the problem is with the API token, network reachability, or the dbus socket binding.

This project can be used standalone, although there are also sister containers available for apcupsd-cgi and a near-zero configuration TIG (telegraf-InfluxDB-Grafana) stack available to monitor your UPS units.  A full write-up can be found here https://technologydragonslayer.com/2023/01/31/ultimate-apc-ups-monitoring-with-apcupsd-admin-plus-and-docker/:

## *apcupsd-cgi:*

![screenshot-raspberrypi10-2023 05 07-11_42_01](https://user-images.githubusercontent.com/41088895/236874426-04a9d101-bf9d-4595-ad55-2bdfce434b4c.png)

The docker image is Debian-based, with nginx-light as web server, fcgiwrap as cgi server and obviously apcupsd-cgi.

Apcupsd-cgi is configured to search and connect to the apcupsd daemon on the host machine IP via the standard port 3551. Nginx is configured to connect with fcgiwrap (CGI server) and to serve multimon.cgi directly on port 80. The container exposes port 80, but can be remapped as required -- I use port 3552.

### *Docker-Compose for apcupd-cgi (Portainer-Stacks recommended):*

```yml
services:
  apcupsd-cgi: # This docker-compose typically requires no editing. Use the Environment variables section of Portainer to set your values.
    # 2026.06.01
    image: bnhf/apcupsd-cgi:${TAG:-latest}
    container_name: apcupsd-cgi
    dns_search: ${DNS_SEARCH:-localdomain} # Set to your LAN's domain name (often local or localdomain). Default=localdomain.
    ports:
      - ${HOST_PORT:-3552}:80 # Port to access the apcupsd-cgi web interface. Default=3552.
    environment:
      - UPSHOSTS=${UPSHOSTS} # Ordered list of hostnames or IP addresses of UPS connected computers (space separated, no quotes).
      - UPSNAMES=${UPSNAMES} # Matching ordered list of location names to display on status page (space separated, no quotes).
      - TZ=${TZ} # Timezone to use for status page -- UTC is the default.
    volumes:
      - ${HOST_DIR:-/data}/apcupsd-cgi:/etc/apcupsd
    restart: unless-stopped
```
*Environment variables required for the above (or hardcode values into compose):*

    UPSHOSTS (List of hostnames or IP addresses for computers with connected APC UPSs. Space separated without quotes.)
    UPSNAMES (List of names you'd like used in the WebUI. Order must match UPSHOSTS. Space separated without quotes.)
    TZ (Timezone for apcupsd-cgi to use when displaying information about individual UPS units)

## *TIG stack:*

![screencapture-apcupsd-2023-04-29-14_56_00](https://user-images.githubusercontent.com/41088895/235324008-e1a9cb27-252a-402f-98c2-83243f5b6b4a.png)

## *Wake-on-LAN:*

This customized and updated version of WoLweb, is used for sending the Wake-on-LAN Magic Packets. It has a web interface, which is used to input the hostnames and MAC addresses of Ethernet connected systems you'd like to wake upon power restoration.  It can also be used for general purposes to wake systems via the web interface, or bookmarkable URLs:

![screenshot-raspberrypi4-2023 05 09-08_14_26](https://github.com/bnhf/apcupsd-master-slave/assets/41088895/8c4d7e5a-01d9-40a0-ac12-80da845ae85c)

```yml
services:
  wolweb: # This docker-compose typically requires no editing. Use the Environment variables section of Portainer to set your values.
    # 2026.06.01
    image: bnhf/wolweb:${TAG:-latest}
    container_name: wolweb
    environment:
      - WOLWEBPORT=${WOLWEBPORT:-8089} # The port you'd like WoLweb to use. Default=8089.
      - WOLWEBVDIR=${WOLWEBVDIR:-/wolweb} # The virtual directory for WoLweb to use. Default=/wolweb.
      - WOLWEBBCASTIP=${WOLWEBBCASTIP} # The broadcast IP for your subnet including the port (192.168.0.255:9 or 192.168.1.255:9 are typical).
    volumes:
      - ${HOST_DIR:-/data}/wolweb:/wolweb/data # Bind a directory to /wolweb/data for data persistence.
    network_mode: host # host is the only network mode that supports WoL Magic Packets.
    restart: unless-stopped
```

## *Proxmox API Shutdown:*

The container can gracefully shut down one or more Proxmox nodes via the PVE API before powering off the host. This runs as part of the `doshutdown` event sequence and logs results to `apcupsd.events`.

### *Proxmox API token setup:*

1. In the Proxmox web UI, create a new user in the `pve` realm, e.g. `shutdown@pve`
2. Create a role with only the `Sys.PowerMgmt` privilege and assign it to that user at the datacenter level
3. Create an API token for the user (uncheck "Privilege Separation") and note the token secret

The token format used in `PVE_SHUTDOWN_TOKENS` is: `username@realm!tokenid=secret`

### *Single host and token (multiple nodes):*

If all nodes are accessible through one Proxmox host using one API token, set `PVE_SHUTDOWN_HOSTS` and `PVE_SHUTDOWN_TOKENS` to single values and list all nodes in `PVE_SHUTDOWN_NODES`:

```console
PVE_SHUTDOWN_HOSTS=192.168.1.10
PVE_SHUTDOWN_NODES=pve1 pve2 pve3
PVE_SHUTDOWN_TOKENS=shutdown@pve!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### *Matched lists (one host and token per node):*

If each node requires its own host address and token, all three lists must be the same length and in matching order:

```console
PVE_SHUTDOWN_HOSTS=192.168.1.10 192.168.1.11
PVE_SHUTDOWN_NODES=pve1 pve2
PVE_SHUTDOWN_TOKENS=shutdown@pve!token1=secret1 shutdown@pve!token2=secret2
```

Run `docker exec apcupsd /etc/apcupsd/testshutdown` after deployment to confirm API reachability and token validity before relying on it during a real power event.
