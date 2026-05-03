/**
 * GEN 0 WORKER - Test Version (No D1 required)
 *
 * Proves the mining algorithm works without database dependency
 * Results stored in memory for testing
 */

let miningState = {
  results: [],
  computedCount: 0,
  startTime: Date.now()
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === '/' && request.method === 'GET') {
      return getDashboard();
    }

    if (path === '/api/status' && request.method === 'GET') {
      return json(getStatus());
    }

    if (path === '/mine' && request.method === 'GET') {
      ctx.waitUntil(startMiningLoop());
      return json({ status: 'mining_started', computed: miningState.computedCount });
    }

    if (path === '/results' && request.method === 'GET') {
      return json(miningState.results.slice(-10));
    }

    return new Response('Test Miner (No D1)\n/mine - Start mining\n/results - Last 10 results\n/api/status - Status\n', {
      headers: { 'Content-Type': 'text/plain' }
    });
  }
};

async function startMiningLoop() {
  console.log('Mining loop started');

  // Compute 20 SHA256 hashes
  for (let i = 0; i < 20; i++) {
    const timestamp = Date.now();
    const random = Math.random().toString(36).substring(2, 15);
    const nonce = `${timestamp}-${random}`;

    try {
      const encoder = new TextEncoder();
      const data = encoder.encode(nonce);
      const hashBuffer = await crypto.subtle.digest('SHA-256', data);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

      miningState.results.push({
        timestamp: new Date().toISOString(),
        nonce,
        hash: hashHex.substring(0, 16) + '...',  // First 16 chars
        computed_at: Date.now()
      });

      miningState.computedCount++;

      // Small delay to avoid overwhelming
      await new Promise(r => setTimeout(r, 10));
    } catch (error) {
      console.error('Compute error:', error.message);
    }
  }

  console.log(`Mining complete: ${miningState.computedCount} hashes computed`);
}

function getStatus() {
  const uptime = Date.now() - miningState.startTime;
  return {
    worker_id: 'test-miner',
    version: '1.0.0',
    status: 'mining',
    computed_count: miningState.computedCount,
    uptime_ms: uptime,
    last_10_results: miningState.results.slice(-10).length,
    d1_bound: false,
    kv_bound: false,
    timestamp: new Date().toISOString()
  };
}

function getDashboard() {
  const lastResults = miningState.results.slice(-5).map(r => `
    <tr>
      <td>${r.timestamp}</td>
      <td>${r.nonce.substring(0, 20)}...</td>
      <td>${r.hash}</td>
    </tr>
  `).join('');

  const html = `<!DOCTYPE html>
<html>
<head>
  <title>Mining Test</title>
  <style>
    body { font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }
    h1 { color: #4ec9b0; }
    .stat { display: flex; justify-content: space-between; padding: 10px; background: #252526; margin: 10px 0; }
    table { width: 100%; border-collapse: collapse; margin-top: 20px; }
    th, td { text-align: left; padding: 8px; border-bottom: 1px solid #3e3e42; }
    th { background: #1e1e1e; color: #4ec9b0; }
    button { background: #007acc; color: white; border: none; padding: 10px 20px; cursor: pointer; margin: 10px 0; }
  </style>
</head>
<body>
  <h1>⛏️ Mining Test Worker (No D1)</h1>
  <p>Testing core SHA256 mining algorithm</p>

  <div class="stat">
    <span>Computed Hashes:</span>
    <strong>${miningState.computedCount}</strong>
  </div>

  <div class="stat">
    <span>Uptime:</span>
    <strong>${((Date.now() - miningState.startTime) / 1000).toFixed(1)}s</strong>
  </div>

  <div class="stat">
    <span>Last Result:</span>
    <strong>${miningState.results[miningState.results.length - 1]?.timestamp || 'None'}</strong>
  </div>

  <button onclick="fetch('/mine').then(r => r.json()).then(d => { alert('Mining started\\n' + JSON.stringify(d, null, 2)); location.reload(); })">Start Mining (20 hashes)</button>
  <button onclick="location.reload()">Refresh</button>

  <h2>Last 5 Results</h2>
  <table>
    <tr>
      <th>Timestamp</th>
      <th>Nonce</th>
      <th>Hash</th>
    </tr>
    ${lastResults || '<tr><td colspan="3">No results yet - click "Start Mining"</td></tr>'}
  </table>
</body>
</html>`;

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  });
}

function json(data) {
  return new Response(JSON.stringify(data, null, 2), {
    headers: { 'Content-Type': 'application/json' }
  });
}
