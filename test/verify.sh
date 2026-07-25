#!/usr/bin/env bash
# Assert end state not covered by the playbook audit; pass extra vars to audit.

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.krew/bin:$PATH"

pass=0; failed=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; failed=$((failed + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

resolved_vars="$(mktemp)"
trap 'rm -f "$resolved_vars"' EXIT
if ! ANSIBLE_DEPRECATION_WARNINGS=false ansible-playbook -i localhost, \
  test/resolve_vars.yml "$@" -e ansible_python_interpreter=auto_silent \
  -e "resolved_vars_path=$resolved_vars" >/dev/null; then
  echo "  FAIL  could not resolve test expectations"
  exit 1
fi
json_value() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$resolved_vars" "$1"
}
configured_crons_match() {
  python3 - "$resolved_vars" "$1" "$2" <<'PY'
import json
import re
import sys
from pathlib import Path

expected = json.load(open(sys.argv[1]))["crons"]
jobs_path = Path(sys.argv[2])
actual = {
    job["name"]: job
    for job in json.load(open(jobs_path)).get("jobs", [])
} if jobs_path.exists() else {}
managed = set(json.load(open(sys.argv[3]))["names"])
assert managed == {job["name"] for job in expected}

def schedule_display(value):
    match = re.fullmatch(r"every (\d+)([mhd])", value.lower())
    if not match:
        return value
    amount, unit = int(match.group(1)), match.group(2)
    return f"every {amount * {'m': 1, 'h': 60, 'd': 1440}[unit]}m"

for wanted in expected:
    found = actual[wanted["name"]]
    assert found["schedule_display"] == schedule_display(wanted["schedule"])
    assert found["prompt"] == wanted["prompt"]
    assert found["deliver"] == wanted.get("deliver", "local")
    assert found.get("skills", []) == wanted.get("skills", [])
    assert found.get("enabled_toolsets", []) == wanted.get("enabled_toolsets", [])
    assert found.get("workdir", "") == wanted.get("workdir", "")
PY
}
obsidian_config_matches() {
  python3 - "$resolved_vars" <<'PY'
import json
import sys
from pathlib import Path

expected = json.load(open(sys.argv[1]))
vault = Path(expected["vault"])
daily = json.load(open(vault / ".obsidian/daily-notes.json"))
templates = json.load(open(vault / ".obsidian/templates.json"))
plugins = set(json.load(open(vault / ".obsidian/core-plugins.json")))
assert daily == {
    "folder": expected["journal_folder"],
    "format": "YYYY-MM-DD",
    "template": f'{expected["templates_folder"]}/Daily Journal',
}
assert templates == {"folder": expected["templates_folder"]}
assert {"daily-notes", "templates"} <= plugins
assert (vault / expected["templates_folder"] / "Daily Journal.md").read_bytes() == Path(
    "files/obsidian/Daily Journal.md"
).read_bytes()
PY
}

echo "== Home directory structure =="
for d in ansible ansible/playbooks ansible/roles repo repo/private repo/public \
         repo/training scripts temp; do
  check "home dir $d exists" "[ -d \"\$HOME/$d\" ]"
done

echo "== Shell configuration =="
check ".zshrc has the env managed block" \
  "grep -q 'BEGIN ANSIBLE MANAGED BLOCK' \"\$HOME/.zshrc\""
check ".zshrc exports the krew PATH entry" \
  "grep -q '.krew/bin' \"\$HOME/.zshrc\""
check ".zshrc has the 'k' alias" \
  "grep -qE \"alias k=|alias k '\" \"\$HOME/.zshrc\""
check ".zshrc has the cat-all function" \
  "grep -q 'cat-all' \"\$HOME/.zshrc\""

echo "== Git configuration =="
check "user.name set"        "[ -n \"\$(git config --global user.name)\" ]"
check "user.email set"       "[ -n \"\$(git config --global user.email)\" ]"
check "core.pager = delta"   "[ \"\$(git config --global core.pager)\" = delta ]"
check "init.defaultBranch"   "[ \"\$(git config --global init.defaultBranch)\" = main ]"
check "pull.rebase = true"   "[ \"\$(git config --global pull.rebase)\" = true ]"
check "credential.helper"    "[ \"\$(git config --global credential.helper)\" = osxkeychain ]"

echo "== Tooling on PATH =="
# Package lists are checked by the audit below.
for bin in brew git ansible-playbook; do
  check "$bin on PATH" "command -v $bin"
done
check "krew installed" "[ -x \"\$HOME/.krew/bin/kubectl-krew\" ]"

echo "== SSH key gate =="
check "ed25519 private key generated" "[ -f \"\$HOME/.ssh/id_ed25519\" ]"
check "ed25519 public key generated"  "[ -f \"\$HOME/.ssh/id_ed25519.pub\" ]"

echo "== Hermes =="
profile="$(json_value profile)"
check "hermes binary installed" "[ -x \"\$HOME/.local/bin/hermes\" ]"
check "$profile profile exists" "hermes profile list | grep -qx '$profile'"
check "$profile is active" "grep -qx '$profile' \"\$HOME/.hermes/active_profile\""
profile_dir="$(hermes profile show "$profile" 2>/dev/null | sed -nE 's/.*Path:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
if [ -n "$profile_dir" ]; then
  if [ "$(json_value persona)" = True ]; then
    check "managed SOUL.md written" "[ -s '$profile_dir/SOUL.md' ]"
  fi
  check "configured crons match" \
    "configured_crons_match '$profile_dir/cron/jobs.json' '$profile_dir/cron/ansible-managed.json'"
else
  bad "could not resolve the $profile profile path"
fi
if [ "$(json_value gateway)" = True ]; then
  check "gateway launchd service loaded" "launchctl list | grep -qi hermes"
fi

echo "== Obsidian =="
vault="$(json_value vault)"
journal_folder="$(json_value journal_folder)"
templates_folder="$(json_value templates_folder)"
check "journal folder created"   "[ -d '$vault/$journal_folder' ]"
check "templates folder created" "[ -d '$vault/$templates_folder' ]"
check "daily journal configuration" "obsidian_config_matches"

echo "== macOS defaults =="
check "Finder shows all extensions" \
  "[ \"\$(defaults read NSGlobalDomain AppleShowAllExtensions)\" = 1 ]"
check "Finder shows hidden files" \
  "[ \"\$(defaults read com.apple.finder AppleShowAllFiles)\" = 1 ]"
check "Finder defaults to list view" \
  "[ \"\$(defaults read com.apple.finder FXPreferredViewStyle)\" = Nlsv ]"
check "Dock hides recents" \
  "[ \"\$(defaults read com.apple.dock show-recents)\" = 0 ]"
check "Screenshot location set" \
  "defaults read com.apple.screencapture location | grep -q Screenshots"
check "Screenshot shadow disabled" \
  "[ \"\$(defaults read com.apple.screencapture disable-shadow)\" = 1 ]"
check "Screenshot folder created" "[ -d \"\$HOME/Pictures/Screenshots\" ]"
check "Screenshot hotkey 29 remapped" \
  "defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -q 1179648"

echo "== Package coverage vs vars.yml (playbook 'audit' tag) =="
audit_json="$(ANSIBLE_STDOUT_CALLBACK=json ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook mac-setup.yml -t audit "$@" -e ssh_gate_enabled=false 2>/dev/null)"
if [ -n "$audit_json" ]; then
  printf '%s' "$audit_json" | python3 test/audit_check.py
  audit_rc=$?
else
  echo "  FAIL  could not run the audit task"
  audit_rc=1
fi
[ "$audit_rc" -eq 0 ] || failed=$((failed + 1))

echo
echo "== $pass passed, $failed failed =="
[ "$failed" -eq 0 ]
