// Receiver for the servers' cron job reports, served by the login service at
// POST /report.
//
// A server's cron job sends the outcome of each run:
//
//   POST /report
//   Authorization: Bearer <the server's token>
//   {"job": "nginx-update", "exit_code": 0, "interval": 86400,
//    "message": "nginx is up to date", "details": {"nginx": "1.31.10"}}
//
// The token says which server reports (REPORT_TOKEN_<SERVER>), so a token
// leaked from one server can't report for another. The latest report per
// server and job is stored as <reportsDir>/<server>/<job>.json, with the time
// it arrived, for the private dashboard. Some reports are about security (is
// nginx up to date), so they must never reach a public page or Gatus.

import { createHash, timingSafeEqual } from 'node:crypto';
import { mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readRawBody } from './webhook.js';

export const MAX_REPORT_BYTES = 10_000;

export const JOB_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
const DETAIL_KEY_PATTERN = /^[a-z0-9_]{1,40}$/;
const MAX_MESSAGE_LENGTH = 500;
const MAX_DETAILS = 20;
const MAX_DETAIL_LENGTH = 200;
// From every 10 minutes to monthly with room to spare.
const MIN_INTERVAL = 60;
const MAX_INTERVAL = 62 * 24 * 60 * 60;

/** The servers and their tokens from REPORT_TOKEN_<SERVER> variables. Empty ones are skipped. */
export function tokensFromEnv(env) {
	const tokens = {};
	for (const [key, value] of Object.entries(env)) {
		const match = /^REPORT_TOKEN_([A-Z0-9]+)$/.exec(key);
		if (match && value) tokens[match[1].toLowerCase()] = value;
	}
	return tokens;
}

function digest(text) {
	return createHash('sha256').update(text).digest();
}

/** The server a bearer token belongs to, or undefined. Compares every token in constant time. */
function serverFor(tokens, header) {
	const match = /^Bearer (\S+)$/.exec(header ?? '');
	if (!match) return undefined;
	const given = digest(match[1]);
	let found;
	for (const [server, token] of Object.entries(tokens)) {
		if (timingSafeEqual(digest(token), given)) found = server;
	}
	return found;
}

/** The report to store, or a string saying what's wrong with it. */
export function validateReport(body) {
	if (typeof body !== 'object' || body === null || Array.isArray(body)) return 'The body must be a JSON object.';
	const { job, exit_code: exitCode, interval, message = '', details = {} } = body;
	if (typeof job !== 'string' || !JOB_PATTERN.test(job)) return 'job: lower case letters, digits and -, up to 40.';
	if (!Number.isInteger(exitCode) || exitCode < 0 || exitCode > 255) return 'exit_code: an integer from 0 to 255.';
	if (!Number.isInteger(interval) || interval < MIN_INTERVAL || interval > MAX_INTERVAL) {
		return `interval: the seconds between runs, from ${MIN_INTERVAL} to ${MAX_INTERVAL}.`;
	}
	if (typeof message !== 'string' || message.length > MAX_MESSAGE_LENGTH) {
		return `message: a string of up to ${MAX_MESSAGE_LENGTH} characters.`;
	}
	if (typeof details !== 'object' || details === null || Array.isArray(details)) return 'details: an object.';
	const entries = Object.entries(details);
	if (entries.length > MAX_DETAILS) return `details: up to ${MAX_DETAILS} entries.`;
	for (const [key, value] of entries) {
		if (!DETAIL_KEY_PATTERN.test(key)) return 'details: keys of lower case letters, digits and _, up to 40.';
		const ok =
			typeof value === 'boolean' ||
			(typeof value === 'number' && Number.isFinite(value)) ||
			(typeof value === 'string' && value.length <= MAX_DETAIL_LENGTH);
		if (!ok) return `details: values must be booleans, numbers or strings of up to ${MAX_DETAIL_LENGTH} characters.`;
	}
	return { job, exit_code: exitCode, interval, message, details };
}

/**
 * Handles POST /report. Without tokens the endpoint doesn't exist (404).
 * Answers: 204 when the report was stored, 401 for a missing or unknown token,
 * 400 for an invalid report (with the reason), 413 for a body over the limit.
 */
export function createReportHandler({ tokens = {}, reportsDir, now = () => Date.now() }) {
	return async function handleReport(req, res) {
		if (!Object.keys(tokens).length) return res.writeHead(404).end();

		const server = serverFor(tokens, req.headers.authorization);
		if (!server) return res.writeHead(401).end();

		let body;
		try {
			body = await readRawBody(req, MAX_REPORT_BYTES);
		} catch (error) {
			if (error.status === 413) return res.writeHead(413).end();
			throw error;
		}

		let parsed;
		try {
			parsed = JSON.parse(body.toString('utf8'));
		} catch {
			return res.writeHead(400).end('The body must be JSON.\n');
		}
		const report = validateReport(parsed);
		if (typeof report === 'string') return res.writeHead(400).end(`${report}\n`);

		const dir = join(reportsDir, server);
		mkdirSync(dir, { recursive: true });
		const file = join(dir, `${report.job}.json`);
		const stored = { server, ...report, received: new Date(now()).toISOString() };
		// Written next to the target and renamed, so the dashboard never reads half a file.
		writeFileSync(`${file}.tmp`, `${JSON.stringify(stored, null, '\t')}\n`);
		renameSync(`${file}.tmp`, file);

		console.log(`Report ${server}/${report.job}: exit code ${report.exit_code}`);
		return res.writeHead(204).end();
	};
}
