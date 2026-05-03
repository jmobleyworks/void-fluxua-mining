/**
 * GEN 0 WORKER SIMPLE - Direct Pipeline
 *
 * ONLY responsible for:
 * 1. Pull nonce job from dispatcher
 * 2. Queue it in KV for persistent submitter
 *
 * Submitter handles pool communication
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Dashboard
    if (path === '/' || path === '/status') {
      return await handleDashboard(env);
    }

    // Pull job and queue nonce
    if (path === '/mine') {
      ctx.waitUntil(pullAndQueueNonce(env));
      return new Response(JSON.stringify({
        status: 'nonce_queued',
        worker_id: env.WORKER_ID || 'unknown',
        timestamp: new Date().toISOString()
      }), { headers: { 'Content-Type': 'application/json' } });
    }

    // Health check
    if (path === '/health') {
      return new Response('OK', { status: 200 });
    }

    return new Response('Gen 0 Simple Worker\n\nEndpoints:\n/health - Health\n/mine - Queue nonce\n', {
      headers: { 'Content-Type': 'text/plain' }
    });
  }
};

async function handleDashboard(env) {
  const workerId = env.WORKER_ID || 'unknown';
  const kvBound = !!env.KV;
  const dispatcherBound = !!env.JOB_DISPATCHER;

  const html = `<!DOCTYPE html>
<html>
<head>
  <title>Worker ${workerId}</title>
  <style>
    body { font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }
    .header { border-bottom: 2px solid #007acc; padding-bottom: 10px; margin-bottom: 20px; }
    .section { background: #252526; padding: 10px; margin-bottom: 10px; border-left: 3px solid #007acc; }
    .stat { display: flex; justify-content: space-between; padding: 5px 0; }
    .status-ok { color: #6a9955; }
    .status-error { color: #f48771; }
    button { background: #007acc; color: white; border: none; padding: 8px 12px; cursor: pointer; margin: 5px 0; }
  </style>
</head>
<body>
  <div class="header">
    <h1>⚙️ Gen 0 Simple Worker</h1>
    <p>Worker ID: <strong>${workerId}</strong></p>
  </div>

  <div class="section">
    <h2>Bindings</h2>
    <div class="stat">
      <span>KV Storage:</span>
      <span class="${kvBound ? 'status-ok' : 'status-error'}">
        ${kvBound ? '✓ Bound' : '✗ Not bound'}
      </span>
    </div>
    <div class="stat">
      <span>Job Dispatcher:</span>
      <span class="${dispatcherBound ? 'status-ok' : 'status-error'}">
        ${dispatcherBound ? '✓ Bound' : '✗ Not bound'}
      </span>
    </div>
  </div>

  <div class="section">
    <h2>Actions</h2>
    <button onclick="fetch('/mine').then(r => r.json()).then(d => alert(JSON.stringify(d)))">
      Queue Nonce
    </button>
  </div>
</body>
</html>`;

  return new Response(html, { headers: { 'Content-Type': 'text/html' } });
}

async function pullAndQueueNonce(env) {
  try {
    const workerId = env.WORKER_ID || 'worker-unknown';

    // Step 1: Pull job from dispatcher
    let job = null;
    if (env.JOB_DISPATCHER) {
      try {
        const dispatcherReq = new Request(
          `https://dispatcher.internal/request-job?worker_id=${encodeURIComponent(workerId)}`,
          { method: 'GET' }
        );
        const dispatcherResp = await env.JOB_DISPATCHER.fetch(dispatcherReq);
        const dispatcherData = await dispatcherResp.json();
        job = dispatcherData.job;
      } catch (e) {
        console.error('Dispatcher call failed:', e.message);
      }
    }

    // Step 2: If no job from dispatcher, stop
    if (!job) {
      console.log('No job from dispatcher');
      return;
    }

    const jobId = job.job_id;
    const nonce = job.task_data; // The nonce from D1

    // Step 3: Queue in KV for persistent submitter
    if (env.KV && nonce) {
      const kvKey = `nonce:${jobId}:${Date.now()}`;
      await env.KV.put(kvKey, JSON.stringify({
        job_id: jobId,
        nonce: nonce,
        difficulty: job.difficulty || 1000000,
        worker_id: workerId,
        queued_at: new Date().toISOString()
      }), { expirationTtl: 86400 });

      console.log(`Queued nonce: ${nonce} (job: ${jobId})`);
    } else {
      console.error('KV not bound or no nonce in job');
    }
  } catch (error) {
    console.error('pullAndQueueNonce error:', error.message);
  }
}
