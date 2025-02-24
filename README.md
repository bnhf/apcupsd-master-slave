# *apcupsd-master-slave*
This is an Ubuntu-based Docker container with <code>apcupsd</code> installed. It manages/monitors one or more connected UPS devices and has the ability to gracefully shut down the host computer, and the UPS itself, in the event of a prolonged power outage.  This is done with no customization to the host whatsoever, there's no need for cron jobs on the host, or trigger files and scripts.  Everything is done within the container.

Postfix is also present to support Email and SMS notifications of power events, via Gmail's SMTP service.  A custom version of WoLweb is also supported, which allows you to wake systems shutdown during the power outage, once power is restored.  A possible sequence of events then is that the power goes out, an Email or SMS will be sent to your desired address, one or more slave systems are shutdown, then the master (connected to the UPS) is shutdown, and finally the UPS is turned off.

When power is restored the UPS comes back on by itself, the master will power up (most SBCs do this automatically, other systems need to be set for this to happen in the BIOS), and finally Magic Packets will be sent to one or more systems to wake them up.  None of this requires you to be present, and the UPS battery life can be extended by not running it down to zero in an extended outage.

### *Use Cases:*
Use this image if your UPS is connected to your docker host by USB Cable and you don't want to run <code>apcupsd</code> in the physical host OS.

Equally, this container can be run on any other host (SLAVE) to monitor another instance of this container running on a host (MASTER) connected to the UPS for power status messages from the UPS, and take action to gracefully shut down the non-UPS connected host. Shutdowns of systems running Linux, Windows and Proxmox are all possible.

The purpose of this image is to containerize the APC UPS monitoring daemon so that it is separated from the OS, yet still has access to the UPS via USB Cable.  

### *Configuration:*

Minimal configuration is currently required for this image to work, though you may be required to tweak the USB device that is passed through to your container by docker.

Portainer is the recommended tool here, and makes maintaining and updating this container substantially easier -- particularly if you have multiple APC UPS units, and multiple other systems you wish to be shutdown when power is lost.

## *apcupsd-master-slave:*

### Here's the minimum docker-compose configuration required, if you want to do some quick testing. The full stack below is recommended though:

```yml
version: '3.7'
services:
  apcupsd:
    image: bnhf/apcupsd:latest
    container_name: apcupsd
    hostname: apcupsd_ups # Use a unique hostname here for each apcupsd instance, and it'll be used instead of the container number in apcupsd-cgi and e-mail notifications. 
    devices:
      - /dev/usb/hiddev0 # This device needs to match what the APC UPS on your APCUPSD_MASTER system uses -- Comment out this section on APCUPSD_SLAVES
    ports:
      - 3551:3551
    environment:
      - UPSNAME=${UPSNAME} # Sets a name for the UPS (1 to 8 chars), that will be used by System Tray notifications, apcupsd-cgi and Grafana dashboards
    volumes:
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket # Required to support host shutdown from the container
      - /data/apcupsd:/etc/apcupsd # /etc/apcupsd can be bound to a directory or a docker volume
```

### *Complete, annotated, apcupsd-master-slave stack (Portainer-Stacks recommended):*

```yml
version: '3.7'
services:
  apcupsd:
    image: bnhf/apcupsd:latest
    container_name: apcupsd
    hostname: apcupsd_ups # Use a unique hostname here for each apcupsd instance, and it'll be used instead of the container number in apcupsd-cgi and Email notifications.
    devices:
      - /dev/usb/hiddev0 # This device needs to match what the APC UPS on your APCUPSD_MASTER system uses -- Comment out this section on APCUPSD_SLAVES
    ports:
      - 3551:3551
    environment:
      - UPSNAME=${UPSNAME} # Sets a name for the UPS (1 to 8 chars), that will be used by System Tray notifications, apcupsd-cgi and Grafana dashboards
      
      # Environment variables for connectivity other than USB, including for slaves that aren't directly connected to a UPS:
#      - UPSCABLE=${UPSCABLE} # Usually doesn't need to be changed on system connected to UPS. (default=usb) On APCUPSD_SLAVES set the value to ether
#      - UPSTYPE=${UPSTYPE} # Usually doesn't need to be changed on system connected to UPS. (default=usb) On APCUPSD_SLAVES set the value to net
#      - DEVICE=${DEVICE} # Use this only on APCUPSD_SLAVES to set the hostname or IP address of the APCUPSD_MASTER with the listening port (:3551)

      # Environment variables for monitoring and shutdown of UPS connected device(s), and the shutdown of the UPS itself:
#      - POLLTIME=${POLLTIME} # Interval (in seconds) at which apcupsd polls the UPS for status (default=60)
#      - ONBATTERYDELAY=${ONBATTERYDELAY} # Sets the time in seconds from when a power failure is detected until an onbattery event is initiated (default=6)
#      - BATTERYLEVEL=${BATTERYLEVEL} # Sets the daemon to send the poweroff signal when the UPS reports a battery level of x% or less (default=5)
#      - MINUTES=${MINUTES} # Sets the daemon to send the poweroff signal when the UPS has x minutes or less remaining power (default=5)
#      - TIMEOUT=${TIMEOUT} # Sets the daemon to send the poweroff signal when the UPS has been ON battery power for x seconds (default=0)
#      - KILLDELAY=${KILLDELAY} # If non-zero, sets the daemon to attempt to turn the UPS off x seconds after sending a shutdown request (default=0)

      # Environment variable for conducting a UPS selftest at a timed interval:
#      - SELFTEST=${SELFTEST} # Sets the daemon to ask the UPS to perform a self test every x hours (default=336)

      # Use these two environment variables to list the slaves that will be connected to this master:
#      - APCUPSD_HOSTS=${APCUPSD_HOSTS} # If this is the MASTER, then enter the APUPSD_HOSTS list here, including this system (space separated)
#      - APCUPSD_NAMES=${APCUPSD_NAMES} # Match the order of this list one-to-one to APCUPSD_HOSTS list, including this system (space separated)

      # Environment variable for setting your local timezone in lieu of UTC:
      - TZ=${TZ}
      
      # Environment variable to update apcupsd scripts and .conf even if a persistent host data directory is being bound to the container.
      # Normally scripts are not overwritten once saved in you bound directory. They are updated occasionally though, so don't let then get out-of-date.
      # You can leave this as true if you've done no manual editing of the scripts
      - UPDATE_SCRIPTS=${UPDATE_SCRIPTS} # Set to true if you'd like all the apcupsd scripts and .conf file to be overwritten with the latest versions
      
      # Environment variables to recieve notifications via Gmail SMTP Email or SMS related to power failure events or urgent UPS maintenance
      # No need to use your personal Gmail account for SMTP. Setup a new one along with 2FA and an "app password" for Proxmox.
      # You can still send notifications to your personal account if you like, or to SMS via carrier's Email to SMS gateway.
      - SMTP_GMAIL=${SMTP_GMAIL} # Gmail account (with 2FA enabled) to use for SMTP
      - GMAIL_APP_PASSWD=${GMAIL_APP_PASSWD} # App password for apcupsd from Gmail account being used for SMTP
      - NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL} # The Email account to receive on/off battery messages and other notifications (Any valid Email will work)
      - POWER_RESTORED_EMAIL=${POWER_RESTORED_EMAIL} # Set to true if you'd like an Email notification when power is restored after UPS shutdown
      
      # Environment variables related to waking sytems after being shutdown during a power failure event. Requires configured bnhf/wolweb container:
      - WOLWEB_HOSTNAMES=${WOLWEB_HOSTNAMES} # Space seperated list of hostnames names to send WoL Magic Packet to on startup
      - WOLWEB_PATH_BASE=${WOLWEB_PATH_BASE} # Everything after http:// and before the /hostname required to wake a system with WoLweb e.g. raspberrypi6:8089/wolweb/wake
      - WOLWEB_DELAY=${WOLWEB_DELAY} # Value to use for "sleep" delay before sending a WoL Magic Packet to WOLWEB_HOSTNAMES in seconds
      
      # Environment variables related to shutting down one or more Proxmox nodes. All VMs and CTs must be shutdown first -- which can be done by setting them up as apcupsd slaves.
      # Create a "shutdwon" pve realm user with "shutdown" role of Sys.PowerMgmt only. Then create API token for that user.
      # You can either list a matching number hosts, nodes and tokens below -- or if it can all be done through the same host and token list those along with multiple nodes:
      - PVE_SHUTDOWN_HOSTS=${PVE_SHUTDOWN_HOSTS} # Ordered list of pve hostnames (or IPs) to be used for API shutdown. Used with matching lists of $PVE_SHUTDOWN_NODES and $PVE_SHUTDOWN_TOKENS
      - PVE_SHUTDOWN_NODES=${PVE_SHUTDOWN_NODES} # Ordered list of pve nodes. Used with matching lists of $PVE_SHUTDOWN_HOSTS and $PVE_SHUTDOWN_TOKENS
      - PVE_SHUTDOWN_TOKENS=${PVE_SHUTDOWN_TOKENS} # Ordered list of pve API tokens with secrets in the form <username>@<node>!<api_token>=<api_secret>
    
    # Healthcheck option that'll show if the UPS is ONLINE and communicating with apcupsd in Portainer (recommended):
    healthcheck:
      test: ["CMD-SHELL", "apcaccess | grep -E 'ONLINE' >> /dev/null"] # Command to check health
      interval: 30s # Interval between health checks
      timeout: 5s # Timeout for each health check
      retries: 3 # How many times to retry
      start_period: 15s # Estimated time to boot
      
    # The system_bus_socket binding is always required for host computer shutdowns. The data directory can be a basic binding as shown, or use a Docker Volume if preferred.
    volumes:
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket # Required to support host shutdown from the container
      - /data/apcupsd:/etc/apcupsd # /etc/apcupsd can be bound to a directory or a docker volume
    restart: unless-stopped
    
# If you prefer to use Docker Volumes instead of directory bindings, uncomment below as required.
# volumes: # Use this section for volume bindings only
#   config: # The name of the stack will be appended to the beginning of this volume name, if the volume doesn't already exist
#     external: true # Use this directive if you created the docker volume in advance
```

### *All environment variables:*

The full list of environment variables that can be pasted into the Portainer-Stacks "Advanced" environment variables section. Replace the ${} part with your values.
Delete those that you're not going to use:

```console
UPSNAME=${UPSNAME}
UPSCABLE=${UPSCABLE}
UPSTYPE=${UPSTYPE}
DEVICE=${DEVICE}
POLLTIME=${POLLTIME} 
ONBATTERYDELAY=${ONBATTERYDELAY}
BATTERYLEVEL=${BATTERYLEVEL}
MINUTES=${MINUTES}
TIMEOUT=${TIMEOUT}
KILLDELAY=${KILLDELAY}
SELFTEST=${SELFTEST} 
APCUPSD_HOSTS=${APCUPSD_HOSTS}
APCUPSD_NAMES=${APCUPSD_NAMES}
TZ=${TZ}
UPDATE_SCRIPTS=${UPDATE_SCRIPTS}
SMTP_GMAIL=${SMTP_GMAIL}
GMAIL_APP_PASSWD=${GMAIL_APP_PASSWD}
NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL}
POWER_RESTORED_EMAIL=${POWER_RESTORED_EMAIL}
WOLWEB_HOSTNAMES=${WOLWEB_HOSTNAMES}
WOLWEB_PATH_BASE=${WOLWEB_PATH_BASE}
WOLWEB_DELAY=${WOLWEB_DELAY}
PVE_SHUTDOWN_HOSTS=${PVE_SHUTDOWN_HOSTS}
PVE_SHUTDOWN_NODES=${PVE_SHUTDOWN_NODES}
PVE_SHUTDOWN_TOKENS=${PVE_SHUTDOWN_TOKENS}
```

This project can be used standalone, although there are also sister containers available for apcupsd-cgi and a near-zero configuration TIG (telegraf-InfluxDB-Grafana) stack available to monitor your UPS units.  A full write-up can be found here https://technologydragonslayer.com/2023/01/31/ultimate-apc-ups-monitoring-with-apcupsd-admin-plus-and-docker/:

## *apcupsd-cgi:*

![screenshot-raspberrypi10-2023 05 07-11_42_01](https://user-images.githubusercontent.com/41088895/236874426-04a9d101-bf9d-4595-ad55-2bdfce434b4c.png)

The docker image is Debian 11 (Bullseye) based, with nginx-light as web server, fcgiwrap as cgi server and obviously apcupsd-cgi. 

Apcupsd-cgi is configured to search and connect to the apcupsd daemon on the host machine IP via the standard port 3551. Nginx is configured to connect with fcgiwrap (CGI server) and to serve multimon.cgi directly on port 80. The container exposes port 80, but can be remapped as required -- I use port 3552.

### *Docker-Compose for apcupd-cgi (Portainer-Stacks recommended):*

```yml
version: '3.7'
services:
  apcupsd-cgi:
    image: bnhf/apcupsd-cgi:latest
    container_name: apcupsd-cgi
    dns_search: localdomain # Set to your LAN's domain name (often local or localdomain), this should help with local DNS resolution of hostnames
    ports:
      - 3552:80
    environment:
      - UPSHOSTS=${UPSHOSTS} # Ordered list of hostnames or IP addresses of UPS connected computers (space separated, no quotes)
      - UPSNAMES=${UPSNAMES} # Matching ordered list of location names to display on status page (space separated, no quotes)
      - TZ=${TZ} # Timezone to use for status page -- UTC is the default
    volumes:
      - /data/apcupsd-cgi:/etc/apcupsd
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
version: '3.7'
services:  
  wolweb:
    image: bnhf/wolweb:latest
    container_name: wolweb  
    environment:
      - WOLWEBPORT=${WOLWEBPORT} # The port you'd like WoLweb to use (8089 recommended)
      - WOLWEBVDIR=${WOLWEBVDIR} # The virtual directory for WoLweb to use (/wolweb recommended)
      - WOLWEBBCASTIP=${WOLWEBBCASTIP} # The broadcast IP for your subnet including the port (192.168.0.255:9 or 192.168.1.255:9 are typical)
    volumes:
      - /data/wolweb:/wolweb/data # Bind a directory to /wolweb/data for data persistence
    network_mode: host # host is the only network mode that supports WoL Magic Packets
    restart: unless-stopped
```
