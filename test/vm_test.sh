#!/usr/bin/env bash
set -euo pipefail

# Run the playbook end-to-end against a throwaway macOS VM (Tart), to prove it
# behaves on a clean system. Clones a base image, boots it headless, syncs this
# repo in, runs bootstrap_mac.sh, then runs the playbook a second time to check
# idempotency (changed=0), and finally asserts the expected end state.
#
#   test/vm_test.sh                      # full clean-machine run
#   test/vm_test.sh --tags dirs,env,git  # fast subset
#   test/vm_test.sh --reuse --keep       # iterate against an existing test VM
#
# The base image is only ever cloned, never modified.

BASE_VM="${BASE_VM:-tahoe-base}"
TEST_VM="${TEST_VM:-mac-setup-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${LOG_DIR:-$REPO_DIR/test/logs}"
GUEST_REPO="mac_setup"

TAGS=""
EXTRA_SKIP_TAGS=""
VARS_FILE=""
KEEP=false
REUSE=false
CHECK_IDEMPOTENCY=true
RUN_VERIFY=true
TEST_TOUCHID=false
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

usage() {
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --base NAME         Base VM to clone (default: tahoe-base, or $BASE_VM)
  --vm NAME           Ephemeral test VM name (default: mac-setup-test)
  --tags TAGS         Limit the playbook to these ansible tags
  --skip-tags TAGS    Additional tags to skip (touchid is handled separately)
  --minimal           Use test/test-vars.yml: cut-down package lists, so the
                      playbook is tested without a 20GB Homebrew download
  --vars-file PATH    Repo-relative vars file to layer over vars.yml
  --touchid           Also exercise the touchid task (uses the VM's sudo)
  --reuse             Reuse an existing test VM instead of re-cloning
  --keep              Leave the VM running afterwards (default: stop + delete)
  --no-idempotency    Skip the second playbook run
  --no-verify         Skip the post-run end-state assertions
  -h, --help          This message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)           BASE_VM="$2"; shift 2 ;;
    --vm)             TEST_VM="$2"; shift 2 ;;
    --tags)           TAGS="$2"; shift 2 ;;
    --skip-tags)      EXTRA_SKIP_TAGS="$2"; shift 2 ;;
    --minimal)        VARS_FILE="test/test-vars.yml"; shift ;;
    --vars-file)      VARS_FILE="$2"; shift 2 ;;
    --touchid)        TEST_TOUCHID=true; shift ;;
    --reuse)          REUSE=true; shift ;;
    --keep)           KEEP=true; shift ;;
    --no-idempotency) CHECK_IDEMPOTENCY=false; shift ;;
    --no-verify)      RUN_VERIFY=false; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RUN_LOG_DIR="$LOG_DIR/$(date +%Y%m%d-%H%M%S)"

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
warn() { printf '%s==>%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s==>%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# PubkeyAuthentication=no / IdentitiesOnly=yes stop ssh from offering every key
# in the agent first, which trips sshd's "Too many authentication failures"
# before it ever gets to the password.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30
          -o PubkeyAuthentication=no -o IdentitiesOnly=yes
          -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)
VM_IP=""

TEST_KEY=""   # set once key auth is in place; until then, password auth

# The ssh invocation as an array, so rsync -e and vm_ssh stay in step.
ssh_argv() {
  if [[ -n "$TEST_KEY" ]]; then
    printf 'ssh %s' "${SSH_OPTS[*]}"
  else
    printf 'sshpass -p %s ssh %s' "$VM_PASS" "${SSH_OPTS[*]}"
  fi
}

# shellcheck disable=SC2029  # commands are built here on purpose, then run remotely
vm_ssh() {
  if [[ -n "$TEST_KEY" ]]; then
    ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"
  else
    sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"
  fi
}

# `tart list --format json` pretty-prints as `"Name" : "foo"`, hence the [[:space:]]*.
# Output is captured rather than piped: `grep -q` exits on the first match, and
# the resulting SIGPIPE would trip `pipefail` into a false negative.
vm_exists() {
  local listing
  listing="$(tart list --format json 2>/dev/null)" || return 1
  grep -qE "\"Name\"[[:space:]]*:[[:space:]]*\"$1\"" <<<"$listing"
}

# --- preflight -------------------------------------------------------------

command -v tart >/dev/null     || fail "tart not found (brew install cirruslabs/cli/tart)"
command -v sshpass >/dev/null  || fail "sshpass not found (brew install sshpass)"
command -v rsync >/dev/null    || fail "rsync not found"
vm_exists "$BASE_VM" \
  || fail "base VM '$BASE_VM' not found. Pull one: tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest $BASE_VM"

mkdir -p "$RUN_LOG_DIR"

if [[ -n "$VARS_FILE" && ! -f "$REPO_DIR/$VARS_FILE" ]]; then
  fail "vars file '$VARS_FILE' not found (paths are relative to the repo root)"
fi

host_free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [[ "$host_free_gb" -lt 40 && -z "$TAGS" && -z "$VARS_FILE" ]]; then
  warn "Host has ${host_free_gb}GB free. A full run installs ~20GB of brew formulae"
  warn "and casks into the clone's copy-on-write disk, which consumes host space."
  warn "Free up space, or narrow the run with --tags."
fi

# --- lifecycle -------------------------------------------------------------

VM_STARTED=false
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  local rc=$?
  if [[ "$VM_STARTED" == true && "$KEEP" == false ]]; then
    log "Stopping and deleting $TEST_VM"
    tart stop "$TEST_VM" >/dev/null 2>&1 || true
    sleep 2
    tart delete "$TEST_VM" >/dev/null 2>&1 || true
  elif [[ "$VM_STARTED" == true ]]; then
    log "Leaving $TEST_VM running at $VM_IP (--keep). Delete with: tart stop $TEST_VM && tart delete $TEST_VM"
  fi
  exit "$rc"
}
trap cleanup EXIT

if [[ "$REUSE" == false ]]; then
  if vm_exists "$TEST_VM"; then
    log "Removing previous $TEST_VM"
    tart stop "$TEST_VM" >/dev/null 2>&1 || true
    sleep 2
    tart delete "$TEST_VM"
  fi
  log "Cloning $BASE_VM -> $TEST_VM"
  tart clone "$BASE_VM" "$TEST_VM"
else
  vm_exists "$TEST_VM" \
    || fail "--reuse given but '$TEST_VM' does not exist"
  log "Reusing existing $TEST_VM (state is NOT clean)"
fi

log "Booting $TEST_VM headless"
nohup tart run --no-graphics "$TEST_VM" >"$RUN_LOG_DIR/tart-run.log" 2>&1 &
VM_STARTED=true

log "Waiting for an IP address"
VM_IP="$(tart ip "$TEST_VM" --wait "$BOOT_TIMEOUT")" || fail "VM never got an IP"
log "VM IP: $VM_IP"

# Probe the TCP port before trying to authenticate. sshd accepts connections
# well before the login stack can authenticate, and every failed password
# attempt counts against sshd's PerSourcePenalties (OpenSSH 9.8+) — enough of
# them and the host gets blocked for the rest of the run.
log "Waiting for port 22"
for _ in $(seq 1 60); do
  nc -z -G 5 "$VM_IP" 22 2>/dev/null && break
  sleep 5
done
nc -z -G 5 "$VM_IP" 22 2>/dev/null || fail "port 22 on $VM_IP never opened"

log "Waiting for the login stack"
ssh_err=""
ssh_ready=false
for attempt in $(seq 1 20); do
  if ssh_err="$(vm_ssh true 2>&1)"; then ssh_ready=true; break; fi
  log "  not authenticating yet (attempt $attempt)"
  sleep 15
done
[[ "$ssh_ready" == true ]] || fail "SSH to $VM_IP never authenticated. Last error: $ssh_err"

# Swap to key auth for the rest of the run: the playbook takes a long time over
# many connections, and password auth is both slower and penalty-prone.
log "Installing a throwaway SSH key for the run"
test_key="$RUN_LOG_DIR/id_vmtest"
ssh-keygen -q -t ed25519 -N '' -f "$test_key" -C mac_setup-vm-test
vm_ssh 'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "$test_key.pub"
TEST_KEY="$test_key"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30
          -i "$test_key" -o IdentitiesOnly=yes
          -o PreferredAuthentications=publickey)
vm_ssh true || fail "key-based SSH failed after installing the test key"

vm_ssh 'sw_vers; echo; df -h / | tail -1' | tee "$RUN_LOG_DIR/guest-info.log"

# --- sync the repo in ------------------------------------------------------

log "Syncing repo to $VM_USER@$VM_IP:~/$GUEST_REPO"
rsync -az --delete \
  --exclude '.git/' --exclude 'test/logs/' --exclude '*.retry' \
  -e "$(ssh_argv)" \
  "$REPO_DIR/" "$VM_USER@$VM_IP:$GUEST_REPO/"

# --- run 1: bootstrap on a clean machine -----------------------------------

# Non-interactive overrides. The SSH gate and the Hermes OAuth gate both pause
# for input on a fresh machine; these turn them into unattended paths. The vars
# file goes first: with ansible, the last -e wins.
PB_VARS=""
[[ -n "$VARS_FILE" ]] && PB_VARS="-e @$VARS_FILE "
PB_VARS+='-e ssh_gate_action=generate -e hermes_auth_enabled=false'
SKIP="touchid"
[[ -n "$EXTRA_SKIP_TAGS" ]] && SKIP="$SKIP,$EXTRA_SKIP_TAGS"
TAG_ARG=""
[[ -n "$TAGS" ]] && TAG_ARG="-t $TAGS"

log "Run 1: ./bootstrap_mac.sh (clean machine) — this is the slow one"
start=$SECONDS
set +e
vm_ssh "cd $GUEST_REPO && ANSIBLE_FORCE_COLOR=0 PATH=/opt/homebrew/bin:\$PATH \
  ./bootstrap_mac.sh $TAG_ARG --skip-tags $SKIP $PB_VARS" \
  2>&1 | tee "$RUN_LOG_DIR/run1-bootstrap.log"
run1_rc=${PIPESTATUS[0]}
set -e
log "Run 1 finished in $(( (SECONDS - start) / 60 ))m (exit $run1_rc)"

# --- run 2: idempotency ----------------------------------------------------

run2_changed=""
if [[ "$CHECK_IDEMPOTENCY" == true ]]; then
  log "Run 2: same playbook again (expecting changed=0)"
  set +e
  vm_ssh "cd $GUEST_REPO && ANSIBLE_FORCE_COLOR=0 PATH=/opt/homebrew/bin:\$PATH \
    ansible-playbook mac-setup.yml $TAG_ARG --skip-tags $SKIP $PB_VARS" \
    2>&1 | tee "$RUN_LOG_DIR/run2-idempotency.log"
  run2_rc=${PIPESTATUS[0]}
  set -e
  run2_changed=$(grep -Eo 'changed=[0-9]+' "$RUN_LOG_DIR/run2-idempotency.log" | tail -1 | cut -d= -f2)
fi

# --- touchid (needs root; the VM has passwordless sudo) --------------------

touchid_rc=""
if [[ "$TEST_TOUCHID" == true ]]; then
  log "Run 3: touchid task"
  set +e
  vm_ssh "cd $GUEST_REPO && ANSIBLE_FORCE_COLOR=0 PATH=/opt/homebrew/bin:\$PATH \
    ansible-playbook mac-setup.yml -t touchid $PB_VARS" \
    2>&1 | tee "$RUN_LOG_DIR/run3-touchid.log"
  touchid_rc=${PIPESTATUS[0]}
  set -e
fi

# --- end-state assertions --------------------------------------------------

verify_rc=""
if [[ "$RUN_VERIFY" == true ]]; then
  log "Verifying end state"
  set +e
  # verify.sh reuses the playbook's `audit` tag for package coverage, so it
  # needs the same vars file to compare against the right lists.
  verify_args=""
  [[ -n "$VARS_FILE" ]] && verify_args="-e @$VARS_FILE"
  vm_ssh "cd $GUEST_REPO && bash test/verify.sh $verify_args" 2>&1 | tee "$RUN_LOG_DIR/verify.log"
  verify_rc=${PIPESTATUS[0]}
  set -e
fi

# --- report ----------------------------------------------------------------

echo
log "Summary  (logs: $RUN_LOG_DIR)"
status() { [[ "$1" == 0 ]] && printf '%sPASS%s' "$GREEN" "$RESET" || printf '%sFAIL%s' "$RED" "$RESET"; }

printf '  bootstrap run      %s (exit %s)\n' "$(status "$run1_rc")" "$run1_rc"
overall=$run1_rc

if [[ "$CHECK_IDEMPOTENCY" == true ]]; then
  if [[ "$run2_rc" != 0 ]]; then
    printf '  idempotency        %s (rerun exited %s)\n' "$(status 1)" "$run2_rc"
    overall=1
  elif [[ "$run2_changed" == 0 ]]; then
    printf '  idempotency        %s (changed=0)\n' "$(status 0)"
  else
    printf '  idempotency        %s (changed=%s — tasks not idempotent)\n' "$(status 1)" "$run2_changed"
    grep -B2 'changed:' "$RUN_LOG_DIR/run2-idempotency.log" | grep -E '^TASK' | sed 's/^/      /' || true
    overall=1
  fi
fi

if [[ "$TEST_TOUCHID" == true ]]; then
  printf '  touchid            %s (exit %s)\n' "$(status "$touchid_rc")" "$touchid_rc"
  [[ "$touchid_rc" != 0 ]] && overall=1
fi

if [[ "$RUN_VERIFY" == true ]]; then
  printf '  end-state checks   %s (exit %s)\n' "$(status "$verify_rc")" "$verify_rc"
  [[ "$verify_rc" != 0 ]] && overall=1
fi

echo
if [[ "$overall" == 0 ]]; then
  log "${GREEN}All checks passed${RESET}"
else
  warn "${RED}Some checks failed${RESET}"
fi
exit "$overall"
