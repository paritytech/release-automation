# Guard helpers

`verify-release-ref.sh` keeps its own copy of the tag validation that also exists
in polkadot-sdk's `lib.sh`. That duplication is deliberate: the guard validates a
tag before the pipeline checks it out, so if it sourced its validation from the
tree at that tag, anyone able to craft a tag could also supply the
`validate_stable_tag` that clears it.

Nothing in here may `source` the checked-out polkadot-sdk tree, and this
directory is exempt from the de-duplication in
paritytech/release-engineering#314.

`tests/` holds the guard's tests, run by `.github/workflows/test-guard.yml`:
`test-verify-release-ref.sh` runs the script against a stubbed GitHub API, and
`check-guard-wiring.py` checks that every guarded workflow checks out
polkadot-sdk at the guard's SHA and asserts it first.
