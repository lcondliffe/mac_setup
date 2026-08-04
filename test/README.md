# Clean-machine test harness

Runs the playbook end-to-end against a throwaway macOS VM ([Tart](https://tart.run)),
so a "does this still work on a fresh Mac?" answer doesn't require a fresh Mac.

## What it checks

1. **Bootstrap from nothing** — `./bootstrap_mac.sh` on a machine with no Homebrew
   and no Ansible, exercising the real first-run path.
2. **Idempotency** — a second `ansible-playbook` run must report `changed=0`.
   Any task that reports changed twice is a bug and is listed in the summary.
3. **End state** — [`verify.sh`](verify.sh) asserts directories, the `.zshrc`
   managed blocks, git config, tooling on `PATH`, the generated SSH key, the
   Obsidian journal setup, and the
   macOS `defaults`. Package coverage is derived from `vars.yml` by running the
   playbook's own `audit` tag, so it can't drift from the package lists.
4. **touchid** (opt-in, `--touchid`) — the one task needing root.

## Prerequisites

```bash
brew install cirruslabs/cli/tart sshpass
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
```

The base VM is only ever **cloned**, never modified. Cirrus base images use
`admin` / `admin` with passwordless sudo; override with `VM_USER` / `VM_PASS`.

## Usage

```bash
test/vm_test.sh
```

| Option | Effect |
|---|---|
| `--base NAME` | Base VM to clone (default `tahoe-base`) |
| `--vm NAME` | Ephemeral test VM name (default `mac-setup-test`) |
| `--tags TAGS` | Limit the playbook to these tags (fast smoke runs) |
| `--skip-tags TAGS` | Extra tags to skip |
| `--minimal` | Use [`test-vars.yml`](test-vars.yml) — cut-down package lists |
| `--vars-file PATH` | Layer an arbitrary vars file over `vars.yml` |
| `--touchid` | Also exercise the `touchid` task |
| `--reuse` | Reuse the existing test VM instead of re-cloning |
| `--keep` | Leave the VM running afterwards for poking around |
| `--no-idempotency` | Skip the second run |
| `--no-verify` | Skip the end-state assertions |

**The default day-to-day run** — exercises every task on a clean machine, with
cut-down package lists so it finishes in minutes instead of hours:

```bash
test/vm_test.sh --minimal --touchid
```

Quick plumbing check (a few minutes — still installs Homebrew and Ansible):

```bash
test/vm_test.sh --tags dirs,env,shell,git --no-verify
```

Full run including every formula and cask in `vars.yml` — slow, and see the
disk-space note below:

```bash
test/vm_test.sh --touchid
```

Iterate on a failure without paying for a re-clone:

```bash
test/vm_test.sh --keep --tags obsidian
test/vm_test.sh --reuse --keep --tags obsidian
```

Logs land in `test/logs/<timestamp>/` (gitignored): `run1-bootstrap.log`,
`run2-idempotency.log`, `verify.log`.

## What is stubbed out, and why

One task pauses for input on a fresh machine. The harness drives it down its
unattended path, so that prompt is **not** covered:

- `-e ssh_gate_action=generate` — takes the "generate a key" branch of the SSH
  gate instead of prompting. The abort branch isn't exercised.

## Minimal mode

[`test-vars.yml`](test-vars.yml) overrides only the package lists and the Dock
layout. Everything else — aliases, env block, git settings, the SSH gate,
Obsidian, krew, the macOS `defaults` — still comes from `vars.yml` and is tested
for real. It keeps one tap, one cask, and five small formulae, which is enough to
exercise every Homebrew code path (tap / formula / cask) without the download.

`dock_apps` is overridden too: the real list points at apps that only exist
once the full cask list is installed, and missing apps are skipped (with a
report), which would leave the layout task nothing to pin. Minimal mode points
it at Safari and two `/System/Applications` bundles, so the Dock layout task
still runs for real.

The audit-based package check reads whichever vars file the run used, so minimal
mode checks the minimal lists — it can't produce false failures.

## Disk space

A full run installs every formula and cask in `vars.yml` — roughly **20 GB** —
into the clone's copy-on-write disk, which consumes **host** disk as the guest
writes. The script warns below 40 GB free. Use `--minimal` unless you're
specifically testing the package lists.

Expect a full run to take a while: the VM gets 4 CPUs and 8 GB RAM, and the
cask downloads (Chrome, VSCode, Zoom, gcloud-cli, PowerShell…) dominate.
