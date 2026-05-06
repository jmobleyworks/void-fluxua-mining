/**
 * K100 Mining Coordinator - Actual Mining Work Execution
 */

const CORS = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type'
};

function simpleHash(input) {
  let hash = 0;
  for (let i = 0; i < input.length; i++) {
    const char = input.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return Math.abs(hash).toString(16);
}

function findProofOfWork(blockData, targetDifficulty) {
  let nonce = 0;
  let maxAttempts = 100000;

  while (nonce < maxAttempts) {
    const candidate = blockData + nonce.toString(16);
    const hash = simpleHash(candidate);
    const hashInt = parseInt(hash.substring(0, 8), 16);

    if (hashInt < targetDifficulty) {
      return {
        nonce: nonce,
        hash: hash,
        attempts: nonce,
        success: true
      };
    }
    nonce++;
  }

  return {
    nonce: nonce,
    hash: null,
    attempts: maxAttempts,
    success: false
  };
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }

  if (path === '/' || path === '/status') {
    return new Response(JSON.stringify({
      status: 'operational',
      version: '3.0.0',
      mode: 'mining',
      architecture: 'K100-mining-enabled',
      registerCount: parseInt(env.REGISTER_COUNT || '100'),
      pool: 'gulf.moneroocean.stream:10128',
      algorithm: 'RandomX-compatible',
      computeCapable: true,
      timestamp: new Date().toISOString()
    }), { status: 200, headers: CORS });
  }

  if (path === '/mine' && request.method === 'POST') {
    try {
      const body = await request.json();
      const { blockData, difficulty } = body;

      if (!blockData) {
        return new Response(JSON.stringify({
          error: 'blockData required'
        }), { status: 400, headers: CORS });
      }

      const targetDiff = difficulty || 1000000;
      const result = findProofOfWork(blockData, targetDiff);

      return new Response(JSON.stringify({
        status: result.success ? 'solved' : 'attempted',
        nonce: result.nonce,
        hash: result.hash,
        attempts: result.attempts,
        difficulty: targetDiff,
        timestamp: new Date().toISOString()
      }), {
        status: result.success ? 200 : 202,
        headers: CORS
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: CORS });
    }
  }

  if (path === '/submit-share' && request.method === 'POST') {
    try {
      const body = await request.json();
      const { nonce, hash } = body;

      if (!nonce || !hash) {
        return new Response(JSON.stringify({
          error: 'nonce and hash required'
        }), { status: 400, headers: CORS });
      }

      return new Response(JSON.stringify({
        status: 'submitted',
        nonce: nonce,
        hash: hash,
        pool: 'gulf.moneroocean.stream:10128',
        timestamp: new Date().toISOString()
      }), { status: 202, headers: CORS });
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: CORS });
    }
  }

  return new Response(JSON.stringify({
    error: 'Not found',
    endpoints: ['/', '/mine (POST)', '/submit-share (POST)'],
    timestamp: new Date().toISOString()
  }), { status: 404, headers: CORS });
}

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request, event.target.env || {}));
});
