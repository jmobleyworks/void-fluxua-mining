/**
 * MASCOM Phase 0 K10 Worker - No KV Dependency (Quick Fix)
 * Returns simple responses without accessing KV
 */

const CORS = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*'
};

function parse(pathname) {
  const m = pathname.match(/^\/phase-(\d+)(\/.*)?$/);
  return m ? { num: parseInt(m[1]), path: m[2] || '/' } : { num: 0, path: pathname };
}

async function route(request) {
  const url = new URL(request.url);
  const { num: reg, path } = parse(url.pathname);

  // Status endpoint
  if (path === '/' || path === '/status') {
    return new Response(JSON.stringify({
      status: 'operational',
      version: '2.1.0',
      registerNum: reg,
      timestamp: new Date().toISOString()
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Dedup endpoint - returns unique for now (no KV tracking)
  if (path === '/dedup' && request.method === 'POST') {
    return new Response(JSON.stringify({
      status: 'unique',
      registerNum: reg,
      timestamp: new Date().toISOString()
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Ledger endpoint
  if (path === '/ledger') {
    return new Response(JSON.stringify({
      uniqueNonces: 0,
      registerNum: reg,
      timestamp: new Date().toISOString()
    }), {
      status: 200,
      headers: CORS
    });
  }

  // QEC endpoint
  if (path.startsWith('/qec')) {
    return new Response(JSON.stringify({
      status: 'ok',
      registerNum: reg
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Coherence endpoint
  if (path.startsWith('/coherence')) {
    return new Response(JSON.stringify({
      coherence: 0.85,
      registerNum: reg
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Pool submit endpoint
  if (path === '/pool/submit' && request.method === 'POST') {
    return new Response(JSON.stringify({
      status: 'accepted',
      registerNum: reg
    }), {
      status: 202,
      headers: CORS
    });
  }

  // Rate endpoint
  if (path.startsWith('/rate')) {
    return new Response(JSON.stringify({
      tokensAvailable: 10,
      registerNum: reg
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Consensus endpoint
  if (path.startsWith('/consensus')) {
    return new Response(JSON.stringify({
      consensusStatus: 'active',
      registerNum: reg
    }), {
      status: 200,
      headers: CORS
    });
  }

  // Default 404
  return new Response(JSON.stringify({
    error: 'Not found',
    path: path
  }), {
    status: 404,
    headers: CORS
  });
}

addEventListener('fetch', event => {
  event.respondWith(route(event.request));
});
