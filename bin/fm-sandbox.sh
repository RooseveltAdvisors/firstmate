#!/usr/bin/env bash
# Own the opt-in Docker Sandboxes execution layer used inside a Herdr task pane.
# This is not a runtime backend: Herdr still owns the endpoint, steering,
# capture, liveness, and recovery, while this helper owns one task-bound sbx
# microVM and its disposable work copy.
#
# Usage:
#   fm-sandbox.sh inventory [--json]
#   fm-sandbox.sh doctor --host <id> [--json]
#   fm-sandbox.sh identity <task-id> <host-id>
#   fm-sandbox.sh prepare <task-id>
#   fm-sandbox.sh run <task-id>
#   fm-sandbox.sh status <task-id> [--json]
#   fm-sandbox.sh lab-proof <task-id> <host-sentinel> <result-file>
#   fm-sandbox.sh cleanup <task-id>
#
# Tracked code is disabled unless config/sandbox-workers-enabled contains the
# exact line `v1`. The required private config/sandbox-hosts.json schema is
# shown in docs/examples/sandbox-hosts.json. Selection is explicit: inventory
# emits role, transport, limits, configured priority, and refusal facts, but
# never computes or hides a scheduler score.
#
# The first vertical path supports only an ordinary ship/scout using harness
# codex, backend herdr, a local transport host, and network profile
# codex-github-bun-v1. All other harnesses, secondmates, remote transports,
# private-service grants, subscription OAuth, GPU work, and runtime backends
# refuse before sandbox creation. A local transport host can be a fleet host
# after controlled rollout launches Firstmate there; remote transport remains
# a documented follow-up instead of an SSH command-string boundary.
#
# prepare requires FM_SANDBOX_OPENAI_API_KEY for a new sandbox and accepts an
# optional FM_SANDBOX_GITHUB_TOKEN. It passes each value only on stdin to
# `sbx secret set <sandbox> <service>`, which scopes the proxy-managed secret to
# this sandbox. Values are never written, logged, put in argv, or injected as
# sandbox environment variables. Docker's global Codex OAuth flow is refused
# because it cannot meet this task-scoped credential contract.
#
# The workspace mounted writable into the microVM is a fresh, no-local clone
# under the task's recorded /tmp root. It contains committed repository data
# and the task brief, not ignored files from the Treehouse worktree. The
# primary project clone and Treehouse task worktree are never mounted. Shared
# Docker Sandbox skills are disabled. Scopey is installed by the pinned kit in
# assets/sandbox-kits/firstmate-codex and remains advisory.
#
# state/<id>.sandbox.json is the machine-readable ownership journal. Cleanup
# requires exact agreement among ordinary task meta, that journal, sbx's
# stable id/name inventory, and /etc/firstmate-owner inside the microVM before
# `sbx rm --force` is allowed. A label, path, PID, ambient sandbox, or sole
# inventory item never proves ownership. Missing or ambiguous evidence refuses
# cleanup even when fm-teardown was invoked with --force.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENABLE_FILE="${FM_SANDBOX_ENABLE_OVERRIDE:-$CONFIG/sandbox-workers-enabled}"
HOSTS_FILE="${FM_SANDBOX_HOSTS_OVERRIDE:-$CONFIG/sandbox-hosts.json}"
KVM_PATH="${FM_SANDBOX_KVM_PATH:-/dev/kvm}"
SBX="${FM_SANDBOX_SBX:-sbx}"
KIT="$FM_ROOT/assets/sandbox-kits/firstmate-codex"
PROFILE=codex-github-bun-v1
SCHEMA=fm-sandbox-owner.v1
HOST_LOCK_ROOT="${FM_SANDBOX_HOST_LOCK_ROOT:-/tmp/firstmate-sandbox-host-locks}"
HOST_LOCK=
HOST_LOCK_HELD=0
PREPARE_ROLLBACK_ACTIVE=0
PREPARE_TASK=
PREPARE_OWNER=
PREPARE_TASK_TMP=
PREPARE_WORKCOPY=
PREPARE_NAME=
PREPARE_HOST=
PREPARE_NONCE=
PREPARE_SBX_ID=
PREPARE_RESERVATION=

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

sandbox_exit_cleanup() {
  local status=$?
  if [ "$PREPARE_ROLLBACK_ACTIVE" = 1 ]; then
    prepare_rollback || true
  fi
  if [ "$HOST_LOCK_HELD" = 1 ]; then
    HOST_LOCK_HELD=0
    fm_lock_release "$HOST_LOCK" || true
  fi
  return "$status"
}

trap sandbox_exit_cleanup EXIT

valid_id() {
  [[ ${1:-} =~ ^[a-zA-Z0-9_:-]+$ ]]
}

meta_exact() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" | cut -d= -f2-
}

enabled() {
  [ -f "$ENABLE_FILE" ] && [ ! -L "$ENABLE_FILE" ] \
    && [ "$(sed -n '1p' "$ENABLE_FILE")" = v1 ] \
    && [ "$(wc -l < "$ENABLE_FILE" | tr -d ' ')" = 1 ]
}

validate_hosts_file() {
  [ -f "$HOSTS_FILE" ] && [ ! -L "$HOSTS_FILE" ] || {
    echo "error: missing sandbox host inventory at $HOSTS_FILE" >&2
    return 1
  }
  jq -e '
    .version == 1
    and (.hosts | type == "array" and length > 0)
    and ([.hosts[].id] | length == (unique | length))
    and all(.hosts[];
      (.id | type == "string" and test("^[a-zA-Z0-9_:-]+$"))
      and (.role | IN("dev", "agt", "gpu", "svc", "srv"))
      and (.transport | IN("local", "ssh-fixed"))
      and (.hostname | type == "string" and test("^[a-zA-Z0-9._-]+$"))
      and (.enabled | type == "boolean")
      and (.priority | type == "number" and floor == . and . >= 0)
      and (.cpus | type == "number" and floor == . and . >= 1 and . <= 64)
      and (.memory | type == "string" and test("^[1-9][0-9]*(MiB|GiB)$"))
      and (.maxConcurrent | type == "number" and floor == . and . >= 1 and . <= 64)
      and (.profiles | type == "array" and all(.[]; . == "codex-github-bun-v1"))
      and (.authMode == "ephemeral-api-key")
      and (.privateNetworkGrant == false)
    )
  ' "$HOSTS_FILE" >/dev/null || {
    echo "error: invalid sandbox host inventory at $HOSTS_FILE" >&2
    return 1
  }
}

host_json() { # <id>
  local id=$1 host count
  validate_hosts_file || return 1
  count=$(jq --arg id "$id" '[.hosts[] | select(.id == $id)] | length' "$HOSTS_FILE")
  [ "$count" = 1 ] || {
    echo "error: sandbox host '$id' is absent or ambiguous in $HOSTS_FILE" >&2
    return 1
  }
  host=$(jq -c --arg id "$id" '.hosts[] | select(.id == $id)' "$HOSTS_FILE")
  printf '%s\n' "$host"
}

actual_hostname() {
  if [ -n "${FM_SANDBOX_HOSTNAME:-}" ]; then
    printf '%s\n' "$FM_SANDBOX_HOSTNAME"
  else
    hostname -f 2>/dev/null || hostname
  fi
}

version_at_least() { # <actual> <minimum>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

sbx_version() {
  "$SBX" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

policy_is_deny_all() {
  local policies text
  policies=$("$SBX" policy ls --json 2>/dev/null) || return 1
  jq -e . >/dev/null 2>&1 <<EOF || return 1
$policies
EOF
  text=$(printf '%s' "$policies" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *balanced*|*allow-all*|*allow_all*|*'"resource":"**"'*|*'"resource": "**"'*) return 1 ;;
  esac
  case "$text" in
    *deny-all*|*deny_all*|*locked-down*|*locked_down*) return 0 ;;
  esac
  return 1
}

local_capability_json() { # <host-json>
  local host=$1 id configured_hostname transport role host_enabled cpus memory max priority
  local actual version="" sbx_present=false kvm=false daemon=false policy=false reason=""
  id=$(jq -r .id <<EOF
$host
EOF
)
  configured_hostname=$(jq -r .hostname <<EOF
$host
EOF
)
  transport=$(jq -r .transport <<EOF
$host
EOF
)
  role=$(jq -r .role <<EOF
$host
EOF
)
  host_enabled=$(jq -r .enabled <<EOF
$host
EOF
)
  cpus=$(jq -r .cpus <<EOF
$host
EOF
)
  memory=$(jq -r .memory <<EOF
$host
EOF
)
  max=$(jq -r .maxConcurrent <<EOF
$host
EOF
)
  priority=$(jq -r .priority <<EOF
$host
EOF
)
  actual=$(actual_hostname)
  command -v "$SBX" >/dev/null 2>&1 && sbx_present=true
  [ -c "$KVM_PATH" ] && [ -r "$KVM_PATH" ] && [ -w "$KVM_PATH" ] && kvm=true
  if enabled && [ "$host_enabled" = true ] && [ "$transport" = local ] && [ "$sbx_present" = true ]; then
    version=$(sbx_version || true)
    if [ -n "$version" ] && version_at_least "$version" 0.35.0 \
      && "$SBX" ls --json >/dev/null 2>&1; then
      daemon=true
      policy_is_deny_all && policy=true
    fi
  fi
  if ! enabled; then reason="rollout-disabled"
  elif [ "$host_enabled" != true ]; then reason="host-disabled"
  elif [ "$transport" != local ]; then reason="transport-unsupported-v1"
  elif [ "$actual" != "$configured_hostname" ] && [ "${actual%%.*}" != "${configured_hostname%%.*}" ]; then reason="wrong-host"
  elif [ "$role" = srv ]; then reason="production-role-refused-v1"
  elif [ "$role" = gpu ]; then reason="gpu-role-refused-v1"
  elif [ "$sbx_present" != true ]; then reason="sbx-missing"
  elif [ -z "$version" ] || ! version_at_least "$version" 0.35.0; then reason="sbx-version"
  elif [ "$kvm" != true ]; then reason="kvm-unavailable"
  elif [ "$daemon" != true ]; then reason="sbx-daemon-unavailable"
  elif [ "$policy" != true ]; then reason="policy-not-deny-all"
  fi
  jq -nc \
    --arg id "$id" --arg role "$role" --arg transport "$transport" \
    --arg configured_hostname "$configured_hostname" --arg actual_hostname "$actual" \
    --arg version "$version" --arg memory "$memory" --arg reason "$reason" \
    --argjson enabled "$host_enabled" --argjson priority "$priority" \
    --argjson cpus "$cpus" --argjson maxConcurrent "$max" \
    --argjson sbxPresent "$sbx_present" --argjson kvm "$kvm" \
    --argjson daemon "$daemon" --argjson denyAllPolicy "$policy" \
    '{id:$id,role:$role,transport:$transport,configuredHostname:$configured_hostname,
      actualHostname:$actual_hostname,configuredEnabled:$enabled,priority:$priority,
      limits:{cpus:$cpus,memory:$memory,maxConcurrent:$maxConcurrent},
      capabilities:{sbxPresent:$sbxPresent,sbxVersion:$version,kvm:$kvm,
        daemonReachable:$daemon,denyAllPolicy:$denyAllPolicy},
      eligible:($reason == ""),refusalReason:(if $reason == "" then null else $reason end)}'
}

inventory() {
  local json=false host rows='[]'
  [ "${1:-}" != --json ] || json=true
  validate_hosts_file || exit 1
  while IFS= read -r host; do
    rows=$(jq -nc --argjson rows "$rows" --argjson row "$(local_capability_json "$host")" '$rows + [$row]')
  done < <(jq -c '.hosts[] | .' "$HOSTS_FILE")
  if [ "$json" = true ]; then
    jq -n --arg schema fm-sandbox-inventory.v1 --argjson rollout "$(enabled && echo true || echo false)" \
      --argjson hosts "$rows" '{schema:$schema,rolloutEnabled:$rollout,hosts:$hosts}'
  else
    printf 'HOST\tROLE\tTRANSPORT\tPRIORITY\tCPUS\tMEMORY\tMAX\tELIGIBLE\tREASON\n'
    jq -r '.[] | [.id,.role,.transport,.priority,.limits.cpus,.limits.memory,.limits.maxConcurrent,.eligible,(.refusalReason // "-")] | @tsv' <<EOF
$rows
EOF
  fi
}

doctor() {
  local host_id='' json=false host result
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host) [ "$#" -ge 2 ] || die "--host requires a value"; host_id=$2; shift 2 ;;
      --json) json=true; shift ;;
      *) die "unknown doctor argument: $1" ;;
    esac
  done
  valid_id "$host_id" || die "doctor requires a valid --host"
  host=$(host_json "$host_id") || exit 1
  result=$(local_capability_json "$host")
  if [ "$json" = true ]; then
    printf '%s\n' "$result"
  else
    jq -r '"host=\(.id) role=\(.role) transport=\(.transport) eligible=\(.eligible) refusal=\(.refusalReason // "none") sbx=\(.capabilities.sbxVersion // "missing") kvm=\(.capabilities.kvm) policy_deny_all=\(.capabilities.denyAllPolicy) cpus=\(.limits.cpus) memory=\(.limits.memory) max=\(.limits.maxConcurrent)"' <<EOF
$result
EOF
  fi
  [ "$(jq -r .eligible <<EOF
$result
EOF
)" = true ]
}

identity() { # <task> <host>
  local task=$1 host=$2 nonce short safe_task
  if ! valid_id "$task" || ! valid_id "$host"; then
    die "invalid sandbox identity request"
  fi
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [ "${#nonce}" = 32 ] || die "could not generate sandbox ownership nonce"
  short=${nonce:0:12}
  safe_task=$(printf '%s' "$task" | tr ':_' '--')
  printf '%s\t%s\n' "fm-${safe_task:0:30}-$short" "$nonce"
}

owner_path() { printf '%s/%s.sandbox.json\n' "$STATE" "$1"; }
log_path() { printf '%s/%s.sandbox-network.json\n' "$STATE" "$1"; }

sidecar_update() { # <path> <jq-filter> [jq args...]
  local path=$1 filter=$2 tmp
  shift 2
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  if jq "$@" "$filter" "$path" > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

snapshot_network_log() { # <task> <sandbox-name>
  local path tmp
  path=$(log_path "$1")
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  if "$SBX" policy log "$2" --json > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

validate_task_meta() { # <id>
  local id=$1 meta execution backend harness host profile name nonce owner kind
  valid_id "$id" || die "invalid task id"
  meta="$STATE/$id.meta"
  execution=$(meta_exact "$meta" execution) || die "task $id has no exact execution metadata"
  backend=$(meta_exact "$meta" backend) || die "sandbox task $id has no exact backend metadata"
  harness=$(meta_exact "$meta" harness) || die "sandbox task $id has no exact harness metadata"
  host=$(meta_exact "$meta" sandbox_host) || die "sandbox task $id has no exact host metadata"
  profile=$(meta_exact "$meta" sandbox_profile) || die "sandbox task $id has no exact network profile metadata"
  name=$(meta_exact "$meta" sandbox_name) || die "sandbox task $id has no exact sandbox name metadata"
  nonce=$(meta_exact "$meta" sandbox_nonce) || die "sandbox task $id has no exact ownership nonce metadata"
  owner=$(meta_exact "$meta" sandbox_owner) || die "sandbox task $id has no exact ownership journal metadata"
  kind=$(meta_exact "$meta" kind) || die "sandbox task $id has no exact kind metadata"
  [ "$execution" = sandbox ] || die "task $id is not a sandbox execution"
  [ "$backend" = herdr ] || die "sandbox execution requires backend=herdr; got $backend"
  [ "$harness" = codex ] || die "sandbox execution supports only harness=codex; got $harness"
  [ "$kind" = ship ] || [ "$kind" = scout ] || die "sandbox execution refuses kind=$kind"
  [ "$profile" = "$PROFILE" ] || die "unsupported sandbox network profile: $profile"
  [ "$owner" = "$(owner_path "$id")" ] || die "sandbox ownership journal path does not match task state"
  if ! valid_id "$host" || ! valid_id "$name"; then
    die "invalid host or sandbox identity in task metadata"
  fi
  [[ $nonce =~ ^[a-f0-9]{32}$ ]] || die "invalid ownership nonce in task metadata"
}

inventory_match() { # <name> <id-or-empty>; prints object
  local name=$1 expected_id=${2:-} list count
  list=$("$SBX" ls --json) || return 1
  jq -e . >/dev/null 2>&1 <<EOF || return 1
$list
EOF
  count=$(jq --arg name "$name" '[.[]? | select(.name == $name)] | length' <<EOF
$list
EOF
)
  [ "$count" = 1 ] || return 1
  if [ -n "$expected_id" ]; then
    count=$(jq --arg name "$name" --arg id "$expected_id" '[.[]? | select(.name == $name and .id == $id)] | length' <<EOF
$list
EOF
)
    [ "$count" = 1 ] || return 1
  fi
  jq -c --arg name "$name" '.[] | select(.name == $name)' <<EOF
$list
EOF
}

policy_expect() { # <name> <allowed|denied> <target>
  local name=$1 expected=$2 target=$3 out status decision
  set +e
  out=$("$SBX" policy check network --sandbox "$name" "$target" 2>&1)
  status=$?
  set -e
  [ "$status" = 0 ] || {
    echo "error: sandbox policy check failed for $target with status $status; got: $out" >&2
    return 1
  }
  decision=${out%%:*}
  case "$decision:$expected" in
    Allowed:allowed|Denied:denied) return 0 ;;
  esac
  echo "error: sandbox policy expected $expected for $target; got: $out" >&2
  return 1
}

verify_policy() { # <name>
  local name=$1 target
  for target in api.openai.com github.com registry.npmjs.org registry-1.docker.io; do
    policy_expect "$name" allowed "$target" || return 1
  done
  for target in portal.arcs.health zeta.health covenant.clinic dev srv svc gpu \
    10.0.0.1 192.168.0.6 127.0.0.1 169.254.169.254 example.com; do
    policy_expect "$name" denied "$target" || return 1
  done
}

write_owner_marker() { # <name> <task> <host> <id> <nonce>
  # shellcheck disable=SC2016
  "$SBX" exec "$1" -- sh -c \
    'umask 077; printf "%s\n" "$1" > /etc/firstmate-owner' sh \
    "$(jq -nc --arg schema "$SCHEMA" --arg task "$2" --arg host "$3" --arg id "$4" --arg nonce "$5" \
      '{schema:$schema,task_id:$task,host_id:$host,sandbox_id:$id,nonce:$nonce}')" >/dev/null
}

verify_owner_marker() { # <name> <task> <host> <id> <nonce>
  local marker
  marker=$("$SBX" exec "$1" -- cat /etc/firstmate-owner 2>/dev/null) || return 1
  jq -e --arg schema "$SCHEMA" --arg task "$2" --arg host "$3" --arg id "$4" --arg nonce "$5" \
    '.schema == $schema and .task_id == $task and .host_id == $host and .sandbox_id == $id and .nonce == $nonce' \
    >/dev/null 2>&1 <<EOF
$marker
EOF
}

acquire_host_lock() { # <host>
  local host=$1 host_dir
  if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  if [ -e "$HOST_LOCK_ROOT" ] || [ -L "$HOST_LOCK_ROOT" ]; then
    [ -d "$HOST_LOCK_ROOT" ] && [ ! -L "$HOST_LOCK_ROOT" ] || die "sandbox host lock root is not a regular directory"
  else
    (umask 077; mkdir "$HOST_LOCK_ROOT") || die "could not create sandbox host lock root"
  fi
  host_dir="$HOST_LOCK_ROOT/$host"
  (umask 077; mkdir -p "$host_dir/reservations") || die "could not create sandbox host reservation directory"
  [ -d "$host_dir" ] && [ ! -L "$host_dir" ] || die "sandbox host lock directory is not a regular directory"
  [ -d "$host_dir/reservations" ] && [ ! -L "$host_dir/reservations" ] \
    || die "sandbox host reservation directory is not a regular directory"
  HOST_LOCK="$host_dir/lock"
  fm_lock_acquire_wait "$HOST_LOCK" || die "could not acquire sandbox host lock for $host"
  HOST_LOCK_HELD=1
}

reservation_path() { # <host> <nonce>
  printf '%s/%s/reservations/%s.json\n' "$HOST_LOCK_ROOT" "$1" "$2"
}

write_reservation() { # <path> <task> <host> <name> <nonce> <owner>
  local path=$1 task=$2 host=$3 name=$4 nonce=$5 owner=$6 tmp now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  if jq -n --arg schema fm-sandbox-reservation.v1 --arg task "$task" \
      --arg host "$host" --arg name "$name" --arg nonce "$nonce" --arg owner "$owner" \
      --arg pid "${BASHPID:-$$}" --arg now "$now" \
      '{schema:$schema,task_id:$task,host_id:$host,sandbox_name:$name,nonce:$nonce,owner:$owner,pid:$pid,created_at:$now}' \
      > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

reservation_is_active() { # <reservation>
  local path=$1 owner pid lifecycle sbx_id
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(jq -r '.owner // empty' "$path" 2>/dev/null || true)
  pid=$(jq -r '.pid // empty' "$path" 2>/dev/null || true)
  if [ -f "$owner" ] && [ ! -L "$owner" ]; then
    lifecycle=$(jq -r '.lifecycle // empty' "$owner" 2>/dev/null || true)
    [ "$lifecycle" != removed ] || return 1
    sbx_id=$(jq -r '.sandbox_id // empty' "$owner" 2>/dev/null || true)
    [ -n "$sbx_id" ] && [ "$sbx_id" != null ] && return 0
  fi
  fm_pid_alive "$pid"
}

reserve_host_slot() { # <task> <host> <name> <nonce> <owner> <max> <existing>
  local task=$1 host=$2 name=$3 nonce=$4 owner=$5 max=$6 existing=$7
  local path reservation active=0
  path=$(reservation_path "$host" "$nonce")
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "sandbox host reservation is not a regular file"
    jq -e --arg task "$task" --arg host "$host" --arg name "$name" --arg nonce "$nonce" --arg owner "$owner" \
      '.schema == "fm-sandbox-reservation.v1" and .task_id == $task and .host_id == $host and .sandbox_name == $name and .nonce == $nonce and .owner == $owner' \
      "$path" >/dev/null || die "sandbox host reservation identity mismatch"
    PREPARE_RESERVATION="$path"
    return 0
  fi
  if [ "$existing" != 1 ]; then
    for reservation in "$HOST_LOCK_ROOT/$host/reservations"/*.json; do
      [ -f "$reservation" ] && [ ! -L "$reservation" ] || continue
      if reservation_is_active "$reservation"; then
        active=$((active + 1))
      else
        rm -f "$reservation"
      fi
    done
    [ "$active" -lt "$max" ] || die "sandbox host $host is at configured maxConcurrent=$max"
  fi
  write_reservation "$path" "$task" "$host" "$name" "$nonce" "$owner" \
    || die "could not publish sandbox host reservation"
  PREPARE_RESERVATION="$path"
}

release_reservation() { # <path> <task> <host> <name> <nonce> <owner>
  local path=$1 task=$2 host=$3 name=$4 nonce=$5 owner=$6
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  jq -e --arg task "$task" --arg host "$host" --arg name "$name" --arg nonce "$nonce" --arg owner "$owner" \
    '.schema == "fm-sandbox-reservation.v1" and .task_id == $task and .host_id == $host and .sandbox_name == $name and .nonce == $nonce and .owner == $owner' \
    "$path" >/dev/null || return 1
  rm -f "$path"
}

ensure_task_root() { # <path>
  local tasktmp=$1 parent parent_real tasktmp_real old_umask
  [ "$tasktmp" = /tmp/* ] || die "sandbox task temp root must be under /tmp"
  parent=$(dirname "$tasktmp")
  [ -d "$parent" ] || die "sandbox task temp parent is missing"
  parent_real=$(cd "$parent" && pwd -P) || die "sandbox task temp parent cannot be resolved"
  if [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; then
    [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || die "sandbox task temp root is missing or symlinked"
  else
    old_umask=$(umask)
    umask 077
    mkdir "$tasktmp"
    umask "$old_umask"
  fi
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] && [ -O "$tasktmp" ] \
    || die "sandbox task temp root is not owned by the controller"
  tasktmp_real=$(cd "$tasktmp" && pwd -P) || die "sandbox task temp root cannot be resolved"
  [ "$tasktmp_real" = "$parent_real/$(basename "$tasktmp")" ] \
    || die "sandbox task temp root resolves outside its parent"
  chmod 700 "$tasktmp"
}

prepare_owner_matches() {
  [ -f "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ] || return 1
  jq -e --arg schema "$SCHEMA" --arg task "$PREPARE_TASK" --arg host "$PREPARE_HOST" \
    --arg name "$PREPARE_NAME" --arg nonce "$PREPARE_NONCE" --arg workcopy "$PREPARE_WORKCOPY" \
    '.schema == $schema and .task_id == $task and .host_id == $host and .sandbox_name == $name and .nonce == $nonce and .workcopy == $workcopy' \
    "$PREPARE_OWNER" >/dev/null 2>&1
}

prepare_rollback() {
  local candidate candidate_id candidate_workspace marker sandbox_present=0 removed=0 now
  [ "$PREPARE_ROLLBACK_ACTIVE" = 1 ] || return 0
  PREPARE_ROLLBACK_ACTIVE=0
  if [ -n "$PREPARE_NAME" ]; then
    if [ -n "$PREPARE_SBX_ID" ]; then
      candidate=$(inventory_match "$PREPARE_NAME" "$PREPARE_SBX_ID" 2>/dev/null || true)
    else
      candidate=$(inventory_match "$PREPARE_NAME" 2>/dev/null || true)
    fi
    if [ -n "$candidate" ]; then
      candidate_id=$(jq -r '.id // empty' <<EOF
$candidate
EOF
)
      candidate_workspace=$(jq -r '.workspace // .path // empty' <<EOF
$candidate
EOF
)
      if [ -n "$candidate_id" ] && { [ -z "$candidate_workspace" ] || [ "$candidate_workspace" = "$PREPARE_WORKCOPY" ]; }; then
        marker=$("$SBX" exec "$PREPARE_NAME" -- cat /etc/firstmate-owner 2>/dev/null || true)
        if [ -z "$marker" ]; then
          write_owner_marker "$PREPARE_NAME" "$PREPARE_TASK" "$PREPARE_HOST" "$candidate_id" "$PREPARE_NONCE" \
            >/dev/null 2>&1 || true
        fi
        if verify_owner_marker "$PREPARE_NAME" "$PREPARE_TASK" "$PREPARE_HOST" "$candidate_id" "$PREPARE_NONCE"; then
          if "$SBX" rm --force "$PREPARE_NAME" >/dev/null 2>&1 \
             && ! inventory_match "$PREPARE_NAME" "$candidate_id" >/dev/null 2>&1; then
            removed=1
          else
            sandbox_present=1
          fi
        else
          sandbox_present=1
        fi
      else
        sandbox_present=1
      fi
    fi
  fi
  if [ "$sandbox_present" = 0 ] && [ "$removed" = 1 -o -z "$candidate" ]; then
    if [ -d "$PREPARE_WORKCOPY" ] && [ ! -L "$PREPARE_WORKCOPY" ] \
       && [ "$PREPARE_WORKCOPY" = "$PREPARE_TASK_TMP/sandbox/workcopy" ]; then
      rm -rf "$PREPARE_WORKCOPY"
    fi
    if prepare_owner_matches; then
      rm -f "$PREPARE_OWNER"
    fi
    if [ -n "$PREPARE_RESERVATION" ]; then
      release_reservation "$PREPARE_RESERVATION" "$PREPARE_TASK" "$PREPARE_HOST" \
        "$PREPARE_NAME" "$PREPARE_NONCE" "$PREPARE_OWNER" || true
    fi
  elif prepare_owner_matches; then
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sidecar_update "$PREPARE_OWNER" '.lifecycle="failed" | .failure="sandbox preparation failed; inspect ownership before retry" | .updated_at=$now' \
      --arg now "$now" || true
    echo "warning: sandbox preparation failed with an owned sandbox still present; preserving its journal for exact recovery" >&2
  fi
}

prepare() { # <task>
  local id=$1 meta host profile name nonce owner source tasktmp workcopy branch commit host_data brief_source
  local cpus memory max sbx_obj sbx_id now tmp token github_token openai_auth
  validate_task_meta "$id"
  enabled || die "sandbox rollout is disabled; $ENABLE_FILE must contain exactly v1"
  meta="$STATE/$id.meta"
  host=$(meta_exact "$meta" sandbox_host)
  profile=$(meta_exact "$meta" sandbox_profile)
  name=$(meta_exact "$meta" sandbox_name)
  nonce=$(meta_exact "$meta" sandbox_nonce)
  owner=$(meta_exact "$meta" sandbox_owner)
  source=$(meta_exact "$meta" worktree) || die "sandbox task has no exact worktree"
  tasktmp=$(meta_exact "$meta" tasktmp) || die "sandbox task has no exact task temp root"
  [ "$tasktmp" = "/tmp/fm-$id" ] || die "sandbox task temp root is not task-bound"
  ensure_task_root "$tasktmp"
  [ -d "$source" ] && [ ! -L "$source" ] || die "sandbox source worktree is missing or symlinked"
  [ "$(git -C "$source" rev-parse --show-toplevel 2>/dev/null)" = "$source" ] \
    || die "sandbox source is not an exact git worktree root"
  host_data=$(host_json "$host") || exit 1
  doctor doctor --host "$host" >/dev/null || die "sandbox host $host failed capability doctor"
  cpus=$(jq -r .cpus <<EOF
$host_data
EOF
)
  memory=$(jq -r .memory <<EOF
$host_data
EOF
)
  max=$(jq -r .maxConcurrent <<EOF
$host_data
EOF
)
  jq -e --arg profile "$PROFILE" '.profiles | index($profile) != null' >/dev/null <<EOF \
    || die "sandbox host $host does not permit profile $PROFILE"
$host_data
EOF
  PREPARE_TASK=$id
  PREPARE_OWNER=$owner
  PREPARE_TASK_TMP=$tasktmp
  PREPARE_WORKCOPY="$tasktmp/sandbox/workcopy"
  PREPARE_NAME=$name
  PREPARE_HOST=$host
  PREPARE_NONCE=$nonce
  acquire_host_lock "$host"
  if [ -f "$owner" ]; then
    sbx_id=$(jq -r '.sandbox_id // empty' "$owner")
    [ -n "$sbx_id" ] || die "existing sandbox journal has no stable sandbox id"
    reserve_host_slot "$id" "$host" "$name" "$nonce" "$owner" "$max" 1
    inventory_match "$name" "$sbx_id" >/dev/null || die "existing sandbox inventory does not match its ownership journal"
    verify_owner_marker "$name" "$id" "$host" "$sbx_id" "$nonce" \
      || die "existing sandbox ownership marker does not match"
    verify_policy "$name" || die "existing sandbox policy does not meet the task profile"
    openai_auth=$(jq -r '.openai_auth // "absent"' "$owner")
    if [ "$openai_auth" != sandbox-scoped ]; then
      token=${FM_SANDBOX_OPENAI_API_KEY:-}
      [ -n "$token" ] || die "sandbox has no task-scoped OpenAI credential; provide ephemeral FM_SANDBOX_OPENAI_API_KEY"
      printf '%s' "$token" | "$SBX" secret set "$name" openai >/dev/null
      # shellcheck disable=SC2016
      sidecar_update "$owner" '.openai_auth="sandbox-scoped" | .updated_at=$now' \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    github_token=${FM_SANDBOX_GITHUB_TOKEN:-}
    if [ -n "$github_token" ] && [ "$(jq -r '.github_auth // "absent"' "$owner")" != sandbox-scoped ]; then
      printf '%s' "$github_token" | "$SBX" secret set "$name" github >/dev/null
      # shellcheck disable=SC2016
      sidecar_update "$owner" '.github_auth="sandbox-scoped" | .updated_at=$now' \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    return 0
  fi
  PREPARE_ROLLBACK_ACTIVE=1
  reserve_host_slot "$id" "$host" "$name" "$nonce" "$owner" "$max" 0
  token=${FM_SANDBOX_OPENAI_API_KEY:-}
  [ -n "$token" ] || die "new sandbox requires ephemeral FM_SANDBOX_OPENAI_API_KEY; subscription OAuth is unsupported"
  github_token=${FM_SANDBOX_GITHUB_TOKEN:-}
  workcopy="$tasktmp/sandbox/workcopy"
  [ ! -e "$tasktmp/sandbox" ] || die "sandbox task directory already exists without an ownership journal"
  (umask 077; mkdir "$tasktmp/sandbox")
  git clone --quiet --no-local --no-hardlinks "$source" "$workcopy"
  branch=$(git -C "$source" symbolic-ref --quiet --short HEAD) || die "sandbox source must be on a named branch"
  commit=$(git -C "$source" rev-parse HEAD)
  mkdir -p "$workcopy/.firstmate"
  brief_source=$(meta_exact "$meta" sandbox_brief) || die "sandbox task has no exact brief metadata"
  [ -f "$brief_source" ] && [ ! -L "$brief_source" ] || die "sandbox brief is missing or symlinked"
  cp "$brief_source" "$workcopy/.firstmate/brief.md"
  : > "$workcopy/.firstmate/status"
  printf '%s\n' '.firstmate/' >> "$workcopy/.git/info/exclude"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp "${owner}.tmp.XXXXXX")
  jq -n --arg schema "$SCHEMA" --arg task "$id" --arg host "$host" \
    --arg hostName "$(actual_hostname)" --arg name "$name" --arg nonce "$nonce" \
    --arg profile "$profile" --arg workcopy "$workcopy" --arg source "$source" \
    --arg branch "$branch" --arg commit "$commit" --arg now "$now" \
    --argjson cpus "$cpus" --arg memory "$memory" \
    '{schema:$schema,task_id:$task,host_id:$host,host_name:$hostName,
      sandbox_name:$name,sandbox_id:null,nonce:$nonce,profile:$profile,
      workcopy:$workcopy,source_worktree:$source,source_branch:$branch,
      source_commit:$commit,synced_commit:$commit,limits:{cpus:$cpus,memory:$memory},
      lifecycle:"creating",openai_auth:"absent",github_auth:"absent",
      host_reservation:$nonce,
      created_at:$now,updated_at:$now}' > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$owner"
  DOCKER_SANDBOXES_KIT_ALLOW_LOCAL=1 "$SBX" create --name "$name" --cpus "$cpus" --memory "$memory" \
    --no-share-skills --kit "$KIT" codex "$workcopy" >/dev/null
  sbx_obj=$(inventory_match "$name") || die "created sandbox is absent or ambiguous in sbx inventory"
  sbx_id=$(jq -r .id <<EOF
$sbx_obj
EOF
)
  [ -n "$sbx_id" ] && [ "$sbx_id" != null ] || die "created sandbox has no stable id"
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.sandbox_id=$id | .lifecycle="created" | .updated_at=$now' \
    --arg id "$sbx_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_owner_marker "$name" "$id" "$host" "$sbx_id" "$nonce" \
    || die "could not publish immutable ownership marker inside sandbox"
  verify_owner_marker "$name" "$id" "$host" "$sbx_id" "$nonce" \
    || die "sandbox ownership marker could not be verified"
  verify_policy "$name" || die "sandbox policy does not meet $profile"
  printf '%s' "$token" | "$SBX" secret set "$name" openai >/dev/null
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.openai_auth="sandbox-scoped" | .updated_at=$now' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$github_token" ]; then
    printf '%s' "$github_token" | "$SBX" secret set "$name" github >/dev/null
    # shellcheck disable=SC2016
    sidecar_update "$owner" '.github_auth="sandbox-scoped" | .updated_at=$now' \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    # shellcheck disable=SC2016
      sidecar_update "$owner" '.github_auth="absent" | .updated_at=$now' \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  PREPARE_ROLLBACK_ACTIVE=0
}

sync_commits() { # <task>
  local id=$1 owner source workcopy branch synced head source_head
  owner=$(owner_path "$id")
  source=$(jq -r .source_worktree "$owner")
  workcopy=$(jq -r .workcopy "$owner")
  branch=$(jq -r .source_branch "$owner")
  synced=$(jq -r .synced_commit "$owner")
  [ -d "$source" ] && [ ! -L "$source" ] && [ -d "$workcopy" ] && [ ! -L "$workcopy" ] || return 1
  [ -z "$(git -C "$workcopy" status --porcelain)" ] || return 1
  head=$(git -C "$workcopy" rev-parse HEAD) || return 1
  git -C "$workcopy" merge-base --is-ancestor "$synced" "$head" || return 1
  source_head=$(git -C "$source" rev-parse HEAD) || return 1
  [ "$source_head" = "$synced" ] || return 1
  [ -z "$(git -C "$source" status --porcelain)" ] || return 1
  if [ "$head" != "$synced" ]; then
    git -C "$source" fetch --quiet "$workcopy" "$branch"
    git -C "$source" merge --quiet --ff-only FETCH_HEAD
  fi
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.synced_commit=$head | .updated_at=$now' \
    --arg head "$head" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mirror_status() { # <task> <line>
  local id=$1 line=$2 verb
  [ "${#line}" -le 1024 ] || return 1
  case "$line" in *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']*) return 1 ;; esac
  verb=${line%%:*}
  case "$verb" in working|needs-decision|blocked|paused|done|failed|resolved) : ;; *) return 1 ;; esac
  case "$verb" in
    done|needs-decision|blocked|failed)
      if ! sync_commits "$id"; then
        printf 'blocked: sandbox committed-work sync failed; inspect %s\n' "$(owner_path "$id")" >> "$STATE/$id.status"
        return 1
      fi
      ;;
  esac
  printf '%s\n' "$line" >> "$STATE/$id.status"
}

bridge_loop() { # <task>
  local id=$1 owner workcopy status_file offset=0 size line turn_seen=0
  owner=$(owner_path "$id")
  workcopy=$(jq -r .workcopy "$owner")
  status_file="$workcopy/.firstmate/status"
  while :; do
    if [ -f "$status_file" ] && [ ! -L "$status_file" ]; then
      size=$(wc -c < "$status_file" | tr -d ' ')
      if [ "$size" -lt "$offset" ]; then offset=0; fi
      if [ "$size" -gt "$offset" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] || mirror_status "$id" "$line" || true
        done < <(tail -c "+$((offset + 1))" "$status_file")
        offset=$size
      fi
    fi
    if [ -f "$workcopy/.firstmate/turn-ended" ]; then
      size=$(stat -c %Y "$workcopy/.firstmate/turn-ended" 2>/dev/null || echo 0)
      if [ "$size" != "$turn_seen" ]; then
        sync_commits "$id" || true
        touch "$STATE/$id.turn-ended"
        turn_seen=$size
      fi
    fi
    sleep 1
  done
}

run_task() { # <task>
  local id=$1 meta owner host name nonce sbx_id workcopy brief model effort prompt bridge_pid rc=0
  local -a args
  validate_task_meta "$id"
  prepare "$id"
  meta="$STATE/$id.meta"
  owner=$(owner_path "$id")
  host=$(meta_exact "$meta" sandbox_host)
  name=$(meta_exact "$meta" sandbox_name)
  nonce=$(meta_exact "$meta" sandbox_nonce)
  sbx_id=$(jq -r .sandbox_id "$owner")
  workcopy=$(jq -r .workcopy "$owner")
  brief="$workcopy/.firstmate/brief.md"
  model=$(meta_exact "$meta" model)
  effort=$(meta_exact "$meta" effort)
  inventory_match "$name" "$sbx_id" >/dev/null || die "sandbox inventory no longer matches task ownership"
  verify_owner_marker "$name" "$id" "$host" "$sbx_id" "$nonce" || die "sandbox ownership verification failed before run"
  verify_policy "$name" || die "sandbox policy verification failed before run"
  prompt=$({
    printf '%s\n' 'SANDBOX CONTROL OVERRIDE:'
    printf '%s\n' '- Host-private paths in the brief are intentionally unavailable.'
    printf '%s\n' '- Append lifecycle lines to .firstmate/status instead of the host status path.'
    printf '%s\n' '- Commit before terminal status; committed work is synchronized to the ordinary task worktree.'
    printf '%s\n' '- Scopey is advisory and cannot stop work that remains within the brief.'
    "$FM_ROOT/bin/fm-operational-input.sh" encode launch-brief < "$brief"
  })
  args=(--dangerously-bypass-approvals-and-sandbox)
  [ "$model" = default ] || args+=(--model "$model")
  [ "$effort" = default ] || args+=(-c "model_reasoning_effort=\"$effort\"")
  args+=(-c 'notify=["bash","-c","touch .firstmate/turn-ended"]' "$prompt")
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.lifecycle="running" | .updated_at=$now' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bridge_loop "$id" &
  bridge_pid=$!
  trap 'kill "$bridge_pid" 2>/dev/null || true; wait "$bridge_pid" 2>/dev/null || true' EXIT INT TERM
  "$SBX" run --name "$name" -- "${args[@]}" || rc=$?
  kill "$bridge_pid" 2>/dev/null || true
  wait "$bridge_pid" 2>/dev/null || true
  trap - EXIT INT TERM
  sync_commits "$id" || true
  snapshot_network_log "$id" "$name" || true
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.lifecycle="stopped" | .last_exit=$rc | .updated_at=$now' \
    --argjson rc "$rc" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  return "$rc"
}

status_task() { # <task> [--json]
  local id=$1 json=${2:-} owner out
  validate_task_meta "$id"
  owner=$(owner_path "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || die "no sandbox ownership journal for task $id"
  out=$(jq -c '. + {inventory:"unchecked"}' "$owner")
  if inventory_match "$(jq -r .sandbox_name "$owner")" "$(jq -r .sandbox_id "$owner")" >/dev/null 2>&1; then
    out=$(jq -c '.inventory="exact"' <<EOF
$out
EOF
)
  else
    out=$(jq -c '.inventory="missing-or-ambiguous"' <<EOF
$out
EOF
)
  fi
  if [ "$json" = --json ]; then printf '%s\n' "$out"; else jq . <<EOF
$out
EOF
  fi
}

lab_proof() { # <task> <host-sentinel> <result-file>
  local id=$1 sentinel=$2 result=$3 meta owner name sbx_id source session output tmp
  [ "${FM_SANDBOX_HERDR_LAB_PROOF:-}" = 1 ] || die "lab-proof requires explicit FM_SANDBOX_HERDR_LAB_PROOF=1"
  validate_task_meta "$id"
  meta="$STATE/$id.meta"
  session=$(meta_exact "$meta" herdr_session) || die "lab-proof requires exact Herdr session metadata"
  case "$session" in fm-lab-*) : ;; *) die "lab-proof refuses non-lab Herdr session $session" ;; esac
  owner=$(owner_path "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || die "lab-proof requires prepared sandbox ownership"
  source=$(jq -r .source_worktree "$owner")
  [ -f "$source/.firstmate-sandbox-proof-fixture" ] \
    && [ "$(cat "$source/.firstmate-sandbox-proof-fixture")" = v1 ] \
    || die "lab-proof refuses a non-fixture repository"
  [ -f "$sentinel" ] && [ ! -L "$sentinel" ] || die "lab-proof requires a regular host sentinel"
  case "$result" in "$STATE/$id.sandbox-proof.json") : ;; *) die "lab-proof result must be task-bound state" ;; esac
  name=$(jq -r .sandbox_name "$owner")
  sbx_id=$(jq -r .sandbox_id "$owner")
  inventory_match "$name" "$sbx_id" >/dev/null || die "lab-proof sandbox inventory mismatch"
  # shellcheck disable=SC2016
  output=$("$SBX" exec "$name" -- sh -c '
    set -eu
    sentinel=$1
    [ ! -r "$sentinel" ]
    ! curl -fsS --max-time 5 https://portal.arcs.health/ >/dev/null 2>&1
    ! curl -fsS --max-time 5 http://192.168.0.6/ >/dev/null 2>&1
    [ -S /var/run/docker.sock ]
    docker info >/dev/null
    printf "%s\n" "edited inside disposable microVM clone" >> proof-output.txt
    docker build -q -t fm-sandbox-proof:v1 . >/dev/null
    docker run --rm fm-sandbox-proof:v1
    git config user.name "Firstmate Sandbox Proof"
    git config user.email "sandbox-proof@example.invalid"
    git add proof-output.txt
    git commit -qm sandbox-proof
    printf "%s\n" "{\"hostSentinelBlocked\":true,\"privateNetworkBlocked\":true,\"hostDockerSocketMounted\":false,\"privateDockerUsable\":true,\"cloneEditBuildTest\":true}"
  ' sh "$sentinel") || die "microVM fixture proof failed"
  printf '%s' "$output" | jq -e '
    .hostSentinelBlocked == true
    and .privateNetworkBlocked == true
    and .hostDockerSocketMounted == false
    and .privateDockerUsable == true
    and .cloneEditBuildTest == true
  ' >/dev/null || die "microVM fixture proof returned invalid evidence"
  sync_commits "$id" || die "microVM fixture proof could not sync its committed edit"
  tmp=$(mktemp "${result}.tmp.XXXXXX")
  jq -n --arg schema fm-sandbox-herdr-proof.v1 --arg task "$id" --arg session "$session" \
    --arg host "$(jq -r .host_id "$owner")" --arg sandbox "$sbx_id" --argjson checks "$output" \
    '{schema:$schema,task_id:$task,herdr_session:$session,host_id:$host,sandbox_id:$sandbox,checks:$checks}' > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$result"
}

cleanup() { # <task>
  local id=$1 meta owner host name nonce sbx_id lifecycle obj marker workcopy tasktmp
  validate_task_meta "$id"
  meta="$STATE/$id.meta"
  owner=$(owner_path "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || die "missing exact sandbox ownership journal for task $id"
  jq -e --arg schema "$SCHEMA" --arg task "$id" '.schema == $schema and .task_id == $task' "$owner" >/dev/null \
    || die "sandbox ownership journal identity mismatch"
  host=$(meta_exact "$meta" sandbox_host)
  name=$(meta_exact "$meta" sandbox_name)
  nonce=$(meta_exact "$meta" sandbox_nonce)
  sbx_id=$(jq -r '.sandbox_id // empty' "$owner")
  lifecycle=$(jq -r .lifecycle "$owner")
  [ -n "$sbx_id" ] || die "sandbox ownership journal lacks a stable id"
  [ "$(jq -r .host_id "$owner")" = "$host" ] \
    && [ "$(jq -r .sandbox_name "$owner")" = "$name" ] \
    && [ "$(jq -r .nonce "$owner")" = "$nonce" ] \
    || die "sandbox meta and ownership journal disagree"
  if [ "$lifecycle" = removed ]; then
    if inventory_match "$name" "$sbx_id" >/dev/null 2>&1; then
      die "sandbox marked removed is still present"
    fi
    return 0
  fi
  obj=$(inventory_match "$name" "$sbx_id") || die "sandbox inventory is missing or ambiguous; refusing destructive cleanup"
  [ "$(jq -r .id <<EOF
$obj
EOF
)" = "$sbx_id" ] || die "sandbox stable id mismatch"
  marker=$("$SBX" exec "$name" -- cat /etc/firstmate-owner 2>/dev/null) || die "cannot read immutable sandbox ownership marker"
  jq -e --arg schema "$SCHEMA" --arg task "$id" --arg host "$host" --arg id "$sbx_id" --arg nonce "$nonce" \
    '.schema == $schema and .task_id == $task and .host_id == $host and .sandbox_id == $id and .nonce == $nonce' \
    >/dev/null <<EOF || die "immutable sandbox ownership marker mismatch"
$marker
EOF
  snapshot_network_log "$id" "$name" || true
  "$SBX" rm --force "$name"
  if inventory_match "$name" "$sbx_id" >/dev/null 2>&1; then
    die "sandbox still exists after bounded removal"
  fi
  # shellcheck disable=SC2016
  sidecar_update "$owner" '.lifecycle="removed" | .updated_at=$now' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  workcopy=$(jq -r .workcopy "$owner")
  tasktmp=$(meta_exact "$meta" tasktmp)
  case "$workcopy" in "$tasktmp/sandbox/workcopy") : ;; *) die "recorded work copy is outside task temp root" ;; esac
}

case "${1:-}" in
  -h|--help|'') usage ;;
  inventory) shift; inventory "$@" ;;
  doctor) doctor "$@" ;;
  identity) [ "$#" = 3 ] || die "identity requires task-id and host-id"; identity "$2" "$3" ;;
  prepare) [ "$#" = 2 ] || die "prepare requires task-id"; prepare "$2" ;;
  run) [ "$#" = 2 ] || die "run requires task-id"; run_task "$2" ;;
  status) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "status requires task-id [--json]"; status_task "$2" "${3:-}" ;;
  lab-proof) [ "$#" = 4 ] || die "lab-proof requires task-id, host-sentinel, and result-file"; lab_proof "$2" "$3" "$4" ;;
  cleanup) [ "$#" = 2 ] || die "cleanup requires task-id"; cleanup "$2" ;;
  *) die "unknown command: $1" ;;
esac
