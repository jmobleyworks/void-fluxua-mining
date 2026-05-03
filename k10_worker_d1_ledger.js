/**
 * MASCOM Phase 0 K10 Worker - With D1 Packet Pattern Ledger
 * Captures void fluxua packet patterns and stores them in SQLite for QEC analysis
 */

const CORS = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type'
};

function parse(pathname) {
  const m = pathname.match(/^\/phase-(\d+)(\/.*)?$/);
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

      // Initialize D1 database tables on first request
      if (env.DB && request.headers.get('X-Initialize') === 'true') {
        try {
          await env.DB.prepare(`
            CREATE TABLE IF NOT EXISTS packets (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              packet_id TEXT UNIQUE,
              src_register INTEGER,
              dst_register INTEGER,
              endpoint TEXT,
              send_timing INTEGER,
              arrival_timing INTEGER,
              created_at INTEGER
            )
          `).run();
        } catch (e) {
          // Table might already exist
        }
      }

      // Status endpoint - verify worker is operational
      if (path === '/' || path === '/status') {
        return new Response(JSON.stringify({
          status: 'operational',
          version: '3.1.0',
          architecture: 'K10-d1-ledger',
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

          const packetId = `pkt_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
          const now = Date.now();

          // Store in D1 ledger (if binding exists)
          if (env.DB) {
            await env.DB.prepare(`
              INSERT INTO packets (packet_id, src_register, dst_register, endpoint, send_timing, arrival_timing, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?)
            `).bind(packetId, sourceRegister, destRegister, endpoint, packetTiming || 0, now, now).run();
          }

          return new Response(JSON.stringify({
            status: 'captured',
            packetId,
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
          let totalPackets = 0;
          let recentPatterns = [];
          let coherence = 0.5;

          if (env.DB) {
            // Get total packet count
            const countResult = await env.DB.prepare('SELECT COUNT(*) as count FROM packets').first();
            totalPackets = countResult?.count || 0;

            // Get recent packet patterns (last 50)
            const patterns = await env.DB.prepare(`
              SELECT
                packet_id,
                src_register,
                dst_register,
                endpoint,
                arrival_timing,
                created_at
              FROM packets
              ORDER BY created_at DESC
              LIMIT 50
            `).all();

            if (patterns.results && patterns.results.length > 0) {
              recentPatterns = patterns.results;

              // Calculate implicit QEC from pattern diversity
              // More diverse source/dest pairs = higher coherence
              const uniquePairs = new Set();
              for (const pkt of patterns.results) {
                uniquePairs.add(`${pkt.src_register}_${pkt.dst_register}`);
              }
              coherence = Math.min(0.99, 0.5 + (uniquePairs.size * 0.05));
            }
          }

          return new Response(JSON.stringify({
            totalPackets,
            recentPatterns: recentPatterns.length,
            implicitQEC: coherence.toFixed(4),
            patterns: recentPatterns.slice(0, 10), // Return first 10 recent patterns
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

      // Pattern analysis endpoint - extract syndrome from patterns
      if (path === '/analyze-patterns') {
        try {
          if (!env.DB) {
            return new Response(JSON.stringify({ error: 'DB not available' }), {
              status: 500,
              headers: CORS
            });
          }

          // Get patterns from last 10 seconds
          const tenSecondsAgo = Date.now() - 10000;
          const patterns = await env.DB.prepare(`
            SELECT
              src_register,
              dst_register,
              endpoint,
              arrival_timing
            FROM packets
            WHERE created_at > ?
            ORDER BY created_at ASC
          `).bind(tenSecondsAgo).all();

          // Calculate pattern-based syndrome
          let syndrome = 0;
          if (patterns.results && patterns.results.length > 0) {
            // Syndrome = hash of pattern sequence
            for (let i = 0; i < patterns.results.length; i++) {
              const pkt = patterns.results[i];
              const val = (pkt.src_register * 10 + pkt.dst_register) * (i + 1);
              syndrome ^= val;
            }
          }

          return new Response(JSON.stringify({
            patternCount: patterns.results?.length || 0,
            derivedSyndrome: syndrome,
            coherence: (0.5 + (patterns.results?.length || 0) * 0.01).toFixed(4),
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
