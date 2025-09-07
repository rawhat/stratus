-module(stratus_ffi).

-export([tcp_shutdown/2, tcp_send/2, ssl_shutdown/2, ssl_send/2, tcp_set_opts/2,
         ssl_set_opts/2, ssl_start/0, custom_sni_matcher/0,
         ssl_controlling_process/2, tcp_controlling_process/2,
         parse_known_socket_reason/1 ]).

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

ssl_start() ->
  case ssl:start() of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

% Thank you!  https://github.com/erlang/otp/issues/4321
custom_sni_matcher() ->
  {customize_hostname_check,
   [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}.

ssl_controlling_process(Socket, NewOwner) ->
  case ssl:controlling_process(Socket, NewOwner) of
    ok -> {ok, nil};
    Error -> Error
  end.

tcp_controlling_process(Socket, NewOwner) ->
  case gen_tcp:controlling_process(Socket, NewOwner) of
    ok -> {ok, nil};
    Error -> Error
  end.

parse_known_socket_reason(Reason) ->
  case Reason of
    closed -> {ok, closed};
    timeout -> {ok, timeout};
    badarg -> {ok, badarg};
    terminated -> {ok, terminated};
    eaddrinuse -> {ok, eaddrinuse};
    eaddrnotavail -> {ok, eaddrnotavail};
    eafnosupport -> {ok, eafnosupport};
    ealready -> {ok, ealready};
    econnaborted -> {ok, econnaborted};
    econnrefused -> {ok, econnrefused};
    econnreset -> {ok, econnreset};
    edestaddrreq -> {ok, edestaddrreq};
    ehostdown -> {ok, ehostdown};
    ehostunreach -> {ok, ehostunreach};
    einprogress -> {ok, einprogress};
    eisconn -> {ok, eisconn};
    emsgsize -> {ok, emsgsize};
    enetdown -> {ok, enetdown};
    enetunreach -> {ok, enetunreach};
    enopkg -> {ok, enopkg};
    enoprotoopt -> {ok, enoprotoopt};
    enotconn -> {ok, enotconn};
    enotty -> {ok, enotty};
    enotsock -> {ok, enotsock};
    eproto -> {ok, eproto};
    eprotonosupport -> {ok, eprotonosupport};
    eprototype -> {ok, eprototype};
    esocktnosupport -> {ok, esocktnosupport};
    etimedout -> {ok, etimedout};
    ewouldblock -> {ok, ewouldblock};
    exbadport -> {ok, exbadport};
    exbadseq -> {ok, exbadseq};
    Unknown -> {error, Unknown}
  end.
