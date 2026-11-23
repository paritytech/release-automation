#!/usr/bin/env bash
#
# The record of which release candidates had their crates published, and what
# release-stable-15 and release-stable-80 derive from it.
#
# release-stable-80 posts a commit status on the rc commit it publishes from, in
# paritytech/polkadot-sdk: `pending` when the publish starts, `success` once
# every crate is on the registry, `failure` when the run ended before that. The
# context is `release/crates-published`, or `release/crates-published-staging`
# for rehearsals on staging.crates.io. As with the e2e gate verdict, only
# statuses posted by the release App count: anyone with status write on
# polkadot-sdk can post under these contexts.
#
# From that record:
#   * release-stable-15 learns which Plan.toml is the newest published one, which
#     is where `parity-publish plan` has to start (find_plan_start);
#   * release-stable-80 checks that the versions it is about to publish were not
#     taken on the registry by another release line in the meantime
#     (check_versions_free).
#
# Sourced, not executed. The working directory must be a polkadot-sdk clone with
# the full history and the tags of the release line. Only git data is read from
# it: nothing in that tree is sourced or run.
#
# Failures: `set -e` does not reach into `$(...)`, so no function here relies on
# it. Each one checks its own commands, reports with record_error and returns
# non-zero. Call the functions that print as `var=$(fn ...)` (a plain assignment
# keeps the status) and the ones that set variables as `fn ... || exit 1`.
#
# Requires: git, gh (GH_TOKEN), jq, curl.
# Reads:    RELEASE_AUTOMATION_APP_BOT_ID  numeric user id of the release App's bot

# The result variables are read by whoever sources this file.
# shellcheck disable=SC2034

readonly PUBLISH_RECORD_REPO="paritytech/polkadot-sdk"

# parity-publish decides what to skip from crates.io, whatever registry it
# uploads to, so this is the only index that is ever asked.
readonly CRATES_IO_INDEX="https://index.crates.io"

# Written to stderr so it reaches the log when called inside $(...).
record_error() { # record_error <title> <message>
	echo "::error title=${1}::${2}" >&2
}

# Prints the status context of the publish record for a registry.
publish_context() { # publish_context <crates.io | staging.crates.io>
	case "$1" in
	crates.io) echo "release/crates-published" ;;
	staging.crates.io) echo "release/crates-published-staging" ;;
	*)
		record_error "Unknown registry" "'$1' is neither crates.io nor staging.crates.io"
		return 1
		;;
	esac
}

# Prints the publish record of a commit: the state of the newest status the
# release App posted under <context> (pending, success, failure or error), or
# "none". Statuses from anyone else are ignored, as in the release guard.
publish_state() { # publish_state <commit sha> <context>
	local statuses state
	if [[ ! "${RELEASE_AUTOMATION_APP_BOT_ID:-}" =~ ^[0-9]+$ ]]; then
		record_error "Publish record not configured" \
			"vars.RELEASE_AUTOMATION_APP_BOT_ID must hold the numeric user id of the release App's bot, got '${RELEASE_AUTOMATION_APP_BOT_ID:-unset}'."
		return 1
	fi

	# Newest first. The record is among the last statuses posted on an rc commit,
	# so the first page is enough.
	if ! statuses=$(gh api "repos/${PUBLISH_RECORD_REPO}/commits/$1/statuses?per_page=100"); then
		record_error "GitHub API error" "Could not list the commit statuses of $1 in ${PUBLISH_RECORD_REPO}"
		return 1
	fi
	if ! state=$(jq -r --arg context "$2" --argjson bot "$RELEASE_AUTOMATION_APP_BOT_ID" \
		'[.[] | select(.context == $context and .creator.id == $bot)] | max_by(.id) | .state // "none"' <<<"$statuses"); then
		record_error "GitHub API error" "Unexpected answer when listing the commit statuses of $1"
		return 1
	fi
	echo "$state"
}

# Prints the nearest final tag of a release line that is reachable from a ref,
# or nothing on a line that has none yet.
last_final_tag() { # last_final_tag <branch, e.g. stable2609> <ref>
	git describe --tags --abbrev=0 \
		--match "polkadot-$1" --match "polkadot-$1-[0-9]*" --exclude '*-rc*' "$2" 2>/dev/null || true
}

# Prints the commits that carry a tag of the release line, from <ref> back to
# <stop> (not included), newest first. These are the commits release-stable-80
# can have published from: it only takes tags.
tagged_commits() { # tagged_commits <branch> <ref> <stop ref, may be empty>
	local tagged history
	tagged=$(git for-each-ref \
		--format='%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' \
		"refs/tags/polkadot-$1" "refs/tags/polkadot-$1-*") || return 1
	[[ -n "$tagged" ]] || return 0
	history=$(git rev-list --first-parent "$2" ${3:+"^$3"}) || return 1
	[[ -n "$history" ]] || return 0
	grep -Fx -f <(sort -u <<<"$tagged") <<<"$history" || true
}

# Finds what is already published on a release line, looking back from <ref>.
#
# Walks the tagged commits from <ref> back to the last final tag of the line and
# reads each one's publish record. The newest commit recorded as `success` is
# the baseline: its Plan.toml holds the versions that are on the registry.
# Without one the last final tag is the baseline, because a final tag closes a
# release. A line with neither has nothing published.
#
# A commit newer than the baseline whose record is anything but `success` or
# missing is a publish that started and did not complete. It is reported, not
# judged: release-stable-15 stops on it, release-stable-80 does not.
#
# Sets:
#   LAST_FINAL_TAG    nearest final tag of the line, or empty
#   BASELINE          commit SHA, or "none"
#   BASELINE_SOURCE   "publish record", "final tag" or "none"
#   INCOMPLETE        newest commit after the baseline with an incomplete publish, or empty
#   INCOMPLETE_STATE  its recorded state
find_published_baseline() { # find_published_baseline <branch> <ref> <context>
	local branch=$1 ref=$2 context=$3 commits commit state
	LAST_FINAL_TAG="" BASELINE=none BASELINE_SOURCE=none INCOMPLETE="" INCOMPLETE_STATE=""

	if ! git rev-parse -q --verify "${ref}^{commit}" >/dev/null; then
		record_error "Unknown ref" "'${ref}' is not a commit in this clone"
		return 1
	fi
	LAST_FINAL_TAG=$(last_final_tag "$branch" "$ref")
	commits=$(tagged_commits "$branch" "$ref" "$LAST_FINAL_TAG") || return 1

	while IFS= read -r commit; do
		[[ -n "$commit" ]] || continue
		state=$(publish_state "$commit" "$context") || return 1
		case "$state" in
		none) ;;
		success)
			BASELINE=$commit
			BASELINE_SOURCE="publish record"
			break
			;;
		*)
			if [[ -z "$INCOMPLETE" ]]; then
				INCOMPLETE=$commit
				INCOMPLETE_STATE=$state
			fi
			;;
		esac
	done <<<"$commits"

	# A final tag from before the line had a Plan.toml gives nothing to plan from.
	if [[ "$BASELINE" == none && -n "$LAST_FINAL_TAG" && -n "$(git ls-tree --name-only "$LAST_FINAL_TAG" -- Plan.toml)" ]]; then
		BASELINE=$(git rev-parse --verify "${LAST_FINAL_TAG}^{commit}") || return 1
		BASELINE_SOURCE="final tag"
	fi
}

# Decides where release-stable-15 starts planning on the branch that is checked
# out: `parity-publish plan` continues from the committed Plan.toml and never
# reuses a version the registry has, so that plan has to be the published one.
#
# Sets:
#   PLAN_BASELINE       commit whose Plan.toml holds the published versions, or "none"
#   PLAN_REPLAN         "true" when the branch tip carries a newer plan than that:
#                       it was merged and never published, and is planned again
#   PLAN_FIRST_PREPARE  "true" when the branch never had a Plan.toml
find_plan_start() { # find_plan_start <branch> <registry> <baseline_ref: empty, "none" or a commit SHA>
	local branch=$1 registry=$2 override=$3 context last_plan head_plan base_plan tags
	PLAN_BASELINE=none PLAN_REPLAN=false PLAN_FIRST_PREPARE=false

	last_plan=$(git log -1 --format=%H -- Plan.toml) || return 1
	[[ -n "$last_plan" ]] || PLAN_FIRST_PREPARE=true

	if [[ -n "$override" ]]; then
		echo "::warning::baseline_ref is set: the publish record is not read and planning starts from '${override}'"
		if [[ "$override" != none ]]; then
			PLAN_BASELINE=$(git rev-parse --verify "${override}^{commit}") || return 1
			if ! git merge-base --is-ancestor "$PLAN_BASELINE" HEAD; then
				record_error "Unusable baseline_ref" "${PLAN_BASELINE} is not on this branch"
				return 1
			fi
			if [[ -z "$(git ls-tree --name-only "$PLAN_BASELINE" -- Plan.toml)" ]]; then
				record_error "Unusable baseline_ref" "${PLAN_BASELINE} has no Plan.toml; use 'none' to plan from scratch"
				return 1
			fi
		fi
	elif [[ "$PLAN_FIRST_PREPARE" == true ]]; then
		echo "No Plan.toml on this branch yet: the first prepare run of a new line."
	else
		context=$(publish_context "$registry") || return 1
		find_published_baseline "$branch" HEAD "$context" || return 1
		if [[ -n "$INCOMPLETE" ]]; then
			tags=$(git tag --points-at "$INCOMPLETE" | paste -sd, -)
			record_error "Crates publish did not complete" \
				"The publish from ${tags} (${INCOMPLETE}) to ${registry} started and did not complete (record: ${INCOMPLETE_STATE}). Run release-stable-80 for that tag again, then this workflow. If that run stopped before its 'Publish crates' step, nothing of it is on the registry: set baseline_ref to '${BASELINE}' instead."
			return 1
		fi
		PLAN_BASELINE=$BASELINE
		echo "Last final tag: ${LAST_FINAL_TAG:-none}. Published so far: ${BASELINE} (${BASELINE_SOURCE})."
	fi

	# Something to undo only if the branch tip's plan is not the baseline's.
	head_plan=$(git rev-parse -q --verify "HEAD:Plan.toml" || echo none)
	base_plan=none
	if [[ "$PLAN_BASELINE" != none ]]; then
		base_plan=$(git rev-parse --verify "${PLAN_BASELINE}:Plan.toml") || return 1
	fi
	[[ "$head_plan" == "$base_plan" ]] || PLAN_REPLAN=true
}

# Prints "name version" for every crate version that the Plan.toml of <commit>
# bumps to and that of <baseline> does not have yet: what a publish from
# <commit> uploads once <baseline> is on the registry. Crates a plan leaves at
# their version (`from` equal to `to`) are not being released.
introduced_versions() { # introduced_versions <commit> <baseline commit | none>
	local plan bumped published=""
	plan=$(git show "$1:Plan.toml") || return 1
	bumped=$(awk -F'"' '/^name = /{name=$2} /^from = /{from=$2} /^to = /{if ($2 != from) print name, $2}' <<<"$plan" |
		LC_ALL=C sort -u)
	if [[ "$2" != none ]]; then
		plan=$(git show "$2:Plan.toml") || return 1
		published=$(awk -F'"' '/^name = /{name=$2} /^to = /{print name, $2}' <<<"$plan" | LC_ALL=C sort -u)
	fi
	# An empty list still arrives as one empty line: drop it.
	LC_ALL=C comm -23 <(printf '%s\n' "$bumped") <(printf '%s\n' "$published") | sed '/^$/d'
}

# Prints the path of a crate in a sparse registry index.
index_path() { # index_path <crate name>
	local name
	name=$(tr '[:upper:]' '[:lower:]' <<<"$1")
	case ${#name} in
	1) echo "1/${name}" ;;
	2) echo "2/${name}" ;;
	3) echo "3/${name:0:1}/${name}" ;;
	*) echo "${name:0:2}/${name:2:2}/${name}" ;;
	esac
}

# Prints "name version" when that version of the crate is on crates.io and
# nothing when it is not. Yanked versions count: their number is taken for good.
# Anything but a clear answer (200 or 404) fails, with the status that makes
# xargs stop: a failed lookup must not pass for "not there".
crates_io_lookup() { # crates_io_lookup <crate> <version>
	local body code status=0
	body=$(mktemp) || return 255
	code=$(curl -sS --compressed --retry 3 --retry-all-errors --max-time 30 -o "$body" -w '%{http_code}' \
		"${CRATES_IO_INDEX}/$(index_path "$1")") || code=000
	case "$code" in
	200) if grep -qF "\"vers\":\"$2\"" "$body"; then echo "$1 $2"; fi ;;
	404) ;;
	*)
		record_error "Registry lookup failed" "Index lookup for $1 at ${CRATES_IO_INDEX} failed (HTTP ${code})"
		status=255
		;;
	esac
	rm -f "$body"
	return "$status"
}

# Reads "name version" lines on stdin and prints the ones that are on crates.io,
# sorted. Fails when any lookup fails (see crates_io_lookup).
versions_on_crates_io() { # versions_on_crates_io
	local found
	# A new stable line plans several hundred versions: look them up side by side.
	export -f crates_io_lookup index_path record_error
	export CRATES_IO_INDEX
	# shellcheck disable=SC2016  # expanded by the bash that xargs starts
	found=$(xargs -r -P 8 -n 2 bash -c 'crates_io_lookup "$@"' _) || return 1
	[[ -z "$found" ]] || LC_ALL=C sort <<<"$found"
}

# Fails when a version that a publish from <commit> would upload is already on
# crates.io although this release line has not published it.
#
# release-stable-15 picks the versions days before release-stable-80 publishes
# them. If another release line publishes the same crate at the same version in
# between, `parity-publish apply -p` takes it for already published and skips
# the crate without a word, so this line's change never reaches the registry.
# It reads crates.io for that even when it uploads to staging.crates.io, so
# crates.io is what is checked for both; <registry> only selects the record.
#
# Checked are the versions the commit's plan adds to what is published (see
# find_published_baseline). Once a publish from this commit, or from an earlier
# rc that was never completed, has started, its own uploads cannot be told from
# foreign ones, so nothing is checked.
check_versions_free() { # check_versions_free <branch> <commit> <registry>
	local branch=$1 commit=$2 registry=$3 context own introduced taken count
	context=$(publish_context "$registry") || return 1

	own=$(publish_state "$commit" "$context") || return 1
	if [[ "$own" != none ]]; then
		echo "A publish from ${commit} to ${registry} was started before (record: ${own}): versions found on the registry may be its own, nothing to check."
		return 0
	fi

	find_published_baseline "$branch" "$commit" "$context" || return 1
	if [[ -n "$INCOMPLETE" ]]; then
		echo "::warning title=Planned versions not checked::The publish from ${INCOMPLETE} to ${registry} did not complete (record: ${INCOMPLETE_STATE}). What it uploaded cannot be told from versions taken by another release line."
		return 0
	fi

	introduced=$(introduced_versions "$commit" "$BASELINE") || return 1
	count=$(grep -c . <<<"$introduced" || true)
	echo "Published so far: ${BASELINE} (${BASELINE_SOURCE}). This commit adds ${count} crate version(s)."

	taken=$(versions_on_crates_io <<<"$introduced") || return 1
	if [[ -n "$taken" ]]; then
		record_error "Planned versions are taken" \
			"Already on crates.io, although this release line has not published them: $(awk '{printf "%s%s@%s", sep, $1, $2; sep = ", "}' <<<"$taken"). Another release line took these versions after release-stable-15 planned this rc, and publishing would skip the crates. Run release-stable-15 again (it plans the next free versions), merge its pull request, tag a new rc and run release-stable-22 for it."
		return 1
	fi
	echo "None of them is on crates.io yet."
}
