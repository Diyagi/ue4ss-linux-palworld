#!/bin/bash
# soak-sampler.sh — host-side telemetry sampler for the Palworld soak.
# Independent of UE4SS fork reliability: reads RSS/CPU/PSS straight from the
# host. Run via cron:  */5 * * * * /bin/bash /home/ubuntu/soak-sampler.sh
#
# Customize CONTAINERS for your deployment (docker names).

CONTAINERS="${CONTAINERS:-palworld-wyxxyjqraays3f2dihlc7gb4 palworld-test}"
OUT="${OUT:-/home/ubuntu/soak-sampler.log}"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "=== $TS ==="
  for C in $CONTAINERS; do
    PID=$(docker inspect --format '{{.State.Pid}}' "$C" 2>/dev/null)
    if [ -z "$PID" ] || [ "$PID" = "0" ]; then echo "$C: DOWN"; continue; fi
    STAT=$(ps -o rss=,pcpu=,etime= -p "$PID" 2>/dev/null)
    PSS=$(awk '/^Pss:/{print $2}' "/proc/$PID/smaps_rollup" 2>/dev/null || echo "n/a")
    echo "$C pid=$PID rss_kb=$(echo $STAT | awk '{print $1}') cpu=$(echo $STAT | awk '{print $2}') uptime=$(echo $STAT | awk '{print $3}') pss_kb=$PSS"
    echo "$C priv_dirty_kb=$(awk '/Private_Dirty:/{s+=$2} END{print s}' "/proc/$PID/smaps" 2>/dev/null || echo n/a) shared_kb=$(awk '/Shared:/{s+=$2} END{print s}' "/proc/$PID/smaps" 2>/dev/null || echo n/a)"
  done
  docker stats --no-stream --format "{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}" $CONTAINERS 2>/dev/null
} >> "$OUT" 2>&1
