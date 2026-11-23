// Manages the users file. Called by bin/user.sh inside the login container, so
// hashing uses the same Node and parameters as the server.
//
//   node cli.js list
//   node cli.js add <name>       password on stdin
//   node cli.js passwd <name>    password on stdin
//   node cli.js remove <name>

import { readFileSync } from 'node:fs';
import { hashPassword, MIN_PASSWORD_LENGTH, NAME_PATTERN, readUsers, writeUsers } from './users.js';

const USERS_FILE = process.env.USERS_FILE ?? '/data/users';

function fail(message) {
	console.error(`Error: ${message}`);
	process.exit(1);
}

function readPassword() {
	const password = readFileSync(0, 'utf8').replace(/\r?\n$/, '');
	if (password.length < MIN_PASSWORD_LENGTH) {
		fail(`the password needs at least ${MIN_PASSWORD_LENGTH} characters.`);
	}
	return password;
}

const [command, name] = process.argv.slice(2);
const users = readUsers(USERS_FILE);

if (command !== 'list' && !NAME_PATTERN.test(name ?? '')) {
	fail('give a user name: lower-case letters, digits, ".", "_" or "-", at most 32 characters.');
}

switch (command) {
	case 'list':
		for (const user of users.keys()) console.log(user);
		break;
	case 'add':
		if (users.has(name)) fail(`user ${name} exists already. Use passwd to change the password.`);
		users.set(name, await hashPassword(name, readPassword()));
		writeUsers(USERS_FILE, users);
		console.log(`Added ${name}.`);
		break;
	case 'passwd':
		if (!users.has(name)) fail(`there is no user ${name}.`);
		users.set(name, await hashPassword(name, readPassword()));
		writeUsers(USERS_FILE, users);
		console.log(`Changed the password of ${name}. Their open sessions have ended.`);
		break;
	case 'remove':
		if (!users.delete(name)) fail(`there is no user ${name}.`);
		writeUsers(USERS_FILE, users);
		console.log(`Removed ${name}. Their open sessions have ended.`);
		break;
	default:
		fail('usage: list | add <name> | passwd <name> | remove <name>');
}
