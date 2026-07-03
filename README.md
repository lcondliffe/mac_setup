# Mac Terminal Setup

![CI](https://github.com/lcondliffe/mac_setup/actions/workflows/ci.yml/badge.svg)

Reproducible setup for macOS (Apple Silicon). The goal is to keep the machine as close to ephemeral as possible so rebuilds or OS reinstalls are fast: re-run the playbook and you're back in a working state.

This is the Mac counterpart to [`~/repo/wsl_setup`](../wsl_setup) — same principle, swapped substrate (Homebrew + casks instead of apt).

## What it manages

- Homebrew taps, formulae, and casks
- Home-directory structure (`~/repo`, `~/scripts`, `~/temp`, etc.)
- A managed block of non-secret env vars / PATH additions in `~/.zshrc`
- A managed block of shell aliases + `cat-all` function in `~/.zshrc`
- Global `git config` (identity + `git_settings` in vars.yml: osxkeychain credential helper, delta as pager, `pull.rebase`, `push.autoSetupRemote`, `init.defaultBranch=main`)
- pipx packages
- `krew` (kubectl plugin manager) install + PATH
- VSCode extensions

**Not managed (intentional):** any plaintext secrets you may have in `~/.zshrc` / `~/.zprofile`. The playbook writes its content inside marker blocks (`# BEGIN/END ANSIBLE MANAGED BLOCK: ...`), so anything else in those files is left alone. If you want to keep secrets out of git, move them to `~/.zshrc.secrets` and source it from `~/.zshrc`.

## Configuration

All knobs live in [`vars.yml`](vars.yml):
- `homebrew_taps`, `homebrew_formulae`, `homebrew_casks`
- `pipx_packages`, `vscode_extensions`
- `shell_aliases`, `env_vars`
- `directories`
- `git_user_name`, `git_user_email`, `git_settings`

Customize:
1. Edit `vars.yml` directly.
2. Use a custom vars file: `ansible-playbook mac-setup.yml -e @my-vars.yml`
3. Override specific variables: `ansible-playbook mac-setup.yml -e git_user_email=me@example.com`

## Usage

First-time bootstrap (installs Homebrew + Ansible if missing, then runs the playbook):

```bash
./bootstrap_mac.sh
```

The bootstrap skips the `touchid` task unless you pass `-K` (it needs sudo); run it afterwards with `ansible-playbook mac-setup.yml -t touchid -K`.

Subsequent runs:

```bash
ansible-playbook mac-setup.yml
```

Targeted runs with tags (faster, incremental):

| Tag | What it touches |
|---|---|
| `ssh` | SSH key gate (also runs on every invocation via `always`) |
| `homebrew` | Taps, formulae, casks |
| `upgrade` | Brew formulae and pipx packages upgraded to latest |
| `cleanup` | `brew autoremove` + `brew cleanup --prune=all` (housekeeping) |
| `aliases,shell` | Just the aliases managed block |
| `env,shell` | Just the env-vars managed block |
| `git` | Global git config |
| `pipx` | pipx packages |
| `kubectl` | krew install + PATH |
| `vscode` | VSCode extensions |
| `keyboard,shortcuts` | macOS screenshot hotkeys |
| `dock` | macOS Dock preferences + pinned-app layout (`dock_apps` via dockutil) |
| `finder` | macOS Finder preferences (extensions, hidden files, path/status bar, list view) |
| `screenshots` | Screenshot save folder + no window shadow |
| `touchid` | Enable Touch ID for `sudo` (needs `-K`) |
| `audit` | Read-only drift report: installed brews/casks/extensions/pipx vs `vars.yml` |

Example: `ansible-playbook mac-setup.yml -t aliases,shell`

Dry-run / verify idempotency:

```bash
ansible-playbook --syntax-check mac-setup.yml
ansible-playbook --check mac-setup.yml
```

## SSH key gate

An SSH key is treated as a prerequisite: every run starts with a check for a private key in `~/.ssh` (`id_ed25519` / `id_ecdsa` / `id_rsa`). If none exists you're prompted to either type `generate` (creates a passphrase-less ed25519 key and prints the public key to add to GitHub) or press Enter to abort and import an existing key first. Non-interactive runs abort with the same instructions; pass `-e ssh_gate_action=generate` to generate unattended. Bypass the gate entirely with `-e ssh_gate_enabled=false`.

## Notes

- Sudo: only the `touchid` task needs root. A normal full run needs `-K` (it will prompt for your sudo password), or run `ansible-playbook mac-setup.yml --skip-tags touchid` to keep it password-free. Everything else (Homebrew included) runs as the user.
- The playbook expects Homebrew at `/opt/homebrew/bin/brew` (Apple Silicon). For Intel Macs, change the `PATH` in `vars.yml` to use `/usr/local/bin` and adjust the brew check in `tasks/homebrew.yml`.
