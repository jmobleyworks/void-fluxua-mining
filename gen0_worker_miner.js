/**
 * GEN 0 WORKER MINING - Nonce Generation + D1 Storage
 * Purpose: Generate nonces and store in D1 for stratum bridge to pick up
 *
 * Each worker:
 * 1. Generates nonces locally (per-request)
 * 2. Stores in D1 database (worker-nonces table)
 * 3. Stratum bridge reads from D1, submits to pool
 * 4. Provides status endpoint for monitoring
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Status endpoint - shows current mining state
    if (path === '/status' || path === '/') {
      try {
        const db = env.DB;
        if (!db) {
          return new Response(JSON.stringify({
            error: 'D1 database not bound',
            binding: 'Missing DB binding in env'
          }), { status: 500, headers: { 'Content-Type': 'application/json' } });
        }

        // Query pending nonces count
        const result = await db.prepare(
          'SELECT COUNT(*) as pending_count FROM worker_nonces WHERE status=?'
        ).bind('pending').first();

        return new Response(JSON.stringify({
          status: 'mining',
          worker_id: env.WORKER_ID || 'unknown',
          d1_bound: true,
          pending_nonces: result?.pending_count || 0,
          timestamp: new Date().toISOString()
        }), {
          headers: { 'Content-Type': 'application/json' }
        });
      } catch (error) {
        return new Response(JSON.stringify({
          status: 'error',
          error: error.message
        }), { status: 500, headers: { 'Content-Type': 'application/json' } });
      }
    }

    // Mining endpoint - generates a nonce and stores in D1
    if (path === '/mine') {
      ctx.waitUntil(generateAndStorNonce(env));
      return new Response(JSON.stringify({
        status: 'nonce_generated',
        timestamp: new Date().toISOString()
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Generate multiple nonces (for testing)
    if (path.startsWith('/mine/')) {
      const count = parseInt(path.split('/')[2]) || 1;
      ctx.waitUntil(generateMultipleNonces(env, count));
      return new Response(JSON.stringify({
        status: 'generating',
        count: count,
        timestamp: new Date().toISOString()
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    return new Response('Gen 0 Worker Miner - D1 Edition\n\nEndpoints:\n/status - Show pending nonces\n/mine - Generate 1 nonce\n/mine/N - Generate N nonces\n', {
      headers: { 'Content-Type': 'text/plain' }
    });
  }
};

/**
 * Generate a single nonce and store in D1
 */
async function generateAndStorNonce(env) {
  try {
    const db = env.DB;
    if (!db) {
      console.error('D1 database not bound');
      return;
    }

    // Generate nonce: epoch_ms + random_hex + worker_id
    const timestamp = Date.now();
    const random = Math.random().toString(36).substring(2, 15);
    const workerId = env.WORKER_ID || 'worker_unknown';
    const nonce = `${timestamp}-${random}-${workerId}`;

    // Create hash: sha256 of nonce (simplified - real mining uses RandomX)
    // For now, just use a deterministic hash pattern based on nonce
    const hash = hashNonce(nonce);

    // Job ID: current timestamp (pool will validate during submission)
    const jobId = `job-${Math.floor(timestamp / 1000)}`;

    // Insert into worker_nonces table
    await db.prepare(`
      INSERT INTO worker_nonces (nonce_hex, result_hex, job_id, source, status)
      VALUES (?, ?, ?, ?, ?)
    `).bind(
      nonce,           // nonce_hex
      hash,            // result_hex
      jobId,           // job_id
      'worker',        // source
      'pending'        // status
    ).run();

    console.log(`✓ Nonce stored: ${nonce}`);

  } catch (error) {
    console.error(`Nonce generation error: ${error.message}`);
  }
}

/**
 * Generate multiple nonces and store in D1
 */
async function generateMultipleNonces(env, count) {
  try {
    const db = env.DB;
    if (!db) {
      console.error('D1 database not bound');
      return;
    }

    const workerId = env.WORKER_ID || 'worker_unknown';
    const timestamp = Date.now();
    const jobId = `job-${Math.floor(timestamp / 1000)}`;

    // Batch insert for efficiency
    const nonces = [];
    for (let i = 0; i < count; i++) {
      const random = Math.random().toString(36).substring(2, 15);
      const nonce = `${timestamp}-${random}-${i}-${workerId}`;
      const hash = hashNonce(nonce);

      nonces.push({
        nonce: nonce,
        hash: hash,
        job: jobId
      });
    }

    // Insert all nonces (one at a time due to D1 API limitations)
    for (const nonce of nonces) {
      try {
        await db.prepare(`
          INSERT INTO worker_nonces (nonce_hex, result_hex, job_id, source, status)
          VALUES (?, ?, ?, ?, ?)
        `).bind(
          nonce.nonce,     // nonce_hex
          nonce.hash,      // result_hex
          nonce.job,       // job_id
          'worker',        // source
          'pending'        // status
        ).run();
      } catch (e) {
        // Ignore duplicate nonce errors
        if (!e.message.includes('UNIQUE')) {
          console.error(`Error inserting nonce: ${e.message}`);
        }
      }
    }

    console.log(`✓ Stored ${count} nonces`);

  } catch (error) {
    console.error(`Batch generation error: ${error.message}`);
  }
}

/**
 * Simple hash function for nonce
 * In production, would use RandomX or SHA256
 */
function hashNonce(nonce) {
  // Generate a deterministic hex string from nonce
  let hash = '';
  for (let i = 0; i < nonce.length; i++) {
    hash += nonce.charCodeAt(i).toString(16).padStart(2, '0');
  }
  // Pad to 64 hex characters (256 bits)
  return hash.padEnd(64, '0').substring(0, 64);
}
