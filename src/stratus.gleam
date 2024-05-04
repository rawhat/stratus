import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import gleam/crypto
import gleam/erlang.{rescue}
import gleam/erlang/charlist
import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/http.{Http, Https}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import gramps.{
  type DataFrame, BinaryFrame, CloseFrame, Continuation, Control,
  Data as DataFrame, PingFrame, PongFrame, TextFrame,
}
import logging
import stratus/internal/socket.{
  type Socket, type SocketMessage, type SocketReason, Cacerts, Once, Pull,
  Receive,
}
import stratus/internal/ssl
import stratus/internal/transport.{type Transport, Ssl, Tcp}

/// This holds some information needed to communicate with the WebSocket.
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

/// These are the messages emitted or received by the underlying process.  You
/// should only need to interact with `Message` below.
pub opaque type InternalMessage(user_message) {
  Started
  UserMessage(user_message)
  Err(SocketReason)
  Data(BitArray)
  Closed
  Shutdown
}

/// This is the type of message your handler might receive.
pub type Message(user_message) {
  Text(String)
  Binary(BitArray)
  User(user_message)
}

pub opaque type Builder(state, user_message) {
  Builder(
    request: Request(String),
    connect_timeout: Int,
    init: fn() -> #(state, Option(Selector(user_message))),
    loop: fn(Message(user_message), state, Connection) ->
      actor.Next(user_message, state),
    on_close: fn(state) -> Nil,
  )
}

//  and `on_close`.
/// This creates a builder to set up a WebSocket actor. This will use default
/// values for the connection initialization timeout, and provide an empty
/// function to be called when the server closes the connection. If you want to
/// customize either of those, see the helper functions `with_connect_timeout`
pub fn websocket(
  request req: Request(String),
  init init: fn() -> #(state, Option(Selector(user_message))),
  loop loop: fn(Message(user_message), state, Connection) ->
    actor.Next(user_message, state),
) -> Builder(state, user_message) {
  Builder(
    request: req,
    connect_timeout: 5000,
    init: init,
    loop: loop,
    on_close: fn(_state) { Nil },
  )
}

/// This sets the maximum amount of time you are willing to wait for both
/// connecting to the server and receiving the upgrade response.  This means
/// that it may take up to `timeout * 2` to begin sending or receiving messages.
/// This value defaults to 5 seconds.
pub fn with_connect_timeout(
  builder: Builder(state, user_message),
  timeout: Int,
) -> Builder(state, user_message) {
  Builder(..builder, connect_timeout: timeout)
}

/// You can provide a function to be called when the connection is closed. This
/// function receives the last value for the state of the WebSocket.
///
/// NOTE:  If you manually call `stratus.close`, this function will not be
/// called. I'm unsure right now if this is a bug or working as intended. But
/// you will be in the loop with the state value handy.
pub fn on_close(
  builder: Builder(state, user_message),
  on_close: fn(state) -> Nil,
) -> Builder(state, user_message) {
  Builder(..builder, on_close: on_close)
}

type State(state, user_message) {
  State(
    buffer: BitArray,
    incomplete: Option(gramps.Frame),
    self: Subject(InternalMessage(user_message)),
    socket: Option(Socket),
    user_state: state,
  )
}

/// This opens the WebSocket connection with the provided `Builder`. It makes
/// some assumptions about the request if you do not provide it.  It will use
/// ports 80 or 443 for `ws` or `wss` respectively.
///
/// It will open the connection and perform the WebSocket handshake. If this
/// fails, the actor will fail to start with the given reason as a string value.
///
/// After that, received messages will be passed to your loop, and you can use
/// the helper functions to send messages to the server. The `close` method will
/// send a close frame and end the connection.
pub fn initialize(
  builder: Builder(state, user_message),
) -> Result(Subject(InternalMessage(user_message)), actor.StartError) {
  let transport = case builder.request.scheme {
    Https -> Ssl
    _ -> Tcp
  }

  actor.start_spec(
    actor.Spec(
      init: fn() {
        let subj = process.new_subject()
        let started_selector =
          process.selecting(process.new_selector(), subj, function.identity)
        logging.log(logging.Debug, "Calling user initializer")
        let #(user_state, user_selector) = builder.init()
        let selector = case user_selector {
          Some(selector) -> {
            selector
            |> process.map_selector(UserMessage)
            |> process.merge_selector(started_selector)
            |> process.merge_selector(process.map_selector(
              socket.selector(),
              from_socket_message,
            ))
          }
          _ ->
            started_selector
            |> process.merge_selector(process.map_selector(
              socket.selector(),
              from_socket_message,
            ))
        }
        process.send(subj, Started)
        actor.Ready(
          State(
            buffer: <<>>,
            incomplete: None,
            self: subj,
            socket: None,
            user_state: user_state,
          ),
          selector,
        )
      },
      init_timeout: 1000,
      loop: fn(msg, state) {
        case msg {
          Started -> {
            logging.log(
              logging.Debug,
              "Attempting handshake to "
                <> uri.to_string(request.to_uri(builder.request)),
            )
            perform_handshake(
              builder.request,
              transport,
              builder.connect_timeout,
            )
            |> result.then(fn(pair) {
              logging.log(logging.Debug, "Handshake successful")
              transport.set_opts(
                transport,
                pair.0,
                socket.convert_options([Receive(Once)]),
              )
              |> result.replace(pair)
              |> result.map_error(Sock)
            })
            |> result.map(fn(pair) {
              let #(socket, buffer) = pair
              logging.log(
                logging.Debug,
                "WebSocket process ready to start receiving",
              )
              let _ = case buffer {
                <<>> -> Nil
                data -> process.send(state.self, Data(data))
              }
              actor.continue(
                State(..state, socket: Some(socket), buffer: buffer),
              )
            })
            |> result.map_error(fn(err) {
              let msg = "Failed to connect to server: " <> string.inspect(err)
              logging.log(logging.Error, msg)
              actor.Stop(process.Abnormal(msg))
            })
            |> result.unwrap_both
          }
          UserMessage(user_message) -> {
            let assert Some(socket) = state.socket
            let conn = Connection(socket, transport)
            let res =
              rescue(fn() {
                builder.loop(User(user_message), state.user_state, conn)
              })
            case res {
              // TODO:  de-dupe this
              Ok(actor.Continue(user_state, user_selector)) -> {
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
              Ok(actor.Stop(reason)) -> actor.Stop(reason)
              Error(reason) -> {
                logging.log(
                  logging.Error,
                  "Caught error in user handler: " <> string.inspect(reason),
                )
                actor.continue(state)
              }
            }
          }
          Err(reason) -> {
            actor.Stop(process.Abnormal(string.inspect(reason)))
          }
          Data(bits) -> {
            let assert Some(socket) = state.socket
            let conn = Connection(socket, transport)
            let #(frames, rest) =
              gramps.get_messages(bit_array.append(state.buffer, bits), [])
            let frames = gramps.aggregate_frames(frames, state.incomplete, [])
            case frames {
              Error(Nil) -> actor.continue(state)
              Ok(frames) -> {
                list.fold_until(frames, actor.continue(state), fn(acc, frame) {
                  let assert actor.Continue(prev_state, _selector) = acc
                  case
                    handle_frame(builder, transport, prev_state, conn, frame)
                  {
                    actor.Continue(..) as next -> list.Continue(next)
                    actor.Stop(..) as err -> list.Stop(err)
                  }
                })
              }
            }
            |> fn(next) {
              case next {
                actor.Stop(..) as stop -> stop
                actor.Continue(state, selector) -> {
                  let assert Ok(_) =
                    transport.set_opts(
                      transport,
                      socket,
                      socket.convert_options([Receive(Once)]),
                    )
                  actor.Continue(State(..state, buffer: rest), selector)
                }
              }
            }
          }
          Closed -> {
            logging.log(logging.Debug, "Received closed frame")
            builder.on_close(state.user_state)
            actor.Stop(process.Normal)
          }
          // TODO:  handle shutdown better?
          Shutdown -> {
            logging.log(logging.Debug, "Received shutdown messag")
            actor.Stop(process.Normal)
          }
        }
      },
    ),
  )
}

fn handle_frame(
  builder: Builder(user_state, user_message),
  transport: Transport,
  state: State(user_state, user_message),
  conn: Connection,
  frame: gramps.Frame,
) -> actor.Next(InternalMessage(user_message), State(user_state, user_message)) {
  let assert Some(socket) = state.socket
  case frame {
    DataFrame(TextFrame(payload: data, ..)) -> {
      let assert Ok(str) = bit_array.to_string(data)
      let res = rescue(fn() { builder.loop(Text(str), state.user_state, conn) })
      case res {
        // TODO:  de-dupe this
        Ok(actor.Continue(user_state, user_selector)) -> {
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
        Ok(actor.Stop(reason)) -> actor.Stop(reason)
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in user handler: " <> string.inspect(reason),
          )
          actor.continue(state)
        }
      }
    }
    DataFrame(BinaryFrame(payload: data, ..)) -> {
      let res =
        rescue(fn() { builder.loop(Binary(data), state.user_state, conn) })
      case res {
        // TODO:  de-dupe this
        Ok(actor.Continue(user_state, user_selector)) -> {
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
        Ok(actor.Stop(reason)) -> actor.Stop(reason)
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in user handler: " <> string.inspect(reason),
          )
          actor.continue(state)
        }
      }
    }
    Control(PingFrame(payload, payload_length)) -> {
      let frame =
        gramps.frame_to_bytes_builder(
          gramps.Control(gramps.PongFrame(payload, payload_length)),
          Some(<<0:unit(8)-size(4)>>),
        )
      let _ = transport.send(conn.transport, conn.socket, frame)
      actor.continue(state)
    }
    Control(PongFrame(..)) -> {
      actor.continue(state)
    }
    Control(CloseFrame(length, payload)) -> {
      let size = length - 2
      case payload {
        <<_reason:int-size(2)-unit(8), message:bytes-size(size)>> -> {
          let msg = "WebSocket closing: " <> string.inspect(message)
          logging.log(logging.Debug, msg)
        }
        _ -> Nil
      }
      builder.on_close(state.user_state)
      actor.Stop(process.Normal)
    }
    Continuation(..) -> {
      actor.continue(state)
    }
  }
}

/// Since the actor receives the raw data from the WebSocket, it needs a less
/// ergonomic message type. You probably don't want (read: shouldn't be able to)
/// send `Data(bits)` to the process, so that message type is opaque.
///
/// To get around that, this helper method lets you provide your custom message
/// type to the actor.
///
/// This is likely what you want if you want to be able to tell the actor to
/// send data to the server. Your message type would be -- in plain language --
/// "this thing happened", and your loop would then send whatever relevant data
/// corresponds to that event.
pub fn send_message(
  subject: Subject(InternalMessage(user_message)),
  message: user_message,
) -> Nil {
  process.send(subject, UserMessage(message))
}

/// From within the actor loop, this is how you send a WebSocket text frame.
/// This must be valid UTF-8, so it is a `String`.
pub fn send_text_message(
  conn: Connection,
  msg: String,
) -> Result(Nil, SocketReason) {
  let frame = gramps.to_text_frame(msg, True)
  transport.send(conn.transport, conn.socket, frame)
}

/// From within the actor loop, this is how you send a WebSocket text frame.
pub fn send_binary_message(
  conn: Connection,
  msg: BitArray,
) -> Result(Nil, SocketReason) {
  let frame = gramps.to_binary_frame(msg, True)
  transport.send(conn.transport, conn.socket, frame)
}

/// Send a ping frame with some data.
pub fn send_ping(conn: Connection, data: BitArray) -> Result(Nil, SocketReason) {
  let size = bit_array.byte_size(data)
  let mask = case size {
    0 -> <<0:size(4)>>
    _n -> crypto.strong_random_bytes(4)
  }
  let frame =
    gramps.frame_to_bytes_builder(
      gramps.Control(gramps.PingFrame(size, data)),
      Some(mask),
    )
  transport.send(conn.transport, conn.socket, frame)
}

/// This will close the WebSocket connection.
pub fn close(conn: Connection) -> Result(Nil, SocketReason) {
  let frame =
    gramps.frame_to_bytes_builder(
      gramps.Control(gramps.CloseFrame(0, <<>>)),
      Some(crypto.strong_random_bytes(4)),
    )
  transport.send(conn.transport, conn.socket, frame)
}

fn make_upgrade(req: Request(String), origin: String) -> BytesBuilder {
  let user_headers =
    req.headers
    |> list.filter(fn(pair) {
      let assert #(key, _value) = pair
      key != "host"
      && key != "upgrade"
      && key != "connection"
      && key != "sec-websocket-key"
      && key != "sec-websocket-version"
      && key != "origin"
    })
    |> list.map(fn(pair) {
      let assert #(key, value) = pair
      key <> ": " <> value
    })
    |> string.join("\r\n")

  let path = case req.path {
    "" -> "/"
    path -> path
  }

  let query =
    req
    |> request.get_query
    |> result.map(uri.query_to_string)
    |> fn(str) {
      case str {
        Ok("") -> ""
        Ok(str) -> "?" <> str
        _ -> ""
      }
    }

  bytes_builder.new()
  |> bytes_builder.append_string("GET " <> path <> query <> " HTTP/1.1\r\n")
  |> bytes_builder.append_string("Host: " <> req.host <> "\r\n")
  |> bytes_builder.append_string("Upgrade: websocket\r\n")
  |> bytes_builder.append_string("Connection: Upgrade\r\n")
  |> bytes_builder.append_string(
    "Sec-WebSocket-Key: " <> gramps.websocket_client_key <> "\r\n",
  )
  |> bytes_builder.append_string("Sec-WebSocket-Version: 13\r\n")
  |> bytes_builder.append_string("Origin: " <> origin <> "\r\n")
  |> bytes_builder.append_string(user_headers)
  |> bytes_builder.append_string("\r\n")
}

type HandshakeError {
  Sock(SocketReason)
  Protocol(BitArray)
}

fn perform_handshake(
  req: Request(String),
  transport: Transport,
  timeout: Int,
) -> Result(#(Socket, BitArray), HandshakeError) {
  let certs = case req.scheme {
    Https -> {
      let assert Ok(_ok) = ssl.start()
      [Cacerts(socket.get_certs()), socket.get_custom_matcher()]
    }
    Http -> []
  }

  let opts =
    socket.convert_options(
      list.append(socket.default_options, [Receive(Pull), ..certs]),
    )

  let port =
    option.lazy_unwrap(req.port, fn() {
      case transport {
        Ssl -> 443
        Tcp -> 80
      }
    })

  let origin = case req.scheme, port {
    Https, 443 -> "https://" <> req.host
    Http, 80 -> "http://" <> req.host
    Https, _ -> "https://" <> req.host <> ":" <> int.to_string(port)
    _, _ -> "http://" <> req.host <> ":" <> int.to_string(port)
  }

  logging.log(
    logging.Debug,
    "Making request to " <> req.host <> " at " <> int.to_string(port),
  )

  use socket <- result.try(result.map_error(
    transport.connect(
      transport,
      charlist.from_string(req.host),
      port,
      opts,
      timeout,
    ),
    Sock,
  ))

  use _nil <- result.try(result.map_error(
    transport.send(transport, socket, make_upgrade(req, origin)),
    Sock,
  ))

  logging.log(
    logging.Debug,
    "Sent upgrade request, waiting " <> int.to_string(timeout),
  )

  use resp <- result.try(result.map_error(
    transport.receive_timeout(transport, socket, 0, timeout),
    Sock,
  ))

  case gramps.read_response(resp) {
    Ok(#(_resp, rest)) -> {
      Ok(#(socket, rest))
    }
    Error(_reason) -> Error(Protocol(resp))
  }
}
