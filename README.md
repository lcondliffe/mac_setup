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
- Terminal: Ghostty config (`~/.config/ghostty/config`) and the starship prompt (`~/.config/starship.toml`), both rendered from [`templates/`](templates)
- herdr: `~/.config/herdr/config.toml` (rendered from [`templates/`](templates); deliberate overrides only) plus per-agent state-reporting hooks (`herdr_integrations`) so the sidebar and attention queue can tell running agents apart. Each integration installs into that agent's own config directory, which only exists once the agent has been launched — installing the cask is not enough. Integrations for agents that have never run are skipped with a message; launch them once, then re-run `-t herdr`.
- VSCode extensions
- Obsidian daily journalling: configures Daily Notes to create `Journal/YYYY-MM-DD.md` from a concise, emoji-headed template
- Hermes agents: installs the Hermes CLI (rolling, tracks `hermes_git_branch`) and configures one on-device profile per entry in `hermes_agents` (default `mack`, using model `gpt-5.6-sol` via the `openai-codex` OAuth provider). Adding an agent is a single `hermes_agents` list entry. Each agent can declare `crons` (scheduled jobs, reconciled by name into `<profile>/cron/jobs.json`) — e.g. a `daily-standup` at 08:00. An agent with `gateway: true` gets a per-profile launchd **user** service (no sudo) that runs the cron scheduler and starts on login, so its crons actually fire. Upgrades are opt-in via `-t upgrade` (runs `hermes update`: pulls latest, reinstalls deps, re-syncs skills, migrates config). The subscription credential is **not** stored in git — each agent with `auth: true` triggers a **one-time interactive OAuth login** saved to `~/.hermes/auth.json`.
  - The bundled `daily-standup` is scoped to yesterday's single journal file and Hermes session history. It must not search other local directories; calendar lookup remains disabled until an integration is configured.

**Not managed (intentional):** any plaintext secrets you may have in `~/.zshrc` / `~/.zprofile`. The playbook writes its content inside marker blocks (`# BEGIN/END ANSIBLE MANAGED BLOCK: ...`), so anything else in those files is left alone. If you want to keep secrets out of git, move them to `~/.zshrc.secrets` and source it from `~/.zshrc`.

## Configuration

All knobs live in [`vars.yml`](vars.yml):
- `homebrew_taps`, `homebrew_formulae`, `homebrew_casks`
- `pipx_packages`, `vscode_extensions`
- `hermes_agents`, `hermes_default_profile`, `hermes_auth_enabled`
- `obsidian_vault_path`, `obsidian_journal_folder`, `obsidian_templates_folder`
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
| `upgrade` | Brew formulae and pipx packages upgraded to latest; `hermes update` (pull latest + reinstall deps + re-sync skills + migrate config) |
| `cleanup` | `brew autoremove` + `brew cleanup --prune=all` (housekeeping) |
| `aliases,shell` | Just the aliases managed block |
| `env,shell` | Just the env-vars managed block |
| `git` | Global git config |
| `pipx` | pipx packages |
| `terminal` | Ghostty config + starship prompt + `.zshrc` starship init |
| `herdr` | herdr `config.toml` + agent integrations (claude/codex/hermes state hooks) |
| `hermes` | Install Hermes + configure agent profiles/models from `hermes_agents`; interactive OpenAI (Codex) login gate |
| `obsidian` | Daily journal folders, template, and Daily Notes/Templates settings |
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

## Testing on a clean machine

[`test/vm_test.sh`](test/README.md) runs the whole thing against a throwaway
macOS VM ([Tart](https://tart.run)): it clones a base image, boots it headless,
runs `bootstrap_mac.sh` from nothing, re-runs the playbook to assert
`changed=0`, and checks the resulting end state against `vars.yml`.

```bash
test/vm_test.sh --minimal --touchid
```

`--minimal` swaps in [`test/test-vars.yml`](test/test-vars.yml), which trims the
package lists to a handful of small formulae plus one tap and one cask — every
task still runs for real, without a 20GB Homebrew download. Drop it to test the
full package lists.

Needs `tart` + `sshpass` and a base image (`tart clone
ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base`). See
[`test/README.md`](test/README.md) for options, the two prompts that get
stubbed out, and disk-space expectations.

## SSH key gate

An SSH key is treated as a prerequisite: every run starts with a check for a private key in `~/.ssh` (`id_ed25519` / `id_ecdsa` / `id_rsa`). If none exists you're prompted to either type `generate` (creates a passphrase-less ed25519 key and prints the public key to add to GitHub) or press Enter to abort and import an existing key first. Non-interactive runs abort with the same instructions; pass `-e ssh_gate_action=generate` to generate unattended. Bypass the gate entirely with `-e ssh_gate_enabled=false`.

## Notes

- Sudo: only the `touchid` task needs root. A normal full run needs `-K` (it will prompt for your sudo password), or run `ansible-playbook mac-setup.yml --skip-tags touchid` to keep it password-free. Everything else (Homebrew included) runs as the user.
- The playbook expects Homebrew at `/opt/homebrew/bin/brew` (Apple Silicon). For Intel Macs, change the `PATH` in `vars.yml` to use `/usr/local/bin` and adjust the brew check in `tasks/homebrew.yml`.
