import exception
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/crypto
import gleam/erlang/charlist
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http.{Http, Https}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import gramps/http as gramps_http
import gramps/websocket.{
  BinaryFrame, CloseFrame, Continuation, Control, Data as DataFrame, PingFrame,
  PongFrame, TextFrame,
}
import gramps/websocket/compression
import logging
import stratus/internal/socket.{
  type Socket, type SocketMessage, Cacerts, Once, Pull, Receive,
}
import stratus/internal/ssl
import stratus/internal/tcp
import stratus/internal/transport.{type Transport, Ssl, Tcp}

/// This holds some information needed to communicate with the WebSocket.
pub opaque type Connection {
  Connection(
    socket: Socket,
    transport: Transport,
    context: Option(compression.Context),
  )
}

pub type SocketReason {
  SocketClosed
  Timeout
  Badarg
  Terminated
  Eaddrinuse
  Eaddrnotavail
  Eafnosupport
  Ealready
  Econnaborted
  Econnrefused
  Econnreset
  Edestaddrreq
  Ehostdown
  Ehostunreach
  Einprogress
  Eisconn
  Emsgsize
  Enetdown
  Enetunreach
  Enopkg
  Enoprotoopt
  Enotconn
  Enotty
  Enotsock
  Eproto
  Eprotonosupport
  Eprototype
  Esocktnosupport
  Etimedout
  Ewouldblock
  Exbadport
  Exbadseq
}

pub type CustomCloseError {
  SocketFail(SocketReason)
  InvalidCode
}

fn convert_socket_reason(reason: socket.SocketReason) -> SocketReason {
  case reason {
    socket.Badarg -> Badarg
    socket.Closed -> SocketClosed
    socket.Eaddrinuse -> Eaddrinuse
    socket.Eaddrnotavail -> Eaddrnotavail
    socket.Eafnosupport -> Eafnosupport
    socket.Ealready -> Ealready
    socket.Econnaborted -> Econnaborted
    socket.Econnrefused -> Econnrefused
    socket.Econnreset -> Econnreset
    socket.Edestaddrreq -> Edestaddrreq
    socket.Ehostdown -> Ehostdown
    socket.Ehostunreach -> Ehostunreach
    socket.Einprogress -> Einprogress
    socket.Eisconn -> Eisconn
    socket.Emsgsize -> Emsgsize
    socket.Enetdown -> Enetdown
    socket.Enetunreach -> Enetunreach
    socket.Enopkg -> Enopkg
    socket.Enoprotoopt -> Enoprotoopt
    socket.Enotconn -> Enotconn
    socket.Enotsock -> Enotsock
    socket.Enotty -> Enotty
    socket.Eproto -> Eproto
    socket.Eprotonosupport -> Eprotonosupport
    socket.Eprototype -> Eprototype
    socket.Esocktnosupport -> Esocktnosupport
    socket.Etimedout -> Etimedout
    socket.Ewouldblock -> Ewouldblock
    socket.Exbadport -> Exbadport
    socket.Exbadseq -> Exbadseq
    socket.Terminated -> Terminated
    socket.Timeout -> Timeout
  }
}

fn from_socket_message(msg: SocketMessage) -> InternalMessage(user_message) {
  case msg {
    socket.Data(bits) -> Data(bits)
    socket.Err(reason) -> Err(convert_socket_reason(reason))
  }
}

pub opaque type Next(state, user_message) {
  Continue(state: state, selector: Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: state) -> Next(state, user_message) {
  Continue(state, None)
}

pub fn with_selector(
  next: Next(state, user_message),
  selector: Selector(user_message),
) -> Next(state, user_message) {
  case next {
    Continue(state, _) -> Continue(state, Some(selector))
    _ -> next
  }
}

pub fn stop() -> Next(state, user_message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(state, user_message) {
  AbnormalStop(reason)
}

/// These are the messages emitted or received by the underlying process.  You
/// should only need to interact with `Message` below.
pub opaque type InternalMessage(user_message) {
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
    init: fn() -> Result(Initialised(state, user_message), String),
    loop: fn(state, Message(user_message), Connection) ->
      Next(state, user_message),
    on_close: fn(state) -> Nil,
  )
}

//  and `on_close`.
/// This creates a builder to set up a WebSocket actor. This will use default
/// values for the connection initialization timeout, and provide an empty
/// function to be called when the server closes the connection. If you want to
/// customize either of those, see the helper functions `with_connect_timeout`
pub fn new(
  request req: Request(String),
  state state: state,
) -> Builder(state, user_message) {
  Builder(
    request: req,
    connect_timeout: 5000,
    init: fn() { Ok(initialised(state)) },
    loop: fn(state, _msg, _conn) { continue(state) },
    on_close: fn(_state) { Nil },
  )
}

pub type Initialised(state, user_message) {
  Initialised(state: state, selector: Option(Selector(user_message)))
}

pub fn initialised(state: state) -> Initialised(state, user_message) {
  Initialised(state:, selector: None)
}

pub fn selecting(
  initialised: Initialised(state, old_message),
  selector: Selector(user_message),
) -> Initialised(state, user_message) {
  Initialised(state: initialised.state, selector: Some(selector))
}

pub fn new_with_initialiser(
  request req: Request(String),
  init init: fn() -> Result(Initialised(state, user_message), String),
) -> Builder(state, user_message) {
  Builder(
    request: req,
    connect_timeout: 5000,
    init: init,
    loop: fn(state, _msg, _conn) { continue(state) },
    on_close: fn(_state) { Nil },
  )
}

pub fn on_message(
  builder: Builder(state, user_message),
  on_message: fn(state, Message(user_message), Connection) ->
    Next(state, user_message),
) -> Builder(state, user_message) {
  Builder(..builder, loop: on_message)
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
    incomplete: Option(websocket.Frame),
    self: Subject(InternalMessage(user_message)),
    socket: Socket,
    user_state: state,
    compression: Option(compression.Compression),
  )
}

/// These are the possible failures when calling `stratus.initialize`.
pub type InitializationError {
  // The WebSocket handshake failed for the provided reason
  HandshakeFailed(HandshakeError)
  // The actor failed to start, most likely due to a timeout in your `init`
  ActorFailed(actor.StartError)
  //
  FailedToTransferSocket(SocketReason)
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
pub fn start(
  builder: Builder(state, user_message),
) -> Result(
  actor.Started(Subject(InternalMessage(user_message))),
  InitializationError,
) {
  let transport = case builder.request.scheme {
    Https -> Ssl
    _ -> Tcp
  }

  let handshake_result =
    perform_handshake(builder.request, transport, builder.connect_timeout)
    |> result.map_error(fn(reason) {
      let msg = case reason {
        UpgradeFailed(resp) ->
          "WebSocket handshake failed with status "
          <> int.to_string(resp.status)
        reason -> "WebSocket handshake failed: " <> string.inspect(reason)
      }
      logging.log(logging.Error, msg)
      HandshakeFailed(reason)
    })

  use handshake_response <- result.try(handshake_result)
  logging.log(logging.Debug, "Handshake successful")

  let extensions =
    handshake_response.response
    |> response.get_header("sec-websocket-extensions")
    |> result.map(string.split(_, "; "))
    |> result.unwrap([])

  let context_takeovers = websocket.get_context_takeovers(extensions)

  let assert Ok(_) =
    transport.set_opts(
      transport,
      handshake_response.socket,
      socket.convert_options([Receive(Once)]),
    )

  actor.new_with_initialiser(1000, fn(subject) {
    let started_selector = process.select(process.new_selector(), subject)
    logging.log(logging.Debug, "Calling user initializer")
    use Initialised(user_state, user_selector) <- result.try(builder.init())
    let selector = case user_selector {
      Some(selector) -> {
        selector
        |> process.map_selector(UserMessage)
        |> process.merge_selector(started_selector)
        |> process.merge_selector(
          process.map_selector(socket.selector(), fn(msg) {
            let assert Ok(msg) = msg
            from_socket_message(msg)
          }),
        )
      }
      _ ->
        started_selector
        |> process.merge_selector(
          process.map_selector(socket.selector(), fn(msg) {
            let assert Ok(msg) = msg
            from_socket_message(msg)
          }),
        )
    }
    let context = case websocket.has_deflate(extensions) {
      True -> Some(compression.init(context_takeovers))
      False -> None
    }
    State(
      buffer: <<>>,
      incomplete: None,
      self: subject,
      socket: handshake_response.socket,
      user_state: user_state,
      compression: context,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case message {
      UserMessage(user_message) -> {
        let conn =
          Connection(
            state.socket,
            transport,
            option.map(state.compression, fn(context) { context.deflate }),
          )
        let res =
          exception.rescue(fn() {
            builder.loop(state.user_state, User(user_message), conn)
          })
        case res {
          // TODO:  de-dupe this
          Ok(Continue(user_state, user_selector)) -> {
            let new_state = State(..state, user_state: user_state)
            case user_selector {
              Some(user_selector) -> {
                let selector =
                  user_selector
                  |> process.map_selector(UserMessage)
                  |> process.merge_selector(
                    process.map_selector(socket.selector(), fn(msg) {
                      let assert Ok(msg) = msg
                      from_socket_message(msg)
                    }),
                  )
                new_state
                |> actor.continue
                |> actor.with_selector(selector)
              }
              _ -> actor.continue(new_state)
            }
          }
          Ok(NormalStop) -> actor.stop()
          Ok(AbnormalStop(reason)) -> actor.stop_abnormal(reason)
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
        close_contexts(state.compression)
        actor.stop_abnormal(string.inspect(reason))
      }
      Data(bits) -> {
        let conn =
          Connection(
            state.socket,
            transport,
            option.map(state.compression, fn(context) { context.deflate }),
          )
        let #(frames, rest) =
          websocket.decode_many_frames(
            bit_array.append(state.buffer, bits),
            option.map(state.compression, fn(context) { context.inflate }),
            [],
          )
        let frames = websocket.aggregate_frames(frames, state.incomplete, [])
        case frames {
          Error(Nil) -> continue(state)
          Ok(frames) -> {
            list.fold_until(frames, continue(state), fn(acc, frame) {
              let assert Continue(prev_state, _selector) = acc
              case handle_frame(builder, prev_state, conn, frame) {
                Continue(..) as next -> list.Continue(next)
                err -> list.Stop(err)
              }
            })
          }
        }
        |> fn(next) {
          case next {
            Continue(state, selector) -> {
              let assert Ok(_) =
                transport.set_opts(
                  transport,
                  state.socket,
                  socket.convert_options([Receive(Once)]),
                )
              let next = actor.continue(State(..state, buffer: rest))
              case selector {
                Some(selector) -> actor.with_selector(next, selector)
                _ -> next
              }
            }
            NormalStop -> {
              close_contexts(state.compression)
              actor.stop()
            }
            AbnormalStop(reason) -> {
              close_contexts(state.compression)
              actor.stop_abnormal(reason)
            }
          }
        }
      }
      Closed -> {
        logging.log(logging.Debug, "Received closed frame")
        builder.on_close(state.user_state)
        close_contexts(state.compression)
        actor.stop()
      }
      // TODO:  handle shutdown better?
      Shutdown -> {
        logging.log(logging.Debug, "Received shutdown messag")
        close_contexts(state.compression)
        actor.stop()
      }
    }
  })
  |> actor.start
  |> result.map_error(ActorFailed)
  |> result.try(fn(started) {
    case transport {
      Tcp -> tcp.controlling_process(handshake_response.socket, started.pid)
      Ssl -> ssl.controlling_process(handshake_response.socket, started.pid)
    }
    |> result.map_error(fn(socket_reason) {
      FailedToTransferSocket(convert_socket_reason(socket_reason))
    })
    |> result.map(fn(_nil) { started })
  })
  |> result.map(fn(started) {
    let _ = case handshake_response.buffer {
      <<>> -> Nil
      data -> process.send(started.data, Data(data))
    }
    started
  })
}

fn handle_frame(
  builder: Builder(user_state, user_message),
  state: State(user_state, user_message),
  conn: Connection,
  frame: websocket.Frame,
) -> Next(State(user_state, user_message), InternalMessage(user_message)) {
  case frame {
    DataFrame(TextFrame(payload: data)) -> {
      let assert Ok(str) = bit_array.to_string(data)
      let res =
        exception.rescue(fn() {
          builder.loop(state.user_state, Text(str), conn)
        })
      case res {
        // TODO:  de-dupe this
        Ok(Continue(user_state, user_selector)) -> {
          let new_state = State(..state, user_state: user_state)
          case user_selector {
            Some(user_selector) -> {
              let selector =
                user_selector
                |> process.map_selector(UserMessage)
                |> process.merge_selector(
                  process.map_selector(socket.selector(), fn(msg) {
                    let assert Ok(msg) = msg
                    from_socket_message(msg)
                  }),
                )
              Continue(new_state, Some(selector))
            }
            _ -> continue(new_state)
          }
        }
        Ok(NormalStop) -> NormalStop
        Ok(AbnormalStop(reason)) -> AbnormalStop(reason)
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in user handler: " <> string.inspect(reason),
          )
          continue(state)
        }
      }
    }
    DataFrame(BinaryFrame(payload: data)) -> {
      let res =
        exception.rescue(fn() {
          builder.loop(state.user_state, Binary(data), conn)
        })
      case res {
        // TODO:  de-dupe this
        Ok(Continue(user_state, user_selector)) -> {
          let new_state = State(..state, user_state: user_state)
          case user_selector {
            Some(user_selector) -> {
              let selector =
                user_selector
                |> process.map_selector(UserMessage)
                |> process.merge_selector(
                  process.map_selector(socket.selector(), fn(msg) {
                    let assert Ok(msg) = msg
                    from_socket_message(msg)
                  }),
                )
              Continue(new_state, Some(selector))
            }
            _ -> continue(new_state)
          }
        }
        Ok(NormalStop) -> NormalStop
        Ok(AbnormalStop(reason)) -> AbnormalStop(reason)
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in user handler: " <> string.inspect(reason),
          )
          continue(state)
        }
      }
    }
    Control(PingFrame(payload)) -> {
      let mask = Some(<<0:unit(8)-size(4)>>)
      let frame = websocket.encode_pong_frame(payload, mask)

      let _ = transport.send(conn.transport, conn.socket, frame)
      continue(state)
    }
    Control(PongFrame(..)) -> {
      continue(state)
    }
    Control(CloseFrame(reason)) -> {
      logging.log(
        logging.Debug,
        "WebSocket closing: " <> string.inspect(reason),
      )
      builder.on_close(state.user_state)
      NormalStop
    }
    Continuation(..) -> {
      continue(state)
    }
  }
}

/// The `Subject` returned from `initialize` is an opaque type.  In order to
/// send custom messages to your process, you can do this mapping.
///
/// For example:
/// ```gleam
///   // using `process.send`
///   MyMessage(some_data)
///   |> stratus.to_user_message
///   |> process.send(stratus_subject, _)
///   // using `process.call`
///   process.call(stratus_subject, fn(subj) {
///     stratus.to_user_message(MyMessage(some_data, subj))
///   })
/// ```
pub fn to_user_message(
  user_message: user_message,
) -> InternalMessage(user_message) {
  UserMessage(user_message)
}

/// From within the actor loop, this is how you send a WebSocket text frame.
/// This must be valid UTF-8, so it is a `String`.
pub fn send_text_message(
  conn: Connection,
  msg: String,
) -> Result(Nil, SocketReason) {
  let frame =
    websocket.encode_text_frame(
      msg,
      conn.context,
      Some(crypto.strong_random_bytes(4)),
    )
  transport.send(conn.transport, conn.socket, frame)
  |> result.map_error(convert_socket_reason)
}

/// From within the actor loop, this is how you send a WebSocket text frame.
pub fn send_binary_message(
  conn: Connection,
  msg: BitArray,
) -> Result(Nil, SocketReason) {
  let frame =
    websocket.encode_binary_frame(
      msg,
      conn.context,
      Some(crypto.strong_random_bytes(4)),
    )
  transport.send(conn.transport, conn.socket, frame)
  |> result.map_error(convert_socket_reason)
}

/// Send a ping frame with some data.
pub fn send_ping(conn: Connection, data: BitArray) -> Result(Nil, SocketReason) {
  let size = bit_array.byte_size(data)
  let mask = case size {
    0 -> Some(<<0:size(4)>>)
    _n -> Some(crypto.strong_random_bytes(4))
  }
  let frame = websocket.encode_ping_frame(data, mask)
  transport.send(conn.transport, conn.socket, frame)
  |> result.map_error(convert_socket_reason)
}

pub opaque type CloseReason {
  NotProvided
  Normal(body: BitArray)
  GoingAway(body: BitArray)
  ProtocolError(body: BitArray)
  UnexpectedDataType(body: BitArray)
  InconsistentDataType(body: BitArray)
  PolicyViolation(body: BitArray)
  MessageTooBig(body: BitArray)
  MissingExtensions(body: BitArray)
  UnexpectedCondition(body: BitArray)
  CustomCloseReason(code: Int, body: BitArray)
}

fn convert_close_reason(reason: CloseReason) -> websocket.CloseReason {
  case reason {
    NotProvided -> websocket.NotProvided
    GoingAway(body:) -> websocket.GoingAway(body:)
    InconsistentDataType(body:) -> websocket.InconsistentDataType(body:)
    MessageTooBig(body:) -> websocket.MessageTooBig(body:)
    MissingExtensions(body:) -> websocket.MissingExtensions(body:)
    Normal(body:) -> websocket.Normal(body:)
    PolicyViolation(body:) -> websocket.PolicyViolation(body:)
    ProtocolError(body:) -> websocket.ProtocolError(body:)
    UnexpectedCondition(body:) -> websocket.UnexpectedCondition(body:)
    UnexpectedDataType(body:) -> websocket.UnexpectedDataType(body:)
    CustomCloseReason(code:, body:) -> websocket.CustomCloseReason(code:, body:)
  }
}

/// Closes without a reason.
pub fn close(conn: Connection) {
  close_with_reason(conn, NotProvided)
}

/// Status code: 1000
pub fn close_normal(conn: Connection, body: BitArray) {
  close_with_reason(conn, Normal(body:))
}

/// Status code: 1001
pub fn close_going_away(conn: Connection, body: BitArray) {
  close_with_reason(conn, GoingAway(body:))
}

/// Status code: 1002
pub fn close_protocol_error(conn: Connection, body: BitArray) {
  close_with_reason(conn, ProtocolError(body:))
}

/// Status code: 1003
pub fn close_unexpected_data_type(conn: Connection, body: BitArray) {
  close_with_reason(conn, UnexpectedDataType(body:))
}

/// Status code: 1007
pub fn close_inconsistent_data_type(conn: Connection, body: BitArray) {
  close_with_reason(conn, InconsistentDataType(body:))
}

/// Status code: 1008
pub fn close_policy_violation(conn: Connection, body: BitArray) {
  close_with_reason(conn, PolicyViolation(body:))
}

/// Status code: 1009
pub fn close_message_too_big(conn: Connection, body: BitArray) {
  close_with_reason(conn, MessageTooBig(body:))
}

/// Status code: 1010
pub fn close_missing_extensions(conn: Connection, body: BitArray) {
  close_with_reason(conn, MissingExtensions(body:))
}

/// Status code: 1011
pub fn close_unexpected_condition(conn: Connection, body: BitArray) {
  close_with_reason(conn, UnexpectedCondition(body:))
}

/// Accepts codes from 0 to 4999.
pub fn close_custom(
  conn: Connection,
  code: Int,
  body: BitArray,
) -> Result(Nil, CustomCloseError) {
  use <- bool.guard(when: code >= 5000, return: Error(InvalidCode))

  close_with_reason(conn, CustomCloseReason(code:, body:))
  |> result.map_error(SocketFail)
}

fn close_with_reason(
  conn: Connection,
  reason: CloseReason,
) -> Result(Nil, SocketReason) {
  let reason = convert_close_reason(reason)
  let mask = crypto.strong_random_bytes(4)
  let frame = websocket.encode_close_frame(reason, Some(mask))

  transport.send(conn.transport, conn.socket, frame)
  |> result.map_error(convert_socket_reason)
}

fn make_upgrade(req: Request(String)) -> BytesTree {
  let user_headers = case req.headers {
    [] -> ""
    _ ->
      req.headers
      |> list.filter(fn(pair) {
        let #(key, _value) = pair
        key != "host"
        && key != "upgrade"
        && key != "connection"
        && key != "sec-websocket-key"
        && key != "sec-websocket-version"
      })
      |> list.map(fn(pair) {
        let #(key, value) = pair
        key <> ": " <> value
      })
      |> string.join("\r\n")
      |> string.append("\r\n")
  }

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

  let port =
    req.port
    |> option.map(fn(port) { ":" <> int.to_string(port) })
    |> option.unwrap("")

  bytes_tree.new()
  |> bytes_tree.append_string("GET " <> path <> query <> " HTTP/1.1\r\n")
  |> bytes_tree.append_string("host: " <> req.host <> port <> "\r\n")
  |> bytes_tree.append_string("upgrade: websocket\r\n")
  |> bytes_tree.append_string("connection: upgrade\r\n")
  |> bytes_tree.append_string(
    "sec-websocket-key: " <> websocket.make_client_key() <> "\r\n",
  )
  |> bytes_tree.append_string("sec-websocket-version: 13\r\n")
  |> bytes_tree.append_string(
    "sec-websocket-extensions: permessage-deflate\r\n",
  )
  |> bytes_tree.append_string(user_headers)
  |> bytes_tree.append_string("\r\n")
}

pub type HandshakeError {
  Sock(SocketReason)
  Protocol(BitArray)
  UpgradeFailed(Response(BitArray))
}

type HandshakeResponse {
  HandshakeResponse(
    socket: Socket,
    response: Response(BitArray),
    buffer: BitArray,
  )
}

fn perform_handshake(
  req: Request(String),
  transport: Transport,
  timeout: Int,
) -> Result(HandshakeResponse, HandshakeError) {
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

  logging.log(
    logging.Debug,
    "Making request to " <> req.host <> " at " <> int.to_string(port),
  )

  use socket <- result.try(
    result.map_error(
      transport.connect(
        transport,
        charlist.from_string(req.host),
        port,
        opts,
        timeout,
      ),
      fn(err) { Sock(convert_socket_reason(err)) },
    ),
  )

  let upgrade_req = make_upgrade(req)

  use _nil <- result.try(
    result.map_error(transport.send(transport, socket, upgrade_req), fn(err) {
      Sock(convert_socket_reason(err))
    }),
  )

  logging.log(
    logging.Debug,
    "Sent upgrade request, waiting " <> int.to_string(timeout),
  )

  use resp <- result.try(
    result.map_error(
      transport.receive_timeout(transport, socket, 0, timeout),
      fn(err) { Sock(convert_socket_reason(err)) },
    ),
  )

  resp
  |> gramps_http.read_response
  |> result.map_error(fn(_err) { Protocol(resp) })
  |> result.try(fn(pair) {
    let #(resp, body) = pair
    let body_size =
      resp.headers
      |> list.key_find("content-length")
      |> result.try(int.parse)
      |> result.unwrap(0)
    case read_body(transport, socket, timeout, body_size, body) {
      Ok(#(body, rest)) -> {
        Ok(#(response.set_body(resp, body), rest))
      }
      Error(reason) -> Error(Sock(reason))
    }
  })
  |> result.try(fn(pair) {
    let #(resp, buffer) = pair
    case resp.status {
      101 -> Ok(HandshakeResponse(socket:, response: resp, buffer:))
      _ -> Error(UpgradeFailed(resp))
    }
  })
}

fn read_body(
  transport: Transport,
  socket: Socket,
  timeout: Int,
  length: Int,
  body: BitArray,
) -> Result(#(BitArray, BitArray), SocketReason) {
  case body {
    <<data:bytes-size(length), rest:bits>> -> Ok(#(data, rest))
    _ -> {
      case transport.receive_timeout(transport, socket, 0, timeout) {
        Ok(data) -> {
          read_body(transport, socket, timeout, length, <<body:bits, data:bits>>)
        }
        Error(reason) -> Error(convert_socket_reason(reason))
      }
    }
  }
}

fn close_contexts(contexts: Option(compression.Compression)) -> Nil {
  case contexts {
    Some(compression) -> {
      compression.close(compression.deflate)
      compression.close(compression.inflate)
      Nil
    }
    _ -> Nil
  }
}
