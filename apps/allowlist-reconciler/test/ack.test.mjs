// Exercises the real ack() source lifted from src/index.mjs — not a retyped
// copy — so the test cannot drift from what ships.
//
// Guards the failure this was written for: fetch resolves on 4xx/5xx, so an
// unchecked ack reports healthy while coreyalan never records the applied
// version and its allowlist entries sit PENDING indefinitely.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'index.mjs');

function extractAck() {
  const src = readFileSync(SRC, 'utf8');
  const start = src.indexOf('async function ack(');
  assert.ok(start > -1, 'ack() not found in src/index.mjs');
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error('unbalanced braces in ack()');
}

const ackSrc = extractAck();

function harness(fetchImpl) {
  const logs = [];
  const CONFIG = { baseUrl: 'http://fake', internalToken: 'token' };
  const log = (level, msg, extra = {}) => logs.push({ level, msg, ...extra });
  const ack = new Function('CONFIG', 'log', 'fetch', `${ackSrc}; return ack;`)(CONFIG, log, fetchImpl);
  return { ack, logs };
}

const status = (code) => async () => ({ ok: code >= 200 && code < 300, status: code });

test('a successful ack logs nothing', async () => {
  const { ack, logs } = harness(status(200));
  await ack('coreyalan', 7, 'hash', 'ok');
  assert.deepEqual(logs, []);
});

test('4xx is an error and is marked as not self-healing', async () => {
  for (const code of [400, 401, 403, 404, 422]) {
    const { ack, logs } = harness(status(code));
    await ack('coreyalan', 7, 'hash', 'ok');
    assert.equal(logs.length, 1, `status ${code} logged nothing`);
    assert.equal(logs[0].level, 'error', `status ${code} should be error-level`);
    assert.equal(logs[0].msg, 'ack rejected');
    assert.equal(logs[0].willRetry, false, `status ${code} will not self-heal`);
    assert.equal(logs[0].status, code);
  }
});

test('5xx is a warning and is marked retryable — the next poll re-acks', async () => {
  for (const code of [500, 502, 503]) {
    const { ack, logs } = harness(status(code));
    await ack('coreyalan', 7, 'hash', 'ok');
    assert.equal(logs.length, 1, `status ${code} logged nothing`);
    assert.equal(logs[0].level, 'warn', `status ${code} should be warn-level`);
    assert.equal(logs[0].willRetry, true);
  }
});

test('a transport failure is caught, not thrown', async () => {
  const { ack, logs } = harness(async () => {
    throw new Error('ECONNREFUSED');
  });
  await ack('coreyalan', 7, 'hash', 'ok');
  assert.equal(logs.length, 1);
  assert.equal(logs[0].msg, 'ack failed');
});

test('ack never throws — a broken ack must not break the reconcile loop', async () => {
  for (const impl of [status(200), status(401), status(500), async () => { throw new Error('boom'); }]) {
    const { ack } = harness(impl);
    await assert.doesNotReject(() => ack('coreyalan', 7, 'hash', 'ok'));
  }
});

test('every log line carries the app and version needed to act on it', async () => {
  const { ack, logs } = harness(status(401));
  await ack('coreyalan', 42, 'hash', 'ok');
  assert.equal(logs[0].app, 'coreyalan');
  assert.equal(logs[0].version, 42);
});
