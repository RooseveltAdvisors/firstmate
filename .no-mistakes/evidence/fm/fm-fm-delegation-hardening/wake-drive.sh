#!/usr/bin/env bash
# Live captain-first wake presentation drive:
# real bin/fm-inbox.sh producer -> real bin/fm-wake-drain.sh drain in a lab home.
set -u
REPO=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5SDV9REPXRKVD9443H5KZTR
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
trap 'rm -rf "$LAB"' EXIT
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
STATE="$LAB/state"; QUEUE="$STATE/.wake-queue"
mkdir -p "$STATE"
export FM_HOME="$LAB"
unset FM_STATE_OVERRIDE 2>/dev/null || true
DRAIN="$REPO/bin/fm-wake-drain.sh"
INBOX="$REPO/bin/fm-inbox.sh"
PASS=0; FAIL=0
check() { if [ "$2" -eq 1 ]; then PASS=$((PASS+1)); printf 'PASS | %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL | %s\n' "$1"; fi }

NOW=$(date +%s)
{
  for i in $(seq 1 50); do
    printf '%s\t%s\tcheck\twatcher-%s\tcheck: watcher %s\n' "$((NOW - 3600 + i))" "$i" "$i" "$i"
  done
  printf '%s\t51\tstale\twin\tstale: win (idle 30m possible wedge ...)\n' "$((NOW - 3000))"
  printf '%s\t52\tprocevent\tnoise\tprocevent: pid 1234 exited\n' "$((NOW - 100))"
  printf '%s\t53\tcheck\ttag-mid\tcheck: tag-in-payload verdict=captain x\n' "$((NOW - 50))"
  printf '%s\t54\tcheck\ttag-space\tcheck: trailing verdict=captain \n' "$((NOW - 40))"
  printf '%s\t55\tcheck\tworded\tcheck: captain follow-up without any tag\n' "$((NOW - 30))"
} > "$QUEUE"

echo "=== W1: real fm-inbox.sh note emits the captain wake row ==="
out=$("$INBOX" note 'please dispatch wiseman-uukr' 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
inbox_id=$(awk -F '\t' '$5 ~ /verdict=captain$/ { k = $4 } END { sub(/^inbox:/, "", k); print k }' "$QUEUE")
captain_row=$(awk -F '\t' '$5 ~ /verdict=captain$/ { print } END { }' "$QUEUE" | tail -1)
[ "$rc" -eq 0 ] && [ -n "$inbox_id" ] && [[ "$captain_row" == *'check: captain inbox note '*" - please dispatch wiseman-uukr verdict=captain" ]] && ok=1 || ok=0
check "inbox producer emits a verdict=captain wake row ($inbox_id)" "$ok"

echo "=== W2: the drain presents the captain row FIRST, ahead of 50 watcher checks + stale wedge ==="
cp "$QUEUE" "$LAB/queue.before"
rc=0; drain_out=$("$DRAIN" 2>"$LAB/drain.err") || rc=$?
printf '%s\n' "$drain_out" | head -3 | sed 's/^/    row: /'
total=$(printf '%s\n' "$drain_out" | awk -F '\t' 'NF == 5 { n++ } END { print n }')
row1=$(printf '%s\n' "$drain_out" | awk -F '\t' 'NF == 5 { print; exit }')
row2=$(printf '%s\n' "$drain_out" | awk -F '\t' 'NF == 5 { c++; if (c == 2) print }')
[ "$rc" -eq 0 ] && [[ "$row1" == *'check: captain inbox note '*'- please dispatch wiseman-uukr verdict=captain' ]] && ok=1 || ok=0
check "captain row leads the drain at rank 1" "$ok"
[[ "$row2" == *'stale: win'* ]] && ok=1 || ok=0
check "the stale wedge is second, ahead of watcher checks" "$ok"
[ "$total" = 56 ] && ok=1 || ok=0
check "all 56 queued rows preserved by presentation (saw $total)" "$ok"

echo "=== W3: untagged look-alike rows are NOT promoted ==="
ranks=$(printf '%s\n' "$drain_out" | awk -F '\t' 'NF == 5 { rank++; if ($5 ~ /verdict=captain$/) suffix=rank; if ($4 == "tag-mid") mid=rank; if ($4 == "tag-space") space=rank; if ($4 == "worded") worded=rank } END { printf "suffix=%s mid=%s space=%s worded=%s", suffix, mid, space, worded }')
echo "    $ranks"
[ "$ranks" = "suffix=1 mid=53 space=54 worded=55" ] && ok=1 || ok=0
check "only the exact end-of-payload verdict=captain suffix is promoted (suffix=1, look-alikes at 53/54/55)" "$ok"

echo "=== W4: presentation does not reorder the durable queue; ack covers every shown row ==="
cmp -s "$STATE/.wake-queue" "$LAB/queue.before" && ok=1 || ok=0
check "durable queue file byte-identical after presentation" "$ok"
ack_line=$(grep '^WAKE_ACK_REQUIRED:' "$LAB/drain.err" | tail -1)
seq_n=$(printf '%s\n' "$ack_line" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
gen=$(printf '%s\n' "$ack_line" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
echo "    $ack_line"
[ "$seq_n" = 56 ] && ok=1 || ok=0
check "acknowledgement cutoff equals the max shown sequence ($seq_n)" "$ok"

echo "=== W5: acknowledgement consumes every presented row ==="
rc=0; "$DRAIN" --ack-through "$seq_n" --recovery-generation "$gen" >/dev/null 2>"$LAB/ack.err" || rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$STATE/.wake-queue" ] && ok=1 || ok=0
check "ack through $seq_n emptied the durable queue (rc=$rc)" "$ok"

echo "=== W6: second wave keeps class/age/sequence order with a fresh captain row on top ==="
{
  printf '%s\t57\theartbeat\theartbeat\theartbeat\n' "$((NOW - 7200))"
  printf '%s\t58\tcheck\tnew-check\tcheck: newer\n' "$NOW"
  printf '%s\t59\tstale\tnew-stale\tstale: newer\n' "$NOW"
  printf '%s\t60\tcheck\tcorrelated\tcheck: corr=x\n' "$NOW"
  printf '%s\t61\tcheck\told-check\tcheck: older\n' "$((NOW - 1900))"
  printf '%s\t62\tstale\told-stale\tstale: older\n' "$((NOW - 1900))"
  printf '%s\t63\tstale\tbead\tstale: bead=x\n' "$((NOW - 1900))"
  printf '%s\t64\tsignal\tplain\tsignal: no correlation\n' "$((NOW - 1900))"
} > "$QUEUE"
out2=$("$INBOX" note 'second captain dispatch please' 2>&1)
captain_seq=$(awk -F '\t' '$5 ~ /verdict=captain$/ { s = $2 } END { print s }' "$QUEUE")
rc=0; drain2=$("$DRAIN" 2>"$LAB/drain2.err") || rc=$?
order=$(printf '%s\n' "$drain2" | awk -F '\t' 'NF == 5 { printf "%s%s", sep, $2; sep = "," }')
echo "    order: $order  (captain seq $captain_seq)"
[ "$rc" -eq 0 ] && [ "$order" = "$captain_seq,63,64,60,62,59,61,58,57" ] && ok=1 || ok=0
check "captain row first, then signal/corr=/bead=, stale, check, heartbeat by age ($order)" "$ok"

echo
echo "WAKE-DRIVE RESULT: pass=$PASS fail=$FAIL"
exit 0
