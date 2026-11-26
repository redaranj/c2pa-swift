#!/usr/bin/env bash
# Keeps the one GitHub issue that says the c2pa-rs schemas have moved on from
# the copies this repository checks its models against.
#
# There is only ever one such issue, found by the schema-change label and not
# by its title, because the title names the releases compared and changes as
# upstream releases. If several are open, the oldest is the one kept current.
#
# Usage:
#   schema-change-issue.sh report <title> <body-file>
#     Open the issue, or bring the open one's title and body up to date. An
#     issue that already says the same is left alone.
#   schema-change-issue.sh clear <comment-file>
#     Comment on and close the open issue; a no-op when none is open.
#
# Requires REPO and GH_TOKEN in the environment. With DRY_RUN=true it prints
# what it would do and changes nothing.
set -euo pipefail

LABEL="schema-change"
cmd="${1:?usage: schema-change-issue.sh <report|clear> ...}"
dry_run="${DRY_RUN:-false}"

# The list endpoint, not --search: search is only eventually consistent, so an
# issue filed by the previous run might not be found and a second one opened.
open_issue() {
  gh issue list --repo "$REPO" --label "$LABEL" --state open --limit 100 --json number \
    | jq -r 'map(.number) | min // empty'
}

# GitHub stores line endings its own way and drops trailing blank lines.
normalized() {
  tr -d '\r' | sed -e 's/[[:space:]]*$//' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

case "$cmd" in
  report)
    title="${2:?missing title}"
    body_file="${3:?missing body file}"
    number="$(open_issue)"
    if [ -z "$number" ]; then
      if [ "$dry_run" = true ]; then
        echo "Dry run: would open an issue titled: ${title}"
        exit 0
      fi
      gh label create "$LABEL" --repo "$REPO" --color D93F0B \
        --description "Upstream c2pa-rs JSON schema has changed" 2>/dev/null || true
      gh issue create --repo "$REPO" --title "$title" --label "$LABEL" --body-file "$body_file"
      exit 0
    fi

    current="$(gh issue view "$number" --repo "$REPO" --json title,body)"
    if [ "$(jq -r .title <<<"$current")" = "$title" ] \
      && [ "$(jq -r .body <<<"$current" | normalized)" = "$(normalized <"$body_file")" ]; then
      echo "Issue #${number} is already current."
    elif [ "$dry_run" = true ]; then
      echo "Dry run: would update issue #${number} to: ${title}"
    else
      gh issue edit "$number" --repo "$REPO" --title "$title" --body-file "$body_file"
    fi
    ;;
  clear)
    comment_file="${2:?missing comment file}"
    number="$(open_issue)"
    if [ -z "$number" ]; then
      echo "No open schema change issue to close."
    elif [ "$dry_run" = true ]; then
      echo "Dry run: would comment on and close issue #${number}."
    else
      gh issue comment "$number" --repo "$REPO" --body-file "$comment_file"
      gh issue close "$number" --repo "$REPO"
    fi
    ;;
  *)
    echo "unknown command: ${cmd}" >&2
    exit 2
    ;;
esac
