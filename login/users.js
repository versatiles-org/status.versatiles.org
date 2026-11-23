// The users file and password hashing, shared by server.js and cli.js.
//
// One user per line: `name:N:r:p:salt:hash`, an scrypt hash with its
// parameters, salt and hash in base64. Only Node's own crypto is used, so the
// login service has no dependencies to keep up to date.

import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { promisify } from 'node:util';

const scrypt = promisify(scryptCallback);

export const NAME_PATTERN = /^[a-z0-9][a-z0-9_.-]{0,31}$/;
export const MIN_PASSWORD_LENGTH = 12;

// OWASP's recommendation for scrypt: N=2^17, r=8, p=1. That needs 128 MiB per
// hash, which is why logins are rate-limited in nginx.
const PARAMS = { N: 2 ** 17, r: 8, p: 1 };
const KEY_LENGTH = 32;

function maxmem({ N, r }) {
	return 256 * N * r;
}

// Reads the users file into a Map from name to record. A missing file means no users.
export function readUsers(file) {
	const users = new Map();
	if (!existsSync(file)) return users;
	for (const line of readFileSync(file, 'utf8').split('\n')) {
		if (!line.trim()) continue;
		const [name, N, r, p, salt, hash] = line.split(':');
		if (!NAME_PATTERN.test(name) || !hash) throw new Error(`Invalid line in ${file}: ${name}`);
		users.set(name, { name, N: Number(N), r: Number(r), p: Number(p), salt, hash });
	}
	return users;
}

// Writes the users file atomically, readable only by its owner.
export function writeUsers(file, users) {
	const lines = [...users.values()]
		.sort((a, b) => a.name.localeCompare(b.name))
		.map((u) => [u.name, u.N, u.r, u.p, u.salt, u.hash].join(':'));
	const tmp = `${file}.tmp`;
	writeFileSync(tmp, lines.map((l) => l + '\n').join(''), { mode: 0o600 });
	renameSync(tmp, file);
}

export async function hashPassword(name, password) {
	const salt = randomBytes(16);
	const key = await scrypt(password, salt, KEY_LENGTH, { ...PARAMS, maxmem: maxmem(PARAMS) });
	return { name, ...PARAMS, salt: salt.toString('base64'), hash: key.toString('base64') };
}

export async function verifyPassword(record, password) {
	const expected = Buffer.from(record.hash, 'base64');
	const params = { N: record.N, r: record.r, p: record.p };
	const key = await scrypt(password, Buffer.from(record.salt, 'base64'), expected.length, {
		...params,
		maxmem: maxmem(params),
	});
	return timingSafeEqual(key, expected);
}
