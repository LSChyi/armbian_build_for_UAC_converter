#!/bin/bash

set -e -x

# Place the udev rules
echo "Install udev rules"
cat << 'EOF' > /etc/udev/rules.d/51-trigger-alsaloop.rules
ACTION=="change", SUBSYSTEM=="sound", ENV{SOUND_INITIALIZED}="1", TAG+="systemd" ENV{SYSTEMD_WANTS}="alsaloop-usb.service uac-gadget-volume-sync.service"
ACTION=="remove", SUBSYSTEM=="sound", RUN+="/usr/local/sbin/stop_sound_redirect.sh"
EOF
chmod 644 /etc/udev/rules.d/51-trigger-alsaloop.rules

# place the alsaloop service file
echo "Install alsaloop-usb service"
cat << 'EOF' >  /etc/systemd/system/alsaloop-usb.service
[Unit]
Description=USB Audio Loopback
After=sound.target

[Service]
ExecStart=/usr/local/sbin/run_alsaloop.sh
# Check if both UAC gadget and external sound cards are ready first.
# If not, no need to run, and script should return success to prevent from restarting.
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/alsaloop-usb.service

echo "Install run_alsaloop  script"
cat << 'EOF' > /usr/local/sbin/run_alsaloop.sh
#!/bin/bash

CARD=$(aplay -L | grep "^plughw:CARD=" | grep -v -e "HDMI" -e "UAC1Gadget" | head -n 1)
if [ -z "${CARD}" ]; then
    echo "External card is not ready, do not run"
    exit 0
fi
if [ -z "$(arecord -l | grep UAC1Gadget)" ]; then
    echo "Gadget sound card is not ready, do not run"
    exit 0
fi

alsaloop -C plughw:CARD=UAC1Gadget,DEV=0 -P "${CARD}" -t 20000 -A 2 -S 5 -b
EOF
chmod 744 /usr/local/sbin/run_alsaloop.sh

# place the uac volume sync service file
echo "Install UAC volume sync service"
cat << 'EOF' > /etc/systemd/system/uac-gadget-volume-sync.service
[Unit]
Description=Gadget volume control sync to the output device
After=sound.target

[Service]
ExecStart=/usr/local/sbin/sync_volume.sh
# Check if both UAC gadget and external sound cards are ready first.
# If not, no need to run, and script should return success to prevent from restarting.
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/uac-gadget-volume-sync.service

echo "Install volume sync script"
cat << 'EOF' > /usr/local/sbin/sync_volume.sh
#!/bin/bash

function find_control() {
  local CARD=$1
  amixer -c "${CARD}" scontrols | grep -Po "(?<=Simple mixer control ).*" | while IFS= read -r control; do
    if amixer -c "${CARD}" sget "${control}" | grep -q pswitch-joined; then
      echo "${control}"
      return 0
    fi
   done
}

function sync_volume() {
  local CARD=$1
  local CONTROL=$2
  local VOLUME=$(amixer -c UAC1Gadget sget PCM | grep -Po "Capture \d+ \[\d+%\]" | grep -Po "\d+(?=%)" | head -n1)
  amixer -c "${CARD}" sset "${CONTROL}" "${VOLUME}%" > /dev/null
}

CARD=$(aplay -L | grep -Po "(?<=default:CARD=).*" | grep -v -e "UAC1Gadget" -e "HDMI" | head -n1)
if [ -z "${CARD}" ]; then
    echo "External card is not ready, do not run"
    exit 0
fi
if [ -z "$(arecord -l | grep UAC1Gadget)" ]; then
    echo "Gadget sound card is not ready, do not run"
    exit 0
fi
CONTROL=$(find_control "${CARD}")

# Initial setup - first set the joint playback to the same as the capture card
# then set 100% for other playbacks. This is to simplify the volume control.
sync_volume "${CARD}" "${CONTROL}"
amixer -c "${CARD}" scontrols | grep -Po "(?<=Simple mixer control ).*" | while IFS= read -r control; do
  if amixer -c "${CARD}" sget "${control}" | grep -q pswitch-joined; then
    continue
  fi
  amixer -c "${CARD}" sget "${control}" 100% > /dev/null
done

# Monitor the Gadget for changes
alsactl monitor | while read -r line; do
  sync_volume "${CARD}" "${CONTROL}"
done
EOF
chmod 744 /usr/local/sbin/sync_volume.sh

echo "Install stoop sound redirect script"
cat << 'EOF' > /usr/local/sbin/stop_sound_redirect.sh
#!/bin/bash


CARD=$(aplay -L | grep -Po "(?<=default:CARD=).*" | grep -v -e "UAC1Gadget" -e "HDMI" | head -n1)
GADGET_CARD=$(arecord -l | grep UAC1Gadget)
if [[ -z "${CARD}" || -z "${GADGET_CARD}" ]]; then
    echo "At least one of the card is not ready, run terminate"
    systemctl stop alsaloop-usb.service
    systemctl stop uac-gadget-volume-sync.service
fi
EOF
chmod 744 /usr/local/sbin/stop_sound_redirect.sh

# load g_audio
echo "Set g_audio to load automatically after boot"
echo g_audio >> /etc/modules
