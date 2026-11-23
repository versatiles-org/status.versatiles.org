// GitHub webhook receiver, served by the login service at POST /webhook.
//
// It checks the X-Hub-Signature-256 signature with WEBHOOK_SECRET and writes a
// file named after each job the event asks for into the queue directory:
// - dashboard: a push to the default branch of DASHBOARD_REPO.
// - update: CI passed on the default branch of UPDATE_REPO (this repo), so the
//   server pulls and applies it with bin/update.sh.
// The container can't run the job itself; a systemd path unit on the host
// does, see bin/webhook/. Many events while a job runs leave one file, so they
// cause one more run.

import { createHmac, timingSafeEqual } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

// GitHub's own limit is 25 MB, but a push with a few hundred commits stays far
// below this. nginx has the same limit (client_max_body_size).
export const MAX_WEBHOOK_BYTES = 5 * 1024 * 1024;

// The CI workflow whose success deploys UPDATE_REPO.
const CI_WORKFLOW = '.github/workflows/ci.yml';

/** "owner/name" of a GitHub repo, given as URL (SSH or HTTPS) or as "owner/name", lowercase, or undefined. */
export function repoName(url) {
	const match =
		/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/.exec(url ?? '') ?? /^([\w.-]+\/[\w.-]+)$/.exec(url ?? '');
	return match?.[1].toLowerCase();
}

export function signature(secret, body) {
	return `sha256=${createHmac('sha256', secret).update(body).digest('hex')}`;
}

function validSignature(secret, body, given) {
	if (typeof given !== 'string') return false;
	const expected = Buffer.from(signature(secret, body));
	const actual = Buffer.from(given);
	return expected.length === actual.length && timingSafeEqual(expected, actual);
}

function readRawBody(req) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		let size = 0;
		req.on('data', (chunk) => {
			size += chunk.length;
			if (size > MAX_WEBHOOK_BYTES) {
				reject(Object.assign(new Error('body too large'), { status: 413 }));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on('end', () => resolve(Buffer.concat(chunks)));
		req.on('error', reject);
	});
}

/** The jobs an event asks for. */
export function jobsFor(event, payload, { dashboardRepo, updateRepo }) {
	const repo = payload.repository;
	if (!repo) return [];
	const name = repoName(repo.full_name);

	if (event === 'push') {
		const dashboard = repoName(dashboardRepo);
		if (dashboard && name === dashboard && payload.ref === `refs/heads/${repo.default_branch}`) {
			return ['dashboard'];
		}
		return [];
	}

	// Only a finished, successful CI run for a push to the default branch of
	// this repo itself. A pull request, even from a fork with a branch named
	// like the default one, never deploys.
	if (event === 'workflow_run') {
		const run = payload.workflow_run;
		const update = repoName(updateRepo);
		if (
			update &&
			name === update &&
			payload.action === 'completed' &&
			run?.conclusion === 'success' &&
			run.event === 'push' &&
			run.path === CI_WORKFLOW &&
			run.head_branch === repo.default_branch &&
			repoName(run.head_repository?.full_name) === update
		) {
			return ['update'];
		}
	}
	return [];
}

/**
 * Handles POST /webhook. Without a secret the endpoint doesn't exist (404).
 * Answers: 200 for ping and for events with nothing to do, 202 when jobs were
 * queued, 401 for a missing or wrong signature, 400 for a body that isn't JSON.
 */
export function createWebhookHandler({ secret, queueDir, dashboardRepo, updateRepo, now = () => Date.now() }) {
	return async function handleWebhook(req, res) {
		if (!secret) return res.writeHead(404).end();

		let body;
		try {
			body = await readRawBody(req);
		} catch (error) {
			if (error.status === 413) return res.writeHead(413).end();
			throw error;
		}
		if (!validSignature(secret, body, req.headers['x-hub-signature-256'])) {
			return res.writeHead(401).end();
		}

		const event = req.headers['x-github-event'];
		if (event === 'ping') return res.writeHead(200).end('pong\n');

		let payload;
		try {
			payload = JSON.parse(body.toString('utf8'));
		} catch {
			// GitHub's other content type, application/x-www-form-urlencoded.
			return res.writeHead(400).end('Set the webhook content type to application/json.\n');
		}

		const jobs = jobsFor(event, payload, { dashboardRepo, updateRepo });
		for (const job of jobs) writeFileSync(join(queueDir, job), `${new Date(now()).toISOString()}\n`);
		const from = payload.repository?.full_name ?? 'unknown repo';
		console.log(`Webhook ${event} from ${from}: ${jobs.length ? `queued ${jobs.join(', ')}` : 'nothing to do'}`);
		if (!jobs.length) return res.writeHead(200).end('nothing to do\n');
		return res.writeHead(202).end(`queued ${jobs.join(', ')}\n`);
	};
}
