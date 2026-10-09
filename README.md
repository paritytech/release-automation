# Release automation repo

This repo runs the release pipelines for `paritytech/polkadot-sdk`: the weekly unstable releases and the stable
releases. Build logic itself lives in polkadot-sdk — every job checks that repo out at the tag being released and
runs its `.github/scripts/`, `scripts/release/` and `docker/`.

Workflows are numbered by stage. `release-*` are the weekly flows, `release-stable-*` the stable ones. Every
sensitive flow starts with `release-guard.yml`, which validates the tag, verifies its signature and pins the
resolved commit SHA that the rest of the run uses.

Release steps for stable are documented in
[polkadot-sdk's RELEASE.md](https://github.com/paritytech/polkadot-sdk/blob/master/docs/RELEASE.md).

**Binaries from the weekly pipeline are for testing only — no guarantees that everything works as expected.**
Stable releases built here are production artifacts.
