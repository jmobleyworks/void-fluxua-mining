addEventListener('fetch', event => {
  const response = new Response(JSON.stringify({
    status: 'operational',
    message: 'K10 worker is responding'
  }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  });
  event.respondWith(response);
});
