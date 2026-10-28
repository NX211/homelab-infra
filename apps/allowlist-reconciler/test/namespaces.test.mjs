// Exercises the real parseNamespaces() and listBaseConfigMaps() lifted from
// src/index.mjs, so the tests cannot drift from what ships.
//
// Guards the move of staging apps into their own namespaces: every watched
// namespace is listed, and one failing namespace does not stop the others.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'index.mjs'), 'utf8');

function extract(signature) {
  const start = SRC.indexOf(signature);
  assert.ok(start > -1, `${signature} not found in src/index.mjs`);
  let depth = 0;
  for (let j = SRC.indexOf('{', start); j < SRC.length; j++) {
    if (SRC[j] === '{') depth++;
    else if (SRC[j] === '}' && --depth === 0) return SRC.slice(start, j + 1);
  }
  throw new Error(`unbalanced braces in ${signature}`);
}

const parseNamespaces = new Function(`${extract('function parseNamespaces(')}; return parseNamespaces;`)();

test('defaults to staging when unset or empty', () => {
  assert.deepEqual(parseNamespaces(undefined), ['staging']);
  assert.deepEqual(parseNamespaces(''), ['staging']);
  assert.deepEqual(parseNamespaces(' , '), ['staging']);
});

test('splits, trims and de-duplicates', () => {
  assert.deepEqual(parseNamespaces('staging, gatherbee-staging,staging'), ['staging', 'gatherbee-staging']);
});

function harness(namespaces, responses) {
  const logs = [];
  const calls = [];
  const CONFIG = { namespaces, labelSelector: 'allowlist.coreyalan.com/managed=true' };
  const log = (level, msg, extra = {}) => logs.push({ level, msg, ...extra });
  const k8sRequest = async (method, path) => {
    calls.push(path);
    const ns = path.split('/')[4];
    const r = responses[ns];
    if (r instanceof Error) throw r;
    return r;
  };
  const list = new Function('CONFIG', 'log', 'k8sRequest', `${extract('async function listBaseConfigMaps(')}; return listBaseConfigMaps;`)(
    CONFIG,
    log,
    k8sRequest
  );
  return { list, logs, calls };
}

test('lists every watched namespace with the label selector', async () => {
  const cm = ns => ({ metadata: { name: 'base', namespace: ns }, data: { app: ns } });
  const { list, calls } = harness(['staging', 'gatherbee-staging'], {
    staging: { items: [cm('staging')] },
    'gatherbee-staging': { items: [cm('gatherbee-staging')] },
  });
  const items = await list();
  assert.deepEqual(items.map(i => i.metadata.namespace), ['staging', 'gatherbee-staging']);
  assert.ok(calls.every(p => p.includes('labelSelector=allowlist.coreyalan.com%2Fmanaged%3Dtrue')));
});

test('a failing namespace is logged and the others still reconcile', async () => {
  const { list, logs } = harness(['staging', 'gone'], {
    staging: { items: [{ metadata: { namespace: 'staging' }, data: {} }] },
    gone: new Error('403 forbidden'),
  });
  const items = await list();
  assert.equal(items.length, 1);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].namespace, 'gone');
  assert.equal(logs[0].level, 'error');
});
