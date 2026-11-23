// Login service for the private area of status.versatiles.org.
//
// nginx asks GET /auth about every request to /private/ (auth_request): 204 lets
// it through, 401 sends the visitor to /login. The service also serves the
// login page and handles POST /login and POST /logout. It also receives the
// GitHub webhook at POST /webhook, see webhook.js. Nothing else is exposed;
// nginx only forwards these paths.
//
// A session is a cookie `name:expires:signature`, signed with LOGIN_SECRET
// (HMAC-SHA256) over the name, the expiry and the user's password hash. So it
// ends when it expires, when the user is removed, when their password changes,
// or for everyone when LOGIN_SECRET changes. The users file is read on every
// check, so changes by bin/user.sh apply at once.

import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { hashPassword, readUsers, verifyPassword } from './users.js';
import { createWebhookHandler } from './webhook.js';

export const COOKIE_NAME = 'versatiles_session';
const SESSION_SECONDS = 7 * 24 * 60 * 60;
const PRIVATE_PREFIX = '/private/';
const MAX_BODY_BYTES = 10_000;

const LOGIN_PAGE = readFileSync(new URL('./login.html', import.meta.url), 'utf8');

function escapeHtml(text) {
	return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// Only paths inside the private area, so the login can't redirect elsewhere.
export function safeNext(next) {
	if (typeof next === 'string' && next.startsWith(PRIVATE_PREFIX) && !/[\\\s]/.test(next)) return next;
	return PRIVATE_PREFIX;
}

function parseCookies(header = '') {
	const cookies = {};
	for (const part of header.split(';')) {
		const i = part.indexOf('=');
		if (i > 0) cookies[part.slice(0, i).trim()] = part.slice(i + 1).trim();
	}
	return cookies;
}

function readBody(req) {
	return new Promise((resolve, reject) => {
		let body = '';
		req.setEncoding('utf8');
		req.on('data', (chunk) => {
			body += chunk;
			if (body.length > MAX_BODY_BYTES) reject(new Error('body too large'));
		});
		req.on('end', () => resolve(body));
		req.on('error', reject);
	});
}

export function createLoginServer({ usersFile, secret, webhook = {}, now = () => Date.now() }) {
	if (!secret || secret.length < 32) throw new Error('LOGIN_SECRET must have at least 32 characters.');

	// Checked against when a user doesn't exist, so a login takes as long for
	// unknown names as for known ones and doesn't reveal which names exist.
	const dummy = hashPassword('dummy', 'dummy password for timing');
	const handleWebhook = createWebhookHandler({ ...webhook, now });

	function sign(name, expires, user) {
		return createHmac('sha256', secret).update(`${name}\n${expires}\n${user.hash}`).digest('base64url');
	}

	// The user name of a valid session, or undefined.
	function sessionUser(req) {
		const value = parseCookies(req.headers.cookie)[COOKIE_NAME];
		if (!value) return undefined;
		const [name, expires, signature] = value.split(':');
		const user = readUsers(usersFile).get(name);
		if (!user || !signature || Number(expires) * 1000 < now()) return undefined;
		const expected = Buffer.from(sign(name, expires, user));
		const given = Buffer.from(signature);
		if (expected.length !== given.length || !timingSafeEqual(expected, given)) return undefined;
		return name;
	}

	function sessionCookie(user) {
		const expires = Math.floor(now() / 1000) + SESSION_SECONDS;
		const value = `${user.name}:${expires}:${sign(user.name, expires, user)}`;
		return `${COOKIE_NAME}=${value}; Path=/; Max-Age=${SESSION_SECONDS}; HttpOnly; Secure; SameSite=Lax`;
	}

	function redirect(res, location, cookie) {
		const headers = { Location: location, 'Cache-Control': 'no-store' };
		if (cookie) headers['Set-Cookie'] = cookie;
		res.writeHead(303, headers).end();
	}

	function loginPage(res, next, error) {
		const html = LOGIN_PAGE.replace('{{next}}', escapeHtml(next)).replace(
			'{{error}}',
			error ? '<p class="error">Wrong user name or password.</p>' : '',
		);
		res.writeHead(200, {
			'Content-Type': 'text/html; charset=utf-8',
			'Cache-Control': 'no-store',
			'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; img-src https://versatiles.org; form-action 'self'; frame-ancestors 'none'",
		});
		res.end(html);
	}

	// Rejects form posts from other sites. Browsers send Origin with every POST.
	function sameOrigin(req) {
		const origin = req.headers.origin;
		return !origin || origin === `https://${req.headers.host}`;
	}

	async function handle(req, res) {
		const url = new URL(req.url, 'http://localhost');

		if (req.method === 'GET' && url.pathname === '/health') {
			return res.writeHead(200).end('ok\n');
		}

		if (req.method === 'GET' && url.pathname === '/auth') {
			const name = sessionUser(req);
			if (!name) return res.writeHead(401).end();
			return res.writeHead(204, { 'X-User': name }).end();
		}

		if (req.method === 'GET' && url.pathname === '/login') {
			const next = safeNext(url.searchParams.get('next'));
			if (sessionUser(req)) return redirect(res, next);
			return loginPage(res, next, url.searchParams.has('error'));
		}

		if (req.method === 'POST' && url.pathname === '/login') {
			if (!sameOrigin(req)) return res.writeHead(403).end();
			const form = new URLSearchParams(await readBody(req));
			const name = form.get('name') ?? '';
			const password = form.get('password') ?? '';
			const next = safeNext(form.get('next'));
			const user = readUsers(usersFile).get(name);
			let ok = false;
			if (user) ok = await verifyPassword(user, password);
			else await verifyPassword(await dummy, password);
			if (!ok) {
				console.log(`Failed login for ${JSON.stringify(name.slice(0, 40))}`);
				return redirect(res, `/login?error=1&next=${encodeURIComponent(next)}`);
			}
			console.log(`Login of ${name}`);
			return redirect(res, next, sessionCookie(user));
		}

		if (req.method === 'POST' && url.pathname === '/webhook') {
			return handleWebhook(req, res);
		}

		if (req.method === 'POST' && url.pathname === '/logout') {
			if (!sameOrigin(req)) return res.writeHead(403).end();
			return redirect(res, '/login', `${COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`);
		}

		res.writeHead(404).end();
	}

	return http.createServer((req, res) => {
		handle(req, res).catch((error) => {
			console.error(error);
			if (!res.headersSent) res.writeHead(500);
			res.end();
		});
	});
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const server = createLoginServer({
		usersFile: process.env.USERS_FILE ?? '/data/users',
		secret: process.env.LOGIN_SECRET,
		webhook: {
			secret: process.env.WEBHOOK_SECRET,
			queueDir: process.env.QUEUE_DIR ?? '/queue',
			dashboardRepo: process.env.DASHBOARD_REPO,
			updateRepo: process.env.UPDATE_REPO,
		},
	});
	server.listen(8080, () => console.log('Login service listening on port 8080.'));
	process.on('SIGTERM', () => server.close(() => process.exit(0)));
}
