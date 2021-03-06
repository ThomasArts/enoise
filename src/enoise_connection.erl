%%% ------------------------------------------------------------------
%%% @copyright 2018, Aeternity Anstalt
%%%
%%% @doc Module implementing a gen_server for holding a handshaked
%%% Noise connection over gen_tcp.
%%%
%%% Some care is needed since the underlying transmission is broken up
%%% into Noise packets, so we need some buffering.
%%%
%%% @end
%%% ------------------------------------------------------------------

-module(enoise_connection).

-export([ controlling_process/2
        , close/1
        , send/2
        , set_active/2
        , start_link/5
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(enoise, { pid }).

-record(state, {rx, tx, owner, owner_ref, tcp_sock, active, msgbuf = [], rawbuf = <<>>}).

%% -- API --------------------------------------------------------------------
start_link(TcpSock, Rx, Tx, Owner, {Active0, Buf}) ->
    Active = case Active0 of
                 true -> true;
                 once -> {once, false}
             end,
    State = #state{ rx = Rx, tx = Tx, owner = Owner,
                    tcp_sock = TcpSock, active = Active },

    case gen_server:start_link(?MODULE, [State], []) of
        {ok, Pid} ->
            case gen_tcp:controlling_process(TcpSock, Pid) of
                ok ->
                    %% Changing controlling process require a bit of
                    %% fiddling with already received and delivered content...
                    [ Pid ! {tcp, TcpSock, Buf} || Buf /= <<>> ],
                    flush_tcp(Pid, TcpSock),
                    {ok, Pid};
                Err = {error, _} ->
                    close(Pid),
                    Err
            end;
        Err = {error, _} ->
            Err
    end.

-spec send(Noise :: pid(), Data :: binary()) -> ok | {error, term()}.
send(Noise, Data) ->
    gen_server:call(Noise, {send, Data}).

-spec set_active(Noise :: pid(), Active :: true | once) -> ok | {error, term()}.
set_active(Noise, Active) ->
    gen_server:call(Noise, {active, self(), Active}).

-spec close(Noise :: pid()) -> ok | {error, term()}.
close(Noise) ->
    gen_server:call(Noise, close).

-spec controlling_process(Noise :: pid(), NewPid :: pid()) -> ok | {error, term()}.
controlling_process(Noise, NewPid) ->
    gen_server:call(Noise, {controlling_process, self(), NewPid}, 100).

%% -- gen_server callbacks ---------------------------------------------------
init([#state{owner = Owner} = State]) ->
    OwnerRef = erlang:monitor(process, Owner),
    {ok, State#state{owner_ref = OwnerRef}}.

handle_call(close, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Call, _From, S = #state{ tcp_sock = closed }) ->
    {reply, {error, closed}, S};
handle_call({send, Data}, _From, S) ->
    {Res, S1} = handle_send(S, Data),
    {reply, Res, S1};
handle_call({controlling_process, OldPid, NewPid}, _From, S) ->
    {Res, S1} = handle_control_change(S, OldPid, NewPid),
    {reply, Res, S1};
handle_call({active, Pid, NewActive}, _From, S) ->
    {Res, S1} = handle_active(S, Pid, NewActive),
    {reply, Res, S1}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({tcp, TS, Data}, S = #state{ tcp_sock = TS, owner = O }) ->
    try
        {S1, Msgs} = handle_data(S, Data),
        S2 = handle_msgs(S1#state{ msgbuf = S1#state.msgbuf ++ Msgs }),
        set_active(S2),
        {noreply, S2}
    catch error:{enoise_error, _} ->
        %% We are not likely to recover, but leave the decision to upstream
        O ! {enoise_error, TS, decrypt_error},
        {noreply, S}
    end;
handle_info({tcp_closed, TS}, S = #state{ tcp_sock = TS, owner = O }) ->
    O ! {tcp_closed, TS},
    {noreply, S#state{ tcp_sock = closed }};
handle_info({'DOWN', OwnerRef, process, _, normal},
            S = #state { tcp_sock = TS, owner_ref = OwnerRef }) ->
    close_tcp(TS),
    {stop, normal, S#state{ tcp_sock = closed, owner_ref = undefined }};
handle_info({'DOWN', _, _, _, _}, S) ->
    %% Ignore non-normal monitor messages - we are linked.
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, #state{ tcp_sock = TcpSock, owner_ref = ORef }) ->
    [ gen_tcp:close(TcpSock) || TcpSock /= closed ],
    [ erlang:demonitor(ORef, [flush]) || ORef /= undefined ],
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% -- Local functions --------------------------------------------------------
handle_control_change(S = #state{ owner = Pid, owner_ref = OldRef }, Pid, NewPid) ->
    NewRef = erlang:monitor(process, NewPid),
    erlang:demonitor(OldRef, [flush]),
    {ok, S#state{ owner = NewPid, owner_ref = NewRef }};
handle_control_change(S, _OldPid, _NewPid) ->
    {{error, not_owner}, S}.

handle_active(S = #state{ owner = Pid, tcp_sock = TcpSock }, Pid, Active) ->
    case Active of
        true ->
            inet:setopts(TcpSock, [{active, true}]),
            {ok, handle_msgs(S#state{ active = true })};
        once ->
            S1 = handle_msgs(S#state{ active = {once, false} }),
            set_active(S1),
            {ok, S1}
    end;
handle_active(S, _Pid, _NewActive) ->
    {{error, not_owner}, S}.

handle_data(S = #state{ rawbuf = Buf, rx = Rx }, Data) ->
    case <<Buf/binary, Data/binary>> of
        B = <<Len:16, Rest/binary>> when Len > byte_size(Rest) ->
            {S#state{ rawbuf = B }, []}; %% Not a full Noise message - save it
        <<Len:16, Rest/binary>> ->
            <<Msg:Len/binary, Rest2/binary>> = Rest,
            case enoise_cipher_state:decrypt_with_ad(Rx, <<>>, Msg) of
                {ok, Rx1, Msg1} ->
                    {S1, Msgs} = handle_data(S#state{ rawbuf = Rest2, rx = Rx1 }, <<>>),
                    {S1, [Msg1 | Msgs]};
                {error, _} ->
                    error({enoise_error, decrypt_input_failed})
            end;
        EmptyOrSingleByte ->
            {S#state{ rawbuf = EmptyOrSingleByte }, []}
    end.

handle_msgs(S = #state{ msgbuf = [] }) ->
    S;
handle_msgs(S = #state{ msgbuf = Msgs, active = true, owner = Owner }) ->
    [ Owner ! {noise, #enoise{ pid = self() }, Msg} || Msg <- Msgs ],
    S#state{ msgbuf = [] };
handle_msgs(S = #state{ msgbuf = [Msg | Msgs], active = {once, Delivered}, owner = Owner }) ->
    case Delivered of
        true  ->
            S;
        false ->
            Owner ! {noise, #enoise{ pid = self() }, Msg},
            S#state{ msgbuf = Msgs, active = {once, true} }
    end.

handle_send(S = #state{ tcp_sock = TcpSock, tx = Tx }, Data) ->
    {ok, Tx1, Msg} = enoise_cipher_state:encrypt_with_ad(Tx, <<>>, Data),
    case gen_tcp:send(TcpSock, <<(byte_size(Msg)):16, Msg/binary>>) of
        ok               -> {ok, S#state{ tx = Tx1 }};
        Err = {error, _} -> {Err, S}
    end.

set_active(#state{ msgbuf = [], active = {once, _}, tcp_sock = TcpSock }) ->
    inet:setopts(TcpSock, [{active, once}]);
set_active(_) ->
    ok.

flush_tcp(Pid, TcpSock) ->
    receive {tcp, TcpSock, Data} ->
        Pid ! {tcp, TcpSock, Data},
        flush_tcp(Pid, TcpSock)
    after 1 -> ok
    end.

close_tcp(closed) ->
    ok;
close_tcp(Sock) ->
    gen_tcp:close(Sock).
