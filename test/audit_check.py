"""Turn the playbook's `audit` tag output into pass/fail lines.

Reads the JSON-callback output of `ansible-playbook mac-setup.yml -t audit` on
stdin. Anything declared in vars.yml but not installed is a failure; extra
packages are drift on a real machine, not a test failure, so they're ignored.
Exits non-zero if anything declared is missing.
"""

import json
import sys

MARKER = "casks_in_vars_but_not_installed"


def find_report(data):
    for play in data.get("plays", []):
        for task in play.get("tasks", []):
            for host in task.get("hosts", {}).values():
                msg = host.get("msg")
                if isinstance(msg, dict) and MARKER in msg:
                    return msg
    return None


def main():
    try:
        report = find_report(json.load(sys.stdin))
    except (json.JSONDecodeError, AttributeError) as exc:
        print(f"  FAIL  could not parse audit output: {exc}")
        return 1

    if not report:
        print("  FAIL  audit task produced no report")
        return 1

    rc = 0
    for key, missing in sorted(report.items()):
        if not key.endswith("_in_vars_but_not_installed"):
            continue
        kind = key.split("_in_vars")[0]
        if missing:
            print(f"  FAIL  {kind}: declared but not installed -> {', '.join(missing)}")
            rc = 1
        else:
            print(f"  PASS  {kind}: everything in vars.yml is installed")
    return rc


if __name__ == "__main__":
    sys.exit(main())
