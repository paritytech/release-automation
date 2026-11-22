#!/usr/bin/env python3
"""Merge every gate's junit results into one verdict.

Reads junit XML files from the directory given as the first argument. The files arrive
as downloaded artifacts, one directory per artifact, named `<gate>-test-results-<rest>`;
the gate name is everything before `-test-results`. Writes a markdown summary to stdout
(meant for $GITHUB_STEP_SUMMARY) and a machine-readable verdict to the path given as the
second argument.

A gate joins the verdict by uploading junit files under that artifact naming scheme.
Nothing here lists the gates; they are discovered from the artifacts present.
"""

import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def gate_name(artifact_dir: str) -> str:
    return artifact_dir.split("-test-results")[0]


def collect(results_dir: Path) -> dict:
    gates: dict[str, dict] = {}
    for xml_path in sorted(results_dir.rglob("*.xml")):
        artifact_dir = xml_path.relative_to(results_dir).parts[0]
        gate = gates.setdefault(
            gate_name(artifact_dir),
            {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "failed": []},
        )
        try:
            root = ET.parse(xml_path).getroot()
        except ET.ParseError as e:
            gate["errors"] += 1
            gate["failed"].append(f"unparseable junit file {xml_path.name}: {e}")
            continue
        suites = root.iter("testsuite")
        for suite in suites:
            gate["tests"] += int(suite.get("tests", 0))
            gate["failures"] += int(suite.get("failures", 0))
            gate["errors"] += int(suite.get("errors", 0))
            gate["skipped"] += int(suite.get("skipped", 0))
            for case in suite.iter("testcase"):
                if case.find("failure") is not None or case.find("error") is not None:
                    gate["failed"].append(f"{case.get('classname', '?')} > {case.get('name', '?')}")
    return gates


def verdict_of(gate: dict) -> str:
    if gate["failures"] or gate["errors"]:
        return "fail"
    if gate["tests"] == 0:
        return "no-results"
    return "pass"


def main() -> int:
    results_dir = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    gates = collect(results_dir)

    candidate = os.environ.get("CANDIDATE", "unknown")
    run_url = os.environ.get("RUN_URL", "")

    print(f"## Release verdict: {candidate}")
    print()
    if not gates:
        print("No gate uploaded test results. Nothing was judged.")
    else:
        print("| Gate | Verdict | Tests | Failed | Skipped |")
        print("|---|---|---|---|---|")
        for name, gate in sorted(gates.items()):
            verdict = verdict_of(gate)
            icon = {"pass": "✅", "fail": "❌", "no-results": "⚪"}[verdict]
            print(f"| {name} | {icon} {verdict} | {gate['tests']} | {gate['failures'] + gate['errors']} | {gate['skipped']} |")
        for name, gate in sorted(gates.items()):
            if gate["failed"]:
                print()
                print(f"### {name}: failed tests")
                for failed in gate["failed"]:
                    print(f"- `{failed}`")

    out = {
        "candidate": candidate,
        "run": run_url,
        "gates": {
            name: {
                "verdict": verdict_of(gate),
                "tests": gate["tests"],
                "failures": gate["failures"] + gate["errors"],
                "skipped": gate["skipped"],
                "failed": gate["failed"],
            }
            for name, gate in sorted(gates.items())
        },
    }
    out_path.write_text(json.dumps(out, indent=2) + "\n")

    # Advisory stage: the verdict reports, it does not block.
    return 0


if __name__ == "__main__":
    sys.exit(main())
