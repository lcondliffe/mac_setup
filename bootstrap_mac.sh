#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a Mac for the mac_setup Ansible playbook:
#   1. Install Homebrew if missing
#   2. Install ansible via brew
#   3. Install the community.general collection
#   4. Run ansible-playbook mac-setup.yml

# If Ansible is already present, just run the playbook directly.
if command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook already installed. Skipping bootstrap install."
else
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Installing..."
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Make brew available in this shell (Apple Silicon path)
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  brew install ansible
fi

# Ensure the required Ansible collection is installed
ansible-galaxy collection install community.general

hash -r

# The touchid task needs root (become: true) and is never-tagged, so it is off
# unless asked for. 'all,touchid' means everything plus that one opt-in task.
case " $* " in
  *" -K "* | *" --ask-become-pass "*)
    ansible-playbook mac-setup.yml --tags all,touchid "$@"
    ;;
  *)
    echo "Note: skipping the touchid task (needs sudo). Run it later with:"
    echo "  ansible-playbook mac-setup.yml -t touchid -K"
    ansible-playbook mac-setup.yml "$@"
    ;;
esac

echo
echo "Done. Open a new zsh session (or 'exec zsh -l') to pick up PATH / alias changes."
