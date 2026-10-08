#!/usr/bin/env bash
#
# Unit tests for ../verify-release-ref.sh. Each case builds a fake polkadot-sdk
# API from fixtures (see fake-gh), runs the guard against it, and checks that it
# passed or halted with the expected error title.
#
# Usage: .github/scripts/guard/tests/test-verify-release-ref.sh
# Requires: bash, jq.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="${here}/../verify-release-ref.sh"
repo="repos/paritytech/polkadot-sdk"

readonly COMMIT_SHA="1111111111111111111111111111111111111111"
readonly TAG_OBJECT_SHA="2222222222222222222222222222222222222222"

failures=0
passes=0

# --- fixture builders --------------------------------------------------------

new_case() {
	case_dir=$(mktemp -d)
	mkdir -p "${case_dir}/fixtures" "${case_dir}/bin"
	ln -s "${here}/fake-gh" "${case_dir}/bin/gh"
	: >"${case_dir}/fixtures/calls"
}

fixture() { # fixture <api path> <json body>
	mkdir -p "$(dirname "${case_dir}/fixtures/$1")"
	printf '%s\n' "$2" >"${case_dir}/fixtures/$1"
}

fixture_error() { # fixture_error <api path> <stderr text>
	mkdir -p "$(dirname "${case_dir}/fixtures/$1")"
	printf '%s\n' "$2" >"${case_dir}/fixtures/$1.error"
}

lightweight_tag() { # lightweight_tag <tag> [object type]
	fixture "${repo}/git/ref/tags/$1" \
		"{\"ref\":\"refs/tags/$1\",\"object\":{\"type\":\"${2:-commit}\",\"sha\":\"${COMMIT_SHA}\"}}"
}

annotated_tag() { # annotated_tag <tag>
	fixture "${repo}/git/ref/tags/$1" \
		"{\"ref\":\"refs/tags/$1\",\"object\":{\"type\":\"tag\",\"sha\":\"${TAG_OBJECT_SHA}\"}}"
	fixture "${repo}/git/tags/${TAG_OBJECT_SHA}" \
		"{\"sha\":\"${TAG_OBJECT_SHA}\",\"object\":{\"type\":\"commit\",\"sha\":\"${COMMIT_SHA}\"}}"
}

commit() { # commit <verified true|false> <reason>
	fixture "${repo}/commits/${COMMIT_SHA}" \
		"{\"sha\":\"${COMMIT_SHA}\",\"commit\":{\"verification\":{\"verified\":$1,\"reason\":\"$2\"}}}"
}

branch() { # branch <name> <protected true|false>
	fixture "${repo}/branches/$1" "{\"name\":\"$1\",\"protected\":$2}"
}

compare() { # compare <branch> <status>
	fixture "${repo}/compare/$1...${COMMIT_SHA}" "{\"status\":\"$2\"}"
}

# A tag that should pass: verified commit, reachable from its protected branch.
valid_release() { # valid_release <tag> <branch>
	lightweight_tag "$1"
	commit true valid
	branch "$2" true
	compare "$2" behind
}

# --- runner ------------------------------------------------------------------

# run_guard <tag> [RELEASES_ON value, "unset" to leave it out]
run_guard() {
	local releases_on=${2-true}
	: >"${case_dir}/output" >"${case_dir}/summary"
	local -a env=(
		"PATH=${case_dir}/bin:${PATH}"
		"FAKE_GH_FIXTURES=${case_dir}/fixtures"
		"GITHUB_OUTPUT=${case_dir}/output"
		"GITHUB_STEP_SUMMARY=${case_dir}/summary"
		"RELEASE_TAG=$1"
	)
	[[ "$releases_on" != "unset" ]] && env+=("RELEASES_ON=${releases_on}")
	env -i HOME="$HOME" "${env[@]}" bash "$guard" >"${case_dir}/stdout" 2>"${case_dir}/stderr"
}

ok() {
	passes=$((passes + 1))
	echo "ok    - $1"
}

not_ok() {
	failures=$((failures + 1))
	echo "FAIL  - $1"
	echo "        $2"
	sed 's/^/        | /' "${case_dir}/stderr"
}

# expect_pass <name> <tag> <expected branch>
expect_pass() {
	local name=$1 tag=$2 want_branch=$3
	if ! run_guard "$tag"; then
		not_ok "$name" "expected the guard to pass, it halted"
	elif ! grep -qx "sha=${COMMIT_SHA}" "${case_dir}/output"; then
		not_ok "$name" "expected sha=${COMMIT_SHA} in GITHUB_OUTPUT, got: $(tr '\n' ' ' <"${case_dir}/output")"
	elif ! grep -qx "stable_branch=${want_branch}" "${case_dir}/output"; then
		not_ok "$name" "expected stable_branch=${want_branch} in GITHUB_OUTPUT, got: $(tr '\n' ' ' <"${case_dir}/output")"
	else
		ok "$name"
	fi
	rm -rf "$case_dir"
}

# expect_halt <name> <tag> <expected ::error title> [RELEASES_ON] [no-api]
expect_halt() {
	local name=$1 tag=$2 title=$3 releases_on=${4-true} no_api=${5-}
	if run_guard "$tag" "$releases_on"; then
		not_ok "$name" "expected the guard to halt with '${title}', it passed"
	elif ! grep -qF "::error title=${title}::" "${case_dir}/stderr"; then
		not_ok "$name" "expected error title '${title}'"
	elif [[ -s "${case_dir}/output" ]]; then
		not_ok "$name" "halted but still wrote outputs: $(tr '\n' ' ' <"${case_dir}/output")"
	elif [[ "$no_api" == "no-api" && -s "${case_dir}/fixtures/calls" ]]; then
		not_ok "$name" "expected to halt before any API call, called: $(tr '\n' ' ' <"${case_dir}/fixtures/calls")"
	else
		ok "$name"
	fi
	rm -rf "$case_dir"
}

# --- cases -------------------------------------------------------------------

new_case
valid_release polkadot-stable2609-rc2 stable2609
expect_pass "valid rc tag on its protected stable branch passes" polkadot-stable2609-rc2 stable2609

new_case
valid_release polkadot-stable2509-3 stable2509
compare stable2509 identical
expect_pass "patch release tag at the branch tip passes" polkadot-stable2509-3 stable2509

new_case
annotated_tag polkadot-stable2609-rc1
commit true valid
branch stable2609 true
compare stable2609 behind
expect_pass "annotated tag is dereferenced to its commit" polkadot-stable2609-rc1 stable2609

new_case
valid_release polkadot-stable2609-rc2 stable2609
expect_halt "RELEASES_ON=false halts" polkadot-stable2609-rc2 "Releases are disabled" false no-api

new_case
valid_release polkadot-stable2609-rc2 stable2609
expect_halt "RELEASES_ON unset halts" polkadot-stable2609-rc2 "Releases are disabled" unset no-api

new_case
valid_release polkadot-stable2609-rc2 stable2609
commit false unsigned
expect_halt "commit without a verified signature halts" polkadot-stable2609-rc2 "Unverified commit"

new_case
valid_release polkadot-stable2609-rc1 stable2609
compare stable2609 diverged
expect_halt "tag off its stable branch (diverged, e.g. tagged on master) halts" \
	polkadot-stable2609-rc1 "Ref not on the release branch"

new_case
valid_release polkadot-stable2609-rc2 stable2609
compare stable2609 ahead
expect_halt "tag ahead of its stable branch halts" polkadot-stable2609-rc2 "Ref not on the release branch"

new_case
valid_release polkadot-stable2609-rc2 stable2609
branch stable2609 false
expect_halt "unprotected release branch halts" polkadot-stable2609-rc2 "Release branch not protected"

new_case
lightweight_tag polkadot-stable7777-rc3
commit true valid
expect_halt "missing release branch halts" polkadot-stable7777-rc3 "Release branch not found"

for hostile in 'stable2609; rm -rf /' 'master' 'stable2606' 'polkadot-stable2609-rc' \
	'polkadot-stable2609-rc2 ' 'refs/tags/polkadot-stable2609-rc2' '../polkadot-stable2609'; do
	new_case
	expect_halt "malformed tag '${hostile}' halts before any API call" "$hostile" "Invalid release tag" true no-api
done

new_case
expect_halt "nonexistent tag halts" polkadot-stable2609-rc9 "Tag not found"

new_case
lightweight_tag polkadot-stable2609-rc2 tree
expect_halt "tag pointing at a tree halts" polkadot-stable2609-rc2 "Tag does not point at a commit"

new_case
fixture_error "${repo}/git/ref/tags/polkadot-stable2609-rc2" "Server Error (HTTP 500)"
expect_halt "5xx is reported as an API error, not a missing tag" polkadot-stable2609-rc2 "GitHub API error"

new_case
valid_release polkadot-stable2609-rc2 stable2609
fixture_error "${repo}/branches/stable2609" "API rate limit exceeded (HTTP 403)"
expect_halt "rate limit is reported as an API error, not a missing branch" polkadot-stable2609-rc2 "GitHub API error"

echo
echo "${passes} passed, ${failures} failed"
((failures == 0))
