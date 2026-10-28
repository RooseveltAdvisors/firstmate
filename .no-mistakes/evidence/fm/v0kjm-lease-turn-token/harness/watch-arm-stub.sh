#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_LIVE_WATCH_LOG:?}"
  exit 0
fi
# Match --restart's home-scoped retirement contract: a replacement must not
# leave its predecessor polling the same trigger file.
if [ "${1:-}" = --restart ] && [ -f "${FM_LIVE_WATCH_LOG:?}" ]; then
  previous=$(awk '/^arm pid=/ { pid = substr($0, 9) } END { print pid }' "$FM_LIVE_WATCH_LOG")
  if [ -n "$previous" ]; then
    kill -TERM "$previous" 2>/dev/null || true
    printf 'retire pid=%s\n' "$previous" >> "$FM_LIVE_WATCH_LOG"
  fi
fi
printf 'arm pid=%s\n' "$$" >> "${FM_LIVE_WATCH_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-sdk-generation\n' "$$"
trap 'exit 0' TERM INT
while :; do
  if [ -e "$FM_LIVE_WATCH_TRIGGER" ]; then
    reason=$(cat "$FM_LIVE_WATCH_TRIGGER")
    rm -f "$FM_LIVE_WATCH_TRIGGER"
    printf 'trigger pid=%s reason=%s\n' "$$" "$reason" >> "${FM_LIVE_WATCH_LOG:?}"
    printf '%s\n' "$reason"
    exit 0
  fi
  sleep 0.02
done
