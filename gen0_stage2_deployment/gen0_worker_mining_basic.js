/**
 * GEN 0 WORKER - BASIC MINING VERSION
 *
 * Simplified worker for Phase 1 deployment
 * - No service bindings (JOB_DISPATCHER)
 * - No D1 database
 * - Basic KV state storage
 * - Mining telemetry logging
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Status endpoint
    if (path === '/' || path === '/status') {
      return new Response(JSON.stringify({
        worker_id: env.WORKER_ID || 'unknown',
        status: 'mining',
        timestamp: new Date().toISOString(),
        version: '0.1.0'
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Health check
    if (path === '/health') {
      return new Response(JSON.stringify({
        status: 'healthy',
        timestamp: new Date().toISOString()
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Start mining loop
    if (path === '/mine') {
      ctx.waitUntil(miningLoop(env));
      return new Response(JSON.stringify({
        status: 'mining_started',
        worker_id: env.WORKER_ID || 'unknown',
        timestamp: new Date().toISOString()
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Default response
    return new Response('Gen 0 Worker Basic v0.1.0\nEndpoints: /, /health, /mine', {
      status: 200,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
};

async function miningLoop(env) {
  const workerId = env.WORKER_ID || 'unknown';
  const kvNamespace = env.KV || null;
  let shareCount = 0;
  let lastLogTime = Date.now();

  while (true) {
    try {
      // Simulate mining work
      shareCount++;
      const timestamp = Date.now();

      // Log to KV every 10 shares
      if (shareCount % 10 === 0 && kvNamespace) {
        try {
          const telemetry = JSON.stringify({
            worker_id: workerId,
            shares: shareCount,
            timestamp: new Date().toISOString()
          });
          await kvNamespace.put(`mining-${workerId}-${timestamp}`, telemetry, {
            expirationTtl: 3600 // 1 hour
          });
        } catch (kvError) {
          // KV is optional, continue mining even if it fails
          console.error('KV write error:', kvError.message);
        }
      }

      // Small delay between iterations
      await new Promise(resolve => setTimeout(resolve, 100));
    } catch (error) {
      console.error('Mining loop error:', error);
      // Continue mining even on errors
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
}
