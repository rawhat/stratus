import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/string

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
  PacketsOf(Binary),
  SendTimeout(30_000),
  SendTimeoutClose(True),
  Reuseaddr(True),
  Nodelay(True),
]

@external(erlang, "gleam@function", "identity")
fn from(value: a) -> Dynamic

pub fn convert_options(options: List(Options)) -> List(TcpOption) {
  let active = atom.create("active")
  list.map(options, fn(opt) {
    case opt {
      Receive(Count(count)) -> #(active, dynamic.int(count))
      Receive(Once) -> #(active, from(atom.create("once")))
      Receive(Pull) -> #(active, dynamic.bool(False))
      Receive(All) -> #(active, dynamic.bool(True))
      PacketsOf(Binary) -> #(atom.create("mode"), from(Binary))
      PacketsOf(List) -> #(atom.create("mode"), from(List))
      Cacerts(data) -> #(atom.create("cacerts"), data)
      Nodelay(bool) -> #(atom.create("nodelay"), dynamic.bool(bool))
      Reuseaddr(bool) -> #(atom.create("reuseaddr"), dynamic.bool(bool))
      SendTimeout(int) -> #(atom.create("send_timeout"), dynamic.int(int))
      SendTimeoutClose(bool) -> #(
        atom.create("send_timeout_close"),
        dynamic.bool(bool),
      )
      CustomizeHostnameCheck(funcs) -> #(
        atom.create("customize_hostname_check"),
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

pub fn selector() -> Selector(Result(SocketMessage, List(decode.DecodeError))) {
  process.new_selector()
  |> process.select_record(Tcp, 2, fn(data) {
    {
      use msg <- decode.field(2, decode.bit_array)
      decode.success(Data(msg))
    }
    |> decode.run(data, _)
  })
  |> process.select_record(Ssl, 2, fn(data) {
    {
      use msg <- decode.field(2, decode.bit_array)
      decode.success(Data(msg))
    }
    |> decode.run(data, _)
  })
  |> process.select_record(SslClosed, 1, fn(_socket) { Ok(Err(Closed)) })
  |> process.select_record(TcpClosed, 1, fn(_socket) { Ok(Err(Closed)) })
  |> process.select_record(TcpError, 2, fn(data) {
    {
      use reason <- decode.field(2, decode.dynamic)
      decode.success(Err(Posix(string.inspect(reason))))
    }
    |> decode.run(data, _)
  })
  |> process.select_record(SslError, 2, fn(data) {
    {
      use reason <- decode.field(2, decode.dynamic)
      decode.success(Err(Posix(string.inspect(reason))))
    }
    |> decode.run(data, _)
  })
}

@external(erlang, "public_key", "cacerts_get")
pub fn get_certs() -> Dynamic

@external(erlang, "stratus_ffi", "custom_sni_matcher")
pub fn get_custom_matcher() -> Options
