#!/bin/bash
# start.sh
# 2026.10.22

EVENTS_FILE=/etc/apcupsd/apcupsd.events
MARKER_FILE=/etc/apcupsd/shutdown-marker
LATEST_COMPOSE=2026.10.21

log_event() {
  echo "$(date '+%Y-%m-%d %H:%M:%S %z')  $1" | tee -a $EVENTS_FILE
}

# Ensure events file exists before any logging
touch $EVENTS_FILE

log_event "start.sh: Container starting"

# Config file moves transferred from Dockerfile to support
# binding /etc/apcupsd to user-specified host directory
cp /opt/apcupsd/apcupsd /etc/default/apcupsd

# Check if /etc/apcupsd files exist, and copy them from /opt/apcupsd if they don't
files=( apcupsd.conf hosts.conf doshutdown apccontrol changeme commfailure commok killpower multimon.conf offbattery onbattery ups-monitor testshutdown testemail power-restore-delay.service power-restore-wait.service power-shutdown-marker.service install-power-restore )

for i in "${files[@]}"
  do
    if [ ! -f /etc/apcupsd/$i ] || [[ $UPDATE_SCRIPTS == "true" ]]; then
      cp /opt/apcupsd/$i /etc/apcupsd/$i \
      && log_event "start.sh: Copied $i (new or UPDATE_SCRIPTS=true)"
    else
      log_event "start.sh: Using existing $i"
    fi
  done

chmod +x /etc/apcupsd/install-power-restore

# Read one property of a host systemd unit over dbus, as dbus-send prints it (empty if the bus isn't reachable)
unitPropertyRaw() {
  local unitPath=$(printf '%s' "$1" | sed 's/-/_2d/g; s/\./_2e/g')
  dbus-send --system --print-reply=literal --dest=org.freedesktop.systemd1 \
    "/org/freedesktop/systemd1/unit/$unitPath" \
    org.freedesktop.DBus.Properties.Get "string:org.freedesktop.systemd1.$2" "string:$3" 2>/dev/null
}

# Read one simple (string, number or boolean) property of a host systemd unit
unitProperty() {
  unitPropertyRaw "$@" | awk '{ print $NF }'
}

# Log whether the host's power-restore units are installed, and the settings in the installed copies
logRestoreUnitSettings() {
  local unit name loadState delay timeout paths
  for unit in power-restore-delay.service power-restore-wait.service; do
    name=${unit%.service}
    loadState=$(unitProperty "$unit" Unit LoadState)
    if [ -z "$loadState" ]; then
      log_event "start.sh: Unable to query host systemd via dbus -- power-restore unit status unavailable"
      return
    fi
    if [ "$loadState" != "loaded" ]; then
      log_event "start.sh: $name: not installed (optional, not needed for UPS shutdown) -- see README (Power Restore Delay and Wait)"
      continue
    fi
    if [ "$(unitProperty "$unit" Unit UnitFileState)" != "enabled" ]; then
      log_event "start.sh: $name: installed but not enabled -- run: sudo systemctl enable $unit"
      continue
    fi

    # The delay/limit is the first number in the ExecStart command line (sleep 60, timeout 120)
    delay=$(unitPropertyRaw "$unit" Service ExecStart | awk '
      /array \[/ { arrays++ }
      arrays >= 2 { for (i = 1; i <= NF; i++) { if ($i == "]") exit; if ($i ~ /^[0-9]+[smhd]?$/) { print $i; exit } } }')
    [[ $delay =~ ^[0-9]+$ ]] && delay="${delay}s"
    timeout=$(unitProperty "$unit" Service TimeoutStartUSec)
    [[ $timeout =~ ^[0-9]{1,15}$ ]] && timeout="$((timeout / 1000000))s" || timeout="none"
    paths=$(unitPropertyRaw "$unit" Unit Conditions | awk '
      { for (i = 1; i <= NF; i++) tok[++n] = $i }
      END { for (i = 1; i <= n; i++) if (tok[i] == "ConditionPathExists") printf "%s%s", (found++ ? " or " : ""), tok[i + 5] }')

    if [ "$name" == "power-restore-delay" ]; then
      log_event "start.sh: $name: enabled -- boot delay ${delay:-unknown} (start timeout $timeout), runs if ${paths:-(no path condition)} exists"
    else
      log_event "start.sh: $name: enabled -- Docker wait up to ${delay:-unknown} (start timeout $timeout), runs if ${paths:-(no path condition)} exists"
    fi
    if [ "$(unitProperty "$unit" Service RemainAfterExit)" != "true" ]; then
      log_event "start.sh: $name: RemainAfterExit not set -- results can't be logged; copy the current unit from /etc/apcupsd"
    fi
  done
}

# Log what the host's power-restore-delay and power-restore-wait units did during this boot
logRestoreUnits() {
  local unit name started finished status secs
  for unit in power-restore-delay.service power-restore-wait.service; do
    name=${unit%.service}
    # Not installed, not enabled or no dbus -- already reported by logRestoreUnitSettings
    [ "$(unitProperty "$unit" Unit LoadState)" == "loaded" ] || continue
    [ "$(unitProperty "$unit" Unit UnitFileState)" == "enabled" ] || continue
    if [ "$(unitProperty "$unit" Unit ConditionTimestampMonotonic)" == "0" ]; then
      log_event "start.sh: $name: didn't run this boot (enabled after boot?)"
      continue
    fi
    if [ "$(unitProperty "$unit" Unit ConditionResult)" != "true" ]; then
      log_event "start.sh: $name: skipped this boot -- check its ConditionPathExists matches the host path of powerfail"
      continue
    fi
    started=$(unitProperty "$unit" Service ExecMainStartTimestampMonotonic)
    finished=$(unitProperty "$unit" Service ExecMainExitTimestampMonotonic)
    status=$(unitProperty "$unit" Service ExecMainStatus)
    if [[ ! $started =~ ^[0-9]+$ ]] || [[ ! $finished =~ ^[0-9]+$ ]] || (( finished < started )); then
      log_event "start.sh: $name: ran this boot, duration unavailable"
      continue
    fi
    secs=$(( (finished - started) / 1000000 ))
    if [ "$name" == "power-restore-delay" ]; then
      log_event "start.sh: $name: held boot for ${secs}s"
    elif [ "$status" == "124" ]; then
      log_event "start.sh: $name: timed out after ${secs}s -- DNS or clock still not ready"
    else
      log_event "start.sh: $name: held Docker for ${secs}s -- DNS and clock ready"
    fi
  done
}

# Log whether the host's shutdown marker unit is installed (no dbus message -- logRestoreUnitSettings reports that)
logMarkerUnitSetting() {
  local loadState=$(unitProperty power-shutdown-marker.service Unit LoadState)
  [ -z "$loadState" ] && return
  if [ "$loadState" != "loaded" ]; then
    log_event "start.sh: power-shutdown-marker: not installed (optional, not needed for UPS shutdown) -- see README (Power Restore Delay and Wait)"
  elif [ "$(unitProperty power-shutdown-marker.service Unit UnitFileState)" != "enabled" ]; then
    log_event "start.sh: power-shutdown-marker: installed but not enabled -- run: sudo systemctl enable power-shutdown-marker.service"
  elif [ "$(unitProperty power-shutdown-marker.service Unit ActiveState)" != "active" ]; then
    log_event "start.sh: power-shutdown-marker: enabled but not running, so it won't record a shutdown -- run: sudo systemctl start power-shutdown-marker.service"
  else
    log_event "start.sh: power-shutdown-marker: enabled -- records when a power-failure shutdown gets past Docker"
  fi
}

# Log whether the last power-failure shutdown got past Docker before the UPS cut power
logShutdownMarker() {
  if [ -f $MARKER_FILE ]; then
    log_event "start.sh: power-shutdown-marker: host got past Docker at $(cat $MARKER_FILE) -- shutdown reached its final stage"
  elif [ "$(unitProperty power-shutdown-marker.service Unit UnitFileState)" == "enabled" ]; then
    log_event "start.sh: WARNING -- power-shutdown-marker: no marker from the power-failure shutdown -- the UPS cut power before the host finished stopping Docker, or the unit wasn't running then (installed without a reboot or start)"
  fi
}

logRestoreUnitSettings
logMarkerUnitSetting

# First, if not previously done, add an extra # to the second UPSNAME used for EPROM updates
sed -i 's/^#UPSNAME UPS_IDEN/##UPSNAME UPS_IDEN/' /etc/apcupsd/apcupsd.conf

# Second, if not previously done, change EVENTSFILE location to /etc/apcupsd for ease of viewing
sed -i 's|^EVENTSFILE /var/log/apcupsd.events|EVENTSFILE /etc/apcupsd/apcupsd.events|' /etc/apcupsd/apcupsd.conf

# Check if environment variables are set, and if so update apcupsd.conf
settings=( "UPSNAME" "UPSCABLE" "UPSTYPE" "DEVICE" "POLLTIME" "ONBATTERYDELAY" "BATTERYLEVEL" "MINUTES" "TIMEOUT" "KILLDELAY" "NETSERVER" "NISIP" "NISPORT" "BATTDATE" "SELFTEST" "EVENTSFILEMAX" )

for i in ${settings[@]}
  do
    if [ ! -z ${!i} ]; then
      sed -i -r 's@(^'"$i"'.*|^#'"$i"'.*)@'"$i"' '"${!i}"'@' /etc/apcupsd/apcupsd.conf \
      && log_event "start.sh: Set $i = ${!i}"
    fi
  done

# if $APCUPSD_HOSTS exists then delete existing hosts.conf, and recreate with specified values
if [ ! -z "$APCUPSD_HOSTS" ]; then
  rm /etc/apcupsd/hosts.conf \
  && touch /etc/apcupsd/hosts.conf
fi

# populate two arrays with host and UPS names
HOSTS=( $APCUPSD_HOSTS )
NAMES=( $APCUPSD_NAMES )

# add monitors to hosts.conf for each host and UPS name combo
for ((i=0;i<${#HOSTS[@]};i++))
  do
    if [ ! -z $i ]; then
      echo "MONITOR ${HOSTS[$i]} \"${NAMES[$i]}\"" >> /etc/apcupsd/hosts.conf \
      && log_event "start.sh: Added MONITOR ${HOSTS[$i]} \"${NAMES[$i]}\""
    fi
  done

# create sasl_passwd and hash it
if [ ! -z $SMTP_GMAIL ]; then
  echo "smtp.gmail.com $SMTP_GMAIL:$GMAIL_APP_PASSWD" > /etc/postfix/sasl_passwd
  postmap hash:/etc/postfix/sasl_passwd
fi

# change notifications to external email address
notifications=( changeme offbattery onbattery doshutdown )

for i in "${notifications[@]}"
  do
    if [ ! -z $NOTIFICATION_EMAIL ]; then
      sed -i 's|$SYSADMIN|'"$NOTIFICATION_EMAIL"'|' /etc/apcupsd/$i
    fi
  done

if [ ! -z $NOTIFICATION_EMAIL ]; then
  log_event "start.sh: Notification email set to $NOTIFICATION_EMAIL"
fi

# systems to wake using WoLweb on startup (with delay in seconds)
wolweb_wakeup=( $WOLWEB_HOSTNAMES )

for i in "${wolweb_wakeup[@]}"
  do
    if [ ! -z $WOLWEB_HOSTNAMES ]; then
      ( sleep $WOLWEB_DELAY ; response=$(curl -s http://$WOLWEB_PATH_BASE/$i) ; log_event "start.sh: WoLweb wake $i: $response" ) &
    fi
  done

# systems to wake using UpSnap on startup (with delay in seconds)
upsnap_wakeup=( $UPSNAP_IDS )

for i in "${upsnap_wakeup[@]}"
  do
    if [ ! -z $UPSNAP_IDS ]; then
      (
        token=$(curl -s -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' \
          --data '{"identity":'"$UPSNAP_USERNAME"',"password":'"$UPSNAP_PASSWD"',"rememberMe":false}' \
          http://$UPSNAP_PATH_BASE/api/admins/auth-with-password | jq -r '.token')
        response=$(curl -H 'Accept: application/json' -H "Authorization: Bearer $token" \
          http://$UPSNAP_PATH_BASE/api/upsnap/wake/:$i)
        log_event "start.sh: UpSnap wake $i: $response"
      ) &
    fi
  done

# start Postfix mail service
log_event "start.sh: Starting Postfix SMTP Mail Server"
if service postfix start > /dev/null 2>&1; then
  log_event "start.sh: Postfix started successfully"
else
  log_event "start.sh: ERROR - Postfix failed to start (exit $?)"
fi

# capture power failure state before prestart removes the flag
POWER_FAILURE_RESTART=false
[ -f /etc/apcupsd/powerfail ] && POWER_FAILURE_RESTART=true
[ "$POWER_FAILURE_RESTART" == "true" ] && logRestoreUnits
[ "$POWER_FAILURE_RESTART" == "true" ] && logShutdownMarker
rm -f $MARKER_FILE

# send notification email on startup after power failure based shutdown
if [ "$POWER_FAILURE_RESTART" == "true" ] && [[ $POWER_RESTORED_EMAIL == "true" ]]; then
  export APCUPSD_MAIL="mail"
  ( sleep 10 ; /etc/apcupsd/offbattery $UPSNAME ) &
  log_event "start.sh: Power restored -- notification email scheduled"
fi

# remove any existing powerfail flag
log_event "start.sh: Removing powerfail flag if present"
/lib/apcupsd/prestart

# start apcupsd daemon
log_event "start.sh: Starting apcupsd daemon"
/sbin/apcupsd
log_event "start.sh: apcupsd started -- tailing events"

# auto-validate dbus and Proxmox connectivity on normal startup (skipped after power failure restarts)
if [ "$POWER_FAILURE_RESTART" != "true" ]; then
  log_event "start.sh: Running connectivity check"
  /etc/apcupsd/testshutdown
fi

# confirm compose version or warn if stale
if [ "${APCUPSD_COMPOSE}" == "$LATEST_COMPOSE" ]; then
  log_event "start.sh: Docker Compose version $APCUPSD_COMPOSE confirmed as up to date"
else
  log_event "start.sh: WARNING -- Docker Compose version '${APCUPSD_COMPOSE:-unset}' does not match latest ($LATEST_COMPOSE) -- please update your compose file"
fi
log_event "start.sh: Currently running bnhf/apcupsd version $APCUPSD_VERSION"

# On a power-failure shutdown, turn the UPS off when Docker stops the container -- unless this is a slave.
# This is done whatever KILLDELAY is: the daemon dies with this script, so it can't be relied on to do it.
onStop() {
  local upsType output status
  if [ -f /etc/apcupsd/powerfail ]; then
    upsType=$(awk '$1 == "UPSTYPE" { print $2 }' /etc/apcupsd/apcupsd.conf)
    if [ "$upsType" == "net" ]; then
      log_event "start.sh: Power-failure shutdown -- slave, leaving UPS power-off to the master"
    else
      log_event "start.sh: Power-failure shutdown -- stopping apcupsd daemon and sending killpower to the UPS"
      pkill -x apcupsd
      for i in {1..6}; do pgrep -x apcupsd > /dev/null || break; sleep 0.5; done
      # killpower and the next start both need the flag
      touch /etc/apcupsd/powerfail
      output=$(/sbin/apcupsd --killpower 2>&1)
      status=$?
      log_event "start.sh: apcupsd --killpower finished (exit $status)${output:+: $(echo $output)}"
    fi
  fi
  kill $tailPid 2> /dev/null
  exit 0
}

# keep container alive and surface events log via docker logs, until Docker stops the container
tail -n 0 -f $EVENTS_FILE &
tailPid=$!
trap onStop TERM INT
wait $tailPid
