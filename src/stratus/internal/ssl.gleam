import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/charlist.{type Charlist}
import stratus/internal/socket.{
  type Shutdown, type Socket, type SocketReason, type TcpOption,
}

@external(erlang, "ssl", "connect")
pub fn connect(
  address: Charlist,
  port: Int,
  options: List(TcpOption),
  timeout: Int,
) -> Result(Socket, SocketReason)

@external(erlang, "stratus_ffi", "ssl_shutdown")
pub fn shutdown(socket: Socket, how: Shutdown) -> Result(Nil, SocketReason)

@external(erlang, "stratus_ffi", "ssl_send")
pub fn send(socket: Socket, packet: BytesTree) -> Result(Nil, SocketReason)

@external(erlang, "ssl", "recv")
pub fn receive(socket: Socket, length: Int) -> Result(BitArray, SocketReason)

@external(erlang, "ssl", "recv")
pub fn receive_timeout(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, SocketReason)

@external(erlang, "stratus_ffi", "ssl_set_opts")
pub fn set_opts(
  socket: Socket,
  opts: List(TcpOption),
) -> Result(Nil, SocketReason)

@external(erlang, "stratus_ffi", "ssl_start")
pub fn start() -> Result(Nil, Nil)
