"""Fail when the playbook's JSON audit reports declared packages missing."""

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

    drift = report.get("macos_defaults_drift", [])
    if drift:
        print("  FAIL  macos defaults: drifted from vars.yml ->")
        for entry in drift:
            print(f"          {entry}")
        rc = 1
    else:
        print("  PASS  macos defaults: match vars.yml")
    return rc


if __name__ == "__main__":
    sys.exit(main())
