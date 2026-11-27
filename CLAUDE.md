# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Release automation for the Polkadot SDK weekly and stable release pipelines. This repo contains the GitHub Actions workflows that orchestrate building, signing and publishing releases for `paritytech/polkadot-sdk`. There is no application code to build or test locally — everything runs as GitHub Actions, and the build logic lives in polkadot-sdk, which every job checks out.

## Repository Structure

- `.github/workflows/` — GitHub Actions workflow files (numbered by stage); `release-*` weekly, `release-stable-*` stable
- `.github/scripts/pipeline-lib.sh` — the helpers specific to this repo (weekly version and tag handling)
- `.github/scripts/guard/` — tag verification for `release-guard.yml`, plus its tests

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
- GitHub App tokens are used for fine-grained permissions (via `vars.RELEASE_AUTOMATION_CLIENT_ID` / `RELEASE_AUTOMATION_APP_PRIVATE_KEY`); the App has contents and pull-requests write on polkadot-sdk
- Workflows run on Parity's custom runners (`parity-default`, `parity-large`)
- Build container images are dynamically resolved from polkadot-sdk's `.github/env`
- Binary builds produce SHA256 checksums and GPG signatures
- The polkadot RPM is built in the rpm v4 format and must carry a v4 header signature: rpm 4.x clients (RHEL 8/9, Amazon Linux 2023, Fedora up to 42) treat a package with only an rpm 6 (v6) signature as unsigned
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
