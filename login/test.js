// Tests for the login service: node --test (Node 24, no dependencies).

import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';
import { COOKIE_NAME, createLoginServer, safeNext } from './server.js';
import { hashPassword, readUsers, writeUsers } from './users.js';
import { jobsFor, MAX_WEBHOOK_BYTES, repoName, signature } from './webhook.js';

const PASSWORD = 'correct horse battery';
const SECRET = 'a'.repeat(64);

let base;
let server;
let usersFile;
let clock = Date.now();

async function setUsers(entries) {
	const users = new Map();
	for (const [name, password] of entries) users.set(name, await hashPassword(name, password));
	writeUsers(usersFile, users);
}

function login(name, password, { next = '/private/', origin } = {}) {
	const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
	if (origin) headers.Origin = origin;
	return fetch(`${base}/login`, {
		method: 'POST',
		redirect: 'manual',
		headers,
		body: new URLSearchParams({ name, password, next }),
	});
}

function sessionCookie(response) {
	return response.headers.get('set-cookie').split(';')[0];
}

function auth(cookie) {
	return fetch(`${base}/auth`, { headers: cookie ? { Cookie: cookie } : {} });
}

before(async () => {
	usersFile = join(mkdtempSync(join(tmpdir(), 'login-test-')), 'users');
	await setUsers([['alice', PASSWORD]]);
	server = createLoginServer({ usersFile, secret: SECRET, now: () => clock });
	await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
	base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

describe('auth', () => {
	test('rejects a request without a session', async () => {
		assert.equal((await auth()).status, 401);
	});

	test('rejects a forged cookie', async () => {
		const forged = `${COOKIE_NAME}=alice:${Math.floor(clock / 1000) + 3600}:AAAA`;
		assert.equal((await auth(forged)).status, 401);
	});
});

describe('login', () => {
	test('a wrong password goes back to the login page with an error', async () => {
		const res = await login('alice', 'wrong password!!');
		assert.equal(res.status, 303);
		assert.equal(res.headers.get('location'), '/login?error=1&next=%2Fprivate%2F');
		assert.equal(res.headers.get('set-cookie'), null);
	});

	test('an unknown user gets the same answer', async () => {
		const res = await login('mallory', PASSWORD);
		assert.equal(res.headers.get('location'), '/login?error=1&next=%2Fprivate%2F');
		assert.equal(res.headers.get('set-cookie'), null);
	});

	test('the right password sets a session that auth accepts', async () => {
		const res = await login('alice', PASSWORD, { next: '/private/page.html' });
		assert.equal(res.status, 303);
		assert.equal(res.headers.get('location'), '/private/page.html');
		const setCookie = res.headers.get('set-cookie');
		assert.match(setCookie, /HttpOnly/);
		assert.match(setCookie, /Secure/);
		assert.match(setCookie, /SameSite=Lax/);

		const ok = await auth(sessionCookie(res));
		assert.equal(ok.status, 204);
		assert.equal(ok.headers.get('x-user'), 'alice');
	});

	test('a session is rejected once it is tampered with', async () => {
		const cookie = sessionCookie(await login('alice', PASSWORD));
		const [name, expires, signature] = cookie.split('=')[1].split(':');
		const longer = `${COOKIE_NAME}=${name}:${Number(expires) + 86400}:${signature}`;
		assert.equal((await auth(longer)).status, 401);
	});

	test('a session expires after 7 days', async () => {
		const cookie = sessionCookie(await login('alice', PASSWORD));
		clock += 8 * 24 * 60 * 60 * 1000;
		try {
			assert.equal((await auth(cookie)).status, 401);
		} finally {
			clock -= 8 * 24 * 60 * 60 * 1000;
		}
	});

	test('a post from another site is refused', async () => {
		const res = await login('alice', PASSWORD, { origin: 'https://evil.example' });
		assert.equal(res.status, 403);
	});

	test('a post from the same site is accepted', async () => {
		// fetch can't set Host, so the service sees 127.0.0.1:<port>.
		const res = await login('alice', PASSWORD, { origin: `https://${new URL(base).host}` });
		assert.equal(res.status, 303);
		assert.ok(res.headers.get('set-cookie'));
	});

	test('a redirect outside the private area goes to the private start page', async () => {
		const res = await login('alice', PASSWORD, { next: 'https://evil.example/' });
		assert.equal(res.headers.get('location'), '/private/');
	});
});

describe('user changes end sessions at once', () => {
	test('a changed password ends the session', async () => {
		const cookie = sessionCookie(await login('alice', PASSWORD));
		await setUsers([['alice', 'another password 123']]);
		try {
			assert.equal((await auth(cookie)).status, 401);
		} finally {
			await setUsers([['alice', PASSWORD]]);
		}
	});

	test('a removed user is logged out', async () => {
		const cookie = sessionCookie(await login('alice', PASSWORD));
		writeUsers(usersFile, new Map());
		try {
			assert.equal((await auth(cookie)).status, 401);
		} finally {
			await setUsers([['alice', PASSWORD]]);
		}
	});
});

describe('pages', () => {
	test('the login page escapes the next parameter', async () => {
		const res = await fetch(`${base}/login?next=${encodeURIComponent('/private/"><script>')}`);
		const html = await res.text();
		assert.equal(res.status, 200);
		assert.ok(!html.includes('"><script>'));
		assert.ok(html.includes('&#34;&#62;&#60;script&#62;'));
	});

	test('the login page redirects a logged-in user', async () => {
		const cookie = sessionCookie(await login('alice', PASSWORD));
		const res = await fetch(`${base}/login?next=/private/x`, { redirect: 'manual', headers: { Cookie: cookie } });
		assert.equal(res.status, 303);
		assert.equal(res.headers.get('location'), '/private/x');
	});

	test('logout clears the cookie', async () => {
		const res = await fetch(`${base}/logout`, { method: 'POST', redirect: 'manual' });
		assert.equal(res.status, 303);
		assert.match(res.headers.get('set-cookie'), /Max-Age=0/);
	});

	test('other paths are not found', async () => {
		assert.equal((await fetch(`${base}/users`)).status, 404);
	});
});

describe('safeNext', () => {
	test('keeps paths in the private area', () => {
		assert.equal(safeNext('/private/a/b.html'), '/private/a/b.html');
	});

	test('replaces everything else', () => {
		for (const next of [null, '', '/', '//evil.example/private/', 'https://evil.example/', '/private/\\evil', '/privatex']) {
			assert.equal(safeNext(next), '/private/', String(next));
		}
	});
});

describe('users file', () => {
	test('round-trips through write and read', async () => {
		const users = readUsers(usersFile);
		assert.deepEqual([...users.keys()], ['alice']);
		assert.equal(users.get('alice').N, 2 ** 17);
	});
});

describe('webhook', () => {
	const WEBHOOK_SECRET = 'w'.repeat(64);
	const DASHBOARD_REPO = 'git@github.com:example/Dashboard.git';
	let hookBase;
	let hookServer;
	let queueDir;

	before(async () => {
		queueDir = mkdtempSync(join(tmpdir(), 'webhook-test-'));
		hookServer = createLoginServer({
			usersFile,
			secret: SECRET,
			webhook: { secret: WEBHOOK_SECRET, queueDir, dashboardRepo: DASHBOARD_REPO },
		});
		await new Promise((resolve) => hookServer.listen(0, '127.0.0.1', resolve));
		hookBase = `http://127.0.0.1:${hookServer.address().port}`;
	});

	after(() => hookServer.close());

	function push(repo, ref = 'refs/heads/main') {
		return {
			ref,
			// Private, like the real dashboard repo, so the dependency status ignores it.
			repository: { full_name: repo, html_url: `https://github.com/${repo}`, default_branch: 'main', private: true },
		};
	}

	function send(event, payload, { sign = WEBHOOK_SECRET } = {}) {
		const body = typeof payload === 'string' ? payload : JSON.stringify(payload);
		const headers = { 'Content-Type': 'application/json', 'X-GitHub-Event': event };
		if (sign) headers['X-Hub-Signature-256'] = signature(sign, body);
		return fetch(`${hookBase}/webhook`, { method: 'POST', headers, body });
	}

	const queued = () => existsSync(join(queueDir, 'now', 'dashboard'));
	const clear = () => rmSync(join(queueDir, 'now', 'dashboard'), { force: true });

	test('does not exist without a secret', async () => {
		assert.equal((await fetch(`${base}/webhook`, { method: 'POST', body: '{}' })).status, 404);
	});

	test('rejects a missing or wrong signature', async () => {
		assert.equal((await send('push', push('example/dashboard'), { sign: false })).status, 401);
		assert.equal((await send('push', push('example/dashboard'), { sign: 'x'.repeat(64) })).status, 401);
		assert.equal(queued(), false);
	});

	test('answers a ping', async () => {
		const response = await send('ping', { zen: 'Keep it simple.' });
		assert.equal(response.status, 200);
		assert.equal(await response.text(), 'pong\n');
	});

	test('a push to the dashboard repo queues the dashboard', async () => {
		clear();
		const response = await send('push', push('example/dashboard'));
		assert.equal(response.status, 202);
		assert.match(readFileSync(join(queueDir, 'now', 'dashboard'), 'utf8'), /^\d{4}-\d\d-\d\dT/);
	});

	test('other repos, branches and events queue nothing', async () => {
		clear();
		assert.equal((await send('push', push('example/other'))).status, 200);
		assert.equal((await send('push', push('example/dashboard', 'refs/heads/feature'))).status, 200);
		assert.equal((await send('issues', push('example/dashboard'))).status, 200);
		assert.equal(queued(), false);
	});

	test('a form-encoded body is refused with a hint', async () => {
		const response = await send('push', 'payload=%7B%7D');
		assert.equal(response.status, 400);
		assert.match(await response.text(), /application\/json/);
	});

	test('a body over the limit is refused', async () => {
		const response = await send('push', 'x'.repeat(MAX_WEBHOOK_BYTES + 1), { sign: false }).catch(
			(error) => error,
		);
		// The server may close the connection before fetch has sent everything.
		assert.ok(response instanceof Error || response.status === 413);
	});

	test('repoName reads SSH and HTTPS URLs', () => {
		assert.equal(repoName('git@github.com:Org/Repo.git'), 'org/repo');
		assert.equal(repoName('https://github.com/org/repo'), 'org/repo');
		assert.equal(repoName('https://github.com/org/repo.git'), 'org/repo');
		assert.equal(repoName(''), undefined);
		assert.equal(repoName(undefined), undefined);
		assert.equal(repoName('Org/Repo'), 'org/repo');
		assert.equal(repoName('not a repo'), undefined);
	});

	test('jobsFor needs a dashboard repo', () => {
		assert.deepEqual(jobsFor('push', push('example/dashboard'), { dashboardRepo: '' }), []);
	});

	describe('dependency status', () => {
		const repository = { full_name: 'example/lib', default_branch: 'main', private: false };
		const jobs = (event, payload) => jobsFor(event, { repository, ...payload }, {});
		const STATUS = ['dependency-status'];

		test('changes in a public repo queue it', () => {
			assert.deepEqual(jobs('push', { ref: 'refs/heads/main' }), STATUS);
			assert.deepEqual(jobs('release', { action: 'published' }), STATUS);
			assert.deepEqual(jobs('issues', { action: 'closed' }), STATUS);
			assert.deepEqual(jobs('pull_request', { action: 'opened' }), STATUS);
			assert.deepEqual(jobs('repository', { action: 'archived' }), STATUS);
			assert.deepEqual(
				jobs('workflow_run', { action: 'completed', workflow_run: { head_branch: 'main' } }),
				STATUS,
			);
		});

		test('other branches, actions and events queue nothing', () => {
			assert.deepEqual(jobs('push', { ref: 'refs/heads/feature' }), []);
			assert.deepEqual(jobs('issues', { action: 'labeled' }), []);
			assert.deepEqual(jobs('pull_request', { action: 'synchronize' }), []);
			assert.deepEqual(jobs('workflow_run', { action: 'requested', workflow_run: { head_branch: 'main' } }), []);
			assert.deepEqual(jobs('workflow_run', { action: 'completed', workflow_run: { head_branch: 'feature' } }), []);
			assert.deepEqual(jobs('star', { action: 'created' }), []);
		});

		test('a private repo queues nothing, unless it just became private', () => {
			const hidden = { ...repository, private: true };
			assert.deepEqual(jobsFor('push', { repository: hidden, ref: 'refs/heads/main' }, {}), []);
			assert.deepEqual(jobsFor('repository', { repository: hidden, action: 'privatized' }, {}), STATUS);
		});

		test('waits in batched/, not now/', async () => {
			const body = JSON.stringify({ repository, action: 'published' });
			const response = await fetch(`${hookBase}/webhook`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'X-GitHub-Event': 'release',
					'X-Hub-Signature-256': signature(WEBHOOK_SECRET, body),
				},
				body,
			});
			assert.equal(response.status, 202);
			assert.ok(existsSync(join(queueDir, 'batched', 'dependency-status')));
			assert.equal(existsSync(join(queueDir, 'now', 'dependency-status')), false);
		});
	});

	describe('update after CI', () => {
		const UPDATE_REPO = 'example/status';
		function ciRun(overrides = {}, run = {}) {
			return {
				action: 'completed',
				repository: { full_name: UPDATE_REPO, default_branch: 'main', private: true },
				workflow_run: {
					conclusion: 'success',
					event: 'push',
					path: '.github/workflows/ci.yml',
					head_branch: 'main',
					head_repository: { full_name: UPDATE_REPO },
					...run,
				},
				...overrides,
			};
		}
		const jobs = (payload, updateRepo = UPDATE_REPO) => jobsFor('workflow_run', payload, { updateRepo });

		test('a passing CI run on main of the repo queues the update', () => {
			assert.deepEqual(jobs(ciRun()), ['update']);
		});

		test('nothing without UPDATE_REPO or for another repo', () => {
			assert.deepEqual(jobs(ciRun(), ''), []);
			assert.deepEqual(jobs(ciRun({ repository: { full_name: 'example/other', default_branch: 'main', private: true } })), []);
		});

		test('nothing for a run that failed, is still running or ran another workflow', () => {
			assert.deepEqual(jobs(ciRun({}, { conclusion: 'failure' })), []);
			assert.deepEqual(jobs(ciRun({ action: 'requested' })), []);
			assert.deepEqual(jobs(ciRun({}, { path: '.github/workflows/other.yml' })), []);
		});

		test('nothing for a pull request, a fork or another branch', () => {
			assert.deepEqual(jobs(ciRun({}, { event: 'pull_request' })), []);
			assert.deepEqual(jobs(ciRun({}, { head_repository: { full_name: 'someone/status' } })), []);
			assert.deepEqual(jobs(ciRun({}, { head_branch: 'feature' })), []);
		});

		test('a push to the repo itself queues nothing', () => {
			assert.deepEqual(jobsFor('push', push(UPDATE_REPO), { updateRepo: UPDATE_REPO }), []);
		});

		test('through the endpoint', async () => {
			const server = createLoginServer({
				usersFile,
				secret: SECRET,
				webhook: { secret: WEBHOOK_SECRET, queueDir, updateRepo: UPDATE_REPO },
			});
			await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
			try {
				const body = JSON.stringify(ciRun());
				const response = await fetch(`http://127.0.0.1:${server.address().port}/webhook`, {
					method: 'POST',
					headers: {
						'Content-Type': 'application/json',
						'X-GitHub-Event': 'workflow_run',
						'X-Hub-Signature-256': signature(WEBHOOK_SECRET, body),
					},
					body,
				});
				assert.equal(response.status, 202);
				assert.ok(existsSync(join(queueDir, 'now', 'update')));
			} finally {
				server.close();
			}
		});
	});
});
