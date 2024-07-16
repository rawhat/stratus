import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/result

pub type Socket

pub type SocketReason {
  Closed
  NotOwner
  Badarg
  Posix(String)
}

pub type TcpOption =
  #(Atom, Dynamic)

pub type ReceiveMode {
  Count(Int)
  Once
  Pull
  All
}

pub type PacketType {
  Binary
  List
}

pub type Options {
  Receive(ReceiveMode)
  PacketsOf(PacketType)
  SendTimeout(Int)
  SendTimeoutClose(Bool)
  Reuseaddr(Bool)
  Nodelay(Bool)
  Cacerts(Dynamic)
  CustomizeHostnameCheck(Dynamic)
}

pub const default_options = [
  PacketsOf(Binary), SendTimeout(30_000), SendTimeoutClose(True),
  Reuseaddr(True), Nodelay(True),
]

pub fn convert_options(options: List(Options)) -> List(TcpOption) {
  let active = atom.create_from_string("active")
  list.map(options, fn(opt) {
    case opt {
      Receive(Count(count)) -> #(active, dynamic.from(count))
      Receive(Once) -> #(active, dynamic.from(atom.create_from_string("once")))
      Receive(Pull) -> #(active, dynamic.from(False))
      Receive(All) -> #(active, dynamic.from(True))
      PacketsOf(Binary) -> #(
        atom.create_from_string("mode"),
        dynamic.from(Binary),
      )
      PacketsOf(List) -> #(atom.create_from_string("mode"), dynamic.from(List))
      Cacerts(data) -> #(atom.create_from_string("cacerts"), data)
      Nodelay(bool) -> #(atom.create_from_string("nodelay"), dynamic.from(bool))
      Reuseaddr(bool) -> #(
        atom.create_from_string("reuseaddr"),
        dynamic.from(bool),
      )
      SendTimeout(int) -> #(
        atom.create_from_string("send_timeout"),
        dynamic.from(int),
      )
      SendTimeoutClose(bool) -> #(
        atom.create_from_string("send_timeout_close"),
        dynamic.from(bool),
      )
      CustomizeHostnameCheck(funcs) -> #(
        atom.create_from_string("customize_hostname_check"),
        funcs,
      )
    }
  })
}

pub type Shutdown {
  Read
  Write
  ReadWrite
}

pub type SocketMessage {
  Data(BitArray)
  Err(SocketReason)
}

type ErlangSocketMessage {
  Ssl
  SslClosed
  SslError
  Tcp
  TcpClosed
  TcpError
}

fn decode_socket_error(
  dyn: Dynamic,
) -> Result(SocketReason, List(dynamic.DecodeError)) {
  dyn
  |> atom.from_dynamic
  |> result.map(atom.to_string)
  |> result.map(fn(atom) {
    case atom {
      "closed" -> Closed
      "not_owner" -> NotOwner
      "badarg" -> Badarg
      posix -> Posix(posix)
    }
  })
}

pub fn selector() -> Selector(SocketMessage) {
  process.new_selector()
  |> process.selecting_record3(Tcp, fn(_socket, msg) {
    let assert Ok(msg) =
      dynamic.bit_array(msg)
      |> result.map(Data)
    msg
  })
  |> process.selecting_record3(Ssl, fn(_socket, msg) {
    let assert Ok(msg) =
      dynamic.bit_array(msg)
      |> result.map(Data)
    msg
  })
  |> process.selecting_record2(SslClosed, fn(_socket) { Err(Closed) })
  |> process.selecting_record2(TcpClosed, fn(_socket) { Err(Closed) })
  |> process.selecting_record3(TcpError, fn(_sockets, reason) {
    let assert Ok(err) = decode_socket_error(reason)
    Err(err)
  })
  |> process.selecting_record3(SslError, fn(_socket, reason) {
    let assert Ok(err) = decode_socket_error(reason)
    Err(err)
  })
}

@external(erlang, "public_key", "cacerts_get")
pub fn get_certs() -> Dynamic

@external(erlang, "stratus_ffi", "custom_sni_matcher")
pub fn get_custom_matcher() -> Options
