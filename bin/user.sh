#!/usr/bin/env bash
set -euo pipefail

# Manages the users of the private area. The users file is
# volumes/login/users; changes apply at once, also to open sessions.
#
# Usage:
#   bin/user.sh list
#   bin/user.sh add <name>       asks for the password
#   bin/user.sh passwd <name>    asks for the new password, ends the user's sessions
#   bin/user.sh remove <name>    ends the user's sessions

cd "$(dirname "$0")/.."

usage() {
	sed -n '7,11p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

# Runs login/cli.js in the login container, so hashing uses the same Node and
# parameters as the service. --no-deps: don't start or touch other services.
cli() {
	docker compose run --rm -T --no-deps login node cli.js "$@"
}

command=${1:-}
name=${2:-}

case "$command" in
	list)
		cli list
		;;
	add | passwd)
		[ -n "$name" ] || usage
		read -rsp "Password for $name (at least 12 characters): " password
		echo
		read -rsp "Repeat it: " repeated
		echo
		if [ "$password" != "$repeated" ]; then
			echo "Error: the passwords differ." >&2
			exit 1
		fi
		# On stdin, so the password appears neither in the process list nor in a log.
		printf '%s' "$password" | cli "$command" "$name"
		;;
	remove)
		[ -n "$name" ] || usage
		cli remove "$name"
		;;
	*)
		usage
		;;
esac
