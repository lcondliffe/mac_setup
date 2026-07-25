#!/usr/bin/env bash
# End-state assertions, run *inside* the test VM after the playbook.
# Package coverage is derived from vars.yml via the playbook's own `audit` tag,
# so this file only hardcodes the things audit doesn't cover.
#
# Usage (from the repo root, inside the VM):
#   bash test/verify.sh                          # against vars.yml
#   bash test/verify.sh -e @test/test-vars.yml   # against the cut-down lists
# Any arguments are passed through to the audit run, so it compares against the
# same vars the playbook was given.

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.krew/bin:$PATH"

pass=0; failed=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; failed=$((failed + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

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
# Only things every run installs regardless of the vars file — the package lists
# themselves are checked against vars.yml by the audit section at the bottom.
for bin in brew git ansible-playbook; do
  check "$bin on PATH" "command -v $bin"
done
check "krew installed" "[ -x \"\$HOME/.krew/bin/kubectl-krew\" ]"

echo "== SSH key gate =="
check "ed25519 private key generated" "[ -f \"\$HOME/.ssh/id_ed25519\" ]"
check "ed25519 public key generated"  "[ -f \"\$HOME/.ssh/id_ed25519.pub\" ]"

echo "== Hermes =="
check "hermes binary installed"    "[ -x \"\$HOME/.local/bin/hermes\" ]"
check "mack profile exists"        "\$HOME/.local/bin/hermes profile list | grep -q mack"
check "mack is the active profile" "grep -q '^mack\$' \"\$HOME/.hermes/active_profile\""
mack_dir="$(hermes profile show mack 2>/dev/null | sed -nE 's/.*Path:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
if [ -n "$mack_dir" ]; then
  check "managed SOUL.md written"       "[ -s '$mack_dir/SOUL.md' ]"
  check "daily-standup cron registered" "grep -q daily-standup '$mack_dir/cron/jobs.json'"
else
  bad "could not resolve the mack profile path"
fi
check "gateway launchd service loaded" \
  "launchctl list | grep -qi hermes"

echo "== Obsidian =="
vault="$HOME/Documents/Obsidian Vault"
check "journal folder created"   "[ -d '$vault/Journal' ]"
check "templates folder created" "[ -d '$vault/Templates' ]"
check "daily journal template"   "[ -s '$vault/Templates/Daily Journal.md' ]"
check "daily-notes plugin config" \
  "grep -q Journal '$vault/.obsidian/daily-notes.json'"

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
