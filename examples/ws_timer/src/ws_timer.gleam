import birl
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http/request
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
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
      loop: fn(msg, state, conn) {
        case msg {
          stratus.Text(msg) -> {
            logging.log(logging.Info, "Got a message: " <> msg)
            actor.continue(state)
          }
          stratus.User(TimeUpdated(msg)) -> {
            let assert Ok(_resp) = stratus.send_text_message(conn, msg)
            actor.continue(state)
          }
          stratus.User(DoTheThing(resp)) -> {
            process.send(resp, 1234)
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
      birl.now()
      |> birl.to_iso8601
      |> TimeUpdated
      |> stratus.to_user_message
      |> process.send(subj, _)
    })

  process.start(
    fn() {
      process.sleep(6000)

      stratus.to_user_message(Close)
      |> process.send(subj, _)
    },
    True,
  )

  process.start(
    fn() {
      process.sleep(500)
      let assert Ok(resp) =
        process.try_call(
          subj,
          fn(subj) { stratus.to_user_message(DoTheThing(subj)) },
          100,
        )
      io.debug(#("got the thing", resp))
      process.sleep(1000)
      let resp =
        process.call_forever(subj, fn(subj) {
          stratus.to_user_message(DoTheThing(subj))
        })
      io.debug(#("got the thing pt 2", resp))
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

  logging.log(
    logging.Info,
    "WebSocket process exited: " <> string.inspect(done),
  )

  repeatedly.stop(timer)
}
