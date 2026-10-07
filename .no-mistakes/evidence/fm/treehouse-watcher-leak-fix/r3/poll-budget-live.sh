#!/usr/bin/env bash
# Run the real bin/fm-watch.sh event_wait_or_sleep supervision loop for 6s at POLL=2
# against a herdr task whose event wait returns 1 at once (closed/empty stream).
root=$1 st=$(mktemp -d)
printf 'window=default:wG:pQ\nbackend=herdr\nkind=ship\n' > "$st/t1.meta"
bash -c '
  export PROBE_ST="$1" FM_STATE_OVERRIDE="$1" FM_ROOT_OVERRIDE="$2" FM_POLL=2
  . "$2/bin/fm-watch.sh"
  fm_backend_events_capable() { return 0; }
  fm_backend_wait_transition() { echo x >> "$PROBE_ST/reader-launches"; return 1; }
  start=$SECONDS; n=0
  while [ $((SECONDS - start)) -lt 6 ]; do event_wait_or_sleep; n=$((n+1)); done
  echo "supervision cycles in 6s at POLL=2: $n ; event-reader launches: $(wc -l < "$PROBE_ST/reader-launches")"
' _ "$st" "$root"
rm -rf "$st"
