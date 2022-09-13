#!/bin/bash

# Github repository, just the name/repo part, no .git suffix, no base url!
REPO="openwrt/openwrt"

# Your repository token, generate this token at your profile page:
# - Navigate to https://github.com/settings/tokens
# - Click on "Generate new token"
# - Enter a description, e.g. "pr.sh" and pick the "repo" scope
# - Hit "Generate token"
#TOKEN="d41d8cd98f00b204e9800998ecf8427e"

PRID="$1"
BRANCH="${2:-master}"
DRY_RUN="$3"
GIT=git

if ! command -v jq &> /dev/null; then
	echo "jq could not be found! This script require jq!"
	exit 1
fi

if [ -z "$PRID" -o -n "${PRID//[0-9]*/}" ]; then
	echo "Usage: $0 <PR-ID> [rebase-branch] [dry-run]" >&2
	exit 1
fi

if [ -n "$DRY_RUN" ]; then
	GIT="echo git"
fi

if [ -z "$(git branch --list "$BRANCH")" ]; then
	echo "Given rebase branch '$BRANCH' does not exist!" >&2
	exit 2
fi

if ! PR_INFO="$(curl -f -s "https://api.github.com/repos/$REPO/pulls/$PRID")"; then
	echo "Failed fetch PR #$PRID info" >&2
	exit 3
fi

if [ "$(echo "$PR_INFO" | jq -r ".maintainer_can_modify")" == "false" ]; then
	echo "PR #$PRID can't be force pushed by maintainers. Can't merge this PR!" >&2
	echo 4
fi

if [ "$(echo "$PR_INFO" | jq -r ".mergeable")" == "false" ]; then
	echo "PR #$PRID is not mergeable for Github.com. Check the PR!" >&2
	echo 5
fi

echo "Pulling current $BRANCH from origin"
$GIT checkout $BRANCH
$GIT fetch origin

if ! $GIT rebase origin/$BRANCH; then
	echo "Failed to rebase $BRANCH with origin/$BRANCH" >&2
	echo 7
fi

PR_USER="$(echo "$PR_INFO" | jq -r ".head.user.login")"
PR_BRANCH="$(echo "$PR_INFO" | jq -r ".head.ref")"
PR_REPO="$(echo "$PR_INFO" | jq -r ".head.repo.html_url")"

if ! $GIT remote get-url $PR_USER &> /dev/null || [ -n "$DRY_RUN" ]; then
	echo "Adding $PR_USER with repo $PR_REPO to remote"
	$GIT remote add  $PR_USER $PR_REPO
fi

echo "Fetching remote $PR_USER"
$GIT fetch $PR_USER

echo "Creating branch $PR_BRANCH"
if ! $GIT checkout -b $PR_BRANCH $PR_USER/$PR_BRANCH; then
	echo "Failed to checkout new branch $PR_BRANCH from $PR_USER/$PR_BRANCH" >&2
	echo 8
fi

echo "Rebasing $PR_BRANCH on top of $BRANCH"
if ! $GIT rebase origin/$BRANCH; then
	echo "Failed to rebase $PR_BRANCH with origin/$BRANCH" >&2
	echo 9
fi

echo "Force pushing $PR_BRANCH to $PR_USER"
if ! $GIT push $PR_USER HEAD --force; then
	echo "Failed to force push HEAD to $PR_USER" >&2
	echo 10
fi

echo "Returning to $BRANCH"
$GIT checkout $BRANCH

echo "Actually merging the PR #$PRID from branch $PR_USER/$PR_BRANCH"
if ! $GIT merge --ff-only $PR_USER/$PR_BRANCH; then
	echo "Failed to merge $PR_USER/$PR_BRANCH on $BRANCH" >&2
	echo 11
fi

echo "Pushing to openwrt git server"
if ! $GIT push; then
	echo "Failed to push to $BRANCH but left branch as is." >&2
	echo 12
fi

echo "Deleting branch $PR_BRANCH"
$GIT branch -D $PR_BRANCH

# Default close comment
COMMENT="Thanks! Rebased on top of $BRANCH and merged!"

if [ -n "$TOKEN" ] && [ -z "$DRY_RUN" ]; then
	echo ""
	echo "Enter a comment and hit <enter> to close the PR at Github automatically now."
	echo "Hit <ctrl>-<c> to exit."
	echo ""
	echo "If you do not provide a comment, the default will be: "
	echo "[$COMMENT]"

	echo -n "Comment > "
	read usercomment

	echo "Sending message to PR..."

	comment="${usercomment:-$COMMENT}"
	comment="${comment//\\/\\\\}"
	comment="${comment//\"/\\\"}"
	comment="$(printf '{"body":"%s"}' "$comment")"

	if ! curl -s -o /dev/null -w "%{http_code} %{url_effective}\\n" --user "$TOKEN:x-oauth-basic" --request POST --data "$comment" "https://api.github.com/repos/$REPO/issues/$PRID/comments" || \
	   ! curl -s -o /dev/null -w "%{http_code} %{url_effective}\\n" --user "$TOKEN:x-oauth-basic" --request PATCH --data '{"state":"closed"}' "https://api.github.com/repos/$REPO/pulls/$PRID"
	then
		echo ""                                                     >&2
		echo "Something failed while sending comment to the PR via ">&2
		echo "the Github API, please review the state manually at " >&2
		echo "https://github.com/$REPO/pull/$PRID"                  >&2
		exit 6
	fi
fi

echo ""
echo "The PR has been merged!"

exit 0
