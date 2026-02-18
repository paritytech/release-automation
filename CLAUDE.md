# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Release automation for the Polkadot SDK weekly release pipeline. This repo contains GitHub Actions workflows and shell scripts that orchestrate building, signing, and publishing releases for the `paritytech/polkadot-sdk` repository. There is no application code to build or test locally — everything runs as GitHub Actions.

## Repository Structure

- `.github/workflows/` — GitHub Actions workflow files (numbered by stage)
- `.github/scripts/common/lib.sh` — Shared utility functions (version parsing, git ops, GitHub API, GPG, S3)
- `.github/scripts/release/release_lib.sh` — Release-specific functions (version bumping, spec version, prdoc reorg)
- `.github/scripts/release/build-linux-release.sh` — Linux binary build script
- `.github/scripts/release/build-macos-release.sh` — macOS binary build script
- `.github/scripts/release/build-deb.sh` — Debian package build script

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
  ├─ release-30_publish_release_draft.yml  (GitHub release draft)
  └─ release-50_publish-docker.yml    (Docker image builds and publishing)

release-reusable-s3-upload.yml  (S3 artifact upload, used by build stages)
```

Dependencies flow top-to-bottom: branch creation → RC tagging → builds (binaries + runtimes in parallel) → Docker images.

## Version Scheme

- **Weekly version**: `weeklyYYYYwNN` (e.g., `weekly2025w07`)
- **Node version**: `X.XX.X-weeklyYYYYwNN` (e.g., `1.19.0-weekly2025w7`)
- **RC tags**: `polkadot-weeklyYYYYwNN-rcX` (e.g., `polkadot-weekly2025w7-rc1`)
- **Spec version**: `MAJOR_0MINOR_000PATCH` (e.g., v1.15.0 → `1_015_000`)
- **Weekly branches**: `weeklyYYYYwNN` in `paritytech/polkadot-sdk`

## Key Patterns

- All commits and tags are GPG-signed using `pgpkms` (KMS-backed signing)
- GitHub App tokens are used for fine-grained permissions (via `RELEASE_AUTOMATION_APP_ID` / `RELEASE_AUTOMATION_APP_PRIVATE_KEY`)
- Workflows run on Parity's custom runners (`parity-default`, `parity-large`)
- Build container images are dynamically resolved from polkadot-sdk's `.github/env`
- Binary builds produce SHA256 checksums and GPG signatures
- Runtime builds use `srtool` for deterministic, reproducible compilation

## Binaries Built

polkadot, polkadot-parachain, polkadot-omni-node, frame-omni-bencher, chain-spec-builder, substrate-node, eth-rpc, subkey (plus polkadot-execute-worker, polkadot-prepare-worker bundled with polkadot).

## Runtimes Built

westend, asset-hub-westend, bridge-hub-westend, collectives-westend, coretime-westend, glutton-westend, people-westend.

## Shell Script Conventions

- Scripts are sourced with `. ./.github/scripts/common/lib.sh`
- Functions use positional arguments (`$1`, `$2`) with comments documenting expected inputs
- GitHub API calls use `$GITHUB_RELEASE_TOKEN` or `$GITHUB_PR_TOKEN`
- S3 URLs follow pattern: `https://releases.parity.io/<binary>/<version>/<target>/<artifact>`
