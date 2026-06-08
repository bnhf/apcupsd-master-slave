#!/bin/bash
# start.sh
# 2026.06.01

EVENTS_FILE=/etc/apcupsd/apcupsd.events
LATEST_COMPOSE=2026.06.01

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
files=( apcupsd.conf hosts.conf doshutdown apccontrol changeme commfailure commok killpower multimon.conf offbattery onbattery ups-monitor testshutdown testemail )

for i in "${files[@]}"
  do
    if [ ! -f /etc/apcupsd/$i ] || [[ $UPDATE_SCRIPTS == "true" ]]; then
      cp /opt/apcupsd/$i /etc/apcupsd/$i \
      && log_event "start.sh: Copied $i (new or UPDATE_SCRIPTS=true)"
    else
      log_event "start.sh: Using existing $i"
    fi
  done

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

# keep container alive and surface events log via docker logs
exec tail -n 0 -f $EVENTS_FILE
