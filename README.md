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
- herdr: `~/.config/herdr/config.toml` (rendered from [`templates/`](templates); deliberate overrides only) plus per-agent state-reporting hooks (`herdr_integrations`) so the sidebar and attention queue can tell running agents apart. Each integration installs into that agent's own config directory, which only exists once the agent has been launched — installing the cask is not enough. Integrations for agents that have never run are skipped with a message; launch them once, then re-run `-t herdr`. Also installs a Claude Code status line (`~/.claude/statusline.py`, rendered from [`templates/`](templates)) that prints Claude's 5h/7d rate-limit usage and reports it to herdr as a `$usage` pane token, shown on the sidebar's claude rows. Claude's status-line payload is the only place those figures are exposed, so there is no equivalent for codex — its rate limits are only in its session logs. The `statusLine` key is merged into `~/.claude/settings.json`; the rest of that file (hooks, model, plugins) is left alone.
- Dictation (`dictation_apps`, currently **superwhisper**): hold `fn` in a herdr pane and the transcript arrives in that agent's prompt. Installs the cask and reports the manual setup — see [Dictating to agents](#dictating-to-agents).
- VSCode extensions
- Obsidian daily journalling: configures Daily Notes to create `Journal/YYYY-MM-DD.md` from a concise, emoji-headed template
- Hermes, the on-device agent: installs the upstream CLI pinned to `hermes_commit` and its launchd gateway (so crons survive logout). Install-only by design — see below.

**Not managed (intentional):**
- Any plaintext secrets you may have in `~/.zshrc` / `~/.zprofile`. The playbook writes its content inside marker blocks (`# BEGIN/END ANSIBLE MANAGED BLOCK: ...`), so anything else in those files is left alone. If you want to keep secrets out of git, move them to `~/.zshrc.secrets` and source it from `~/.zshrc`.
- Hermes' state in `~/.hermes` (persona/SOUL.md, profiles, memories, config, skills). It's the agent's own, grown by talking to it — an earlier attempt at reconciling it from git fought every organic change. Back it up separately instead of managing it as code.

## Configuration

All knobs live in [`vars.yml`](vars.yml):
- `homebrew_taps`, `homebrew_formulae`, `homebrew_casks`
- `pipx_packages`, `vscode_extensions`
- `hermes_commit`, `hermes_install_enabled`
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
| `upgrade` | Brew formulae, casks, and pipx packages upgraded to latest (set `homebrew_cask_upgrade_greedy: true` to also move self-updating casks) |
| `cleanup` | `brew autoremove` + `brew cleanup --prune=all` (housekeeping) |
| `aliases,shell` | Just the aliases managed block |
| `env,shell` | Just the env-vars managed block |
| `git` | Global git config |
| `pipx` | pipx packages |
| `terminal` | Ghostty config + starship prompt + `.zshrc` starship init |
| `herdr` | herdr `config.toml` + agent integrations (claude/codex/hermes state hooks) |
| `hermes` | Hermes agent CLI (pinned to `hermes_commit`) + launchd gateway; `-t upgrade` moves the pin |
| `obsidian` | Daily journal folders, template, and Daily Notes/Templates settings |
| `dictation` | Dictation app install checks + permission/setup report (`dictation_apps`) |
| `vscode` | VSCode extensions |
| `keyboard,shortcuts` | macOS screenshot hotkeys + what the fn/globe key does (`fn_key_usage`) |
| `dock` | macOS Dock preferences + pinned-app layout (`dock_apps` via dockutil) |
| `finder` | macOS Finder preferences (extensions, hidden files, path/status bar, list view) |
| `screenshots` | Screenshot save folder + no window shadow |
| `touchid` | Enable Touch ID for `sudo` (needs `-K`) |
| `audit` | Read-only drift report: installed taps/brews/casks/extensions/pipx and the managed macOS `defaults` vs `vars.yml` |
| `prune` | Uninstall brews/casks/extensions/pipx present on the machine but missing from `vars.yml`. Uninstalls immediately — run `-t audit` first to preview the drift, and keep deliberate one-offs in the `prune_ignore_*` lists |

Example: `ansible-playbook mac-setup.yml -t aliases,shell`

Dry-run / verify idempotency:

```bash
ansible-playbook --syntax-check mac-setup.yml
ansible-playbook --check mac-setup.yml
```

## Testing on a clean machine

CI runs the playbook for real on a GitHub macOS runner on every push/PR:
bootstrap, a second run asserting `changed=0`, and the end-state checks, using
the cut-down [`test/test-vars.yml`](test/test-vars.yml) package lists.

For the genuinely-clean-machine guarantee (the runner image ships Homebrew and
a pile of preinstalled tools), [`test/vm_test.sh`](test/README.md) runs the whole thing against a throwaway
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

## Dictating to agents

[superwhisper](https://superwhisper.com) types into the focused window, so a focused herdr pane gets the transcript as a paste. Ghostty enables secure input at password prompts, so dictation is dead there by design.

`-t dictation` checks the install and reports what is outstanding; `-e dictation_open_settings=true` opens the Settings panes. Grants are read from the TCC databases when the terminal has Full Disk Access, otherwise reported as unknown.

Two steps stay manual:

1. **Permissions** — grant Microphone and Accessibility (the latter is what lets it type into Ghostty). macOS only accepts these from a user click.
2. **Hotkey and modes** — set in the app. A mode is a transcription model plus optional LLM reformatting under your own instructions; one aimed at coding agents ("preserve identifiers and paths verbatim, strip filler, stay imperative") can auto-activate when Ghostty is frontmost. Modes are JSON under `~/superwhisper`, so a good one can be templated later.

`fn_key_usage: 0` (tag `keyboard`) frees fn by setting *Keyboard → "Press 🌐 key to"* to Do Nothing; otherwise macOS keeps the key and the hotkey never fires.

Chosen over Wispr Flow (trialled side by side, July 2026): half the price, on-device transcription, and manageable config — Wispr Flow's preferences are a blob their [MDM guide](https://docs.wisprflow.ai/articles/9363440133-deploy-wispr-flow-via-mdm) confirms cannot be injected.

## Notes

- Sudo: only the `touchid` task needs root. A normal full run needs `-K` (it will prompt for your sudo password), or run `ansible-playbook mac-setup.yml --skip-tags touchid` to keep it password-free. Everything else (Homebrew included) runs as the user.
- The playbook expects Homebrew at `/opt/homebrew/bin/brew` (Apple Silicon). For Intel Macs, change the `PATH` in `vars.yml` to use `/usr/local/bin` and adjust the brew check in `tasks/homebrew.yml`.
