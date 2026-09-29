#!/usr/bin/env bash
#
# Verifies that a release tag names a ref we are willing to build.
#
# IMPORTANT: this logic is deliberately owned by release-automation and is never
# sourced from the repository under verification. The guard validates a tag and
# the pipeline then checks that tag out; if the guard sourced its own validation
# from the tree at that tag, whoever could craft a tag could also supply a
# validator that returns success, and the guard would validate itself away.
# `validate_stable_tag` therefore exists both here and in polkadot-sdk's
# lib.sh on purpose. Do not "de-duplicate" it.
# See paritytech/release-engineering#310 and #314.
#
# Requires: gh (authenticated via GH_TOKEN), jq.
# Reads:    RELEASE_TAG, UPSTREAM_REPO
# Writes:   sha, stable_branch  -> $GITHUB_OUTPUT

set -euo pipefail

# Matches polkadot-stable2609, stable2509-3, polkadot-stable2609-rc2, ...
readonly TAG_PATTERN='^(polkadot-)?stable[0-9]{4}(-[0-9]+)?(-rc[0-9]+)?$'

fail() {
	echo "::error title=${1}::${2}"
	exit 1
}

: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${UPSTREAM_REPO:?UPSTREAM_REPO is required}"

# 1. The tag must look like a release tag.
[[ "$RELEASE_TAG" =~ $TAG_PATTERN ]] ||
	fail "Invalid release tag" "'${RELEASE_TAG}' does not match ${TAG_PATTERN}"

# 2. Resolve the tag to a commit. This endpoint dereferences both annotated and
#    lightweight tags, which matters because release tags are currently a mix of
#    the two: release-11 creates annotated signed tags, while `gh release create`
#    in release-30 creates lightweight ones.
commit_json=$(gh api "repos/${UPSTREAM_REPO}/commits/${RELEASE_TAG}" 2>/dev/null) ||
	fail "Tag not found" "'${RELEASE_TAG}' does not resolve to a commit in ${UPSTREAM_REPO}"

sha=$(jq -r '.sha' <<<"$commit_json")
verified=$(jq -r '.commit.verification.verified' <<<"$commit_json")
reason=$(jq -r '.commit.verification.reason' <<<"$commit_json")

# 3. The commit it points at must carry a signature GitHub can verify.
[[ "$verified" == "true" ]] ||
	fail "Unverified commit" "Commit ${sha} is not a verified signed commit (reason: ${reason})"

# 4. Derive the release branch this tag belongs to.
stable_branch=$(sed -E 's/^polkadot-//; s/^(stable[0-9]{4}).*/\1/' <<<"$RELEASE_TAG")

# 5. The commit must be reachable from a protected branch. Two branches are
#    acceptable, because release tags legitimately sit on either:
#      - the release branch, for tags cut after branch-off (the common case)
#      - master, for the first rc, which is tagged at branch-off time before
#        the release branch diverges (e.g. polkadot-stable2609-rc1 sits on
#        master and is 'diverged' from stable2609 by nine commits)
#    Requiring only the release branch would reject those first rcs.
#
#    Comparing with the branch as base, a reachable commit reads as 'behind',
#    or 'identical' at the tip; 'ahead' or 'diverged' means it is not on that
#    branch. This is also what rejects throwaway tags: they are on no protected
#    branch, and typically on no branch at all.
verified_branch=""
for candidate in "$stable_branch" master; do
	protected=$(gh api "repos/${UPSTREAM_REPO}/branches/${candidate}" --jq '.protected' 2>/dev/null) || continue
	[[ "$protected" == "true" ]] || continue

	status=$(gh api "repos/${UPSTREAM_REPO}/compare/${candidate}...${sha}" --jq '.status' 2>/dev/null) || continue

	case "$status" in
	identical | behind)
		verified_branch="$candidate"
		break
		;;
	esac
done

[[ -n "$verified_branch" ]] ||
	fail "Ref not on a protected branch" \
		"Commit ${sha} is not reachable from protected branch '${stable_branch}' or 'master' in ${UPSTREAM_REPO}"

# 7. Publish the pinned SHA. Downstream jobs check this out instead of the tag
#    name, so the ref cannot change under the pipeline mid-run.
echo "sha=${sha}" >>"$GITHUB_OUTPUT"
echo "stable_branch=${stable_branch}" >>"$GITHUB_OUTPUT"
echo "verified_branch=${verified_branch}" >>"$GITHUB_OUTPUT"

cat >>"$GITHUB_STEP_SUMMARY" <<EOF
### Release guard passed

| Check | Result |
| --- | --- |
| Tag | \`${RELEASE_TAG}\` |
| Resolved commit | \`${sha}\` |
| Commit signature | verified (${reason}) |
| Release branch | \`${stable_branch}\` |
| Reachable from | protected \`${verified_branch}\` |

Downstream jobs must check out \`${sha}\`, not \`${RELEASE_TAG}\`.
EOF

echo "Guard passed: ${RELEASE_TAG} -> ${sha} (reachable from protected ${verified_branch})"
