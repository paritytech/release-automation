#!/usr/bin/env bash

# Helpers specific to the pipelines in this repo. Everything else comes from
# polkadot-sdk's .github/scripts, which the build jobs check out.

# Get the current week number and year for weekly version generation
#
# input: none
# output: weekly_version (e.g., weekly2025w1)
get_current_weekly_version() {
    # %G (ISO week-numbering year), not %Y: %V is the ISO week number, and the two
    # disagree across the New Year. On 2025-12-31 the %Y/%V pair yields "weekly2025w01",
    # colliding with the branch cut on 2025-01-01 — the flow would then silently take the
    # "branch already exists" path and cut an RC off a year-old branch.
    current_year=$(date +%G)
    current_week=$(date +%V)
    echo "weekly${current_year}w${current_week}"
}

# Get the next weekly version based on the current one
#
# input: current_weekly_version (weekly2025w1)
# output: next_weekly_version (weekly2025w2)
get_next_weekly_version() {
    current_version="$1"

    if [[ $current_version =~ weekly([0-9]{4})w([0-9]+) ]]; then
        year="${BASH_REMATCH[1]}"
        week="${BASH_REMATCH[2]}"

        # Convert to number and increment
        week_num=$((10#$week))
        next_week=$((week_num + 1))

        # Handle year rollover (assuming max 52 weeks per year)
        if [ $next_week -gt 52 ]; then
            next_year=$((10#$year + 1))
            echo "weekly${next_year}w1"
        else
            printf "weekly%sw%02d" "$year" "$next_week"
        fi
    else
        echo "Invalid weekly version format: $current_version" >&2
        return 1
    fi
}

# Find the latest weekly release branch
#
# input: none
# output: latest_branch_name or empty string if not found
find_latest_weekly_branch() {
    latest_branch=$(git branch -r | grep -E 'origin/weekly[0-9]{4}w[0-9]+' | sed 's/origin\///' | sort -V | tail -1)

    if [ -n "$latest_branch" ]; then
        echo "$latest_branch"
    else
        return 1
    fi
}

# Find the previous weekly release branch based on the current weekly version
#
# input: current_weekly_version (weekly2025w1)
# output: previous_branch_name or empty string if not found
find_previous_weekly_branch() {
    current_weekly_version="$1"

    # Extract year and week from current version
    if [[ $current_weekly_version =~ weekly([0-9]{4})w([0-9]+) ]]; then
        current_year="${BASH_REMATCH[1]}"
        current_week="${BASH_REMATCH[2]}"
    else
        echo "Invalid weekly version format: $current_weekly_version" >&2
        return 1
    fi

    # Convert to numbers for comparison
    current_year_num=$((10#$current_year))
    current_week_num=$((10#$current_week))

    # Find all weekly branches
    weekly_branches=($(git branch -r | grep -E 'origin/weekly[0-9]{4}w[0-9]+' | sed 's/origin\///' | sort -V))

    if [ ${#weekly_branches[@]} -eq 0 ]; then
        return 1
    fi

    # Find the most recent weekly branch before the current one
    previous_branch=""
    for branch in "${weekly_branches[@]}"; do
        if [[ $branch =~ weekly([0-9]{4})w([0-9]+) ]]; then
            branch_year=$((10#${BASH_REMATCH[1]}))
            branch_week=$((10#${BASH_REMATCH[2]}))

            # Check if this branch is older than current
            if [ $branch_year -lt $current_year_num ] ||
               ([ $branch_year -eq $current_year_num ] && [ $branch_week -lt $current_week_num ]); then
                previous_branch="$branch"
            fi
        fi
    done

    if [ -n "$previous_branch" ]; then
        echo "$previous_branch"
    else
        return 1
    fi
}

# List all weekly release branches with details
#
# input: none
# output: formatted list of weekly branches
list_weekly_branches() {
    echo "[+] Getting all weekly release branches:"
    echo "========================================"

    branches=($(git branch -r | grep -E 'origin/weekly[0-9]{4}w[0-9]+' | sed 's/origin\///' | sort -V))

    if [ ${#branches[@]} -eq 0 ]; then
        echo "No weekly branches found"
        return 0
    fi

    echo "Weekly Release Branches:"
    echo "========================"

    for branch in "${branches[@]}"; do
        last_commit=$(git log -1 --format="%h %s" "origin/$branch" 2>/dev/null || echo "N/A")
        last_date=$(git log -1 --format="%ci" "origin/$branch" 2>/dev/null || echo "N/A")
        echo "📁 $branch"
        echo "   Last commit: $last_commit"
        echo "   Date: $last_date"
        echo
    done
}

validate_weekly_release_tag() {
    tag="$1"
    pattern="^(polkadot-)?weekly[0-9]{4}[Ww][0-9]+(-rc[0-9]+)?$"

    if [[ $tag =~ $pattern ]]; then
        echo $tag
    else
        echo "The input '$tag' does not match the pattern."
        exit 1
    fi
}

# Prepare docker weekly tag from the polkadot weekly tag
#
# input: tag (polkadot-weeklyYYYYwNN(-rcX))
# output: weeklyYYYYwNN(-rcX)
prepare_docker_weekly_tag() {
  tag="$1"
  if [[ "$tag" =~ weekly[0-9]{4}[Ww][0-9]+(-rc[0-9]+)? ]]; then
      echo "${BASH_REMATCH[0]}"
  else
      echo "Tag is invalid: $tag"
      exit 1
  fi
}

# Check if a branch exists (local or remote)
#
# input: branch_name
# output: 0 if exists, 1 if not
branch_exists() {
    branch_name="$1"

    # Check local branch
    if git rev-parse --verify -q "$branch_name" &>/dev/null; then
        return 0
    fi

    # Check remote branch
    if git rev-parse --verify -q "origin/$branch_name" &>/dev/null; then
        return 0
    fi

    return 1
}

# Checkout a new branch or switch to it if the branch already exists
#
# input: branch (weeklyW1)
# output: none
checkout_or_switch_branch() {
    branch=$1

    if git rev-parse --verify -q "$branch" &>/dev/null; then
        git checkout -q "$branch"
    else
        git checkout -b "$branch"
    fi
}

# Filter the version matches the particular pattern and return it.
# input: version (v1.8.0 or v1.8.0-rc1)
# output: none
filter_version_from_input() {
  version=$1
  regex="^(v)?[0-9]+\.[0-9]+\.[0-9]+(-weekly[0-9]{4}[Ww][0-9]+)?(-rc[0-9]+)?$"

  if [[ $version =~ $regex ]]; then
      echo $version
  else
      echo "Invalid version: $version"
      exit 1
  fi

}
