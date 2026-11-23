# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Release automation for the Polkadot SDK weekly and stable release pipelines. This repo contains the GitHub Actions workflows that orchestrate building, signing and publishing releases for `paritytech/polkadot-sdk`. There is no application code to build or test locally — everything runs as GitHub Actions, and the build logic lives in polkadot-sdk, which every job checks out.

## Repository Structure

- `.github/workflows/` — GitHub Actions workflow files (numbered by stage); `release-*` weekly, `release-stable-*` stable
- `.github/scripts/pipeline-lib.sh` — the helpers specific to this repo (weekly version and tag handling)
- `.github/scripts/guard/` — tag verification for `release-guard.yml`, plus its tests
- `.github/scripts/crates/` — the crates publish record that `release-stable-15` and `release-stable-80` read, plus its tests

Everything else — `lib.sh`, `release_lib.sh` and the build scripts — comes from the polkadot-sdk checkout, which
is the source of truth. A CI check fails the build if copies reappear here.

## Workflow Pipeline Architecture

The release is orchestrated as a multi-stage pipeline, triggered weekly (Wednesday 20:00 UTC) or manually:

```
release-01_combined-flow.yml  (orchestrator — calculates inputs, calls all stages)
  ├─ release-10_branchoff-weekly.yml  (create/update weekly branch, bump versions, sign commits)
  ├─ release-11_rc-automation.yml     (compute and push signed RC tags)
  ├─ release-20_build-rc.yml          (build binaries via reusable workflow)
  │     └─ release-reusable-rc-build.yml / release-build-binary.yml
  ├─ release-21_build-runtimes.yml    (deterministic runtime builds via srtool)
  │     └─ release-srtool.yml
  ├─ polkadot-pop-e2e release-gate.yml  (external, advisory: e2e tests on a Westend fork)
  ├─ release-30_publish_release_draft.yml  (GitHub release draft)
  └─ release-50_publish-docker.yml    (Docker image builds and publishing)

release-reusable-s3-upload.yml  (S3 artifact upload, used by build stages)
```

Dependencies flow top-to-bottom: branch creation → RC tagging → builds (binaries + runtimes in parallel) → release draft and publish; Docker images follow the binary build, and the e2e gate runs alongside the draft once both builds are done.

The e2e gate (`e2e-gate` in the combined flow) calls `paritytech/polkadot-pop-e2e`'s `release-gate.yml`, which forks
live Westend, runs it on the `polkadot` and `polkadot-parachain` binaries from this run (bundled by
`bundle-e2e-binaries`), upgrades relay, Asset Hub and People to the runtimes from this run and runs chain tests. It
runs only on full runs (`binary` and `chain` both `all`) and is advisory: nothing waits for it, a red gate does not
block the release, and `release-99_notify-failure.yml` posts its failures to the release Matrix room. The `uses:` ref
is pinned to a commit; the gate still takes its code and network manifests from its own main branch.

The stable pipeline mirrors this as `release-stable-*`, with `release-stable-22` for the combined builds and draft,
`release-stable-70` for promoting to final plus deb, RPM and Docker, and `release-stable-32` to sign the final tag
and publish the draft. The stable flows also release `unstableYYMM` branches; `release-guard.yml` accepts both
`polkadot-stable*` and `polkadot-unstable*` tags. Both pipelines start with `release-guard.yml`.

## Stable Release Order and the E2E Gate

Every step is a manual dispatch. Nothing is published before the e2e gate has passed on the rc:

```
release-stable-10  branch off (new stable line only)
release-stable-15  prepare crates: plan + version bumps + NODE_VERSION/spec_version + prdocs -> PR -> merge
release-stable-11  tag the rc on the stable branch tip = commit C
release-stable-22  build binaries and runtimes at C -> e2e gate -> verdict on C -> release draft
release-stable-80  publish crates from C (no commits, no push) and record that on C
release-stable-70  promote to final on S3, deb/rpm, Docker
release-stable-32  final tag on C, publish the GitHub release
```

The final tag, the tested binaries and the published crate sources are all commit C, so the commit hash that
`polkadot --version` prints is the final tag's. A crates-only release runs 15, 11, `release-stable-30` with
`crates_only`, 80 and 32: 80 publishes from a tag, so it needs an rc too.

- **Verdict.** `release-stable-22` records the gate's result as the commit status `release/e2e-gate` on C in
  polkadot-sdk (`pending` when a gated run starts, then `success`, `failure` or `error`). `release-guard.yml`
  requires a `success` posted by the release App (matched by `vars.RELEASE_AUTOMATION_APP_BOT_ID`) in every
  workflow that publishes: 80 (crates.io, not a dry run), 70, 31, 40 and 41 (production package repo), 50
  (release images) and 32. `check-guard-wiring.py` fails the build if a guard call does not state
  `require_e2e_gate`. The verdict belongs to the commit: a rebuild of the same commit that is not gated
  (partial, or with `skip_e2e_gate`) leaves it as it is. Do not start a gated run of 22 for an rc while 70
  runs for it: every stage of 70 reads the verdict again, and a new `pending` stops it halfway.
- **Scope.** Gated: runs of 22 with `binary: all` and either `chain: all` or `no_runtimes`. With runtimes the
  gate only passes while they are ahead of live Westend (it fails on an equal or lower `spec_version`), which in
  practice means the newest stable line after its `spec_version` bump. With `no_runtimes` the new binaries run
  the fork on Westend's current runtimes.
- **Override.** `skip_e2e_gate`, on 22 and on every publishing workflow, for releases the gate cannot test:
  older stable lines built with runtimes, crates-only releases, partial rebuilds. 22 reports to the release
  Matrix room every gated run that ends without a passing verdict (failed, cancelled, not started, verdict not
  recorded) and every run with `skip_e2e_gate`. When the gate fails only because the release cannot be gated,
  nothing is built again: `release-stable-30` with that run's `build_run_id` creates the draft.
- **One gated run at a time.** The gate's concurrency group is the calling workflow and ref, so two gated runs
  of 22 cancel each other's gate, also across release lines.
- **Publish record.** 80 records on C that its crates were published: commit status `release/crates-published`
  (`release/crates-published-staging` for staging.crates.io), `pending` when the publish starts, then `success`
  or `failure`. Like the verdict it only counts when posted by the release App. Dry runs record nothing. The
  logic that reads it is in `.github/scripts/crates/publish-record.sh`.
- **Re-running 15.** After a fix is backported, 15 runs again before the next rc. It plans from the newest
  published `Plan.toml`, so plans that were merged but never published are redone instead of bumped on top. What
  is published comes from the publish record: the newest rc commit of the line recorded as `success`, otherwise
  the last final tag. It stops when a newer rc has a publish that started and did not complete (finish 80 for
  it first), and `baseline_ref` overrides the lookup. A crate that was never on the registry is the exception:
  it is bumped once more per re-run, because its starting version comes from its manifest.
- **What 80 checks first.** It refuses a commit that still has prdocs at top level, i.e. one that 15 has not
  prepared since the last backport. It also refuses when a version the plan introduces is already on
  crates.io although this line has not published it: another release line took it between 15 and 80, and
  `parity-publish` would skip that crate silently (it reads crates.io for that, also when it uploads to
  staging). Then 15 has to run again (it plans the next free version), followed by a new rc and 22.

Deb and RPM packages for the `release` distribution go to `s3://releases-package-repos` (public, served at
`releases.parity.io/{deb,rpm}`). Staging goes to `s3://staging-package-repos`, so test packages never land in the
production repo.

## Version Scheme

- **Weekly version**: `weeklyYYYYwNN` (e.g., `weekly2025w07`)
- **Node version**: `X.XX.X-weeklyYYYYwNN` (e.g., `1.19.0-weekly2025w7`)
- **RC tags**: `polkadot-weeklyYYYYwNN-rcX` (e.g., `polkadot-weekly2025w7-rc1`)
- **Spec version**: `MAJOR_0MINOR_000PATCH` (e.g., v1.15.0 → `1_015_000`)
- **Weekly branches**: `weeklyYYYYwNN` in `paritytech/polkadot-sdk`
- **Stable/unstable tags**: `polkadot-(un)stableYYMM`, with optional patch `-X` and rc `-rcX` (e.g., `polkadot-stable2509-3-rc1`, `polkadot-unstable2604-rc5`) on branches `(un)stableYYMM`

## Key Patterns

- All commits and tags are GPG-signed using `pgpkms` (KMS-backed signing)
- GitHub App tokens are used for fine-grained permissions (via `vars.RELEASE_AUTOMATION_CLIENT_ID` / `RELEASE_AUTOMATION_APP_PRIVATE_KEY`); the App has contents and pull-requests write on polkadot-sdk, and needs commit statuses write for the e2e gate verdict and the crates publish record. The key is a secret of the `release` environment (`weekly` for the weekly flows)
- Workflows run on Parity's custom runners (`parity-default`, `parity-large`)
- Build container images are dynamically resolved from polkadot-sdk's `.github/env`
- Binary builds produce SHA256 checksums and GPG signatures
- Runtime builds use `srtool` for deterministic, reproducible compilation

## Binaries Built

polkadot, polkadot-parachain, polkadot-omni-node, frame-omni-bencher, chain-spec-builder, substrate-node, eth-rpc, subkey (plus polkadot-execute-worker, polkadot-prepare-worker bundled with polkadot).

## Runtimes Built

westend, asset-hub-westend, bridge-hub-westend, collectives-westend, coretime-westend, glutton-westend, people-westend.

## Shell Script Conventions

- Scripts are sourced with `. ./.github/scripts/common/lib.sh`, which resolves into the polkadot-sdk checkout at the workspace root
- Functions use positional arguments (`$1`, `$2`) with comments documenting expected inputs
- GitHub API calls use `$GITHUB_RELEASE_TOKEN` or `$GITHUB_PR_TOKEN`
- S3 URLs follow pattern: `https://releases.parity.io/<binary>/<version>/<target>/<artifact>`
