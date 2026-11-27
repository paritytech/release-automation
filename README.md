# Release automation repo

This repo runs the release pipelines for `paritytech/polkadot-sdk`: the weekly releases and the stable releases.
The stable flows also release the `unstableYYMM` branches on demand (tags `polkadot-unstableYYMM(-X)(-rcX)`). Build logic itself lives in polkadot-sdk — every job checks that repo out at the tag being released and
runs its `.github/scripts/`, `scripts/release/` and `docker/`.

Workflows are numbered by stage. `release-*` are the weekly flows, `release-stable-*` the stable ones. Every
sensitive flow starts with `release-guard.yml`, which validates the tag, verifies its signature and pins the
resolved commit SHA that the rest of the run uses.

Release steps for stable are documented in
[polkadot-sdk's RELEASE.md](https://github.com/paritytech/polkadot-sdk/blob/master/docs/RELEASE.md).

## Stable release order

Each step is dispatched by hand. Nothing is published before the e2e gate has passed on the release candidate.

| Step | Workflow | What it does |
| --- | --- | --- |
| 1 | `release-stable-10` | Branches off a new stable line (new stable only) |
| 2 | `release-stable-15` | Prepares the crates release: plans versions, bumps them, bumps `NODE_VERSION` and `spec_version`, moves prdocs, opens a PR. Publishes nothing. Merge the PR |
| 3 | `release-stable-11` | Tags the rc on the stable branch tip |
| 4 | `release-stable-22` | Builds binaries and runtimes, runs the e2e gate, records its verdict on the rc commit, creates the release draft |
| 5 | `release-stable-80` | Publishes the crates from the rc commit and records that on it |
| 6 | `release-stable-70` | Promotes the rc binaries to final, publishes deb/rpm packages and Docker images |
| 7 | `release-stable-32` | Signs the final tag on the rc commit and publishes the GitHub release |

Steps 5 to 7 refuse an rc without a passing e2e gate verdict.

- **Gate is red:** backport the fix, run step 2 again, tag the next rc and run step 4 again. Nothing has been
  published yet.
- **Running step 2 again:** it plans from what is published and redoes plans that were merged but never
  published. It knows what is published from the record step 5 leaves on the rc commit (commit status
  `release/crates-published`) and from the final tags. If step 5 was started for an rc and did not complete,
  step 2 stops until it has.
- **Release cannot be gated:** older stable lines built with runtimes (they are behind live Westend), crates-only
  releases and partial rebuilds. Set `skip_e2e_gate` on step 4 and on each publishing step. If step 4 already ran
  and only the gate failed, nothing has to be built again: `release-stable-30` with that run's `build_run_id`
  creates the draft (the run's summary lists the inputs).
- **Step 5 says a planned version is taken:** another release line published the same crate version after
  step 2 planned it. Run step 2 again (it plans the next free version), tag a new rc and run step 4 for it.
  Preparing the lines one after the other, each published before the next is planned, avoids this.
- **Crates-only release:** steps 2 and 3, then `release-stable-30` with `crates_only`, then steps 5 and 7. Crates
  are published from a tag, so a crates-only release needs an rc as well.
- **One gated run of step 4 at a time:** a second one cancels the first one's gate, also for another release line.
  Do not start one for an rc while step 6 runs for it either: step 6 reads the verdict at every stage and would
  stop halfway.
- **Test packages:** deb and rpm packages for the staging repo need no verdict, like rc Docker images and crates
  on staging.crates.io.
- **Single-binary rebuild after a green gate:** replaces that binary on the rc path without a new verdict. It is
  the same commit, so the existing verdict stands.

**Binaries from the weekly pipeline are for testing only — no guarantees that everything works as expected.**
Stable releases built here are production artifacts.
