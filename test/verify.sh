#!/usr/bin/env bash
# Assert end state not covered by the playbook audit; pass extra vars to audit.
# Runs standalone on any machine the playbook has configured (VM, CI, or your
# own): bash test/verify.sh [-e @test/test-vars.yml ...]

# mac-setup.yml is addressed relative to the repo root, so settle there
# regardless of caller.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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
# Package lists are checked by the audit below.
for bin in brew git ansible-playbook; do
  check "$bin on PATH" "command -v $bin"
done
if brew list --formula krew >/dev/null 2>&1; then
  check "krew installed" "command -v kubectl-krew"
else
  echo "  SKIP  krew installed (formula not in this run's package list)"
fi

echo "== SSH key gate =="
# Same key types the gate itself accepts (tasks/ssh.yml); a fresh VM/CI run
# will have the generated id_ed25519, a real machine may have any of them.
check "a private key the gate accepts exists" \
  "ls \"\$HOME/.ssh/id_ed25519\" \"\$HOME/.ssh/id_ecdsa\" \"\$HOME/.ssh/id_rsa\" 2>/dev/null | grep -q ."
check "its public key exists" \
  "ls \"\$HOME/.ssh/id_ed25519.pub\" \"\$HOME/.ssh/id_ecdsa.pub\" \"\$HOME/.ssh/id_rsa.pub\" 2>/dev/null | grep -q ."

echo "== Terminal stack =="
check "ghostty config rendered"   "[ -s \"\$HOME/.config/ghostty/config\" ]"
check "starship config rendered"  "[ -s \"\$HOME/.config/starship.toml\" ]"
check ".zshrc initialises starship" \
  "grep -q 'starship init zsh' \"\$HOME/.zshrc\""

echo "== herdr =="
if command -v herdr >/dev/null 2>&1; then
  check "herdr config rendered" "[ -s \"\$HOME/.config/herdr/config.toml\" ]"
  check "herdr config validates" "herdr config check"
else
  echo "  SKIP  herdr checks (formula not in this run's package list)"
fi

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
if [ "$audit_rc" -eq 0 ]; then pass=$((pass + 1)); else failed=$((failed + 1)); fi

echo
echo "== $pass passed, $failed failed =="
[ "$failed" -eq 0 ]
