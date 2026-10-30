// Exercises the real serialized()/scheduleReconcileAll() lifted from
// src/index.mjs. Guards the overlap that let two passes ack the same app at
// once: setInterval does not wait for a slow pass, and the push webhook ran
// alongside the poll.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'index.mjs');

function extractBlock() {
  const src = readFileSync(SRC, 'utf8');
  const start = src.indexOf('let queue = Promise.resolve();');
  const end = src.indexOf('async function reconcileOneApp(');
  assert.ok(start > -1 && end > start, 'serialization block not found in src/index.mjs');
  return src.slice(start, end);
}

function harness() {
  let active = 0;
  let maxActive = 0;
  let passes = 0;
  const gates = [];
  const reconcileAll = async () => {
    active++;
    maxActive = Math.max(maxActive, active);
    passes++;
    await new Promise(resolve => gates.push(resolve));
    active--;
  };
  const api = new Function(
    'reconcileAll',
    `${extractBlock()}; return { serialized, scheduleReconcileAll };`
  )(reconcileAll);
  const release = async () => {
    while (gates.length === 0) await new Promise(r => setImmediate(r));
    gates.shift()();
    await new Promise(r => setImmediate(r));
  };
  return { ...api, release, stats: () => ({ maxActive, passes }) };
}

test('ticks during a slow pass never run a second pass concurrently', async () => {
  const h = harness();
  h.scheduleReconcileAll(); // running
  await new Promise(r => setImmediate(r));
  h.scheduleReconcileAll(); // queued
  h.scheduleReconcileAll(); // dropped: a pass is already queued
  h.scheduleReconcileAll(); // dropped
  await h.release();
  await h.release();
  assert.deepEqual(h.stats(), { maxActive: 1, passes: 2 });
});

test('push work waits for the running pass instead of overlapping it', async () => {
  const h = harness();
  const order = [];
  h.scheduleReconcileAll();
  await new Promise(r => setImmediate(r));
  const push = h.serialized(async () => order.push('push'));
  await new Promise(r => setImmediate(r));
  assert.deepEqual(order, []); // still blocked behind the pass
  await h.release();
  await push;
  assert.deepEqual(order, ['push']);
});

test('a failed job does not wedge the queue', async () => {
  const h = harness();
  await assert.rejects(h.serialized(async () => { throw new Error('boom'); }));
  let ran = false;
  await h.serialized(async () => { ran = true; });
  assert.equal(ran, true);
});
