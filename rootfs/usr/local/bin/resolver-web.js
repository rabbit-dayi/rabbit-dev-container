#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { Resolver } = require('node:dns').promises;

const stateFile = process.env.RESOLV_STATE_FILE || '/root/.rabbit_container/resolver.json';
const port = Number.parseInt(process.env.RESOLV_WEB_PORT || '8787', 10);
const cloudflaredBin = process.env.CLOUDFLARED_BIN || 'cloudflared';
const tunnelRuntimeDir = '/run/cloudflared';
const tunnelDefaultTarget = process.env.NGINX_UPSTREAM || '127.0.0.1:8080';
const tunnelStartTimeoutMs = 15000;
const tunnelMaxStartAttempts = 3;
const tunnelRetryDelayMs = 1000;
const cloudflaredProtocol = (() => {
  const allowed = ['http2', 'quic', 'auto'];
  const value = process.env.CLOUDFLARED_PROTOCOL || 'http2';
  if (!allowed.includes(value)) {
    console.warn(`[resolver-web] Invalid CLOUDFLARED_PROTOCOL "${value}"; falling back to http2.`);
    return 'http2';
  }
  return value;
})();
const defaults = {
  auto_config: true,
  local_nameserver: '127.0.0.1',
  fallback_nameserver: '1.1.1.1',
  fallback_always: false,
  check_domain: 'example.com',
};
const environmentNames = {
  auto_config: 'RESOLV_AUTO_CONFIG',
  local_nameserver: 'RESOLV_LOCAL_NAMESERVER',
  fallback_nameserver: 'RESOLV_FALLBACK_NAMESERVER',
  fallback_always: 'RESOLV_FALLBACK_ALWAYS',
  check_domain: 'RESOLV_CHECK_DOMAIN',
};

function hasEnvironment(name) {
  return Object.prototype.hasOwnProperty.call(process.env, name);
}

function parseBoolean(value, field) {
  if (value === true || value === false) return value;
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`${field} must be true or false`);
}

function validServer(value, field) {
  if (typeof value !== 'string' || net.isIP(value) !== 4) {
    throw new Error(`${field} must be an IPv4 address`);
  }
  return value;
}

function validDomain(value) {
  if (typeof value !== 'string' || value.length > 253 || !/^[A-Za-z0-9.-]+$/.test(value)) {
    throw new Error('check_domain must be a simple DNS name');
  }
  return value;
}

function normalizeTunnelTarget(value) {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > 255) {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  const input = value.trim();
  if (input.includes('://') && !/^https?:\/\//i.test(input)) {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  const candidate = /^https?:\/\//i.test(input) ? input : `http://${input}`;
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('target must be an HTTP(S) origin without credentials or query parameters');
  }
  const hostname = parsed.hostname.toLowerCase();
  const validHostname = net.isIP(hostname) === 4
    || hostname === 'localhost'
    || /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(hostname);
  if (!validHostname || hostname.includes('..')) {
    throw new Error('target hostname must be a valid IPv4 address, localhost, or DNS name');
  }
  if (parsed.port && (!/^\d+$/.test(parsed.port) || Number(parsed.port) < 1 || Number(parsed.port) > 65535)) {
    throw new Error('target port must be between 1 and 65535');
  }
  const pathname = parsed.pathname && parsed.pathname !== '/' ? parsed.pathname : '';
  return `${parsed.protocol}//${hostname}${parsed.port ? `:${parsed.port}` : ''}${pathname}`;
}

function validateConfig(input) {
  return {
    auto_config: parseBoolean(input.auto_config, 'auto_config'),
    local_nameserver: validServer(input.local_nameserver, 'local_nameserver'),
    fallback_nameserver: validServer(input.fallback_nameserver, 'fallback_nameserver'),
    fallback_always: parseBoolean(input.fallback_always, 'fallback_always'),
    check_domain: validDomain(input.check_domain),
  };
}

function readStored() {
  try {
    const value = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

function effectiveConfig() {
  const stored = readStored();
  const hasStoredFile = fs.existsSync(stateFile);
  const config = { ...defaults };
  const locked = {};
  for (const key of Object.keys(environmentNames)) {
    const envName = environmentNames[key];
    if (hasEnvironment(envName)) {
      config[key] = process.env[envName];
      locked[key] = true;
    } else if (Object.prototype.hasOwnProperty.call(stored, key)) {
      config[key] = stored[key];
    }
  }
  try {
    return { config: validateConfig(config), locked, stored: hasStoredFile };
  } catch (error) {
    return { config: { ...defaults }, locked, stored: false, warning: error.message };
  }
}

function writeJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body),
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > 16384) {
        reject(new Error('request body is too large'));
        request.destroy();
      }
    });
    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

async function probe(server, domain) {
  const resolver = new Resolver();
  resolver.setServers([`${server}:53`]);
  let timeout;
  try {
    const result = await Promise.race([
      resolver.resolve4(domain),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('timeout')), 2000);
      }),
    ]);
    return { server, ok: true, addresses: result };
  } catch (error) {
    return { server, ok: false, error: error.code || error.message || 'unavailable' };
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function testConfig(config) {
  const [local, fallback] = await Promise.all([
    probe(config.local_nameserver, config.check_domain),
    probe(config.fallback_nameserver, config.check_domain),
  ]);
  return { local, fallback };
}

function saveConfig(config) {
  const stateDir = path.dirname(stateFile);
  if (!fs.existsSync(stateDir)) {
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  }
  const temporary = `${stateFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify({ ...config, updated_at: new Date().toISOString() }, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, stateFile);
}

function applyConfig(config) {
  return new Promise((resolve) => {
    const child = spawn('/usr/local/bin/configure-resolv', [], {
      env: {
        ...process.env,
        RESOLV_AUTO_CONFIG: String(config.auto_config),
        RESOLV_LOCAL_NAMESERVER: config.local_nameserver,
        RESOLV_FALLBACK_NAMESERVER: config.fallback_nameserver,
        RESOLV_FALLBACK_ALWAYS: String(config.fallback_always),
        RESOLV_CHECK_DOMAIN: config.check_domain,
        RESOLV_STATE_FILE: stateFile,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => resolve({ code: 1, stdout, stderr: error.message }));
    child.on('close', (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

// --- Cloudflare quick tunnels -------------------------------------------------
//
// Multiple tunnels (one per distinct target) can run concurrently; each is
// tracked in `tunnels`, keyed by its normalized target so re-requesting the
// same target reuses/replaces the same slot instead of colliding.
const tunnels = new Map();

function tunnelId(target) {
  return crypto.createHash('sha1').update(target).digest('hex').slice(0, 12);
}

function createTunnelHandle(target) {
  return {
    id: tunnelId(target),
    target,
    process: null,
    url: null,
    started_at: null,
    last_error: null,
    output_tail: '',
    crashed: false,
    stopRequested: false,
  };
}

function pidFilePath(id) {
  return path.join(tunnelRuntimeDir, `${id}.pid`);
}

function readTunnelPid(id) {
  try {
    const value = Number.parseInt(fs.readFileSync(pidFilePath(id), 'utf8').trim(), 10);
    return Number.isInteger(value) && value > 1 ? value : null;
  } catch {
    return null;
  }
}

function writeTunnelPid(id, pid) {
  if (!Number.isInteger(pid) || pid <= 1) throw new Error('cloudflared did not return a valid process ID');
  fs.mkdirSync(tunnelRuntimeDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(tunnelRuntimeDir, 0o700);
  const temporary = `${pidFilePath(id)}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, `${pid}\n`, { mode: 0o600 });
    fs.renameSync(temporary, pidFilePath(id));
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch {}
    throw error;
  }
}

function clearTunnelPid(id, expectedPid) {
  if (expectedPid && readTunnelPid(id) !== expectedPid) return;
  try { fs.unlinkSync(pidFilePath(id)); } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`[resolver-web] Could not remove tunnel PID file: ${error.message}`);
  }
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function isManagedTunnel(pid) {
  try {
    const args = fs.readFileSync(`/proc/${pid}/cmdline`)
      .toString('utf8')
      .split('\0')
      .filter(Boolean);
    const executableMatches = path.basename(args[0]) === path.basename(cloudflaredBin)
      || (args.length > 1 && path.basename(args[1]) === path.basename(cloudflaredBin));
    return executableMatches
      && args.includes('tunnel')
      && args.includes('--no-autoupdate')
      && args.includes('--url');
  } catch {
    return false;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForProcessExit(pid, attempts = 40) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (!processExists(pid)) return true;
    await delay(50);
  }
  return !processExists(pid);
}

async function terminateManagedTunnel(id, pid) {
  if (!processExists(pid)) {
    clearTunnelPid(id, pid);
    return;
  }
  if (!isManagedTunnel(pid)) {
    console.warn(`[resolver-web] Ignoring stale tunnel PID ${pid} (tunnel ${id}): command does not match managed cloudflared.`);
    clearTunnelPid(id, pid);
    return;
  }
  try { process.kill(pid, 'SIGTERM'); } catch {}
  if (!await waitForProcessExit(pid)) {
    try { process.kill(pid, 'SIGKILL'); } catch {}
    await waitForProcessExit(pid, 20);
  }
  clearTunnelPid(id, pid);
}

async function cleanupStaleTunnels() {
  let entries = [];
  try {
    entries = fs.readdirSync(tunnelRuntimeDir).filter((name) => name.endsWith('.pid'));
  } catch {
    return;
  }
  for (const entry of entries) {
    const id = entry.slice(0, -4);
    const pid = readTunnelPid(id);
    if (!pid) {
      clearTunnelPid(id);
      continue;
    }
    console.warn(`[resolver-web] Cleaning up stale cloudflared process ${pid} (tunnel ${id}).`);
    await terminateManagedTunnel(id, pid);
  }
}

function defaultTunnelTarget() {
  try {
    return normalizeTunnelTarget(tunnelDefaultTarget);
  } catch {
    return 'http://127.0.0.1:8080';
  }
}

function extractTunnelUrl(output) {
  const match = output.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com(?:\/[^\s]*)?/i);
  return match ? match[0].replace(/[),.;]+$/, '') : null;
}

function tunnelOutput(handle, chunk) {
  handle.output_tail = `${handle.output_tail}${chunk}`.slice(-4096);
  if (!handle.url) {
    const url = extractTunnelUrl(handle.output_tail);
    if (url) handle.url = url;
  }
}

// Wires up permanent output/exit handling for a spawned cloudflared process.
// Runs for the process's whole life, including after the initial start
// succeeds, so an unexpected later death is recorded instead of leaving the
// tunnel silently looking "running" from a client's point of view.
function attachTunnelLifecycle(handle, child) {
  child.stdout.on('data', (chunk) => tunnelOutput(handle, chunk));
  child.stderr.on('data', (chunk) => tunnelOutput(handle, chunk));
  child.once('exit', (code, signal) => {
    if (handle.process !== child) return;
    handle.process = null;
    clearTunnelPid(handle.id, child.pid);
    if (handle.stopRequested) {
      handle.stopRequested = false;
      return;
    }
    handle.crashed = true;
    handle.last_error = handle.url
      ? `cloudflared exited unexpectedly (${signal || `code ${code}`})`
      : `cloudflared exited before creating a tunnel (${signal || `code ${code}`})`;
  });
}

function spawnCloudflared(handle) {
  return spawn(cloudflaredBin, ['tunnel', '--no-autoupdate', '--protocol', cloudflaredProtocol, '--url', handle.target], {
    cwd: '/',
    env: { ...process.env, HOME: tunnelRuntimeDir, XDG_CONFIG_HOME: tunnelRuntimeDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function waitForUrlOrExit(handle, child, timeoutMs) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdout.off('data', check);
      child.stderr.off('data', check);
      child.off('exit', onExit);
      if (error) reject(error);
      else resolve();
    };
    const check = () => { if (handle.url) finish(); };
    const onExit = () => { if (!handle.url) finish(new Error(handle.last_error || 'cloudflared exited before creating a tunnel')); };
    const timer = setTimeout(
      () => finish(new Error('cloudflared did not publish a trycloudflare.com URL within the timeout')),
      timeoutMs,
    );
    child.stdout.on('data', check);
    child.stderr.on('data', check);
    child.once('exit', onExit);
  });
}

function publicTunnelView(handle) {
  const running = Boolean(handle.process);
  return {
    id: handle.id,
    running,
    crashed: handle.crashed,
    pid: running ? handle.process.pid : null,
    url: handle.url,
    target: handle.target,
    started_at: handle.started_at,
    last_error: handle.last_error,
    output_tail: running ? '' : handle.output_tail,
  };
}

function publicTunnelsState() {
  return {
    tunnels: Array.from(tunnels.values()).map(publicTunnelView),
    default_target: defaultTunnelTarget(),
  };
}

function findTunnelHandle(identifier) {
  if (!identifier) {
    return tunnels.size === 1 ? tunnels.values().next().value : null;
  }
  for (const handle of tunnels.values()) {
    if (handle.id === identifier || handle.target === identifier) return handle;
  }
  return null;
}

// Starting a tunnel retries a few times before giving up: cloudflared's
// default QUIC transport needs outbound UDP, which many container/firewall
// setups block or throttle inconsistently, and even with --protocol http2
// edge assignment can be transiently slow. A single 10s attempt was reporting
// "failed" for what was really just a slow retry.
async function startTunnel(targetInput) {
  const target = normalizeTunnelTarget(targetInput || tunnelDefaultTarget);
  const existing = tunnels.get(target);
  if (existing && existing.process) {
    throw new Error('a tunnel to this target is already running');
  }

  const handle = createTunnelHandle(target);
  tunnels.set(target, handle);

  let lastError;
  for (let attempt = 1; attempt <= tunnelMaxStartAttempts; attempt += 1) {
    handle.url = null;
    handle.output_tail = '';
    handle.crashed = false;
    handle.last_error = null;

    let child;
    try {
      child = spawnCloudflared(handle);
    } catch (error) {
      lastError = error;
      if (attempt < tunnelMaxStartAttempts) await delay(tunnelRetryDelayMs);
      continue;
    }
    handle.process = child;
    handle.started_at = new Date().toISOString();
    attachTunnelLifecycle(handle, child);
    if (Number.isInteger(child.pid)) {
      try {
        writeTunnelPid(handle.id, child.pid);
      } catch (error) {
        child.kill('SIGTERM');
        handle.process = null;
        lastError = error;
        if (attempt < tunnelMaxStartAttempts) await delay(tunnelRetryDelayMs);
        continue;
      }
    }

    try {
      await waitForUrlOrExit(handle, child, tunnelStartTimeoutMs);
      return publicTunnelView(handle);
    } catch (error) {
      lastError = error;
      if (handle.process === child) {
        child.kill('SIGTERM');
        handle.process = null;
        clearTunnelPid(handle.id, child.pid);
      }
      if (attempt < tunnelMaxStartAttempts) await delay(tunnelRetryDelayMs);
    }
  }

  handle.last_error = lastError ? lastError.message : 'could not start temporary tunnel';
  handle.crashed = true;
  throw new Error(handle.last_error);
}

async function stopTunnel(identifier) {
  const handle = findTunnelHandle(identifier);
  if (!handle) throw new Error('tunnel not found');
  if (!handle.process) {
    tunnels.delete(handle.target);
    return { stopped: true, id: handle.id, target: handle.target, running: false };
  }
  const child = handle.process;
  handle.stopRequested = true;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (handle.process === child) child.kill('SIGKILL');
      resolve();
    }, 5000);
    child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
  });
  if (handle.process === child) handle.process = null;
  clearTunnelPid(handle.id, child.pid);
  tunnels.delete(handle.target);
  return { stopped: true, id: handle.id, target: handle.target, running: false };
}

async function stopAllTunnels() {
  const targets = Array.from(tunnels.keys());
  await Promise.all(targets.map((target) => stopTunnel(target).catch(() => {})));
}

async function handle(request, response) {
  const requestUrl = new URL(request.url, `http://${request.headers.host || '127.0.0.1'}`);
  if (request.method === 'GET' && requestUrl.pathname === '/api/resolver') {
    const state = effectiveConfig();
    writeJson(response, 200, {
      ...state,
      state_file: stateFile,
      password_protected: Boolean(process.env.RESOLV_WEB_PASSWORD || process.env.PASSWORD),
    });
    return;
  }

  if (request.method === 'GET' && requestUrl.pathname === '/api/tunnel') {
    writeJson(response, 200, publicTunnelsState());
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/tunnel/start') {
    let body = {};
    try {
      body = JSON.parse((await readBody(request)) || '{}');
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'invalid JSON' });
      return;
    }
    try {
      writeJson(response, 200, await startTunnel(body.target));
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'could not start temporary tunnel', state: publicTunnelsState() });
    }
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/tunnel/stop') {
    let body = {};
    try {
      body = JSON.parse((await readBody(request)) || '{}');
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'invalid JSON' });
      return;
    }
    try {
      writeJson(response, 200, await stopTunnel(body.id || body.target));
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'could not stop temporary tunnel' });
    }
    return;
  }

  if (request.method !== 'POST' || !['/api/resolver/test', '/api/resolver/apply'].includes(requestUrl.pathname)) {
    writeJson(response, 404, { error: 'not found' });
    return;
  }

  let body;
  try {
    body = JSON.parse(await readBody(request));
  } catch (error) {
    writeJson(response, 400, { error: error.message || 'invalid JSON' });
    return;
  }

  const state = effectiveConfig();
  const requested = { ...state.config, ...body };
  for (const key of Object.keys(state.locked)) {
    if (state.locked[key]) requested[key] = state.config[key];
  }

  let config;
  try {
    config = validateConfig(requested);
  } catch (error) {
    writeJson(response, 400, { error: error.message });
    return;
  }

  if (requestUrl.pathname === '/api/resolver/test') {
    writeJson(response, 200, { config, results: await testConfig(config) });
    return;
  }

  try {
    saveConfig(config);
    const result = await applyConfig(config);
    writeJson(response, result.code === 0 ? 200 : 500, {
      config,
      applied: result.code === 0,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
  } catch (error) {
    writeJson(response, 500, { error: error.message });
  }
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('RESOLV_WEB_PORT must be between 1 and 65535');
}

const server = http.createServer((request, response) => {
  handle(request, response).catch((error) => {
    writeJson(response, 500, { error: error.message || 'internal error' });
  });
});
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await stopAllTunnels();
  server.close(() => process.exit(0));
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

async function startServer() {
  await cleanupStaleTunnels();
  server.listen(port, '127.0.0.1', () => {
    console.log(`[resolver-web] Listening on 127.0.0.1:${port}; state=${stateFile}`);
  });
}

startServer().catch((error) => {
  console.error(`[resolver-web] Could not start: ${error.message}`);
  process.exit(1);
});
