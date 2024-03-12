import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/result

pub type Socket

pub type SocketReason

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
}

pub const default_options = [
  Receive(Once),
  PacketsOf(Binary),
  SendTimeout(30_000),
  SendTimeoutClose(True),
  Reuseaddr(True),
  Nodelay(True),
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
      rest -> dynamic.unsafe_coerce(dynamic.from(rest))
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
  Closed
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
  |> process.selecting_record2(SslClosed, fn(_socket) { Closed })
  |> process.selecting_record2(TcpClosed, fn(_socket) { Closed })
  |> process.selecting_record3(TcpError, fn(_sockets, reason) {
    Err(dynamic.unsafe_coerce(reason))
  })
  |> process.selecting_record3(SslError, fn(_socket, reason) {
    Err(dynamic.unsafe_coerce(reason))
  })
}

@external(erlang, "public_key", "cacerts_get")
pub fn get_certs() -> Dynamic
