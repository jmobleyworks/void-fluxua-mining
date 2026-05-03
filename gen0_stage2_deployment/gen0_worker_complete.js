/**
 * GEN 0 WORKER - Complete Virtual Computer ALU
 *
 * Architecture:
 *   - Worker = ALU (computes arbitrary jobs)
 *   - KV = RAM (fast temporary state)
 *   - D1 = Disk (persistent state, job queue, results)
 *   - DO = Router (job dispatcher, coordination)
 *   - Website = Introspection (reasoning about worker behavior)
 *
 * This worker:
 *   1. Serves HTML dashboard at GET /
 *   2. Provides JSON API at /api/*
 *   3. Pulls jobs from job queue
 *   4. Executes computation (SHA256 or RandomX)
 *   5. Stores results atomically
 *   6. Handles failures and retries
 */

const WORKER_VERSION = '1.0.0';
const COMPUTE_TIMEOUT_MS = 60000; // 60 seconds max per job
const HEARTBEAT_INTERVAL_MS = 5000; // Update status every 5s
const LOG_MAX_ENTRIES = 100;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    try {
      // HTML Dashboard
      if (path === '/' && method === 'GET') {
        return handleDashboard(env);
      }

      // JSON API
      if (path.startsWith('/api/')) {
        if (path === '/api/status' && method === 'GET') {
          return handleStatusAPI(env);
        }
        if (path === '/api/logs' && method === 'GET') {
          return handleLogsAPI(env);
        }
        if (path === '/api/command' && method === 'POST') {
          return handleCommandAPI(request, env);
        }
        return notFound('Unknown API endpoint');
      }

      // WebSocket (future)
      if (path === '/ws') {
        return new Response('WebSocket upgrade not yet implemented', { status: 501 });
      }

      // Test: Pull a job from dispatcher via service binding
      if (path === '/test/pull-job' && method === 'GET') {
        const workerId = url.searchParams.get('worker_id') || 'test-worker-1';
        try {
          // Use service binding to call dispatcher
          const req = new Request('https://dispatcher.internal/request-job?worker_id=' + encodeURIComponent(workerId), {
            method: 'GET'
          });
          const dispatcherResp = await env.JOB_DISPATCHER.fetch(req);

          // Get response as text first to debug
          const respText = await dispatcherResp.text();
          try {
            const jobData = JSON.parse(respText);
            return json({ status: 'success', job: jobData });
          } catch (e) {
            return json({ status: 'error', error: 'Invalid JSON from dispatcher', response: respText.substring(0, 100) }, 500);
          }
        } catch (error) {
          return json({ status: 'error', error: error.message }, 500);
        }
      }

      // Mining endpoint - pull jobs and submit to MoneroOcean
      if (path === '/mine/moneroocean' && method === 'GET') {
        ctx.waitUntil(runMoneroOceanMining(env));
        return json({
          status: 'mining_started',
          worker_id: env.WORKER_ID || 'unknown',
          pool: 'gulf.moneroocean.stream:10128',
          timestamp: new Date().toISOString()
        });
      }

      // Mining endpoint (backward compat)
      if (path === '/mine' && method === 'GET') {
        ctx.waitUntil(runMiningLoop(env));
        return json({
          status: 'mining_started',
          worker_id: env.WORKER_ID || 'unknown',
          timestamp: new Date().toISOString()
        });
      }

      return new Response('Gen 0 Worker ALU v1.0.0\n\nEndpoints:\n/ - Dashboard\n/api/status - Status JSON\n/api/logs - Recent logs\n/test/pull-job - Test job dispatcher\n/mine - Start mining loop\n/mine/moneroocean - Start MoneroOcean mining\n', {
        headers: { 'Content-Type': 'text/plain' }
      });
    } catch (error) {
      return json({ error: error.message, stack: error.stack }, 500);
    }
  }
};

/**
 * DASHBOARD - HTML introspection interface
 */
async function handleDashboard(env) {
  const status = await getWorkerStatus(env);
  const logs = await getRecentLogs(env);

  const html = `<!DOCTYPE html>
<html>
<head>
  <title>Worker ${status.worker_id} Dashboard</title>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * { font-family: monospace; margin: 0; padding: 0; }
    body { background: #1e1e1e; color: #d4d4d4; padding: 20px; }
    .header { border-bottom: 2px solid #007acc; padding-bottom: 10px; margin-bottom: 20px; }
    .section { margin-bottom: 20px; padding: 10px; background: #252526; border-left: 3px solid #007acc; }
    .section h2 { color: #4ec9b0; margin-bottom: 10px; }
    .stat { display: flex; justify-content: space-between; padding: 5px 0; border-bottom: 1px solid #3e3e42; }
    .stat-label { color: #9cdcfe; }
    .stat-value { color: #ce9178; font-weight: bold; }
    .status-ok { color: #6a9955; }
    .status-warn { color: #dcdcaa; }
    .status-error { color: #f48771; }
    .logs { max-height: 400px; overflow-y: auto; }
    .log-entry { padding: 5px; border-bottom: 1px solid #3e3e42; font-size: 11px; }
    .log-ts { color: #858585; }
    .log-level-info { color: #4ec9b0; }
    .log-level-warn { color: #dcdcaa; }
    .log-level-error { color: #f48771; }
    button { background: #007acc; color: white; border: none; padding: 8px 12px; cursor: pointer; margin: 5px 5px 5px 0; }
    button:hover { background: #005a9e; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    @media (max-width: 800px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="header">
    <h1>⚙️ Worker ALU Dashboard</h1>
    <p>Worker ID: <strong>${status.worker_id}</strong> | Version: ${WORKER_VERSION} | Uptime: ${formatUptime(status.uptime_ms)}</p>
  </div>

  <div class="grid">
    <div>
      <div class="section">
        <h2>Status</h2>
        ${renderStatus(status)}
      </div>

      <div class="section">
        <h2>Current Job</h2>
        ${renderCurrentJob(status.current_job)}
      </div>

      <div class="section">
        <h2>Statistics</h2>
        <div class="stat">
          <span class="stat-label">Total Results:</span>
          <span class="stat-value">${status.total_results}</span>
        </div>
        <div class="stat">
          <span class="stat-label">Valid Results:</span>
          <span class="stat-value status-ok">${status.valid_results}</span>
        </div>
        <div class="stat">
          <span class="stat-label">Invalid Results:</span>
          <span class="stat-value status-warn">${status.invalid_results}</span>
        </div>
        <div class="stat">
          <span class="stat-label">Compute Time (avg):</span>
          <span class="stat-value">${status.avg_compute_ms.toFixed(1)}ms</span>
        </div>
      </div>
    </div>

    <div>
      <div class="section">
        <h2>Recent Logs (Last ${logs.length})</h2>
        <div class="logs">
          ${logs.map(log => {
            const ts = log.timestamp || 'N/A';
            const level = (log.level || 'info').toUpperCase();
            const msg = log.message || '';
            return `<div class="log-entry"><span class="log-ts">[${ts}]</span><span class="log-level-${log.level}">${level}</span> ${msg}</div>`;
          }).join('')}
        </div>
      </div>

      <div class="section">
        <h2>Controls</h2>
        <button onclick="fetch('/api/command', { method: 'POST', body: JSON.stringify({ command: 'restart' }) }).then(r => alert(r.status))">
          Restart Job
        </button>
        <button onclick="fetch('/api/command', { method: 'POST', body: JSON.stringify({ command: 'clear_logs' }) }).then(r => alert(r.status))">
          Clear Logs
        </button>
        <button onclick="location.reload()">
          Refresh
        </button>
      </div>
    </div>
  </div>

  <script>
    // Auto-refresh every 5 seconds
    setTimeout(() => location.reload(), 5000);
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  });
}

/**
 * API: /api/status - Current worker state
 */
async function handleStatusAPI(env) {
  const status = await getWorkerStatus(env);
  return json(status);
}

/**
 * API: /api/logs - Recent log entries
 */
async function handleLogsAPI(env) {
  const logs = await getRecentLogs(env);
  return json({ logs, count: logs.length });
}

/**
 * API: /api/command - Control commands
 */
async function handleCommandAPI(request, env) {
  try {
    const { command } = await request.json();

    if (command === 'restart') {
      await appendLog(env, 'info', 'User command: restart job');
      return json({ success: true, message: 'Job restart signal sent' });
    }

    if (command === 'clear_logs') {
      await clearLogs(env);
      return json({ success: true, message: 'Logs cleared' });
    }

    return json({ error: 'Unknown command: ' + command }, 400);
  } catch (error) {
    return json({ error: error.message }, 400);
  }
}

/**
 * CORE LOOP - Pull job, compute, store result
 */
async function runMiningLoop(env) {
  const workerId = env.WORKER_ID || 'unknown';
  const startTime = Date.now();

  await appendLog(env, 'info', `Mining loop started (worker: ${workerId})`);

  try {
    while (true) {
      // STEP 1: Pull job from D1 job queue
      const job = await getNextJob(env, workerId);
      if (!job) {
        await appendLog(env, 'warn', 'No jobs available, waiting...');
        await sleep(5000);
        continue;
      }

      await appendLog(env, 'info', `Pulled job: ${job.job_id} (type: ${job.type})`);

      // STEP 2: Mark job as "assigned" to this worker
      await markJobAssigned(env, job.job_id, workerId);

      // STEP 3: Execute computation with timeout
      let result;
      try {
        const computeStart = Date.now();
        result = await executeJob(job, computeStart);
        const computeTime = Date.now() - computeStart;

        // STEP 4: Validate result
        const isValid = await validateResult(job, result);

        // STEP 5: Store result to D1
        await storeResult(env, {
          job_id: job.job_id,
          worker_id: workerId,
          nonce: result.nonce,
          result_hash: result.hash,
          status: isValid ? 'valid' : 'invalid',
          compute_time_ms: computeTime,
          timestamp: new Date().toISOString()
        });

        await appendLog(env, 'info', `Result stored (${isValid ? 'VALID' : 'INVALID'}, ${computeTime}ms)`);
      } catch (computeError) {
        await appendLog(env, 'error', `Compute error: ${computeError.message}`);
        await markJobFailed(env, job.job_id, computeError.message);
      }

      // Brief pause before next job
      await sleep(100);
    }
  } catch (loopError) {
    await appendLog(env, 'error', `Mining loop error: ${loopError.message}`);
  }
}

/**
 * EXECUTE JOB - Run actual computation
 */
async function executeJob(job, startTime) {
  switch (job.type) {
    case 'sha256':
      return computeSHA256(job);
    case 'randomx':
      // TODO: implement RandomX when library available
      throw new Error('RandomX not yet implemented');
    default:
      throw new Error('Unknown job type: ' + job.type);
  }
}

/**
 * COMPUTE: SHA256 - Generate hash from nonce
 */
async function computeSHA256(job) {
  const nonce = `${job.job_id}-${Math.random().toString(36).substring(2, 15)}-${Date.now()}`;
  const encoder = new TextEncoder();
  const data = encoder.encode(nonce);

  try {
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

    return {
      nonce,
      hash: hashHex,
      algorithm: 'sha256'
    };
  } catch (error) {
    // Fallback if SubtleCrypto unavailable
    let hash = '';
    for (let i = 0; i < nonce.length; i++) {
      hash += nonce.charCodeAt(i).toString(16).padStart(2, '0');
    }
    return {
      nonce,
      hash: hash.padEnd(64, '0').substring(0, 64),
      algorithm: 'sha256_fallback'
    };
  }
}

/**
 * VALIDATE: Check result meets difficulty
 */
async function validateResult(job, result) {
  // For SHA256: hash must be < target difficulty
  // For testing: accept all valid 64-char hex strings
  if (result.hash.length !== 64) return false;
  if (!/^[a-f0-9]{64}$/.test(result.hash)) return false;

  // TODO: Compare hash to job.difficulty once difficulty format is standardized
  return true;
}

/**
 * D1 OPERATIONS - Job management
 */
async function getNextJob(env, workerId) {
  if (!env.DB) {
    console.warn('D1 not bound, returning null job');
    return null;
  }

  try {
    // Ensure job queue table exists
    await env.DB.prepare(`
      CREATE TABLE IF NOT EXISTS job_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        difficulty REAL,
        params TEXT,
        status TEXT DEFAULT 'pending',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `).run();

    // Get next pending job
    const result = await env.DB.prepare(
      'SELECT * FROM job_queue WHERE status=? ORDER BY created_at ASC LIMIT 1'
    ).bind('pending').first();

    if (!result) return null;

    // Update status to "assigned"
    await env.DB.prepare(
      'UPDATE job_queue SET status=? WHERE job_id=?'
    ).bind('assigned', result.job_id).run();

    return result;
  } catch (error) {
    console.error('Error fetching job:', error.message);
    return null;
  }
}

async function markJobAssigned(env, jobId, workerId) {
  if (!env.DB) return;

  try {
    await env.DB.prepare(`
      CREATE TABLE IF NOT EXISTS job_assignments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        worker_id TEXT NOT NULL,
        assigned_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        status TEXT DEFAULT 'assigned'
      )
    `).run();

    await env.DB.prepare(
      'INSERT INTO job_assignments (job_id, worker_id) VALUES (?, ?)'
    ).bind(jobId, workerId).run();
  } catch (error) {
    console.error('Error marking job assigned:', error.message);
  }
}

async function markJobFailed(env, jobId, reason) {
  if (!env.DB) return;

  try {
    await env.DB.prepare(
      'UPDATE job_queue SET status=? WHERE job_id=?'
    ).bind('failed', jobId).run();

    await env.DB.prepare(`
      CREATE TABLE IF NOT EXISTS job_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        reason TEXT,
        failed_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `).run();

    await env.DB.prepare(
      'INSERT INTO job_failures (job_id, reason) VALUES (?, ?)'
    ).bind(jobId, reason).run();
  } catch (error) {
    console.error('Error marking job failed:', error.message);
  }
}

async function storeResult(env, result) {
  if (!env.DB) return;

  try {
    await env.DB.prepare(`
      CREATE TABLE IF NOT EXISTS job_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        worker_id TEXT NOT NULL,
        nonce TEXT NOT NULL UNIQUE,
        result_hash TEXT NOT NULL,
        status TEXT NOT NULL,
        compute_time_ms INTEGER,
        submitted BOOLEAN DEFAULT 0,
        pool_status TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `).run();

    await env.DB.prepare(`
      INSERT INTO job_results (job_id, worker_id, nonce, result_hash, status, compute_time_ms)
      VALUES (?, ?, ?, ?, ?, ?)
    `).bind(
      result.job_id,
      result.worker_id,
      result.nonce,
      result.result_hash,
      result.status,
      result.compute_time_ms
    ).run();

    // Mark job as complete
    await env.DB.prepare(
      'UPDATE job_queue SET status=? WHERE job_id=?'
    ).bind('completed', result.job_id).run();
  } catch (error) {
    console.error('Error storing result:', error.message);
  }
}

/**
 * LOGGING - Local audit trail
 */
async function appendLog(env, level, message) {
  try {
    const logs = await env.KV.get('worker_logs_v1') || '[]';
    const entries = JSON.parse(logs);

    entries.push({
      timestamp: new Date().toISOString(),
      level,
      message
    });

    // Keep only recent logs
    if (entries.length > LOG_MAX_ENTRIES) {
      entries.shift();
    }

    await env.KV.put('worker_logs_v1', JSON.stringify(entries), { expirationTtl: 86400 });
  } catch (error) {
    console.error('Error appending log:', error.message);
  }
}

async function getRecentLogs(env) {
  try {
    const logs = await env.KV.get('worker_logs_v1') || '[]';
    return JSON.parse(logs);
  } catch (error) {
    return [];
  }
}

async function clearLogs(env) {
  try {
    await env.KV.delete('worker_logs_v1');
  } catch (error) {
    console.error('Error clearing logs:', error.message);
  }
}

/**
 * STATUS - Aggregate worker state
 */
async function getWorkerStatus(env) {
  const uptime = await getUptime(env);
  const results = await getResultsStats(env);

  return {
    worker_id: env.WORKER_ID || 'unknown',
    version: WORKER_VERSION,
    uptime_ms: uptime,
    current_job: await getCurrentJob(env),
    total_results: results.total,
    valid_results: results.valid,
    invalid_results: results.invalid,
    avg_compute_ms: results.avg_time,
    d1_bound: !!env.DB,
    kv_bound: !!env.KV,
    timestamp: new Date().toISOString()
  };
}

async function getCurrentJob(env) {
  if (!env.DB) return null;

  try {
    const result = await env.DB.prepare(
      'SELECT * FROM job_queue WHERE status=? LIMIT 1'
    ).bind('assigned').first();
    return result || null;
  } catch (error) {
    return null;
  }
}

async function getResultsStats(env) {
  if (!env.DB) return { total: 0, valid: 0, invalid: 0, avg_time: 0 };

  try {
    const stats = await env.DB.prepare(`
      SELECT
        COUNT(*) as total,
        SUM(CASE WHEN status='valid' THEN 1 ELSE 0 END) as valid,
        SUM(CASE WHEN status='invalid' THEN 1 ELSE 0 END) as invalid,
        AVG(compute_time_ms) as avg_time
      FROM job_results
    `).first();

    return {
      total: stats?.total || 0,
      valid: stats?.valid || 0,
      invalid: stats?.invalid || 0,
      avg_time: stats?.avg_time || 0
    };
  } catch (error) {
    return { total: 0, valid: 0, invalid: 0, avg_time: 0 };
  }
}

async function getUptime(env) {
  try {
    const start = await env.KV.get('worker_start_time');
    if (!start) {
      await env.KV.put('worker_start_time', Date.now().toString(), { expirationTtl: 2592000 });
      return 0;
    }
    return Date.now() - parseInt(start);
  } catch (error) {
    return 0;
  }
}

/**
 * UTILITIES
 */
function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  });
}

function notFound(message) {
  return new Response(message, { status: 404 });
}

function formatUptime(ms) {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 0) return `${days}d ${hours % 24}h`;
  if (hours > 0) return `${hours}h ${minutes % 60}m`;
  if (minutes > 0) return `${minutes}m ${seconds % 60}s`;
  return `${seconds}s`;
}

function renderStatus(status) {
  const dbStatus = status.d1_bound ? '<span class="status-ok">✓ Bound</span>' : '<span class="status-error">✗ Not bound</span>';
  const kvStatus = status.kv_bound ? '<span class="status-ok">✓ Bound</span>' : '<span class="status-error">✗ Not bound</span>';

  return `
    <div class="stat">
      <span class="stat-label">D1 Database:</span>
      <span class="stat-value">${dbStatus}</span>
    </div>
    <div class="stat">
      <span class="stat-label">KV Storage:</span>
      <span class="stat-value">${kvStatus}</span>
    </div>
  `;
}

function renderCurrentJob(job) {
  if (!job) return '<p style="color: #858585;">No active job</p>';
  return `
    <div class="stat">
      <span class="stat-label">Job ID:</span>
      <span class="stat-value">${job.job_id}</span>
    </div>
    <div class="stat">
      <span class="stat-label">Type:</span>
      <span class="stat-value">${job.type || 'unknown'}</span>
    </div>
  `;
}

/**
 * MONERO OCEAN MINING - Pull nonces and prepare for stratum submission
 */
async function runMoneroOceanMining(env) {
  const workerId = env.WORKER_ID || 'unknown';
  const poolHost = 'gulf.moneroocean.stream';
  const poolPort = 10128;

  await appendLog(env, 'info', `MoneroOcean mining started (worker: ${workerId})`);

  try {
    let submittedCount = 0;
    while (true) {
      // STEP 1: Pull job (nonce) from dispatcher
      try {
        const req = new Request('https://dispatcher.internal/request-job?worker_id=' + encodeURIComponent(workerId), {
          method: 'GET'
        });
        const dispatcherResp = await env.JOB_DISPATCHER.fetch(req);
        const respText = await dispatcherResp.text();
        const jobData = JSON.parse(respText);

        if (!jobData.job) {
          await appendLog(env, 'warn', 'No jobs available from dispatcher');
          await sleep(5000);
          continue;
        }

        const job = jobData.job;
        await appendLog(env, 'info', `Pulled job: ${job.job_id}`);

        // STEP 2: Prepare nonce for stratum submission
        const nonce = job.task_data || `${job.job_id}-${Date.now()}`;

        // STEP 3: Store in KV for backend submission processor
        // (CF workers can't do raw TCP, so we queue for submission)
        const submissionKey = `nonce:${job.job_id}:${Date.now()}`;
        await env.KV.put(submissionKey, JSON.stringify({
          job_id: job.job_id,
          nonce: nonce,
          difficulty: job.difficulty || 1000000,
          created_at: new Date().toISOString(),
          worker_id: workerId,
          status: 'pending_submission'
        }), { expirationTtl: 86400 }); // 24 hour TTL

        await appendLog(env, 'info', `Queued for submission: ${job.job_id}`);

        submittedCount++;
        if (submittedCount % 100 === 0) {
          await appendLog(env, 'info', `Progress: ${submittedCount} nonces queued`);
        }

        // Brief pause before next
        await sleep(100);

      } catch (jobError) {
        await appendLog(env, 'error', `Job pull error: ${jobError.message}`);
        await sleep(5000);
      }
    }
  } catch (loopError) {
    await appendLog(env, 'error', `MoneroOcean mining error: ${loopError.message}`);
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
