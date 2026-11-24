// Tests for token.mjs: node --test (Node 24, no dependencies). GitHub is
// replaced by a fake fetch, so this needs no app and no network.

import assert from 'node:assert/strict';
import { createVerify, generateKeyPairSync } from 'node:crypto';
import { describe, test } from 'node:test';
import { appJwt, installationToken, PERMISSIONS } from './token.mjs';

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
	modulusLength: 2048,
	privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
	publicKeyEncoding: { type: 'spki', format: 'pem' },
});

const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));

describe('appJwt', () => {
	test('is signed with the key and names the app', () => {
		const now = Date.UTC(2026, 10, 24, 12);
		const [header, payload, signature] = appJwt('Iv23test', privateKey, now).split('.');
		assert.deepEqual(decode(header), { alg: 'RS256', typ: 'JWT' });
		const claims = decode(payload);
		assert.equal(claims.iss, 'Iv23test');
		assert.equal(claims.iat, now / 1000 - 60);
		// GitHub accepts at most 10 minutes.
		assert.ok(claims.exp - claims.iat <= 600);
		const valid = createVerify('RSA-SHA256').update(`${header}.${payload}`).verify(publicKey, signature, 'base64url');
		assert.ok(valid);
	});
});

describe('installationToken', () => {
	function fakeGitHub(answers) {
		const calls = [];
		const fetchImpl = async (url, options) => {
			calls.push({ url, ...options, body: options.body ? JSON.parse(options.body) : undefined });
			const [status, body] = answers.shift();
			return { ok: status < 300, status, text: async () => JSON.stringify(body) };
		};
		return { calls, fetchImpl };
	}

	test('finds the installation and asks for a read-only token', async () => {
		const { calls, fetchImpl } = fakeGitHub([
			[200, { id: 42 }],
			[201, { token: 'ghs_test' }],
		]);
		const token = await installationToken({ clientId: 'Iv23test', privateKey, org: 'example', fetchImpl });
		assert.equal(token, 'ghs_test');
		assert.equal(calls[0].url, 'https://api.github.com/orgs/example/installation');
		assert.equal(calls[1].url, 'https://api.github.com/app/installations/42/access_tokens');
		assert.equal(calls[1].method, 'POST');
		assert.deepEqual(calls[1].body, { permissions: PERMISSIONS });
		assert.ok(Object.values(calls[1].body.permissions).every((level) => level === 'read'));
		assert.match(calls[0].headers.Authorization, /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
	});

	test('fails with GitHub\'s answer', async () => {
		const { fetchImpl } = fakeGitHub([[404, { message: 'Not Found' }]]);
		await assert.rejects(
			installationToken({ clientId: 'Iv23test', privateKey, org: 'example', fetchImpl }),
			/GitHub GET \/orgs\/example\/installation: 404/,
		);
	});
});
