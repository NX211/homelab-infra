// Staging allowlist reconciler.
//
// Reconciles each app's Traefik ipAllowList Middleware from coreyalan.com's
// desired state. The DB (coreyalan) is the source of truth; this writes
// `base ∪ reviewer IPs` into the single Middleware per app (Traefik chains
// ipAllowList with AND, so the union must live in one middleware).
//
// Discovery: base ConfigMaps labeled allowlist.coreyalan.com/managed=true in
// the staging namespace carry { app, middleware, baseSourceRange, enabled }.
// For each, we fetch the signed desired state, verify the HMAC, merge with the
// base ranges, patch the Middleware if changed, and POST an ack.
//
// Zero runtime dependencies: Node built-ins only, talking to the Kubernetes
// REST API with the in-cluster ServiceAccount token + CA.

import { readFileSync } from 'node:fs';
import https from 'node:https';
import http from 'node:http';
import crypto from 'node:crypto';

const CONFIG = {
  baseUrl: requireEnv('COREYALAN_BASE_URL').replace(/\/$/, ''),
  internalToken: requireEnv('STAGING_INTERNAL_API_TOKEN'),
  hmacSecret: requireEnv('STAGING_ALLOWLIST_HMAC_SECRET'),
  webhookToken: process.env.RECONCILER_WEBHOOK_TOKEN || '',
  namespace: process.env.NAMESPACE || 'staging',
  labelSelector: process.env.LABEL_SELECTOR || 'allowlist.coreyalan.com/managed=true',
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS) || 20000,
  port: Number(process.env.PORT) || 8080,
  // Base CIDR(s) unioned into every managed app's allowlist, sourced from the
  // ESO secret (Bitwarden) instead of committed values so the homelab WAN IP
  // stays out of the public repo. Accepts a JSON array or comma-separated list.
  // Unset ⇒ empty ⇒ behaviour unchanged (the per-app baseSourceRange still
  // applies), so this is safe to ship before the secret exists.
  globalBaseSourceRange: parseCidrList(process.env.STAGING_BASE_ALLOWLIST_CIDR),
};

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const K8S_CA = readFileSync(`${SA_DIR}/ca.crt`);
const K8S_HOST = requireEnv('KUBERNETES_SERVICE_HOST');
const K8S_PORT = process.env.KUBERNETES_SERVICE_PORT_HTTPS || '443';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(JSON.stringify({ level: 'fatal', msg: `missing required env ${name}` }));
    process.exit(1);
  }
  return value;
}

// Parse a CIDR list from either a JSON array (`["a/32","b/32"]`) or a
// comma-separated string (`a/32, b/32`). Empty/unset ⇒ [].
function parseCidrList(raw) {
  if (!raw) return [];
  const trimmed = raw.trim();
  if (trimmed.startsWith('[')) {
    try {
      const arr = JSON.parse(trimmed);
      if (Array.isArray(arr)) return arr.map(String).map(s => s.trim()).filter(Boolean);
    } catch {
      // fall through to comma-split
    }
  }
  return trimmed.split(',').map(s => s.trim()).filter(Boolean);
}

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({ level, msg, ts: new Date().toISOString(), ...extra }));
}

function timingSafeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

// ── Kubernetes REST helper ────────────────────────────────────────────────

function k8sRequest(method, path, body, contentType = 'application/json') {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request(
      {
        host: K8S_HOST,
        port: K8S_PORT,
        path,
        method,
        ca: K8S_CA,
        headers: {
          // Read the token fresh each call — projected SA tokens rotate.
          authorization: `Bearer ${readFileSync(`${SA_DIR}/token`, 'utf8')}`,
          accept: 'application/json',
          ...(data ? { 'content-type': contentType, 'content-length': Buffer.byteLength(data) } : {}),
        },
      },
      res => {
        let raw = '';
        res.on('data', chunk => (raw += chunk));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(raw ? JSON.parse(raw) : {});
          } else {
            reject(new Error(`k8s ${method} ${path} -> ${res.statusCode}: ${raw}`));
          }
        });
      }
    );
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

const listBaseConfigMaps = () =>
  k8sRequest(
    'GET',
    `/api/v1/namespaces/${CONFIG.namespace}/configmaps?labelSelector=${encodeURIComponent(
      CONFIG.labelSelector
    )}`
  ).then(res => res.items || []);

const getMiddlewareSourceRange = name =>
  k8sRequest(
    'GET',
    `/apis/traefik.io/v1alpha1/namespaces/${CONFIG.namespace}/middlewares/${name}`
  ).then(mw => mw?.spec?.ipAllowList?.sourceRange || []);

const patchMiddlewareSourceRange = (name, sourceRange) =>
  k8sRequest(
    'PATCH',
    `/apis/traefik.io/v1alpha1/namespaces/${CONFIG.namespace}/middlewares/${name}`,
    { spec: { ipAllowList: { sourceRange } } },
    'application/merge-patch+json'
  );

// ── coreyalan.com internal API ────────────────────────────────────────────

async function fetchDesiredState(app) {
  const res = await fetch(`${CONFIG.baseUrl}/api/internal/staging-allowlist?app=${encodeURIComponent(app)}`, {
    headers: { authorization: `Bearer ${CONFIG.internalToken}` },
    cache: 'no-store',
  });
  if (!res.ok) throw new Error(`desired-state fetch ${app} -> ${res.status}`);
  return res.json();
}

async function ack(app, version, appliedHash, result) {
  try {
    await fetch(`${CONFIG.baseUrl}/api/internal/staging-allowlist/ack`, {
      method: 'POST',
      headers: { authorization: `Bearer ${CONFIG.internalToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ app, version, appliedAt: new Date().toISOString(), appliedHash, result }),
    });
  } catch (error) {
    log('warn', 'ack failed', { app, error: String(error) });
  }
}

// Recompute the HMAC the way coreyalan signs it (fixed key order).
function verifySignature(payload) {
  const canonical = JSON.stringify({
    app: payload.app,
    version: payload.version,
    generatedAt: payload.generatedAt,
    reviewerSourceRange: payload.reviewerSourceRange,
  });
  const expected = crypto.createHmac('sha256', CONFIG.hmacSecret).update(canonical).digest('base64url');
  return typeof payload.signature === 'string' && timingSafeEqual(expected, payload.signature);
}

// Defense-in-depth: reviewer entries must be a single public host CIDR.
function isPublicHostCidr(cidr) {
  if (typeof cidr !== 'string') return false;
  const [ip, bits] = cidr.split('/');
  if (ip.includes(':')) {
    if (bits !== '128') return false;
    const v = ip.toLowerCase();
    // Reject loopback, link-local (fe80::/10), and unique-local (fc00::/7).
    if (v === '::' || v === '::1' || /^fe[89ab]/.test(v) || /^f[cd]/.test(v)) return false;
    return /^[0-9a-f:]+$/.test(v);
  }
  if (bits !== '32') return false;
  const parts = ip.split('.');
  if (parts.length !== 4 || parts.some(p => !/^\d{1,3}$/.test(p) || Number(p) > 255)) return false;
  const n = parts.map(Number);
  if (n[0] === 0 || n[0] === 10 || n[0] === 127 || n[0] >= 224) return false;
  if (n[0] === 100 && n[1] >= 64 && n[1] <= 127) return false; // CGNAT
  if (n[0] === 169 && n[1] === 254) return false; // link-local
  if (n[0] === 172 && n[1] >= 16 && n[1] <= 31) return false; // private
  if (n[0] === 192 && n[1] === 168) return false; // private
  return true;
}

// ── Reconcile ─────────────────────────────────────────────────────────────

async function reconcileConfigMap(cm) {
  const data = cm.data || {};
  if (data.enabled === 'false') return;
  const app = data.app;
  const middleware = data.middleware;
  if (!app || !middleware) {
    log('warn', 'base configmap missing app/middleware', { name: cm.metadata?.name });
    return;
  }

  let base = [];
  try {
    base = JSON.parse(data.baseSourceRange || '[]');
  } catch {
    log('warn', 'invalid baseSourceRange JSON', { app });
    return;
  }

  let desired;
  try {
    desired = await fetchDesiredState(app);
  } catch (error) {
    log('error', 'fetch desired state failed', { app, error: String(error) });
    return;
  }

  if (!verifySignature(desired)) {
    log('error', 'signature verification failed — refusing to apply', { app, version: desired.version });
    return;
  }

  const reviewers = (desired.reviewerSourceRange || []).filter(cidr => {
    const ok = isPublicHostCidr(cidr);
    if (!ok) log('warn', 'dropping non-public reviewer CIDR', { app, cidr });
    return ok;
  });

  const merged = Array.from(new Set([...CONFIG.globalBaseSourceRange, ...base, ...reviewers])).sort();
  const appliedHash = crypto.createHash('sha256').update(merged.join(',')).digest('hex');

  try {
    const current = (await getMiddlewareSourceRange(middleware)).sort();
    if (JSON.stringify(current) === JSON.stringify(merged)) {
      // Already in sync; still ack so coreyalan records the confirmed version.
      await ack(app, desired.version, appliedHash, 'ok');
      return;
    }
    await patchMiddlewareSourceRange(middleware, merged);
    log('info', 'applied allowlist', { app, version: desired.version, count: merged.length });
    await ack(app, desired.version, appliedHash, 'ok');
  } catch (error) {
    log('error', 'apply failed', { app, error: String(error) });
    await ack(app, desired.version, appliedHash, 'error');
  }
}

async function reconcileAll() {
  try {
    const items = await listBaseConfigMaps();
    for (const cm of items) {
      await reconcileConfigMap(cm);
    }
  } catch (error) {
    log('error', 'reconcileAll failed', { error: String(error) });
  }
}

async function reconcileOneApp(app) {
  const items = await listBaseConfigMaps();
  const cm = items.find(item => item.data?.app === app);
  if (cm) await reconcileConfigMap(cm);
  else log('warn', 'push for unknown app', { app });
}

// ── HTTP server (push webhook + health) ───────────────────────────────────

function readBody(req) {
  return new Promise(resolve => {
    let raw = '';
    req.on('data', chunk => (raw += chunk));
    req.on('end', () => resolve(raw));
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200).end('ok');
    return;
  }

  if (req.method === 'POST' && req.url === '/reconcile') {
    const auth = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    if (!CONFIG.webhookToken || !timingSafeEqual(auth, CONFIG.webhookToken)) {
      res.writeHead(401).end('unauthorized');
      return;
    }
    let payload = {};
    try {
      payload = JSON.parse((await readBody(req)) || '{}');
    } catch {
      // ignore — fall through to full reconcile
    }
    res.writeHead(202).end('accepted');
    if (payload.app) reconcileOneApp(payload.app).catch(e => log('error', 'push reconcile failed', { error: String(e) }));
    else reconcileAll();
    return;
  }

  res.writeHead(404).end('not found');
});

server.listen(CONFIG.port, () => log('info', 'reconciler started', {
  namespace: CONFIG.namespace,
  pollIntervalMs: CONFIG.pollIntervalMs,
  port: CONFIG.port,
}));

reconcileAll();
setInterval(reconcileAll, CONFIG.pollIntervalMs);
