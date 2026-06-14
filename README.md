# Mac Terminal Setup

Reproducible setup for macOS (Apple Silicon). The goal is to keep the machine as close to ephemeral as possible so rebuilds or OS reinstalls are fast: re-run the playbook and you're back in a working state.

This is the Mac counterpart to [`~/repo/wsl_setup`](../wsl_setup) — same principle, swapped substrate (Homebrew + casks instead of apt).

## What it manages

- Homebrew taps, formulae, and casks
- Home-directory structure (`~/repo`, `~/scripts`, `~/temp`, etc.)
- A managed block of non-secret env vars / PATH additions in `~/.zshrc`
- A managed block of shell aliases + `cat-all` function in `~/.zshrc`
- Global `git config` (identity, osxkeychain credential helper, `pager.diff=false`)
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
- `git_user_name`, `git_user_email`

Customize:
1. Edit `vars.yml` directly.
2. Use a custom vars file: `ansible-playbook mac-setup.yml -e @my-vars.yml`
3. Override specific variables: `ansible-playbook mac-setup.yml -e git_user_email=me@example.com`

## Usage

First-time bootstrap (installs Homebrew + Ansible if missing, then runs the playbook):

```bash
./bootstrap_mac.sh
```

Subsequent runs:

```bash
ansible-playbook mac-setup.yml
```

Targeted runs with tags (faster, incremental):

| Tag | What it touches |
|---|---|
| `homebrew` | Taps, formulae, casks |
| `homebrew,upgrade` | Formulae upgraded to latest (`state: latest`) |
| `aliases,shell` | Just the aliases managed block |
| `env,shell` | Just the env-vars managed block |
| `git` | Global git config |
| `pipx` | pipx packages |
| `kubectl` | krew install + PATH |
| `vscode` | VSCode extensions |
| `keyboard,shortcuts` | macOS screenshot hotkeys |
| `dock` | macOS Dock preferences (e.g. hide recent apps) |

Example: `ansible-playbook mac-setup.yml -t aliases,shell`

Dry-run / verify idempotency:

```bash
ansible-playbook --syntax-check mac-setup.yml
ansible-playbook --check mac-setup.yml
```

## Notes

- No `-K` (sudo password): Homebrew runs as the user. There are no `become: true` tasks.
- The playbook expects Homebrew at `/opt/homebrew/bin/brew` (Apple Silicon). For Intel Macs, change the `PATH` in `vars.yml` to use `/usr/local/bin` and adjust the brew check in `tasks/homebrew.yml`.
