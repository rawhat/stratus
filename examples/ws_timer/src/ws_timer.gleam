import birl
import gleam/erlang/process
import gleam/function
import gleam/http/request
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
import repeatedly
import stratus

pub type Msg {
  Close
  SendText(String)
}

pub fn main() {
  let assert Ok(req) = request.to("http://localhost:3000/ws")
  let builder =
    stratus.websocket(
      request: req,
      init: fn() { #(Nil, None) },
      loop: fn(msg, state, conn) {
        case msg {
          stratus.Text(_msg) -> {
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
    |> stratus.on_close(fn(_state) { io.println("oh noooo") })

  let assert Ok(subj) = stratus.initialize(builder)

  let timer =
    repeatedly.call(1000, Nil, fn(_state, _count_) {
      let now =
        birl.now()
        |> birl.to_iso8601
      stratus.send_message(subj, SendText(now))
    })

  process.start(
    fn() {
      process.sleep(6000)

      stratus.send_message(subj, Close)
    },
    True,
  )

  let done =
    process.new_selector()
    |> process.selecting_process_down(
      process.monitor_process(process.subject_owner(subj)),
      function.identity,
    )
    |> process.select_forever

  io.debug(#("WebSocket process exited", done))

  repeatedly.stop(timer)
}
