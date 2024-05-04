Bun.serve({
  fetch(req, server) {
    if (server.upgrade(req)) {
      console.log("Upgraded with request", req)
      return;
    }
    return new Response("Upgrade failed", { status: 500 })
  },
  websocket: {
    message(_ws, message) {
      console.log("Received message", message)
    },
    open(_ws) {
      console.log("WebSocket opened!")
    },
    close(_ws, code, message) {
      console.log(`WebSocket closed for ${code} with ${message}`)
    }
  }
})
