Bun.serve({
  fetch(req, server) {
    if (server.upgrade(req)) {
      console.log("Upgraded with request", req)
      return;
    }
    return new Response("Upgrade failed", { status: 500 })
  },
  websocket: {
    perMessageDeflate: true,
    message(ws, message) {
      ws.send("ok", true)
      console.log("Received message", message)
    },
    open(ws) {
      ws.send("opened!", true)
      console.log("WebSocket opened!")
    },
    close(_ws, code, message) {
      console.log(`WebSocket closed for ${code} with ${message}`)
    }
  }
})
