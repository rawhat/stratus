import birl
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http/request
import gleam/io
import gleam/option.{None}
import gleam/string
import logging
import repeatedly
import stratus

pub type Msg {
  Close
  TimeUpdated(String)
  DoTheThing(Subject(Int))
}

pub type LogLevel {
  Debug
}

pub type Log {
  Level
}

@external(erlang, "logger", "set_primary_config")
fn set_logger_level(log: Log, level: LogLevel) -> Nil

pub fn main() {
  logging.configure()
  set_logger_level(Level, Debug)
  let assert Ok(req) =
    request.to("http://localhost:3000/ws?hello=world&value=123")
  let builder =
    stratus.websocket(
      request: req,
      init: fn() { #(Nil, None) },
      loop: fn(state, msg, conn) {
        case msg {
          stratus.Text(msg) -> {
            logging.log(logging.Info, "Got a message: " <> msg)
            stratus.continue(state)
          }
          stratus.User(TimeUpdated(msg)) -> {
            let assert Ok(_resp) = stratus.send_text_message(conn, msg)
            stratus.continue(state)
          }
          stratus.User(DoTheThing(resp)) -> {
            process.send(resp, 1234)
            stratus.continue(state)
          }
          stratus.Binary(_msg) -> stratus.continue(state)
          stratus.User(Close) -> {
            let assert Ok(_) = stratus.close(conn)
            stratus.stop()
          }
        }
      },
    )
    |> stratus.on_close(fn(_state) { io.println("oh noooo") })

  let assert Ok(subj) = stratus.initialize(builder)

  let timer =
    repeatedly.call(1000, Nil, fn(_state, _count_) {
      birl.now()
      |> birl.to_iso8601
      |> TimeUpdated
      |> stratus.to_user_message
      |> process.send(subj.data, _)
    })

  process.spawn(fn() {
    process.sleep(6000)

    stratus.to_user_message(Close)
    |> process.send(subj.data, _)
  })

  process.spawn(fn() {
    process.sleep(500)
    let resp =
      process.call(subj.data, 100, fn(subj) {
        stratus.to_user_message(DoTheThing(subj))
      })
    echo #("got the thing", resp)
    process.sleep(1000)
    let resp =
      process.call_forever(subj.data, fn(subj) {
        stratus.to_user_message(DoTheThing(subj))
      })
    echo #("got the thing pt 2", resp)
  })

  let assert Ok(owner) = process.subject_owner(subj.data)
  let done =
    process.new_selector()
    |> process.select_specific_monitor(
      process.monitor(owner),
      function.identity,
    )
    |> process.selector_receive_forever

  logging.log(
    logging.Info,
    "WebSocket process exited: " <> string.inspect(done),
  )

  repeatedly.stop(timer)
}
