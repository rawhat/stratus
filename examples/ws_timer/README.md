# `stratus` Sample Application

This is an example application to demonstrate using `stratus` as a WebSocket
client.  To run this for yourself, you will need `gleam`, `erlang`, and `bun`
installed.  You don't need bun if you want to test it against a different
WebSocket server.

To execute this locally:

```sh
bun run sample_server/index.ts
# in a separate terminal
gleam run
```

You should see some logging for both sides of the connection, and the `bun`
server should log the messages that `stratus` sends (which are timestamps).
