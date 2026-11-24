// Prints a GitHub access token of the read-only GitHub App, for the collector
// of the dependency status (bin/dependency-status/update.sh).
//
// The app is installed on the organisation. With its private key this signs a
// JWT, finds the installation and asks for an installation token, read-only
// and valid for one hour. Node's standard library only, like login/.
//
// Environment: GITHUB_APP_CLIENT_ID, GITHUB_APP_KEY (path to the private key,
// default /key/private-key.pem), GITHUB_ORG (default versatiles-org).

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const API = 'https://api.github.com';

// What the collector reads. The token gets these and nothing else, whatever
// the app may be granted later.
export const PERMISSIONS = {
	checks: 'read',
	contents: 'read',
	issues: 'read',
	metadata: 'read',
	pull_requests: 'read',
	statuses: 'read',
};

const base64url = (data) => Buffer.from(data).toString('base64url');

/** A JWT for the app, valid for 9 minutes; issued a minute early against clock drift. */
export function appJwt(clientId, privateKey, now = Date.now()) {
	const seconds = Math.floor(now / 1000);
	const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
	const payload = base64url(JSON.stringify({ iat: seconds - 60, exp: seconds + 540, iss: clientId }));
	const signature = createSign('RSA-SHA256').update(`${header}.${payload}`).sign(privateKey, 'base64url');
	return `${header}.${payload}.${signature}`;
}

async function call(fetchImpl, method, path, jwt, body) {
	const response = await fetchImpl(`${API}${path}`, {
		method,
		headers: {
			Accept: 'application/vnd.github+json',
			Authorization: `Bearer ${jwt}`,
			'X-GitHub-Api-Version': '2022-11-28',
			'User-Agent': 'status.versatiles.org',
		},
		body: body ? JSON.stringify(body) : undefined,
	});
	const text = await response.text();
	if (!response.ok) throw new Error(`GitHub ${method} ${path}: ${response.status} ${text.slice(0, 200)}`);
	return JSON.parse(text);
}

export async function installationToken({ clientId, privateKey, org, fetchImpl = fetch, now }) {
	const jwt = appJwt(clientId, privateKey, now);
	const installation = await call(fetchImpl, 'GET', `/orgs/${org}/installation`, jwt);
	const answer = await call(fetchImpl, 'POST', `/app/installations/${installation.id}/access_tokens`, jwt, {
		permissions: PERMISSIONS,
	});
	return answer.token;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const clientId = process.env.GITHUB_APP_CLIENT_ID;
	if (!clientId) {
		console.error('GITHUB_APP_CLIENT_ID is not set.');
		process.exit(1);
	}
	try {
		const token = await installationToken({
			clientId,
			privateKey: readFileSync(process.env.GITHUB_APP_KEY ?? '/key/private-key.pem', 'utf8'),
			org: process.env.GITHUB_ORG ?? 'versatiles-org',
		});
		process.stdout.write(`${token}\n`);
	} catch (error) {
		console.error(error.message);
		process.exit(1);
	}
}
