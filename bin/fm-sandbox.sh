#!/usr/bin/env bash
# Own the inert Docker Sandboxes Stage 1 lifecycle journal.
#
# Usage:
#   fm-sandbox.sh inventory [--json]
#   fm-sandbox.sh doctor --host <id> [--json]
#   fm-sandbox.sh identity <task-id> <host-id>
#   fm-sandbox.sh prepare <task-id> --host <id> --name <name> --nonce <32-hex> --source <worktree> --task-root <path>
#   fm-sandbox.sh commit <task-id> --sandbox-id <stable-id>
#   fm-sandbox.sh rollback <task-id>
#   fm-sandbox.sh cleanup-begin <task-id> [--json]
#   fm-sandbox.sh cleanup-commit <task-id> --sandbox-id <stable-id>
#   fm-sandbox.sh recover <task-id> [--json]
#   fm-sandbox.sh status <task-id> [--json]
#
# Stage 1 never creates, runs, enters, stops, or removes a Docker Sandbox.
# It has no worker-runtime, Herdr, harness, credential, Docker, or remote-host
# integration. It records read-only host capability facts, validates the exact
# deny-by-default contract in config/sandbox-hosts.json, makes a committed-only
# disposable clone, and owns local lifecycle transactions for a later Stage 2.
#
# prepare atomically claims one configured host slot and publishes lifecycle
# `preparing` before it creates the disposable clone. It commits `prepared`
# only after the clone exactly matches the recorded source commit. commit binds
# one stable sandbox id without contacting sbx. rollback is allowed only before
# that id is committed. cleanup-begin emits the immutable receipt that Stage 2
# must verify before any external removal; cleanup-commit only finalizes local
# state after Stage 2 supplies the same stable id. recover resumes only local
# `preparing`, `commit_pending`, `rollback_pending`, or `cleanup_finalizing`
# transactions and never guesses external sandbox state.
#
# The ownership journal is state/<task-id>.sandbox.json. Host reservations live
# below a private coordination root and are counted while holding the existing
# Firstmate crash-recoverable lock primitive. Destructive local cleanup requires
# exact task, host, name, nonce, stable-id, workcopy, and reservation agreement.
# A label, PID, path alone, sole inventory item, or ambient session is never
# ownership evidence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HOSTS_FILE="${FM_SANDBOX_HOSTS_OVERRIDE:-$CONFIG/sandbox-hosts.json}"
COORD_ROOT="${FM_SANDBOX_COORDINATION_ROOT:-$STATE/sandbox-coordination}"
TASK_ROOT_BASE="${FM_SANDBOX_TASK_ROOT_BASE:-/tmp}"
KVM_PATH="${FM_SANDBOX_KVM_PATH:-/dev/kvm}"
SBX="${FM_SANDBOX_SBX:-sbx}"
JOURNAL_SCHEMA=fm-sandbox-journal.v1
RESERVATION_SCHEMA=fm-sandbox-reservation.v1
LOCK_PATH=
LOCK_HELD=0

usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then
    LOCK_HELD=0
    fm_lock_release "$LOCK_PATH" || true
  fi
}

on_exit() {
  local status=$?
  release_lock
  return "$status"
}

trap on_exit EXIT

valid_id() {
  [[ ${1:-} =~ ^[a-zA-Z0-9_:-]+$ ]]
}

valid_nonce() {
  [[ ${1:-} =~ ^[a-f0-9]{32}$ ]]
}

utc_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

journal_path() {
  printf '%s/%s.sandbox.json\n' "$STATE" "$1"
}

validate_hosts_file() {
  [ -f "$HOSTS_FILE" ] && [ ! -L "$HOSTS_FILE" ] || {
    echo "error: missing sandbox host inventory at $HOSTS_FILE" >&2
    return 1
  }
  jq -e '
    .version == 1
    and .stage == 1
    and .launchEnabled == false
    and .policy.id == "model-forge-packages-v1"
    and .policy.mode == "deny-all"
    and ((.policy.allowedDomains | sort) == ([
      "api.openai.com", "github.com", "api.github.com",
      "registry.npmjs.org", "registry-1.docker.io"
    ] | sort))
    and ((.policy.deniedDomains | sort) == ([
      "*.arcs.health", "*.zeta.health", "*.covenant.clinic",
      "*.home.arcs.internal", "*.internal", "dev", "srv", "svc", "gpu"
    ] | sort))
    and .policy.denyPrivateNetworks == true
    and .policy.hostDockerSocket == false
    and .policy.hostMounts == []
    and .policy.workspaceMode == "disposable-committed-clone"
    and .policy.secretMode == "sandbox-scoped-ephemeral"
    and .policy.persistentAuth == false
    and .policy.sharedSkills == false
    and (.hosts | type == "array" and length > 0)
    and ([.hosts[].id] | length == (unique | length))
    and all(.hosts[];
      (.id | type == "string" and test("^[a-zA-Z0-9_:-]+$"))
      and (.role | IN("dev", "agt", "gpu", "svc", "srv"))
      and (.transport | IN("local", "ssh-fixed"))
      and (.hostname | type == "string" and test("^[a-zA-Z0-9._-]+$"))
      and .enabled == false
      and (.priority | type == "number" and floor == . and . >= 0)
      and (.cpus | type == "number" and floor == . and . >= 1 and . <= 64)
      and (.memory | type == "string" and test("^[1-9][0-9]*(MiB|GiB)$"))
      and (.maxConcurrent | type == "number" and floor == . and . >= 1 and . <= 64)
      and .profile == "model-forge-packages-v1"
      and .authMode == "ephemeral-only"
      and .privateNetworkGrant == false
    )
  ' "$HOSTS_FILE" >/dev/null || {
    echo "error: invalid inert Stage 1 sandbox host inventory at $HOSTS_FILE" >&2
    return 1
  }
}

host_json() {
  local id=$1 count
  validate_hosts_file || return 1
  count=$(jq --arg id "$id" '[.hosts[] | select(.id == $id)] | length' "$HOSTS_FILE")
  [ "$count" = 1 ] || {
    echo "error: sandbox host '$id' is absent or ambiguous in $HOSTS_FILE" >&2
    return 1
  }
  jq -c --arg id "$id" '.hosts[] | select(.id == $id)' "$HOSTS_FILE"
}

actual_hostname() {
  if [ -n "${FM_SANDBOX_HOSTNAME:-}" ]; then
    printf '%s\n' "$FM_SANDBOX_HOSTNAME"
  else
    hostname -f 2>/dev/null || hostname
  fi
}

sbx_version() {
  "$SBX" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

capability_json() {
  local host=$1 id role transport configured actual priority cpus memory max
  local sbx_present=false version='' kvm=false reason
  id=$(jq -r .id <<EOF
$host
EOF
)
  role=$(jq -r .role <<EOF
$host
EOF
)
  transport=$(jq -r .transport <<EOF
$host
EOF
)
  configured=$(jq -r .hostname <<EOF
$host
EOF
)
  priority=$(jq -r .priority <<EOF
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
  actual=$(actual_hostname)
  if [ "$transport" = local ] && { [ "$actual" = "$configured" ] || [ "${actual%%.*}" = "${configured%%.*}" ]; }; then
    if command -v "$SBX" >/dev/null 2>&1; then
      sbx_present=true
      version=$(sbx_version || true)
    fi
    [ -c "$KVM_PATH" ] && [ -r "$KVM_PATH" ] && [ -w "$KVM_PATH" ] && kvm=true
  fi
  if [ "$role" = srv ]; then
    reason=production-role-deferred
  elif [ "$role" = gpu ]; then
    reason=gpu-role-deferred
  elif [ "$transport" != local ]; then
    reason=remote-transport-deferred
  elif [ "$actual" != "$configured" ] && [ "${actual%%.*}" != "${configured%%.*}" ]; then
    reason=not-current-host
  else
    reason=stage1-journal-only
  fi
  jq -nc --arg id "$id" --arg role "$role" --arg transport "$transport" \
    --arg configured "$configured" --arg actual "$actual" --arg version "$version" \
    --arg memory "$memory" --arg reason "$reason" --argjson priority "$priority" \
    --argjson cpus "$cpus" --argjson max "$max" --argjson sbx "$sbx_present" \
    --argjson kvm "$kvm" \
    '{id:$id,role:$role,transport:$transport,configuredHostname:$configured,
      actualHostname:$actual,configuredEnabled:false,priority:$priority,
      limits:{cpus:$cpus,memory:$memory,maxConcurrent:$max},
      capabilities:{sbxPresent:$sbx,sbxVersion:$version,kvm:$kvm,
        daemonReachable:null,denyAllPolicy:null},
      stage:1,launchSupported:false,eligible:false,refusalReason:$reason}'
}

inventory() {
  local json=false host rows='[]' policy
  case "${1:-}" in
    '') ;;
    --json) json=true ;;
    *) die "inventory accepts only --json" ;;
  esac
  validate_hosts_file || exit 1
  policy=$(jq -c .policy "$HOSTS_FILE")
  while IFS= read -r host; do
    rows=$(jq -nc --argjson rows "$rows" --argjson row "$(capability_json "$host")" '$rows + [$row]')
  done < <(jq -c '.hosts[]' "$HOSTS_FILE")
  if [ "$json" = true ]; then
    jq -n --arg schema fm-sandbox-inventory.v1 --argjson policy "$policy" --argjson hosts "$rows" \
      '{schema:$schema,stage:1,launchEnabled:false,policy:$policy,hosts:$hosts}'
  else
    printf 'HOST\tROLE\tTRANSPORT\tPRIORITY\tCPUS\tMEMORY\tMAX\tLAUNCH\tREASON\n'
    jq -r '.[] | [.id,.role,.transport,.priority,.limits.cpus,.limits.memory,.limits.maxConcurrent,.launchSupported,.refusalReason] | @tsv' <<EOF
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
  result=$(capability_json "$host")
  if [ "$json" = true ]; then
    printf '%s\n' "$result"
  else
    jq -r '"host=\(.id) role=\(.role) transport=\(.transport) launch_supported=false refusal=\(.refusalReason) sbx=\(.capabilities.sbxVersion // \"missing\") kvm=\(.capabilities.kvm) cpus=\(.limits.cpus) memory=\(.limits.memory) max=\(.limits.maxConcurrent)"' <<EOF
$result
EOF
  fi
}

identity() {
  local task=$1 host=$2 nonce short safe_task
  if ! valid_id "$task" || ! valid_id "$host"; then
    die "invalid sandbox identity request"
  fi
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  valid_nonce "$nonce" || die "could not generate sandbox ownership nonce"
  short=${nonce:0:12}
  safe_task=$(printf '%s' "$task" | tr ':_' '--')
  printf '%s\t%s\n' "fm-${safe_task:0:30}-$short" "$nonce"
}

ensure_owned_dir() {
  local path=$1 parent
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || die "unsafe sandbox directory: $path"
  else
    parent=$(dirname "$path")
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ -O "$parent" ] || die "unsafe sandbox directory parent: $parent"
    (umask 077; mkdir "$path") || die "could not create sandbox directory: $path"
  fi
  chmod 700 "$path" || die "could not restrict sandbox directory: $path"
}

ensure_state_root() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -O "$STATE" ] \
    || die "sandbox state root is unsafe: $STATE"
}

ensure_coordination() {
  local host=$1
  ensure_state_root
  ensure_owned_dir "$COORD_ROOT"
  ensure_owned_dir "$COORD_ROOT/$host"
  ensure_owned_dir "$COORD_ROOT/$host/reservations"
}

acquire_host_lock() {
  local host=$1
  ensure_coordination "$host"
  if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  LOCK_PATH="$COORD_ROOT/$host/lock"
  fm_lock_acquire_wait "$LOCK_PATH" || die "could not acquire sandbox host lock for $host"
  LOCK_HELD=1
}

reservation_path() {
  printf '%s/%s/reservations/%s.json\n' "$COORD_ROOT" "$1" "$2"
}

json_update() {
  local path=$1 filter=$2 tmp
  shift 2
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if jq "$@" "$filter" "$path" > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

journal_valid() {
  local path=$1 task=$2
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  jq -e --arg schema "$JOURNAL_SCHEMA" --arg task "$task" '
    .schema == $schema and .stage == 1 and .task_id == $task
    and (.host_id | type == "string" and test("^[a-zA-Z0-9_:-]+$"))
    and (.sandbox_name | type == "string" and test("^[a-zA-Z0-9_:-]+$"))
    and (.nonce | type == "string" and test("^[a-f0-9]{32}$"))
    and (.sandbox_id == null or (.sandbox_id | type == "string" and test("^[a-zA-Z0-9_:-]+$")))
    and (.profile == "model-forge-packages-v1")
    and (.source_worktree | type == "string" and length > 0)
    and (.source_commit | type == "string" and test("^[a-f0-9]{40,64}$"))
    and (.task_root | type == "string" and length > 0)
    and (.workcopy | type == "string" and length > 0)
    and (.reservation | type == "string" and length > 0)
    and (.limits.cpus | type == "number")
    and (.limits.memory | type == "string")
    and (.limits.maxConcurrent | type == "number")
    and (.lifecycle | IN("preparing","prepared","commit_pending","committed",
      "rollback_pending","rolled_back","cleanup_pending","cleanup_finalizing",
      "cleanup_releasing","cleaned"))
  ' "$path" >/dev/null 2>&1
}

reservation_matches() {
  local path=$1 journal=$2 task host name nonce owner
  task=$(jq -r .task_id "$journal")
  host=$(jq -r .host_id "$journal")
  name=$(jq -r .sandbox_name "$journal")
  nonce=$(jq -r .nonce "$journal")
  owner=$(journal_path "$task")
  [ "$path" = "$(reservation_path "$host" "$nonce")" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  jq -e --arg schema "$RESERVATION_SCHEMA" --arg task "$task" --arg host "$host" \
    --arg name "$name" --arg nonce "$nonce" --arg owner "$owner" '
      .schema == $schema and .task_id == $task and .host_id == $host
      and .sandbox_name == $name and .nonce == $nonce and .owner == $owner
      and .state == "claimed"
      and (.sandbox_id == null or (.sandbox_id | type == "string" and test("^[a-zA-Z0-9_:-]+$")))
    ' "$path" >/dev/null 2>&1
}

reservation_sandbox_id_matches() {
  local path=$1 journal=$2 journal_id reservation_id
  journal_id=$(jq -r '.sandbox_id // empty' "$journal")
  reservation_id=$(jq -r '.sandbox_id // empty' "$path")
  [ "$journal_id" = "$reservation_id" ]
}

write_reservation() {
  local path=$1 task=$2 host=$3 name=$4 nonce=$5 owner=$6 max=$7 tmp
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if jq -n --arg schema "$RESERVATION_SCHEMA" --arg task "$task" --arg host "$host" \
      --arg name "$name" --arg nonce "$nonce" --arg owner "$owner" --arg now "$(utc_now_iso)" \
      --argjson max "$max" \
      '{schema:$schema,task_id:$task,host_id:$host,sandbox_name:$name,sandbox_id:null,
        nonce:$nonce,owner:$owner,state:"claimed",max_concurrent:$max,created_at:$now,updated_at:$now}' \
      > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

claim_host_slot() {
  local task=$1 host=$2 name=$3 nonce=$4 owner=$5 max=$6 path file active=0
  path=$(reservation_path "$host" "$nonce")
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ ! -f "$owner" ] || ! reservation_matches "$path" "$owner"; then
      echo "error: sandbox reservation identity mismatch: $path" >&2
      return 1
    fi
    return 0
  fi
  for file in "$COORD_ROOT/$host/reservations"/*.json; do
    [ -e "$file" ] || continue
    if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -O "$file" ]; then
      echo "error: unsafe sandbox reservation entry: $file" >&2
      return 1
    fi
    jq -e --arg schema "$RESERVATION_SCHEMA" --arg host "$host" \
      '.schema == $schema and .host_id == $host and .state == "claimed"' "$file" >/dev/null \
      || {
        echo "error: malformed sandbox reservation blocks host $host: $file" >&2
        return 1
      }
    active=$((active + 1))
  done
  if [ "$active" -ge "$max" ]; then
    echo "error: sandbox host $host is at configured maxConcurrent=$max" >&2
    return 1
  fi
  write_reservation "$path" "$task" "$host" "$name" "$nonce" "$owner" "$max" \
    || {
      echo "error: could not publish sandbox host reservation" >&2
      return 1
    }
}

release_host_slot() {
  local journal=$1 host nonce path
  host=$(jq -r .host_id "$journal")
  nonce=$(jq -r .nonce "$journal")
  path=$(reservation_path "$host" "$nonce")
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  reservation_matches "$path" "$journal" || die "sandbox reservation identity mismatch during release"
  reservation_sandbox_id_matches "$path" "$journal" \
    || die "sandbox reservation stable id mismatch during release"
  rm -f "$path" || die "could not release sandbox host reservation"
}

resolve_source() {
  local source=$1 real top
  [ -d "$source" ] && [ ! -L "$source" ] || die "sandbox source worktree is missing or symlinked"
  real=$(cd "$source" && pwd -P) || die "sandbox source worktree cannot be resolved"
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || die "sandbox source is not a git worktree"
  top=$(cd "$top" && pwd -P) || die "sandbox source root cannot be resolved"
  [ "$top" = "$real" ] || die "sandbox source is not an exact git worktree root"
  printf '%s\n' "$real"
}

ensure_task_root() {
  local task=$1 requested=$2 base_real parent parent_real root_real
  [ "$(basename "$requested")" = "fm-$task" ] || die "sandbox task root is not task-bound"
  [ -d "$TASK_ROOT_BASE" ] && [ ! -L "$TASK_ROOT_BASE" ] || die "sandbox task-root base is missing or symlinked"
  base_real=$(cd "$TASK_ROOT_BASE" && pwd -P) || die "sandbox task-root base cannot be resolved"
  parent=$(dirname "$requested")
  [ ! -L "$parent" ] || die "sandbox task-root parent is symlinked"
  parent_real=$(cd "$parent" && pwd -P) || die "sandbox task-root parent cannot be resolved"
  [ "$parent_real" = "$base_real" ] || die "sandbox task root is outside its configured base"
  if [ -e "$requested" ] || [ -L "$requested" ]; then
    [ -d "$requested" ] && [ ! -L "$requested" ] && [ -O "$requested" ] || die "sandbox task root is unsafe"
  else
    (umask 077; mkdir "$requested") || die "could not create sandbox task root"
  fi
  chmod 700 "$requested" || die "could not restrict sandbox task root"
  root_real=$(cd "$requested" && pwd -P) || die "sandbox task root cannot be resolved"
  [ "$root_real" = "$base_real/fm-$task" ] || die "sandbox task root canonical identity mismatch"
  printf '%s\n' "$root_real"
}

recorded_paths_safe() {
  local journal=$1 task root workcopy base_real parent_real root_real
  task=$(jq -r .task_id "$journal")
  root=$(jq -r .task_root "$journal")
  workcopy=$(jq -r .workcopy "$journal")
  [ "$(basename "$root")" = "fm-$task" ] || return 1
  [ -d "$TASK_ROOT_BASE" ] && [ ! -L "$TASK_ROOT_BASE" ] || return 1
  base_real=$(cd "$TASK_ROOT_BASE" && pwd -P) || return 1
  [ -d "$root" ] && [ ! -L "$root" ] && [ -O "$root" ] || return 1
  parent_real=$(cd "$(dirname "$root")" && pwd -P) || return 1
  root_real=$(cd "$root" && pwd -P) || return 1
  [ "$parent_real" = "$base_real" ] && [ "$root_real" = "$base_real/fm-$task" ] \
    && [ "$workcopy" = "$root_real/sandbox/workcopy" ]
}

remove_local_copy() {
  local journal=$1 root sandbox
  recorded_paths_safe "$journal" || die "recorded sandbox workcopy boundary is unsafe"
  root=$(jq -r .task_root "$journal")
  sandbox="$root/sandbox"
  if [ ! -e "$sandbox" ] && [ ! -L "$sandbox" ]; then
    return 0
  fi
  [ -d "$sandbox" ] && [ ! -L "$sandbox" ] && [ -O "$sandbox" ] || die "sandbox workcopy directory is unsafe"
  [ "$(cd "$sandbox" && pwd -P)" = "$root/sandbox" ] || die "sandbox workcopy canonical boundary mismatch"
  rm -rf -- "$sandbox"
}

local_copy_absent() {
  local journal=$1 task root workcopy base_real parent_real
  task=$(jq -r .task_id "$journal")
  root=$(jq -r .task_root "$journal")
  workcopy=$(jq -r .workcopy "$journal")
  [ "$(basename "$root")" = "fm-$task" ] || return 1
  [ -d "$TASK_ROOT_BASE" ] && [ ! -L "$TASK_ROOT_BASE" ] || return 1
  base_real=$(cd "$TASK_ROOT_BASE" && pwd -P) || return 1
  parent_real=$(cd "$(dirname "$root")" && pwd -P) || return 1
  [ "$parent_real" = "$base_real" ] && [ "$root" = "$base_real/fm-$task" ] \
    && [ "$workcopy" = "$root/sandbox/workcopy" ] || return 1
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    return 0
  fi
  [ -d "$root" ] && [ ! -L "$root" ] && [ -O "$root" ] \
    && [ ! -e "$root/sandbox" ] && [ ! -L "$root/sandbox" ]
}

terminal_local_state_clean() {
  local journal=$1 reservation
  reservation=$(jq -r .reservation "$journal")
  [ ! -e "$reservation" ] && [ ! -L "$reservation" ] && local_copy_absent "$journal"
}

test_failpoint() {
  if [ "${FM_SANDBOX_TEST_MODE:-}" = 1 ] && [ "${FM_SANDBOX_TEST_FAILPOINT:-}" = "$1" ]; then
    echo "error: simulated sandbox journal crash at $1" >&2
    exit 75
  fi
}

write_initial_journal() {
  local owner=$1 task=$2 host=$3 name=$4 nonce=$5 source=$6 commit=$7 root=$8 workcopy=$9
  local cpus=${10} memory=${11} max=${12} reservation=${13} tmp now
  now=$(utc_now_iso)
  tmp=$(mktemp "${owner}.tmp.XXXXXX") || return 1
  if jq -n --arg schema "$JOURNAL_SCHEMA" --arg task "$task" --arg host "$host" \
      --arg name "$name" --arg nonce "$nonce" --arg source "$source" --arg commit "$commit" \
      --arg root "$root" --arg workcopy "$workcopy" --arg reservation "$reservation" \
      --arg memory "$memory" --arg now "$now" --argjson cpus "$cpus" --argjson max "$max" \
      '{schema:$schema,stage:1,task_id:$task,host_id:$host,sandbox_name:$name,
        sandbox_id:null,nonce:$nonce,profile:"model-forge-packages-v1",
        source_worktree:$source,source_commit:$commit,task_root:$root,workcopy:$workcopy,
        reservation:$reservation,limits:{cpus:$cpus,memory:$memory,maxConcurrent:$max},lifecycle:"preparing",
        created_at:$now,updated_at:$now}' > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$owner"
  else
    rm -f "$tmp"
    return 1
  fi
}

parse_prepare() {
  local task=$1 host='' name='' nonce='' source='' task_root='' host_data max cpus memory
  local source_real root_real source_commit owner reservation sandbox workcopy lifecycle
  shift
  ensure_state_root
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host) [ "$#" -ge 2 ] || die "--host requires a value"; host=$2; shift 2 ;;
      --name) [ "$#" -ge 2 ] || die "--name requires a value"; name=$2; shift 2 ;;
      --nonce) [ "$#" -ge 2 ] || die "--nonce requires a value"; nonce=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || die "--source requires a value"; source=$2; shift 2 ;;
      --task-root) [ "$#" -ge 2 ] || die "--task-root requires a value"; task_root=$2; shift 2 ;;
      *) die "unknown prepare argument: $1" ;;
    esac
  done
  if ! valid_id "$task" || ! valid_id "$host" || ! valid_id "$name" || ! valid_nonce "$nonce"; then
    die "prepare requires valid task, host, name, and nonce identities"
  fi
  [ -n "$source" ] && [ -n "$task_root" ] || die "prepare requires --source and --task-root"
  host_data=$(host_json "$host") || exit 1
  max=$(jq -r .maxConcurrent <<EOF
$host_data
EOF
)
  cpus=$(jq -r .cpus <<EOF
$host_data
EOF
)
  memory=$(jq -r .memory <<EOF
$host_data
EOF
)
  source_real=$(resolve_source "$source")
  root_real=$(ensure_task_root "$task" "$task_root")
  source_commit=$(git -C "$source_real" rev-parse HEAD)
  owner=$(journal_path "$task")
  reservation=$(reservation_path "$host" "$nonce")
  sandbox="$root_real/sandbox"
  workcopy="$sandbox/workcopy"
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    journal_valid "$owner" "$task" || die "existing sandbox journal is malformed"
    jq -e --arg host "$host" --arg name "$name" --arg nonce "$nonce" --arg source "$source_real" \
      --arg root "$root_real" --arg workcopy "$workcopy" --arg reservation "$reservation" \
      '.host_id == $host and .sandbox_name == $name and .nonce == $nonce
       and .source_worktree == $source and .task_root == $root and .workcopy == $workcopy
       and .reservation == $reservation' "$owner" >/dev/null \
      || die "existing sandbox journal identity disagrees with prepare"
    lifecycle=$(jq -r .lifecycle "$owner")
    [ "$lifecycle" = prepared ] || die "existing sandbox journal requires recover or a terminal transition; lifecycle=$lifecycle"
    return 0
  fi
  [ ! -e "$sandbox" ] && [ ! -L "$sandbox" ] || die "sandbox task directory exists without an ownership journal"
  if ! write_initial_journal "$owner" "$task" "$host" "$name" "$nonce" "$source_real" \
      "$source_commit" "$root_real" "$workcopy" "$cpus" "$memory" "$max" "$reservation"; then
    die "could not publish sandbox preparing journal"
  fi
  test_failpoint after-journal
  acquire_host_lock "$host"
  if ! claim_host_slot "$task" "$host" "$name" "$nonce" "$owner" "$max"; then
    release_lock
    rollback_internal "$task"
    die "could not claim sandbox host capacity; local transaction rolled back"
  fi
  release_lock
  test_failpoint after-reservation
  (umask 077; mkdir "$sandbox") || {
    rollback_internal "$task"
    die "could not create sandbox workcopy directory; local transaction rolled back"
  }
  if ! git clone --quiet --no-local --no-hardlinks "$source_real" "$workcopy"; then
    rollback_internal "$task"
    die "could not create committed-only sandbox workcopy; local transaction rolled back"
  fi
  if [ "$(git -C "$workcopy" rev-parse HEAD 2>/dev/null || true)" != "$source_commit" ]; then
    rollback_internal "$task"
    die "sandbox workcopy commit differs from its journal; local transaction rolled back"
  fi
  json_update "$owner" ".lifecycle=\"prepared\" | .updated_at=\$now" --arg now "$(utc_now_iso)" || {
    rollback_internal "$task"
    die "could not commit sandbox prepared journal; local transaction rolled back"
  }
}

rollback_internal() {
  local task=$1 owner lifecycle sandbox_id host
  ensure_state_root
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for rollback"
  lifecycle=$(jq -r .lifecycle "$owner")
  sandbox_id=$(jq -r '.sandbox_id // empty' "$owner")
  [ -z "$sandbox_id" ] || die "rollback refuses a committed sandbox identity"
  case "$lifecycle" in
    rolled_back)
      terminal_local_state_clean "$owner" || die "rolled-back sandbox journal has unexpected local artifacts"
      return 0
      ;;
    preparing|prepared|rollback_pending) ;;
    *) die "rollback refuses lifecycle=$lifecycle" ;;
  esac
  if [ "$lifecycle" != rollback_pending ]; then
    json_update "$owner" ".lifecycle=\"rollback_pending\" | .updated_at=\$now" --arg now "$(utc_now_iso)" \
      || die "could not begin sandbox rollback transaction"
  fi
  test_failpoint after-rollback-mark
  host=$(jq -r .host_id "$owner")
  acquire_host_lock "$host"
  if [ -e "$(jq -r .reservation "$owner")" ] || [ -L "$(jq -r .reservation "$owner")" ]; then
    reservation_matches "$(jq -r .reservation "$owner")" "$owner" \
      || die "sandbox reservation identity mismatch during rollback"
    reservation_sandbox_id_matches "$(jq -r .reservation "$owner")" "$owner" \
      || die "sandbox reservation stable id mismatch during rollback"
  fi
  remove_local_copy "$owner"
  release_host_slot "$owner"
  release_lock
  json_update "$owner" ".lifecycle=\"rolled_back\" | .updated_at=\$now" --arg now "$(utc_now_iso)" \
    || die "sandbox rollback local cleanup finished but its journal needs recover"
}

commit_internal() {
  local task=$1 sandbox_id=$2 owner lifecycle host reservation current reserved_id
  ensure_state_root
  valid_id "$sandbox_id" || die "commit requires a valid stable sandbox id"
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for commit"
  lifecycle=$(jq -r .lifecycle "$owner")
  current=$(jq -r '.sandbox_id // empty' "$owner")
  if [ "$lifecycle" = committed ] && [ "$current" = "$sandbox_id" ]; then
    return 0
  fi
  case "$lifecycle" in
    prepared)
      [ -z "$current" ] || die "prepared sandbox journal already has a stable id"
      json_update "$owner" ".sandbox_id=\$id | .lifecycle=\"commit_pending\" | .updated_at=\$now" \
        --arg id "$sandbox_id" --arg now "$(utc_now_iso)" || die "could not begin sandbox id commit"
      ;;
    commit_pending)
      [ "$current" = "$sandbox_id" ] || die "sandbox id commit disagrees with pending journal"
      ;;
    *) die "commit refuses lifecycle=$lifecycle" ;;
  esac
  test_failpoint after-commit-mark
  host=$(jq -r .host_id "$owner")
  reservation=$(jq -r .reservation "$owner")
  acquire_host_lock "$host"
  reservation_matches "$reservation" "$owner" || die "sandbox reservation is missing or mismatched during commit"
  reserved_id=$(jq -r '.sandbox_id // empty' "$reservation")
  [ -z "$reserved_id" ] || [ "$reserved_id" = "$sandbox_id" ] \
    || die "sandbox reservation has a different stable id during commit"
  if ! json_update "$reservation" ".sandbox_id=\$id | .updated_at=\$now" \
      --arg id "$sandbox_id" --arg now "$(utc_now_iso)"; then
    die "could not bind stable sandbox id to its reservation"
  fi
  release_lock
  json_update "$owner" ".lifecycle=\"committed\" | .updated_at=\$now" --arg now "$(utc_now_iso)" \
    || die "sandbox id was reserved but its journal needs recover"
}

cleanup_begin() {
  local task=$1 json=${2:-} owner lifecycle
  [ -z "$json" ] || [ "$json" = --json ] || die "cleanup-begin accepts only --json"
  ensure_state_root
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for cleanup"
  lifecycle=$(jq -r .lifecycle "$owner")
  case "$lifecycle" in
    committed)
      json_update "$owner" ".lifecycle=\"cleanup_pending\" | .cleanup_requested_at=\$now | .updated_at=\$now" \
        --arg now "$(utc_now_iso)" || die "could not begin sandbox cleanup journal"
      ;;
    cleanup_pending) ;;
    *) die "cleanup-begin refuses lifecycle=$lifecycle" ;;
  esac
  if [ "$json" = --json ]; then
    jq '{schema:"fm-sandbox-cleanup-receipt.v1",task_id,host_id,sandbox_name,sandbox_id,nonce,lifecycle}' "$owner"
  else
    jq -r '"task=\(.task_id) host=\(.host_id) sandbox=\(.sandbox_name) stable_id=\(.sandbox_id) nonce=\(.nonce) lifecycle=\(.lifecycle)"' "$owner"
  fi
}

cleanup_finalize() {
  local task=$1 sandbox_id=$2 owner lifecycle current host reservation
  ensure_state_root
  valid_id "$sandbox_id" || die "cleanup-commit requires a valid stable sandbox id"
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for cleanup commit"
  lifecycle=$(jq -r .lifecycle "$owner")
  current=$(jq -r '.sandbox_id // empty' "$owner")
  [ "$current" = "$sandbox_id" ] || die "cleanup stable sandbox id disagrees with ownership journal"
  if [ "$lifecycle" = cleaned ]; then
    terminal_local_state_clean "$owner" || die "cleaned sandbox journal has unexpected local artifacts"
    return 0
  fi
  case "$lifecycle" in
    cleanup_pending)
      json_update "$owner" ".lifecycle=\"cleanup_finalizing\" | .updated_at=\$now" --arg now "$(utc_now_iso)" \
        || die "could not begin local cleanup finalization"
      ;;
    cleanup_finalizing|cleanup_releasing) ;;
    *) die "cleanup-commit refuses lifecycle=$lifecycle" ;;
  esac
  host=$(jq -r .host_id "$owner")
  reservation=$(jq -r .reservation "$owner")
  if [ "$lifecycle" != cleanup_releasing ]; then
    test_failpoint after-cleanup-mark
    acquire_host_lock "$host"
    reservation_matches "$reservation" "$owner" \
      || die "sandbox reservation identity mismatch before local cleanup"
    reservation_sandbox_id_matches "$reservation" "$owner" \
      || die "sandbox reservation stable id mismatch before local cleanup"
    remove_local_copy "$owner"
    json_update "$owner" ".lifecycle=\"cleanup_releasing\" | .updated_at=\$now" \
      --arg now "$(utc_now_iso)" || die "local copy was removed but its cleanup journal needs recover"
    test_failpoint after-cleanup-local-mark
  else
    acquire_host_lock "$host"
    local_copy_absent "$owner" || die "cleanup-releasing journal has unexpected local workcopy artifacts"
    if [ -e "$reservation" ] || [ -L "$reservation" ]; then
      reservation_matches "$reservation" "$owner" \
        || die "sandbox reservation identity mismatch during cleanup recovery"
      reservation_sandbox_id_matches "$reservation" "$owner" \
        || die "sandbox reservation stable id mismatch during cleanup recovery"
    fi
  fi
  release_host_slot "$owner"
  release_lock
  test_failpoint after-cleanup-release
  json_update "$owner" ".lifecycle=\"cleaned\" | .cleaned_at=\$now | .updated_at=\$now" \
    --arg now "$(utc_now_iso)" || die "local cleanup finished but its journal needs recover"
}

workcopy_complete() {
  local owner=$1 workcopy expected
  workcopy=$(jq -r .workcopy "$owner")
  expected=$(jq -r .source_commit "$owner")
  recorded_paths_safe "$owner" || return 1
  [ -d "$workcopy" ] && [ ! -L "$workcopy" ] \
    && [ "$(git -C "$workcopy" rev-parse HEAD 2>/dev/null || true)" = "$expected" ]
}

status_task() {
  local task=$1 json=${2:-} owner reservation workcopy reservation_present=false workcopy_present=false next out lifecycle
  [ -z "$json" ] || [ "$json" = --json ] || die "status accepts only --json"
  ensure_state_root
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for task $task"
  reservation=$(jq -r .reservation "$owner")
  workcopy=$(jq -r .workcopy "$owner")
  if [ -e "$reservation" ] || [ -L "$reservation" ]; then
    reservation_matches "$reservation" "$owner" || die "sandbox reservation accounting is ambiguous"
    reservation_sandbox_id_matches "$reservation" "$owner" \
      || die "sandbox reservation stable id accounting is ambiguous"
    reservation_present=true
  fi
  [ -d "$workcopy" ] && [ ! -L "$workcopy" ] && workcopy_present=true
  lifecycle=$(jq -r .lifecycle "$owner")
  case "$lifecycle" in
    preparing|commit_pending|rollback_pending|cleanup_finalizing) next=recover ;;
    cleanup_releasing) next=recover ;;
    prepared) next=stage2-create-or-rollback ;;
    committed) next=stage2-supervision-required ;;
    cleanup_pending) next=stage2-removal-proof-required ;;
    rolled_back|cleaned)
      if terminal_local_state_clean "$owner"; then
        next=complete
      else
        next=manual-inspection
      fi
      ;;
    *) next=manual-inspection ;;
  esac
  out=$(jq -c --arg next "$next" --argjson reservation "$reservation_present" \
    --argjson workcopy "$workcopy_present" \
    '. + {accounting:{reservation_present:$reservation,workcopy_present:$workcopy,
      launch_supported:false,next_action:$next}}' "$owner")
  if [ "$json" = --json ]; then
    printf '%s\n' "$out"
  else
    jq . <<EOF
$out
EOF
  fi
}

recover_task() {
  local task=$1 json=${2:-} owner lifecycle sandbox_id
  [ -z "$json" ] || [ "$json" = --json ] || die "recover accepts only --json"
  ensure_state_root
  owner=$(journal_path "$task")
  journal_valid "$owner" "$task" || die "missing or malformed sandbox journal for recovery"
  lifecycle=$(jq -r .lifecycle "$owner")
  case "$lifecycle" in
    preparing)
      if reservation_matches "$(jq -r .reservation "$owner")" "$owner" \
          && reservation_sandbox_id_matches "$(jq -r .reservation "$owner")" "$owner" \
          && workcopy_complete "$owner"; then
        json_update "$owner" ".lifecycle=\"prepared\" | .updated_at=\$now" --arg now "$(utc_now_iso)" \
          || die "could not recover completed sandbox preparation"
      else
        rollback_internal "$task"
      fi
      ;;
    commit_pending)
      sandbox_id=$(jq -r .sandbox_id "$owner")
      commit_internal "$task" "$sandbox_id"
      ;;
    rollback_pending) rollback_internal "$task" ;;
    cleanup_finalizing|cleanup_releasing)
      sandbox_id=$(jq -r .sandbox_id "$owner")
      cleanup_finalize "$task" "$sandbox_id"
      ;;
    prepared|committed|cleanup_pending|rolled_back|cleaned) ;;
    *) die "recovery refuses unknown lifecycle=$lifecycle" ;;
  esac
  status_task "$task" "$json"
}

parse_sandbox_id() {
  local command=$1 task=$2 sandbox_id=''
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sandbox-id) [ "$#" -ge 2 ] || die "--sandbox-id requires a value"; sandbox_id=$2; shift 2 ;;
      *) die "unknown $command argument: $1" ;;
    esac
  done
  if ! valid_id "$task" || ! valid_id "$sandbox_id"; then
    die "$command requires valid task and stable sandbox ids"
  fi
  if [ "$command" = commit ]; then
    commit_internal "$task" "$sandbox_id"
  else
    cleanup_finalize "$task" "$sandbox_id"
  fi
}

case "${1:-}" in
  -h|--help|'') usage ;;
  inventory) shift; [ "$#" -le 1 ] || die "inventory accepts only --json"; inventory "${1:-}" ;;
  doctor) doctor "$@" ;;
  identity) [ "$#" = 3 ] || die "identity requires task-id and host-id"; identity "$2" "$3" ;;
  prepare) [ "$#" -ge 2 ] || die "prepare requires task-id and exact flags"; task=$2; shift 2; parse_prepare "$task" "$@" ;;
  commit) [ "$#" -ge 2 ] || die "commit requires task-id and --sandbox-id"; parse_sandbox_id commit "$2" "${@:3}" ;;
  rollback) [ "$#" = 2 ] || die "rollback requires task-id"; valid_id "$2" || die "invalid task id"; rollback_internal "$2" ;;
  cleanup-begin) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "cleanup-begin requires task-id [--json]"; valid_id "$2" || die "invalid task id"; cleanup_begin "$2" "${3:-}" ;;
  cleanup-commit) [ "$#" -ge 2 ] || die "cleanup-commit requires task-id and --sandbox-id"; parse_sandbox_id cleanup-commit "$2" "${@:3}" ;;
  recover) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "recover requires task-id [--json]"; valid_id "$2" || die "invalid task id"; recover_task "$2" "${3:-}" ;;
  status) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "status requires task-id [--json]"; valid_id "$2" || die "invalid task id"; status_task "$2" "${3:-}" ;;
  *) die "unknown command: $1" ;;
esac
