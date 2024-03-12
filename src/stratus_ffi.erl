-module(stratus_ffi).

-export([tcp_shutdown/2, tcp_send/2, ssl_shutdown/2, ssl_send/2, tcp_set_opts/2,
         ssl_set_opts/2]).

tcp_shutdown(Socket, How) ->
  case gen_tcp:shutdown(Socket, How) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

tcp_send(Socket, Packet) ->
  case gen_tcp:send(Socket, Packet) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

ssl_shutdown(Socket, How) ->
  case ssl:shutdown(Socket, How) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

ssl_send(Socket, Packet) ->
  case ssl:send(Socket, Packet) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

tcp_set_opts(Socket, Opts) ->
  case inet:setopts(Socket, Opts) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

ssl_set_opts(Socket, Opts) ->
  case ssl:setopts(Socket, Opts) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.
