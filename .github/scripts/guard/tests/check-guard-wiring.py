#!/usr/bin/env python3
"""Static check that the release guard actually gates every build from a tag.

Every workflow is checked, so a new one is covered by default. Two explicit
allowlists are exempt from the checkout rules: stable workflows that check out
a branch because no tag exists yet (BRANCH_CHECKOUTS), and the weekly pipeline,
which the guard does not cover (WEEKLY_PIPELINE).

  1. every checkout of paritytech/polkadot-sdk takes `ref:` from the guard SHA
     (`needs.guard.outputs.sha`, or `inputs.sha` in a reusable workflow),
     never from the tag name; allowlisted branch checkouts must not use a tag;
  2. every such checkout is preceded, in the same job, by the canonical
     "Assert the guard ran" step checking that same SHA, because an empty
     `ref:` makes actions/checkout silently fall back to the default branch.
     That step must not be conditional or allowed to fail;
  3. a job reading `needs.guard.outputs.sha` lists `guard` in `needs:`;
  4. every call to a reusable workflow that takes `sha` passes the guard SHA;
  5. in a workflow with a `dry_run` input, the release environment, signing,
     attestation and S3 upload are all skipped in a dry run, so a pull request
     dry run never reaches them.

Usage: python3 .github/scripts/guard/tests/check-guard-wiring.py [workflows dir]
Requires: PyYAML.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: apt-get install python3-yaml, or pip install pyyaml")

ASSERT_NAME = "Assert the guard ran"
ASSERT_RUN = """'[[ "$GUARD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::No verified SHA from the release guard"; exit 1; }'"""
# What the canonical one-liner looks like once YAML has unquoted it.
ASSERT_SCRIPT = yaml.safe_load(f"x: {ASSERT_RUN}")["x"]
GUARD_SHA_EXPRS = ("${{ needs.guard.outputs.sha }}", "${{ inputs.sha }}")
SDK_REPO = "paritytech/polkadot-sdk"
LOCAL_CALL = re.compile(r"\A\./\.github/workflows/(.+\.yml)\Z")

# Stable workflows that run before a release tag exists, so they check out a
# branch and do not call the guard.
BRANCH_CHECKOUTS = {
    "release-stable-10_branchoff.yml",
    "release-stable-11_rc-automation.yml",
    "release-stable-60_post-crates-release-activities.yml",
    "release-stable-80_publish-crates.yml",
}

# The weekly pipeline is not covered by the guard (see release-guard.yml).
WEEKLY_PIPELINE = {
    "release-10_branchoff-weekly.yml",
    "release-11_rc-automation.yml",
    "release-30_publish_release_draft.yml",
    "release-50_publish-docker.yml",
    "release-build-binary.yml",
    "release-reusable-rc-build.yml",
    "release-reusable-s3-upload.yml",
    "release-srtool.yml",
}

# Dry-run rules (5).
DRY_RUN_STEP_IF = "${{ !inputs.dry_run }}"
DRY_RUN_ENVIRONMENT = "${{ !inputs.dry_run && 'release' || '' }}"


def triggers(wf):
    # `on:` parses as True under YAML 1.1.
    return wf.get("on", wf.get(True)) or {}


def call_inputs(wf):
    t = triggers(wf)
    call = t.get("workflow_call") if isinstance(t, dict) else None
    return (call.get("inputs") or {}) if isinstance(call, dict) else {}


def check_assertion():
    """The assertion must reject what a job wired without the guard would see."""
    errors = []
    cases = {
        "": False,  # guard missing from needs:, or skipped
        "polkadot-stable2609-rc2": False,  # tag name passed instead of the SHA
        "1" * 40: True,  # verified SHA
    }
    for guard_sha, want in cases.items():
        got = subprocess.run(
            ["bash", "-c", ASSERT_SCRIPT],
            env={**os.environ, "GUARD_SHA": guard_sha},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if got != want:
            verb = "rejects" if want else "accepts"
            errors.append(f"'{ASSERT_NAME}' {verb} GUARD_SHA={guard_sha!r}")
    return errors


def check_checkouts(where, job, branch_checkouts):
    """Rules 1 and 2."""
    errors = []
    asserted = set()
    for i, step in enumerate(job.get("steps") or []):
        if step.get("name") == ASSERT_NAME:
            if str(step.get("run", "")).strip() != ASSERT_SCRIPT:
                errors.append(f"{where}: step {i} '{ASSERT_NAME}' does not run the canonical assertion")
            for key in ("if", "continue-on-error"):
                if key in step:
                    errors.append(f"{where}: step {i} '{ASSERT_NAME}' must not set '{key}'")
            asserted.add(str((step.get("env") or {}).get("GUARD_SHA", "")))
            continue

        if not str(step.get("uses", "")).startswith("actions/checkout@"):
            continue
        w = step.get("with") or {}
        if str(w.get("repository", "")) != SDK_REPO:
            continue

        ref = str(w.get("ref", ""))
        if branch_checkouts:
            if "tag" in ref.lower():
                errors.append(f"{where}: step {i} is allowlisted for branch checkouts but checks out {ref!r}")
        elif ref not in GUARD_SHA_EXPRS:
            errors.append(f"{where}: step {i} checks out {SDK_REPO} at {ref!r}, not the guard SHA")
        elif ref not in asserted:
            errors.append(f"{where}: step {i} checks out {SDK_REPO} without a preceding '{ASSERT_NAME}' step on {ref}")
    return errors


def check_guard_needs(where, job):
    """Rule 3."""
    needs = job.get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    if "needs.guard.outputs.sha" in yaml.safe_dump(job) and "guard" not in needs:
        return [f"{where}: reads needs.guard.outputs.sha without 'guard' in needs:"]
    return []


def check_sha_calls(where, job, workflows):
    """Rule 4."""
    m = LOCAL_CALL.match(str(job.get("uses", "")))
    if not m or "sha" not in call_inputs(workflows.get(m.group(1), {})):
        return []
    sha = str((job.get("with") or {}).get("sha", ""))
    if sha not in GUARD_SHA_EXPRS:
        return [f"{where}: calls {m.group(1)} with sha={sha!r}, expected the guard SHA"]
    return []


def check_dry_run(where, job):
    """Rule 5."""
    errors = []
    env = job.get("environment")
    if env is not None and env != DRY_RUN_ENVIRONMENT:
        errors.append(f"{where}: environment must be {DRY_RUN_ENVIRONMENT!r} so a dry run gets no environment secrets")

    if "s3-upload" in str(job.get("uses", "")) and not str(job.get("if", "")).startswith("${{ !inputs.dry_run && "):
        errors.append(f"{where}: S3 upload job must be skipped in a dry run (if: ${{{{ !inputs.dry_run && ... }}}})")

    for i, step in enumerate(job.get("steps") or []):
        uses, run = str(step.get("uses", "")), str(step.get("run", ""))
        sensitive = uses.startswith("actions/attest") or "pgpkms" in run or "aws s3" in run
        if sensitive and step.get("if") != DRY_RUN_STEP_IF:
            errors.append(f"{where}: step {i} '{step.get('name', uses)}' signs, attests or uploads; it needs if: {DRY_RUN_STEP_IF}")
    return errors


def main():
    wf_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows")
    workflows = {p.name: yaml.safe_load(p.read_text()) or {} for p in sorted(wf_dir.glob("*.yml"))}

    errors = check_assertion()
    for name, wf in workflows.items():
        if name == "release-guard.yml":
            continue
        has_dry_run = "dry_run" in call_inputs(wf)
        for job_name, job in (wf.get("jobs") or {}).items():
            where = f"{name} :: {job_name}"
            if name not in WEEKLY_PIPELINE:
                errors += check_checkouts(where, job, name in BRANCH_CHECKOUTS)
            errors += check_guard_needs(where, job)
            errors += check_sha_calls(where, job, workflows)
            if has_dry_run:
                errors += check_dry_run(where, job)

    for listed in sorted((BRANCH_CHECKOUTS | WEEKLY_PIPELINE) - workflows.keys()):
        errors.append(f"{listed} is allowlisted but does not exist; remove it from the allowlist")

    if errors:
        print("Guard wiring problems:")
        for e in errors:
            print(f"  {e}")
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
