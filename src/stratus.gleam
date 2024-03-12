import gleam/bytes_builder.{type BytesBuilder}
import gleam/bit_array
import gleam/erlang/charlist
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import stratus/internal/socket.{
  type Socket, type SocketMessage, type SocketReason, Once, Pull, Receive,
}
import stratus/internal/transport.{type Transport, Ssl, Tcp}
import gramps.{
  type DataFrame, BinaryFrame, Complete, Data as DataFrame, TextFrame,
}

pub opaque type Connection {
  Connection(socket: Socket, transport: Transport)
}

fn from_socket_message(msg: SocketMessage) -> InternalMessage(user_message) {
  case msg {
    socket.Data(bits) -> Data(bits)
    socket.Closed -> Closed
    socket.Err(reason) -> Err(reason)
  }
}

pub opaque type InternalMessage(user_message) {
  UserMessage(user_message)
  Err(SocketReason)
  Data(BitArray)
  Closed
  Shutdown
}

pub type Message(user_message) {
  Text(String)
  Binary(BitArray)
  User(user_message)
}

pub opaque type Builder(state, user_message) {
  Builder(
    uri: Uri,
    init_timeout: Option(Int),
    init: fn() -> #(state, Option(Selector(user_message))),
    loop: fn(Message(user_message), state, Connection) ->
      actor.Next(user_message, state),
  )
}

pub fn websocket(
  uri uri: Uri,
  init init: fn() -> #(state, Option(Selector(user_message))),
  loop loop: fn(Message(user_message), state, Connection) ->
    actor.Next(user_message, state),
) -> Builder(state, user_message) {
  Builder(uri: uri, init_timeout: None, init: init, loop: loop)
}

pub type State(state) {
  State(
    buffer: BitArray,
    incomplete: Option(DataFrame),
    socket: Socket,
    user_state: state,
  )
}

pub type UriError {
  MissingHost
  MissingPort
}

pub type StartError {
  ActorError(actor.StartError)
  UriError(UriError)
}

pub fn initialize(
  builder: Builder(state, user_message),
) -> Result(Subject(InternalMessage(user_message)), StartError) {
  let transport = case builder.uri.scheme {
    Some("wss") -> Ssl
    _ -> Tcp
  }
  use host <- result.try(option.to_result(
    builder.uri.host,
    UriError(MissingHost),
  ))
  use port <- result.try(option.to_result(
    builder.uri.port,
    UriError(MissingPort),
  ))

  let origin = case builder.uri.scheme, port {
    Some("wss"), 443 -> "https://" <> host
    Some("ws"), 80 -> "http://" <> host
    Some("wss"), _ -> "https://" <> host <> ":" <> int.to_string(port)
    _, _ -> "http://" <> host <> ":" <> int.to_string(port)
  }

  let timeout = option.unwrap(builder.init_timeout, 5000)

  actor.start_spec(
    actor.Spec(
      init: fn() {
        perform_handshake(
          transport,
          host,
          port,
          builder.uri.path,
          origin,
          timeout,
        )
        |> result.try(fn(socket) {
          case
            transport.set_opts(
              transport,
              socket,
              socket.convert_options([Receive(Once)]),
            )
          {
            Ok(_) -> Ok(socket)
            Error(reason) -> Error(Sock(reason))
          }
        })
        |> result.map(fn(socket) {
          let #(user_state, user_selector) = builder.init()
          let selector = case user_selector {
            Some(selector) -> {
              selector
              |> process.map_selector(UserMessage)
              |> process.merge_selector(process.map_selector(
                socket.selector(),
                from_socket_message,
              ))
            }
            _ -> process.map_selector(socket.selector(), from_socket_message)
          }
          actor.Ready(
            State(
              buffer: <<>>,
              incomplete: None,
              socket: socket,
              user_state: user_state,
            ),
            selector,
          )
        })
        |> result.map_error(fn(err) { actor.Failed(string.inspect(err)) })
        |> result.unwrap_both
      },
      init_timeout: timeout,
      loop: fn(msg, state) {
        let conn = Connection(state.socket, transport: transport)
        case msg {
          UserMessage(user_message) -> {
            case builder.loop(User(user_message), state.user_state, conn) {
              actor.Continue(user_state, user_selector) -> {
                let new_state = State(..state, user_state: user_state)
                case user_selector {
                  Some(user_selector) -> {
                    let selector =
                      user_selector
                      |> process.map_selector(UserMessage)
                      |> process.merge_selector(process.map_selector(
                        socket.selector(),
                        from_socket_message,
                      ))
                    actor.Continue(new_state, Some(selector))
                  }
                  _ -> actor.continue(new_state)
                }
              }
              actor.Stop(reason) -> actor.Stop(reason)
            }
          }
          Err(reason) -> {
            actor.Stop(process.Abnormal(string.inspect(reason)))
          }
          Data(bits) -> {
            // io.debug(#("got some data", bits))
            gramps.frame_from_message(bit_array.append(state.buffer, bits))
            |> result.map(fn(data) {
              let #(parsed_frame, rest) = data
              let frame = case parsed_frame {
                Complete(DataFrame(TextFrame(payload: data, ..))) -> {
                  let assert Ok(str) = bit_array.to_string(data)
                  Text(str)
                }
                Complete(DataFrame(BinaryFrame(payload: data, ..))) ->
                  Binary(data)
                _ -> panic as "Incomplete messages not supported right now"
              }
              case builder.loop(frame, state.user_state, conn) {
                actor.Continue(user_state, _selector) -> {
                  let assert Ok(_) =
                    transport.set_opts(
                      transport,
                      state.socket,
                      socket.convert_options([Receive(Once)]),
                    )
                  actor.continue(
                    State(..state, user_state: user_state, buffer: rest),
                  )
                }
                actor.Stop(reason) -> actor.Stop(reason)
              }
            })
            |> result.lazy_unwrap(fn() {
              let assert Ok(_) =
                transport.set_opts(
                  transport,
                  state.socket,
                  socket.convert_options([Receive(Once)]),
                )
              actor.continue(
                State(..state, buffer: bit_array.append(state.buffer, bits)),
              )
            })
          }
          // TODO:  handle shutdown better?
          Closed | Shutdown -> {
            actor.Stop(process.Normal)
          }
        }
      },
    ),
  )
  |> result.map_error(ActorError)
}

pub fn send_message(
  subject: Subject(InternalMessage(user_message)),
  message: user_message,
) -> Nil {
  process.send(subject, UserMessage(message))
}

pub fn send_text_message(
  conn: Connection,
  msg: String,
) -> Result(Nil, SocketReason) {
  let frame = gramps.to_text_frame(msg, True)
  transport.send(conn.transport, conn.socket, frame)
}

pub fn send_binary_message(
  conn: Connection,
  msg: BitArray,
) -> Result(Nil, SocketReason) {
  let frame = gramps.to_binary_frame(msg, True)
  transport.send(conn.transport, conn.socket, frame)
}

pub fn close(conn: Connection) -> Result(Nil, SocketReason) {
  let frame =
    gramps.frame_to_bytes_builder(
      gramps.Control(gramps.CloseFrame(0, <<>>)),
      None,
    )
  transport.send(conn.transport, conn.socket, frame)
}

fn make_upgrade(path: String, host: String, origin: String) -> BytesBuilder {
  bytes_builder.new()
  |> bytes_builder.append_string("GET " <> path <> " HTTP/1.1\r\n")
  |> bytes_builder.append_string("Host: " <> host <> "\r\n")
  |> bytes_builder.append_string("Upgrade: websocket\r\n")
  |> bytes_builder.append_string("Connection: Upgrade\r\n")
  |> bytes_builder.append_string(
    "Sec-WebSocket-Key: " <> gramps.websocket_client_key <> "\r\n",
  )
  |> bytes_builder.append_string("Sec-WebSocket-Version: 13\r\n")
  |> bytes_builder.append_string("Origin: " <> origin <> "\r\n")
  |> bytes_builder.append_string("\r\n")
}

type HandshakeError {
  Sock(SocketReason)
  Protocol(BitArray)
}

fn perform_handshake(
  transport: Transport,
  host: String,
  port: Int,
  path: String,
  origin: String,
  timeout: Int,
) -> Result(Socket, HandshakeError) {
  let opts =
    socket.convert_options(list.append(socket.default_options, [Receive(Pull)]))

  use socket <- result.try(result.map_error(
    transport.connect(transport, charlist.from_string(host), port, opts),
    Sock,
  ))

  use _nil <- result.try(result.map_error(
    transport.send(transport, socket, make_upgrade(path, host, origin)),
    Sock,
  ))

  use resp <- result.try(result.map_error(
    transport.receive_timeout(transport, socket, 0, timeout),
    Sock,
  ))

  case resp {
    <<"HTTP/1.1 101 Switching Protocols":utf8, _rest:bits>> -> Ok(socket)
    _ -> Error(Protocol(resp))
  }
}
