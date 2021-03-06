%%%-------------------------------------------------------------------
%%% File    : yaws_revproxy.erl
%%% Author  :  <klacke@hyber.org>
%%% Description : reverse proxy
%%%
%%% Created :  3 Dec 2003 by  <klacke@hyber.org>
%%%-------------------------------------------------------------------
-module(yaws_revproxy).

-include("../include/yaws.hrl").
-include("../include/yaws_api.hrl").
-include("yaws_debug.hrl").
-export([out/1]).


%% reverse proxy implementation.

%% the revproxy internal state
-record(revproxy, {srvsock,         %% the socket opened on the backend server
                   type,            %% the socket type: ssl | nossl

                   cliconn_status,  %% "Connection:" header value:
                   srvconn_status,  %%   "keep-alive' or "close"

                   state,           %% revproxy state:
                                    %%   sendheaders | sendcontent | sendchunk |
                                    %%   recvheaders | recvcontent | recvchunk |
                                    %%   terminate
                   prefix,          %% The prefix to strip and add
                   url,             %% the url we're proxying to
                   r_meth,          %% what req method are we processing
                   r_host,          %%   and value of Host: for the cli request

                   resp,            %% response reveiced from the server
                   headers,         %%   and associated headers
                   srvdata,         %% the server data
                   is_chunked}).    %% true is the response is chunked


%% TODO: Activate proxy keep-alive with a new option ?
-define(proxy_keepalive, false).


%% Initialize the connection to the backend server. If an error occured, return
%% an error 404.
out(Arg = #arg{req=Req, headers=Hdrs, state={Prefix,URL}}) ->
    case connect(URL) of
        {ok, Sock, Type} ->
            ?Debug("Connection established on ~p: Socket=~p, Type=~p~n",
                   [URL, Sock, Type]),
            RPState = #revproxy{srvsock= Sock,
                                type   = Type,
                                state  = sendheaders,
                                prefix = Prefix,
                                url    = URL,
                                r_meth = Req#http_request.method,
                                r_host = Hdrs#headers.host},
            out(Arg#arg{state=RPState});
        _ERR ->
            ?Debug("Connection failed: ~p~n", [_ERR]),
            out404(Arg)
    end;


%% Send the client request to the server then check if the request content is
%% chunked or not
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == sendheaders ->
    ?Debug("Send request headers to backend server: ~n"
           " - ~s~n", [?format_record(Arg#arg.req, http_request)]),

    Hdrs    = Arg#arg.headers,
    ReqStr  = yaws_api:reformat_request(rewrite_request(RPState,  Arg#arg.req)),
    HdrsStr = yaws:headers_to_str(rewrite_client_headers(RPState, Hdrs)),
    case send(RPState, [ReqStr, "\r\n", HdrsStr, "\r\n"]) of
        ok ->
            RPState1 = if
                           (Hdrs#headers.content_length == undefined andalso
                            Hdrs#headers.transfer_encoding == "chunked") ->
                               ?Debug("Request content is chunked~n", []),
                               RPState#revproxy{state=sendchunk};
                           true ->
                               RPState#revproxy{state=sendcontent}
                       end,
            out(Arg#arg{state=RPState1});

        {error, Reason} ->
            ?Debug("TCP error: ~p~n", [Reason]),
            case Reason of
                closed -> close(RPState);
                _      -> ok
            end,
            outXXX(500, Arg)
    end;


%% Send the request content to the server. Here the content is not chunked. But
%% it can be splitted because of 'partial_post_size' value.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == sendcontent ->
    case Arg#arg.clidata of
        {partial, Bin} ->
            ?Debug("Send partial content to backend server: ~p bytes~n",
                   [size(Bin)]),
            case send(RPState, Bin) of
                ok ->
                    {get_more, undefined, RPState};
                {error, Reason} ->
                    ?Debug("TCP error: ~p~n", [Reason]),
                    case Reason of
                        closed -> close(RPState);
                        _      -> ok
                    end,
                    outXXX(500, Arg)
            end;

        Bin when is_binary(Bin), Bin /= <<>> ->
            ?Debug("Send content to backend server: ~p bytes~n", [size(Bin)]),
            case send(RPState, Bin) of
                ok ->
                    RPState1 = RPState#revproxy{state=recvheaders},
                    out(Arg#arg{state=RPState1});
                {error, Reason} ->
                    ?Debug("TCP error: ~p~n", [Reason]),
                    case Reason of
                        closed -> close(RPState);
                        _      -> ok
                    end,
                    outXXX(500, Arg)
            end;

        _ ->
            ?Debug("no content found~n", []),
            RPState1 = RPState#revproxy{state=recvheaders},
            out(Arg#arg{state=RPState1})
    end;


%% Send the request content to the server. Here the content is chunked, so we
%% must rebuild the chunk before sending it. Chunks can have different size than
%% the original request because of 'partial_post_size' value.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == sendchunk ->
    case Arg#arg.clidata of
        {partial, Bin} ->
            ?Debug("Send chunked content to backend server: ~p bytes~n",
                   [size(Bin)]),
            Res = send(RPState,
                       [yaws:integer_to_hex(size(Bin)),"\r\n",Bin,"\r\n"]),
            case Res of
                ok ->
                    {get_more, undefined, RPState};
                {error, Reason} ->
                    ?Debug("TCP error: ~p~n", [Reason]),
                    case Reason of
                        closed -> close(RPState);
                        _      -> ok
                    end,
                    outXXX(500, Arg)
            end;

        <<>> ->
            ?Debug("Send last chunk to backend server~n", []),
            case send(RPState, "0\r\n\r\n") of
                ok ->
                    RPState1 = RPState#revproxy{state=recvheaders},
                    out(Arg#arg{state=RPState1});
                {error, Reason} ->
                    ?Debug("TCP error: ~p~n", [Reason]),
                    case Reason of
                        closed -> close(RPState);
                        _      -> ok
                    end,
                    outXXX(500, Arg)
            end
    end;


%% The request and its content were sent. Now, we try to read the response
%% headers. Then we check if the response content is chunked or not.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == recvheaders ->
    Res = yaws:http_get_headers(RPState#revproxy.srvsock,
                                RPState#revproxy.type),
    case Res of
        {error, {too_many_headers, _Resp}} ->
            ?Debug("Response headers too large from backend server~n", []),
            close(RPState),
            outXXX(500, Arg);

        {Resp, RespHdrs} when is_record(Resp, http_response) ->
            ?Debug("Response headers received from backend server:~n"
                   " - ~s~n - ~s~n", [?format_record(Resp, http_response),
                                      ?format_record(RespHdrs, headers)]),

            {CliConn, SrvConn} = get_connection_status(
                                   (Arg#arg.req)#http_request.version,
                                   Arg#arg.headers, RespHdrs
                                  ),
            RPState1 = RPState#revproxy{cliconn_status = CliConn,
                                        srvconn_status = SrvConn,
                                        resp           = Resp,
                                        headers        = RespHdrs},
            if
                RPState1#revproxy.r_meth =:= 'HEAD' ->
                    RPState2 = RPState1#revproxy{state=terminate},
                    out(Arg#arg{state=RPState2});

                Resp#http_response.status =:= 100 orelse
                Resp#http_response.status =:= 204 orelse
                Resp#http_response.status =:= 205 orelse
                Resp#http_response.status =:= 304 orelse
                Resp#http_response.status =:= 406 ->
                    RPState2 = RPState1#revproxy{state=terminate},
                    out(Arg#arg{state=RPState2});

                true ->
                    RPState2 =
                        case RespHdrs#headers.content_length of
                            undefined ->
                                case RespHdrs#headers.transfer_encoding of
                                    "chunked" ->
                                        ?Debug("Response content is chunked~n",
                                               []),
                                        RPState1#revproxy{state=recvchunk};
                                    _ ->
                                        RPState1#revproxy{state=terminate}
                                end;
                            _ ->
                                RPState1#revproxy{state=recvcontent}
                        end,
                    out(Arg#arg{state=RPState2})
            end;

        {_R, _H} ->
            %% bad_request
            ?Debug("Bad response received from backend server: ~p~n", [_R]),
            close(RPState),
            outXXX(500, Arg);

        closed ->
            ?Debug("TCP error: ~p~n", [closed]),
            outXXX(500, Arg)
    end;


%% The reponse content is not chunked.
%% TODO: use partial_post_size to split huge content and avoid memory
%% exhaustion.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == recvcontent ->
    Len = list_to_integer((RPState#revproxy.headers)#headers.content_length),
    case read(RPState, Len) of
        {ok, Data} ->
            ?Debug("Response content received from the backend server : "
                   "~p bytes~n", [size(Data)]),
            RPState1 = RPState#revproxy{state      = terminate,
                                        is_chunked = false,
                                        srvdata    = {content, Data}},
            out(Arg#arg{state=RPState1});
        {error, Reason} ->
            ?Debug("TCP error: ~p~n", [Reason]),
            case Reason of
                closed -> close(RPState);
                _      -> ok
            end,
            outXXX(500, Arg)
    end;


%% The reponse content is chunked. Read the first chunk here and spawn a process
%% to read others.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == recvchunk ->
    case read_chunk(RPState) of
        {ok, Data} ->
            ?Debug("First chunk received from the backend server : "
                   "~p bytes~n", [size(Data)]),
            RPState1 = RPState#revproxy{state      = terminate,
                                        is_chunked = (Data /= <<>>),
                                        srvdata    = {stream, Data}},
            out(Arg#arg{state=RPState1});
        {error, Reason} ->
            ?Debug("TCP error: ~p~n", [Reason]),
            case Reason of
                closed -> close(RPState);
                _      -> ok
            end,
            outXXX(500, Arg)
    end;


%% Now, we return the result and we let yaws_server deals with it. If it is
%% possible, we try to cache the connection.
out(Arg = #arg{state=RPState}) when RPState#revproxy.state == terminate ->
    case RPState#revproxy.srvconn_status of
        "close" when RPState#revproxy.is_chunked == false -> close(RPState);
        _  -> cache_connection(RPState)
    end,

    AllHdrs = [{header, H} || H <- yaws_api:reformat_header(
                                     rewrite_server_headers(RPState)
                                    )],
    ?Debug("~p~n", [AllHdrs]),

    Res = [
           {status, (RPState#revproxy.resp)#http_response.status},
           {allheaders, AllHdrs}
          ],
    case RPState#revproxy.srvdata of
        {content, <<>>} ->
            Res;
        {content, Data} ->
            MimeType = (RPState#revproxy.headers)#headers.content_type,
            Res ++ [{content, MimeType, Data}];

        {stream, <<>>} ->
            %% Chunked response with only the last empty chunk: do not spawn a
            %% process to manage chunks
            yaws_api:stream_chunk_end(self()),
            MimeType = (RPState#revproxy.headers)#headers.content_type,
            Res ++ [{streamcontent, MimeType, <<>>}];

        {stream, Chunk} ->
            Self = self(),
            GC   = get(gc),
            spawn(fun() -> put(gc, GC), recv_next_chunk(Self, Arg) end),
            MimeType = (RPState#revproxy.headers)#headers.content_type,
            Res ++ [{streamcontent, MimeType, Chunk}];
        _ ->
            Res
    end;


%% Catch unexpected state by sending an error 500
out(Arg = #arg{state=RPState}) ->
    ?Debug("Unexpected revproxy state:~n - ~s~n",
           [?format_record(RPState, revproxy)]),
    case RPState#revproxy.srvsock of
        undefined -> ok;
        _         -> close(RPState)
    end,
    outXXX(500, Arg).


%%==========================================================================
out404(Arg) ->
    SC=get(sc),
    (SC#sconf.errormod_404):out404(Arg,get(gc),SC).


outXXX(Code, _Arg) ->
    Content = ["<html><h1>", integer_to_list(Code), $\ ,
               yaws_api:code_to_phrase(Code), "</h1></html>"],
    [
     {status, Code},
     {header, {connection, "close"}},
     {content, "text/html", Content}
    ].


%%==========================================================================
%% This function is used to read a chunk and to stream it to the client.
recv_next_chunk(YawsPid, Arg = #arg{state=RPState}) ->
    case read_chunk(RPState) of
        {ok, <<>>} ->
            ?Debug("Last chunk received from the backend server~n", []),
            yaws_api:stream_chunk_end(YawsPid),
            case RPState#revproxy.srvconn_status of
                "close" -> close(RPState);
                _       -> ok %% Cached by the main process
            end;
        {ok, Data} ->
            ?Debug("Next chunk received from the backend server : "
                   "~p bytes~n", [size(Data)]),
            yaws_api:stream_chunk_deliver(YawsPid, Data),
            recv_next_chunk(YawsPid, Arg);
        {error, Reason} ->
            ?Debug("TCP error: ~p~n", [Reason]),
            case Reason of
                closed -> close(RPState);
                _      -> ok
            end,
            outXXX(500, Arg)
    end.


%%==========================================================================
%% TODO: find a better way to cache connections to backend servers. Here we can
%% have 1 connection per gserv process for each backend server.
get_cached_connection(URL) ->
    Key = lists:flatten(yaws_api:reformat_url(URL)),
    case erase(Key) of
        undefined ->
            undefined;
        {Sock, nossl} ->
            case gen_tcp:recv(Sock, 0, 1) of
                {error, closed} ->
                    ?Debug("Invalid cached connection~n", []),
                    undefined;
                _ ->
                    ?Debug("Found cached connection to ~s~n", [Key]),
                    {ok, Sock, nossl}
            end;
        {Sock, ssl} ->
            case ssl:recv(Sock, 0, 1) of
                {error, closed} ->
                    ?Debug("Invalid cached connection~n", []),
                    undefined;
                _ ->
                    ?Debug("Found cached connection to ~s~n", [Key]),
                    {ok, Sock, ssl}
            end
    end.

cache_connection(RPState) ->
    Key = lists:flatten(yaws_api:reformat_url(RPState#revproxy.url)),
    ?Debug("Cache connection to ~s~n", [Key]),
    InitDB0 = get(init_db),
    InitDB1 = lists:keystore(
                Key, 1, InitDB0,
                {Key, {RPState#revproxy.srvsock, RPState#revproxy.type}}
               ),
    put(init_db, InitDB1),
    ok.


%%==========================================================================
connect(URL) ->
    case get_cached_connection(URL) of
        {ok, Sock, Type} -> {ok, Sock, Type};
        undefined        -> do_connect(URL)
    end.

do_connect(URL) ->
    InetType = if
                   is_tuple(URL#url.host), size(URL#url.host) == 8 -> [inet6];
                   true -> []
               end,
    Opts = [
            binary,
            {packet,    raw},
            {active,    false},
            {recbuf,    8192},
            {reuseaddr, true}
           ] ++ InetType,
    case URL#url.scheme of
        http  ->
            Port = case URL#url.port of
                       undefined -> 80;
                       P         -> P
                   end,
            case gen_tcp:connect(URL#url.host, Port, Opts) of
                {ok, S} -> {ok, S, nossl};
                Err     -> Err
            end;
        https ->
            Port = case URL#url.port of
                       undefined -> 443;
                       P         -> P
                   end,
            case ssl:connect(URL#url.host, Port, Opts) of
                {ok, S} -> {ok, S, ssl};
                Err     -> Err
            end;
        _ ->
            {error, unsupported_protocol}
    end.


send(#revproxy{srvsock=Sock, type=ssl}, Data) ->
    ssl:send(Sock, Data);
send(#revproxy{srvsock=Sock, type=nossl}, Data) ->
    gen_tcp:send(Sock, Data).


read(RPState, Len) ->
    yaws:setopts(RPState#revproxy.srvsock, [{packet, raw}, binary],
                 RPState#revproxy.type),
    read(RPState, Len, []).

read(_, 0, Data) ->
    {ok, iolist_to_binary(lists:reverse(Data))};
read(RPState = #revproxy{srvsock=Sock, type=Type}, Len, Data) ->
    case yaws:do_recv(Sock, Len, Type) of
        {ok, Bin}       -> read(RPState, Len-size(Bin), [Bin|Data]);
        {error, Reason} -> {error, Reason}
    end.

read_chunk(#revproxy{srvsock=Sock, type=Type}) ->
    try
        yaws:setopts(Sock, [binary, {packet, line}], Type),
        Len = yaws:get_chunk_num(Sock, Type),
        yaws:setopts(Sock, [binary, {packet, raw}], Type),

        Data = if
                   Len == 0 -> <<>>;
                   true     -> yaws:get_chunk(Sock, Len, 0, Type)
               end,
        ok = yaws:eat_crnl(Sock, Type),
        {ok, iolist_to_binary(Data)}
    catch
        _:Reason ->
            {error, Reason}
    end.


close(#revproxy{srvsock=Sock, type=ssl}) ->
    ssl:close(Sock);
close(#revproxy{srvsock=Sock, type=nossl}) ->
    gen_tcp:close(Sock).


get_connection_status(Version, ReqHdrs, RespHdrs) ->
    CliConn = case Version of
                  {0,9} ->
                      "close";
                  {1, 0} ->
                      case ReqHdrs#headers.connection of
                          undefined -> "close";
                          C1        -> yaws:to_lower(C1)
                      end;
                  {1, 1} ->
                      case ReqHdrs#headers.connection of
                          undefined -> "keep-alive";
                          C1        -> yaws:to_lower(C1)
                      end
              end,
    ?Debug("Client Connection header: ~p~n", [CliConn]),

    %% below, ignore dialyzer warning:
    %% "The pattern 'true' can never match the type 'false'"
    SrvConn = case ?proxy_keepalive of
                  true ->
                      case RespHdrs#headers.connection of
                          undefined -> CliConn;
                          C2        -> yaws:to_lower(C2)
                      end;
                  false ->
                      "close"
              end,
    ?Debug("Server Connection header: ~p~n", [SrvConn]),
    {CliConn, SrvConn}.

%%==========================================================================
rewrite_request(RPState, Req) ->
    ?Debug("Request path to rewrite:  ~p~n", [Req#http_request.path]),
    {abs_path, Path} = Req#http_request.path,
    NewPath = strip_prefix(Path, RPState#revproxy.prefix),
    ?Debug("New Request path: ~p~n", [NewPath]),
    Req#http_request{path = {abs_path, NewPath}}.


rewrite_client_headers(RPState, Hdrs) ->
    ?Debug("Host header to rewrite:  ~p~n", [Hdrs#headers.host]),
    Host = case Hdrs#headers.host of
               undefined ->
                   undefined;
               _ ->
                   ProxyUrl = RPState#revproxy.url,
                   [ProxyUrl#url.host,
                    case ProxyUrl#url.port of
                        undefined -> [];
                        P         -> [$:|integer_to_list(P)]
                    end]
           end,
    ?Debug("New Host header: ~p~n", [Host]),
    Hdrs#headers{host = Host}.


rewrite_server_headers(RPState) ->
    Hdrs = RPState#revproxy.headers,
    ?Debug("Location header to rewrite:  ~p~n", [Hdrs#headers.location]),
    Loc = case Hdrs#headers.location of
              undefined ->
                  undefined;
              L ->
                  ?Debug("parse_url(~p)~n", [L]),
                  LocUrl   = (catch yaws_api:parse_url(L)),
                  ProxyUrl = RPState#revproxy.url,
                  if
                      LocUrl#url.scheme == ProxyUrl#url.scheme andalso
                      LocUrl#url.host   == ProxyUrl#url.host   andalso
                      LocUrl#url.port   == ProxyUrl#url.port ->
                          rewrite_loc_url(RPState, LocUrl);

                      element(1, L) == 'EXIT' ->
                          rewrite_loc_rel(RPState, L);

                      true ->
                          L
                  end
          end,
    ?Debug("New Location header: ~p~n", [Loc]),

    %% FIXME: And we also should do cookies here ...

    Hdrs#headers{location = Loc, connection = RPState#revproxy.cliconn_status}.


%% Rewrite a properly formatted location redir
rewrite_loc_url(RPState, LocUrl) ->
    SC=get(sc),
    Scheme    = yaws:redirect_scheme(SC),
    RedirHost = yaws:redirect_host(SC, RPState#revproxy.r_host),
    [Scheme, RedirHost, slash_append(RPState#revproxy.prefix, LocUrl#url.path)].


%% This is the case for broken webservers that reply with
%% Location: /path
%% or even worse, Location: path
rewrite_loc_rel(RPState, Loc) ->
    SC=get(sc),
    Scheme    = yaws:redirect_scheme(SC),
    RedirHost = yaws:redirect_host(SC, RPState#revproxy.r_host),
    [Scheme, RedirHost, Loc].



strip_prefix("", "") ->
    "/";
strip_prefix(P, "") ->
    P;
strip_prefix(P, "/") ->
    P;
strip_prefix([H|T1], [H|T2]) ->
    strip_prefix(T1, T2).


slash_append("/", [$/|T]) ->
    [$/|T];
slash_append("/", T) ->
    [$/|T];
slash_append([], [$/|T]) ->
    [$/|T];
slash_append([], T) ->
    [$/|T];
slash_append([H|T], X) ->
    [H | slash_append(T, X)].
