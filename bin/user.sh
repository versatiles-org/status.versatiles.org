#!/usr/bin/env bash
set -euo pipefail

# Manages the users of the private area. The users file is
# volumes/login/users; changes apply at once, also to open sessions.
#
# Usage:
#   bin/user.sh list
#   bin/user.sh add <name>       asks for the password; Enter generates one
#   bin/user.sh passwd <name>    the same for a new password; ends the user's sessions
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
		read -rsp "Password for $name (at least 12 characters, or Enter for a generated one): " password
		echo
		if [ -z "$password" ]; then
			# 24 characters from 18 random bytes, without the base64 characters
			# that are awkward to type or to pass on.
			password=$(openssl rand -base64 18 | tr '+/' '-_')
			generated=true
		else
			read -rsp "Repeat it: " repeated
			echo
			if [ "$password" != "$repeated" ]; then
				echo "Error: the passwords differ." >&2
				exit 1
			fi
			generated=false
		fi
		# On stdin, so the password appears neither in the process list nor in a log.
		printf '%s' "$password" | cli "$command" "$name"
		if [ "$generated" = "true" ]; then
			echo "Password for $name: $password"
			echo "It is shown only now. Pass it on through a password manager or another private channel."
		fi
		;;
	remove)
		[ -n "$name" ] || usage
		cli remove "$name"
		;;
	*)
		usage
		;;
esac
