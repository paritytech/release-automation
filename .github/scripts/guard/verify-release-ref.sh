#!/usr/bin/env bash
#
# Verifies that a stable release tag names a ref we are willing to build.
#
# IMPORTANT: this logic is deliberately owned by release-automation and is never
# sourced from the repository under verification. The guard validates a tag and
# the pipeline then checks that tag out; if the guard sourced its own validation
# from the tree at that tag, whoever could craft a tag could also supply a
# validator that returns success, and the guard would validate itself away.
# `validate_stable_tag` therefore exists both here and in polkadot-sdk's
# lib.sh on purpose, and this copy is stricter (it requires the `polkadot-`
# prefix). Do not "de-duplicate" it.
# See paritytech/release-engineering#310 and #314.
#
# Requires: gh (authenticated via GH_TOKEN), jq.
# Reads:    RELEASES_ON, RELEASE_TAG
# Writes:   sha, stable_branch  -> $GITHUB_OUTPUT

set -euo pipefail

readonly UPSTREAM_REPO="paritytech/polkadot-sdk"

# Release tags are always polkadot-stableYYMM, with an optional patch and rc
# suffix: polkadot-stable2609, polkadot-stable2509-3, polkadot-stable2609-rc2,
# polkadot-stable2509-10-rc1. The bare `stableYYMM` form is rejected: it is
# never used for tags, and it is the name of the release branch itself.
readonly TAG_PATTERN='^polkadot-stable[0-9]{4}(-[0-9]+)?(-rc[0-9]+)?$'

# Written to stderr so it still reaches the log when called inside $(...).
fail() {
	echo "::error title=${1}::${2}" >&2
	exit 1
}

# api <not-found title> <not-found message> <gh api args...>
#
# Prints the response on success. A 404 fails with the given message; any other
# failure (rate limit, auth, 5xx, timeout) fails with the API's own error rather
# than being mistaken for a missing ref. Callers use plain `var=$(api ...)`
# assignments so `set -e` stops the script when the subshell fails.
api() {
	local title=$1 msg=$2 out err
	shift 2
	err=$(mktemp)
	if out=$(gh api "$@" 2>"$err"); then
		rm -f "$err"
		printf '%s' "$out"
		return 0
	fi
	out=$(<"$err")
	rm -f "$err"
	[[ "$out" == *"HTTP 404"* ]] && fail "$title" "$msg"
	fail "GitHub API error" "gh api $* failed: ${out}"
}

# 0. The release killswitch (vars.RELEASES_ON) must be on. Checked here rather
#    than inline in the workflow so the tests in tests/ can exercise it.
[[ "${RELEASES_ON:-}" == "true" ]] ||
	fail "Releases are disabled" \
		"vars.RELEASES_ON is '${RELEASES_ON:-unset}', expected 'true'. Set it to 'true' to allow releases."

: "${RELEASE_TAG:?RELEASE_TAG is required}"

# 1. The tag must look like a stable release tag.
[[ "$RELEASE_TAG" =~ $TAG_PATTERN ]] ||
	fail "Invalid release tag" "'${RELEASE_TAG}' does not match ${TAG_PATTERN}"

# 2. Resolve the tag to a commit.
ref_json=$(api "Tag not found" "'${RELEASE_TAG}' is not a tag in ${UPSTREAM_REPO}" \
	"repos/${UPSTREAM_REPO}/git/ref/tags/${RELEASE_TAG}")

obj_type=$(jq -r '.object.type' <<<"$ref_json")
obj_sha=$(jq -r '.object.sha' <<<"$ref_json")
while [[ "$obj_type" == "tag" ]]; do
	tag_json=$(api "Tag not found" "Tag object ${obj_sha} for '${RELEASE_TAG}' is missing" \
		"repos/${UPSTREAM_REPO}/git/tags/${obj_sha}")
	obj_type=$(jq -r '.object.type' <<<"$tag_json")
	obj_sha=$(jq -r '.object.sha' <<<"$tag_json")
done

[[ "$obj_type" == "commit" ]] ||
	fail "Tag does not point at a commit" "'${RELEASE_TAG}' points at a ${obj_type} (${obj_sha})"

commit_json=$(api "Commit not found" "Commit ${obj_sha} for '${RELEASE_TAG}' is missing" \
	"repos/${UPSTREAM_REPO}/commits/${obj_sha}")

sha=$(jq -r '.sha' <<<"$commit_json")
verified=$(jq -r '.commit.verification.verified' <<<"$commit_json")
reason=$(jq -r '.commit.verification.reason' <<<"$commit_json")

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] ||
	fail "Unexpected commit SHA" "'${RELEASE_TAG}' resolved to '${sha}'"

# 3. The commit must carry a signature GitHub can verify.
[[ "$verified" == "true" ]] ||
	fail "Unverified commit" "Commit ${sha} is not a verified signed commit (reason: ${reason})"

# 4. Derive the release branch this tag belongs to.
stable_branch=$(sed -E 's/^polkadot-(stable[0-9]{4}).*/\1/' <<<"$RELEASE_TAG")

# 5. The commit must be reachable from the release branch, and that branch must
#    be protected. Only the release branch is accepted, every
#    release tag must come from its stable branch. Accepting master would let
#    anyone able to push a tag name any merged master commit as a release.
#
#    Comparing with the branch as base, a reachable commit reads as 'behind',
#    or 'identical' at the tip; 'ahead' or 'diverged' means it is not on that
#    branch.
protected=$(api "Release branch not found" "Branch '${stable_branch}' does not exist in ${UPSTREAM_REPO}" \
	"repos/${UPSTREAM_REPO}/branches/${stable_branch}" --jq '.protected')
[[ "$protected" == "true" ]] ||
	fail "Release branch not protected" "Branch '${stable_branch}' in ${UPSTREAM_REPO} is not protected"

status=$(api "Compare failed" "Could not compare ${sha} against '${stable_branch}' in ${UPSTREAM_REPO}" \
	"repos/${UPSTREAM_REPO}/compare/${stable_branch}...${sha}" --jq '.status')

case "$status" in
identical | behind) ;;
*)
	fail "Ref not on the release branch" \
		"Commit ${sha} is not reachable from protected branch '${stable_branch}' in ${UPSTREAM_REPO} (status: ${status})"
	;;
esac

# 6. Publish the pinned SHA. Downstream jobs check this out instead of the tag
#    name, so the ref cannot change under the pipeline mid-run.
echo "sha=${sha}" >>"$GITHUB_OUTPUT"
echo "stable_branch=${stable_branch}" >>"$GITHUB_OUTPUT"

cat >>"$GITHUB_STEP_SUMMARY" <<EOF
### Release guard passed

| Check | Result |
| --- | --- |
| Tag | \`${RELEASE_TAG}\` |
| Resolved commit | \`${sha}\` |
| Commit signature | verified by GitHub (${reason}) — not a provenance check |
| Reachable from | protected \`${stable_branch}\` |

Downstream jobs must check out \`${sha}\`, not \`${RELEASE_TAG}\`.
EOF

echo "Guard passed: ${RELEASE_TAG} -> ${sha} (reachable from protected ${stable_branch})"
