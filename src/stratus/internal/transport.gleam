import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/charlist.{type Charlist}
import stratus/internal/socket.{
  type Shutdown, type Socket, type SocketReason, type TcpOption,
}
import stratus/internal/tcp
import stratus/internal/ssl

pub type Transport {
  Tcp
  Ssl
}

import gleam/io

pub fn connect(
  transport: Transport,
  host: Charlist,
  port: Int,
  options: List(TcpOption),
) -> Result(Socket, SocketReason) {
  case transport {
    Ssl -> ssl.connect(host, port, options)
    Tcp -> tcp.connect(host, port, options)
  }
}

pub fn send(
  transport: Transport,
  socket: Socket,
  data: BytesBuilder,
) -> Result(Nil, SocketReason) {
  case transport {
    Ssl -> ssl.send(socket, data)
    Tcp -> tcp.send(socket, data)
  }
}

pub fn receive(
  transport: Transport,
  socket: Socket,
  length: Int,
) -> Result(BitArray, SocketReason) {
  case transport {
    Ssl -> ssl.receive(socket, length)
    Tcp -> tcp.receive(socket, length)
  }
}

pub fn receive_timeout(
  transport: Transport,
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, SocketReason) {
  case transport {
    Ssl -> ssl.receive_timeout(socket, length, timeout)
    Tcp -> tcp.receive_timeout(socket, length, timeout)
  }
}

pub fn shutdown(
  transport: Transport,
  socket: Socket,
  how: Shutdown,
) -> Result(Nil, SocketReason) {
  case transport {
    Ssl -> ssl.shutdown(socket, how)
    Tcp -> tcp.shutdown(socket, how)
  }
}

pub fn set_opts(
  transport: Transport,
  socket: Socket,
  opts: List(TcpOption),
) -> Result(Nil, SocketReason) {
  case transport {
    Tcp -> tcp.set_opts(socket, opts)
    Ssl -> ssl.set_opts(socket, opts)
  }
}
