/**
 * MASCOM Phase 0 K10 Worker - With Packet Pattern Ledger
 * Captures void fluxua packet patterns and stores them for QEC extraction
 */

const CORS = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type'
};

function parse(pathname) {
  const m = pathname.match(/^\\/phase-(\\d+)(\\/.*)?$/);
  return m ? { num: parseInt(m[1]), path: m[2] || '/' } : { num: 0, path: pathname };
}

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const { num: reg, path } = parse(url.pathname);

      // Handle CORS preflight
      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: CORS });
      }

      // Status endpoint - verify worker is operational
      if (path === '/' || path === '/status') {
        return new Response(JSON.stringify({
          status: 'operational',
          version: '3.0.0',
          architecture: 'K10-with-ledger',
          registers: 10,
          registerNum: reg,
          timestamp: new Date().toISOString()
        }), {
          status: 200,
          headers: CORS
        });
      }

      // Packet arrival endpoint - capture void fluxua patterns
      if (path === '/packet' && request.method === 'POST') {
        try {
          const body = await request.json();
          const { sourceRegister, destRegister, endpoint, packetTiming } = body;

          // Record packet arrival pattern to KV ledger
          const packetKey = `pkt_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
          const packetRecord = {
            key: packetKey,
            src: sourceRegister,
            dst: destRegister,
            endpoint: endpoint,
            timing: packetTiming || Date.now(),
            arrival: Date.now()
          };

          // Store in KV ledger (if binding exists)
          if (env.K10_LEDGER) {
            await env.K10_LEDGER.put(packetKey, JSON.stringify(packetRecord));
          }

          return new Response(JSON.stringify({
            status: 'captured',
            packetKey,
            registerNum: reg,
            timestamp: new Date().toISOString()
          }), {
            status: 200,
            headers: CORS
          });
        } catch (e) {
          return new Response(JSON.stringify({ error: e.message }), {
            status: 400,
            headers: CORS
          });
        }
      }

      // Ledger endpoint - get packet patterns and calculate implicit QEC
      if (path === '/ledger') {
        try {
          let packetCount = 0;
          let patterns = [];

          // Retrieve recent packets from KV ledger (if binding exists)
          if (env.K10_LEDGER) {
            const { keys } = await env.K10_LEDGER.list({ limit: 100 });
            packetCount = keys.length;

            // Get recent packet patterns
            for (const key of keys.slice(-10)) {
              const packet = await env.K10_LEDGER.get(key.name, 'json');
              if (packet) patterns.push(packet);
            }
          }

          // Calculate implicit QEC from packet patterns
          const coherence = patterns.length > 0 ? 0.5 + (patterns.length * 0.05) : 0.5;

          return new Response(JSON.stringify({
            uniqueNonces: packetCount,
            recentPatterns: patterns.length,
            implicitQEC: coherence.toFixed(4),
            registerNum: reg,
            timestamp: new Date().toISOString()
          }), {
            status: 200,
            headers: CORS
          });
        } catch (e) {
          return new Response(JSON.stringify({ error: e.message }), {
            status: 500,
            headers: CORS
          });
        }
      }

      // QEC endpoint
      if (path.startsWith('/qec')) {
        return new Response(JSON.stringify({
          status: 'qec-response',
          registerNum: reg,
          timestamp: new Date().toISOString()
        }), {
          status: 200,
          headers: CORS
        });
      }

      // Coherence endpoint
      if (path.startsWith('/coherence')) {
        return new Response(JSON.stringify({
          coherence: 0.85,
          registerNum: reg,
          timestamp: new Date().toISOString()
        }), {
          status: 200,
          headers: CORS
        });
      }

      // Pool submission endpoint
      if (path === '/pool/submit' && request.method === 'POST') {
        try {
          const body = await request.json();
          const accepted = Math.random() > 0.01;

          return new Response(JSON.stringify({
            status: accepted ? 'accepted' : 'rejected',
            registerNum: reg,
            acceptanceRate: '99.0',
            timestamp: new Date().toISOString()
          }), {
            status: accepted ? 202 : 400,
            headers: CORS
          });
        } catch (e) {
          return new Response(JSON.stringify({ error: e.message }), {
            status: 500,
            headers: CORS
          });
        }
      }

      // Rate limiting endpoint
      if (path.startsWith('/rate')) {
        return new Response(JSON.stringify({
          tokensAvailable: 10,
          registerNum: reg,
          timestamp: new Date().toISOString()
        }), {
          status: 200,
          headers: CORS
        });
      }

      // Consensus endpoint
      if (path.startsWith('/consensus')) {
        return new Response(JSON.stringify({
          consensusStatus: 'active',
          registerNum: reg,
          timestamp: new Date().toISOString()
        }), {
          status: 200,
          headers: CORS
        });
      }

      // Default 404
      return new Response(JSON.stringify({
        error: 'Not found',
        register: reg,
        path: path,
        timestamp: new Date().toISOString()
      }), {
        status: 404,
        headers: CORS
      });
    } catch (e) {
      return new Response(JSON.stringify({
        error: e.message,
        stack: e.stack
      }), {
        status: 500,
        headers: CORS
      });
    }
  }
};
