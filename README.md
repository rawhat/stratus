# stratus

A Gleam WebSocket client (and possibly more).

[![Package Version](https://img.shields.io/hexpm/v/stratus)](https://hex.pm/packages/stratus)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/stratus/)

```sh
gleam add stratus
```
```gleam
import birl
import gleam/erlang/process
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
import gleam/uri
import repeatedly
import stratus

pub type Msg {
  Close
  SendText(String)
}

pub fn main() {
  let assert Ok(url) = uri.parse("ws://localhost:3000/ws")
  let builder =
    stratus.websocket(
      uri: url,
      init: fn() { #(Nil, None) },
      loop: fn(msg, state, conn) {
        case msg {
          stratus.Text(msg) -> {
            let assert Ok(_resp) =
              stratus.send_text_message(conn, "hello, world!")
            actor.continue(state)
          }
          stratus.User(SendText(msg)) -> {
            let assert Ok(_resp) = stratus.send_text_message(conn, msg)
            actor.continue(state)
          }
          stratus.Binary(_msg) -> actor.continue(state)
          stratus.User(Close) -> {
            let assert Ok(_) = stratus.close(conn)
            actor.Stop(process.Normal)
          }
        }
      },
    )

  let res = stratus.initialize(builder)
  io.debug(res)
  let assert Ok(subj) = res

  let timer =
    repeatedly.call(1000, Nil, fn(_state, _count_) {
      let now =
        birl.now()
        |> birl.to_iso8601
      stratus.send_message(subj, SendText(now))
    })

  process.sleep(5000)

  stratus.send_message(subj, Close)
}
```

Further documentation can be found at <https://hexdocs.pm/stratus>.
