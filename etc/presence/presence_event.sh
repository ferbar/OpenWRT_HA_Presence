#!/bin/sh
set -eu

# This script is invoked by hostapd_cli -a as:
#   presence_event.sh <iface> <event> <mac> [extra...]

CONF="/etc/presence/presence.conf"
MQTT_CONF="/etc/presence/presence_mqtt.conf"
DEV_CONF="/etc/presence/presence_devices.conf"

HOST_ID="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo openwrt)"

[ -f "$CONF" ] || exit 0
[ -f "$MQTT_CONF" ] || exit 0
[ -f "$DEV_CONF" ] || exit 0

# shellcheck disable=SC1090
. "$CONF"
# shellcheck disable=SC1090
. "$MQTT_CONF"
PUB="mosquitto_pub -h $BROKER $AUTH -q 1"

LOGTAG="presence_event"
log() {
  [ "${DEBUG:-0}" -eq 1 ] || return 0
  logger -t "$LOGTAG" "$*"
}

devices() {
  awk '/^[[:space:]]*#/ { next } NF>=2 { print tolower($1), $2 }' "$DEV_CONF"
}

is_known() {
  devices | awk -v m="$1" '$1 == tolower(m) { f=1 } END { exit !f }'
}

mac_id()   { echo "$1" | tr 'A-Z:' 'a-z-'; }            # b8-f4-a4-...
mac_up()   { echo "$1" | tr 'a-z' 'A-Z'; }              # B8:F4:A4:...
mac_flat() { echo "$1" | tr -d ':' | tr 'A-Z' 'a-z'; }  # b8f4a4...

publish() {   # $1=mac  $2=connected|not_connected
  log "publish topic='$TOPIC_PREFIX/station/$HOST_ID/$(mac_id "$1")/state' payload='$2'"
  $PUB -r -t "$TOPIC_PREFIX/station/$HOST_ID/$(mac_id "$1")/state" -m "$2"
}

discovery() {
  mac="$1"; name="$2"
  log "discover device $mac"
  id=$(mac_id "$mac"); flat=$(mac_flat "$mac"); up=$(mac_up "$mac")
  $PUB -r \
    -t "homeassistant/device_tracker/$HOST_ID/$id/config" \
    -m "{
\"name\":\"$name $HOST_ID\",
\"unique_id\":\"wifipresence_${flat}_$HOST_ID\",
\"default_entity_id\":\"device_tracker.${flat}_$HOST_ID\",
\"source_type\":\"router\",
\"state_topic\":\"$TOPIC_PREFIX/station/$HOST_ID/$id/state\",
\"payload_home\":\"connected\",
\"payload_not_home\":\"not_connected\",
\"availability_topic\":\"$TOPIC_PREFIX/$HOST_ID/status\",
\"payload_available\":\"online\",
\"payload_not_available\":\"offline\",
\"device\":{\"connections\":[[\"mac\",\"$up\"]],\"name\":\"$name\"}
}"
}

STATE_DIR="/tmp/presence_state"
mkdir -p "$STATE_DIR"

IFACE="${1:-}"
EVENT="${2:-}"
shift 2 || true
REST="$*"

# online status
if [ "$EVENT" == status ] ; then
  log "status thread"
  {
      echo online
      sleep infinity &
      SLEEPPID=$!
      trap 'kill $SLEEPPID' TERM INT
      wait $SLEEPPID
      echo offline
  } | $PUB -r -l -k 30 \
          -t "$TOPIC_PREFIX/$HOST_ID/status" \
          --will-topic "$TOPIC_PREFIX/$HOST_ID/status" \
          --will-payload offline --will-retain --will-qos 1
  exit 0
# send device status on start
elif [ "$EVENT" == sync ] ; then
  connected=$(for i in $IFACE; do hostapd_cli -i "$i" all_sta; done \
                | grep -Eio '^([0-9a-f]{2}:){5}[0-9a-f]{2}')
  devices | while read -r mac name; do
      log "sync device $mac"
      if echo "$connected" | grep -qix "$mac"; then
        publish "$mac" connected
      else
        publish "$mac" not_connected
      fi
  done
  exit 0
elif [ "$EVENT" == discover ] ; then
  devices | while read -r mac name; do
    discovery "$mac" "$name"
  done
  exit 0
fi

# Extract MAC with colons from the remaining args (hostapd_cli may append key=value tokens)
MAC_RAW="$(printf '%s\n' "$REST" | grep -Eoi '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -n 1 || true)"
MAC="$(printf '%s' "$MAC_RAW" | tr '[:lower:]' '[:upper:]')"

log "iface=$IFACE event=$EVENT rest='$REST' mac='$MAC'"

# Ignore events without a MAC (e.g. EAPOL-4WAY-HS-COMPLETED without args on some builds)
[ -n "$MAC" ] || exit 0

STATE_FILE="$STATE_DIR/${MAC}.state"

if ! is_known $MAC ; then
  log "unknown mac $MAC"
  exit 0
fi

is_seen_anywhere() {
  # Roaming check across local radios on the same AP
  for i in ${IFACES:-}; do
    if iw dev "$i" station dump 2>/dev/null       | awk '/^Station/ {print toupper($2)}'       | grep -Fxq "$MAC"; then
      return 0
    fi
  done
  return 1
}

case "$EVENT" in
  AP-STA-CONNECTED)
    # Cancel grace timer and publish home immediately
    rm -f "$STATE_FILE" 2>/dev/null || true
    publish $MAC "home"
    ;;

  AP-STA-DISCONNECTED)
    # Start grace timer; only publish not_home if still absent after GRACE_SECONDS
    date +%s > "$STATE_FILE"
    log "start grace timer (${GRACE_SECONDS:-0}s) for mac=$MAC"

    (
      sleep "${GRACE_SECONDS:-0}"

      if [ -f "$STATE_FILE" ]; then
        # If the client is visible again (roamed back or reconnected), suppress not_home
        if is_seen_anywhere; then
          log "mac=$MAC reappeared during grace -> suppress not_home"
          rm -f "$STATE_FILE" 2>/dev/null || true
          exit 0
        fi

        log "grace expired for mac=$MAC -> publish not_home"
        rm -f "$STATE_FILE" 2>/dev/null || true
        publish $MAC "not_home"
      fi
    ) &

    ;;

  *)
    # Ignore other events
    exit 0
    ;;
esac

exit 0
