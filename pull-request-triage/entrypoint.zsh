#!/bin/zsh
set -e
set -o pipefail

# When exiting, return exit code 78 (EX_CONFIG) to stop the action
# with a neutral status, instead of success / failure. See:
# - https://developer.github.com/actions/creating-github-actions/accessing-the-runtime-environment/#exit-codes-and-statuses
# - https://man.openbsd.org/sysexits.3#EX_CONFIG

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo Set the GITHUB_TOKEN env variable.
	exit 78
fi

URI=https://api.github.com
API_VERSION=v3
API_HEADER="Accept: application/vnd.github.${API_VERSION}+json"
AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

typeset -A LABELS
LABELS=(
	core    'Area: core'
	init    'Area: init'
	install 'Area: installer'
	update  'Area: updater'
	plugin  'Area: plugin'
	theme   'Area: theme'
	uninstall   'Area: uninstaller'
	new_plugin  'New: plugin'
	new_theme   'New: theme'
	plugin_aws  'Plugin: aws'
	plugin_git  'Plugin: git'
	plugin_mercurial    'Plugin: mercurial'
	plugin_tmux 'Plugin: tmux'
	alias       'Topic: alias'
	bindkey     'Topic: bindkey'
	completion  'Topic: completion'
	conflicts   'Status: conflicts'
)

has_conflicts() {
	git -c user.name=bot -c user.email=b@o.t \
		merge --no-commit --no-ff $GITHUB_SHA && ret=1 || ret=0
	git merge --abort &>/dev/null
	return $ret
}

triage_pull_request() {
	local -aU labels
	local -aU files plugins themes
	local file plugin theme diff

	# Changed files
	files=("${(f)$(git diff --name-only HEAD...$GITHUB_SHA)}")

	# Filter files to only obtain core files (inside 'lib/' or 'tools/')
	if (( ${files[(I)lib/*|tools/*]} > 0 )); then
		labels+=($LABELS[core])
	fi

	# Filter files to only obtain changed plugins ('plugins/$name')
	plugins=(${(M)files#plugins/*/})
	if (( $#plugins > 0 )); then
		labels+=($LABELS[plugin])
		for plugin ($plugins); do
			# If the plugin doesn't exist mark it as new
			[[ ! -e "$plugin" ]] && labels+=($LABELS[new_plugin])
		done
	fi

	# Filter files to only obtain changed themes ('themes/$name.zsh-theme')
	themes=(${(M)files#themes/*.zsh-theme})
	if (( $#themes > 0 )); then
		labels+=($LABELS[theme])
		for theme ($themes); do
			[[ ! -e "$theme" ]] && labels+=($LABELS[new_theme])
		done
	fi

	# Loop over the rest of the files for miscellaneous tests
	for file ($files); do
		case $file in
			oh-my-zsh.(sh|.zsh)) labels+=($LABELS[init]) ;;
			tools/*upgrade.sh) labels+=($LABELS[update]) ;;
			tools/install.sh) labels+=($LABELS[install]) ;;
			tools/uninstall.sh) labels+=($LABELS[uninstall]) ;;
			plugins/aws/*) labels+=($LABELS[plugin_aws]) ;;
			plugins/git/*) labels+=($LABELS[plugin_git]) ;;
			plugins/mercurial/*) labels+=($LABELS[plugin_mercurial]) ;;
			plugins/tmux/*) labels+=($LABELS[plugin_tmux]) ;;
		esac

		case ${file:t} in
			*.zsh) # check if or aliases or bindkeys are added, deleted or modified
				diff=$(git diff HEAD...$GITHUB_SHA -- $file)
				grep -q -E '^[-+][ #]*alias ' <<< $diff && labels+=($LABELS[alias])
				grep -q -E '^[-+][ #]*bindkey ' <<< $diff && labels+=($LABELS[bindkey]) ;;
			_*) # check if completion files are added, deleted or modified
				labels+=($LABELS[completion]) ;;
		esac
	done

	# Print labels in ascending order and quote for labels with spaces
	if (( $#labels > 0 )); then
		print -l ${(oq)labels}
	fi
}

main() {
	local action number owner repo sha replace=0
	local -aU current_labels labels

	# Get basic info
	action=$(jq --raw-output .action "$GITHUB_EVENT_PATH")
	number=$(jq --raw-output .number "$GITHUB_EVENT_PATH")
	owner=$(jq --raw-output .pull_request.base.repo.owner.login "$GITHUB_EVENT_PATH")
	repo=$(jq --raw-output .pull_request.base.repo.name "$GITHUB_EVENT_PATH")

	# We only care about the PR if it was opened or updated. These are the only
	# actions where there will be code changes to sort out.
	if [[ "$action" != (opened|synchronize) ]]; then
		exit 78
	fi

	# Obtain SHA of the HEAD commit of the Pull Request
	sha=$(jq --raw-output .pull_request.head.sha "$GITHUB_EVENT_PATH")

	# Regarding $GITHUB_SHA:
	#
	# GitHub Actions' environment makes it so that a `GITHUB_SHA` is the head of
	# the Pull Request only if the branch is available in the original repository.
	#
	# On the contrary, if the Pull Request's HEAD can only be found in a fork repo,
	# the `GITHUB_SHA` variable will point to the newest base commit of the PR
	# branch that is contained in the list of commits of the forked repository.
	#
	# This is not what we want: we're interested in the SHA of the head commit of
	# the Pull Request, which can be obtained with the JSON of the GitHub event
	# received (see $sha above). This also means that we don't have the commits in
	# the repository, so we need to fetch them via the `pull/<ID>/head` trick.
	if [[ $sha != $GITHUB_SHA ]]; then
		git fetch origin "refs/pull/${number}/head"

		# Really obtain SHA of PR head and compare it to the actual sha read from
		# the event JSON file. If they don't match, this means there was a force-push
		# in between from when the first pull_request event was triggered and when the
		# code reached this point. If that's the case, there will be another event
		# triggered (with an action 'synchronize'), so let's bail out early so that
		# the next event trigger deals with it.
		if [[ $(git rev-parse FETCH_HEAD) != $sha ]]; then
			exit 78
		fi

		GITHUB_SHA=$sha
	fi

	# Make sure we're on master to correctly git-diff the changes of the Pull Request
	git checkout -q origin/master

	# Get current labels of Pull Request
	current_labels=("${(f)$(jq --raw-output '.pull_request.labels | .[].name' "$GITHUB_EVENT_PATH")}")

	# Creates an array of labels to apply to the PR being analyzed
	labels=("${(f)$(triage_pull_request)}")

	# Check if PR has conflicts with master
	if has_conflicts; then
		echo Pull request with conflicts
		labels+=($LABELS[conflicts])
	# If it hasn't, remove the conflicts label if necessary
	elif (( $current_labels[(I)$LABELS[conflicts]] > 0 )); then
		echo Pull request doesn\'t have conflicts anymore
		replace=1
	fi

	if (( $replace )); then
		# If we're replacing the labels, we need to add all the old ones, except the
		# "conflicts" label, because we checked that there aren't conflicts anymore.
		labels+=(${current_labels:#$LABELS[conflicts]})
	else
		# If we're just adding labels, make sure that we're not adding labels that are
		# already there. This is useful if it turns out that all the labels we've found
		# are already set, so we don't need to make an API request.
		labels=(${labels:|current_labels})
	fi

	# Update labels
	if (( $#labels > 0 )); then
		data=$(print -l $labels | jq -cnR '{ labels: [inputs | select(length>0)] }')

		# Show curl output but also get the HTTP response code
		# Taken from: https://superuser.com/a/862395
		exec 3>&1

		if (( $replace )); then
			# Replace labels: https://developer.github.com/v3/issues/labels/#replace-all-labels-for-an-issue
			echo "Replacing labels of PR #$number on ${owner}/${repo}:" ${(j:, :)${(qq)labels}}...
			HTTP_STATUS=$(curl -w "%{http_code}" -o >(cat >&3) \
				-XPUT -sSL \
				-H "${AUTH_HEADER}" \
				-H "${API_HEADER}" \
				--data $data \
				"${URI}/repos/${owner}/${repo}/issues/${number}/labels")
		else
			# Add labels: https://developer.github.com/v3/issues/labels/#add-labels-to-an-issue
			echo "Adding labels to PR #$number on ${owner}/${repo}:" ${(j:, :)${(qq)labels}}...
			HTTP_STATUS=$(curl -w "%{http_code}" -o >(cat >&3) \
				-XPUT -sSL \
				-H "${AUTH_HEADER}" \
				-H "${API_HEADER}" \
				--data $data \
				"${URI}/repos/${owner}/${repo}/issues/${number}/labels")
		fi
		
		case $HTTP_STATUS in
			4*) echo HTTP Response: $HTTP_STATUS; exit 78 ;;
			*) return ;;
		esac
	else
		echo "No labels added to PR #$number."
		exit 78
	fi
}

if [[ $DEBUG_ACTIONS != false ]]; then
	cat "$GITHUB_EVENT_PATH"
	env
	set -x
fi

main "$@"
