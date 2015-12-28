%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc MQTT Packet Serializer
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------
-module(emqttd_serializer).

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

%% API
-export([serialize/1]).

%%------------------------------------------------------------------------------
%% @doc Serialise MQTT Packet
%% @end
%%------------------------------------------------------------------------------
-spec serialize(mqtt_packet()) -> binary().
serialize(#mqtt_packet{header = Header = #mqtt_packet_header{type = Type},
                       variable = Variable,
                       payload  = Payload}) ->
    serialize_header(Header,
        serialize_variable(Type, Variable,
            serialize_payload(Payload))).

serialize_header(#mqtt_packet_header{type   = Type,
                                     dup    = Dup,
                                     qos    = Qos,
                                     retain = Retain},
                 {VariableBin, PayloadBin}) when ?CONNECT =< Type andalso Type =< ?DISCONNECT ->
    Len = size(VariableBin) + size(PayloadBin),
    true = (Len =< ?MAX_LEN),
    LenBin = serialize_len(Len),
    <<Type:4, (opt(Dup)):1, (opt(Qos)):2, (opt(Retain)):1,
      LenBin/binary,
      VariableBin/binary,
      PayloadBin/binary>>.

serialize_variable(?CONNECT, #mqtt_packet_connect{client_id   =  ClientId,
                                                  proto_ver   =  ProtoVer,
                                                  proto_name  =  ProtoName,
                                                  will_retain =  WillRetain,
                                                  will_qos    =  WillQos,
                                                  will_flag   =  WillFlag,
                                                  clean_sess  =  CleanSess,
                                                  keep_alive  =  KeepAlive,
                                                  will_topic  =  WillTopic,
                                                  will_msg    =  WillMsg,
                                                  username    =  Username,
                                                  password    =  Password}, undefined) ->
    VariableBin = <<(size(ProtoName)):16/big-unsigned-integer,
                    ProtoName/binary,
                    ProtoVer:8,
                    (opt(Username)):1,
                    (opt(Password)):1,
                    (opt(WillRetain)):1,
                    WillQos:2,
                    (opt(WillFlag)):1,
                    (opt(CleanSess)):1,
                    0:1,
                    KeepAlive:16/big-unsigned-integer>>,
    PayloadBin = serialize_utf(ClientId),
    PayloadBin1 = case WillFlag of
                      true -> <<PayloadBin/binary,
                                (serialize_utf(WillTopic))/binary,
                                (size(WillMsg)):16/big-unsigned-integer,
                                WillMsg/binary>>;
                      false -> PayloadBin
                  end,
    UserPasswd = << <<(serialize_utf(B))/binary>> || B <- [Username, Password], B =/= undefined >>,
    {VariableBin, <<PayloadBin1/binary, UserPasswd/binary>>};

serialize_variable(?CONNACK, #mqtt_packet_connack{ack_flags   = AckFlags,
                                                  return_code = ReturnCode}, undefined) ->
    {<<AckFlags:8, ReturnCode:8>>, <<>>};

serialize_variable(?SUBSCRIBE, #mqtt_packet_subscribe{packet_id = PacketId,
                                                      topic_table = Topics }, undefined) ->
    {<<PacketId:16/big>>, serialize_topics(Topics)};

serialize_variable(?SUBACK, #mqtt_packet_suback{packet_id = PacketId,
                                                qos_table = QosTable}, undefined) ->
    {<<PacketId:16/big>>, << <<Q:8>> || Q <- QosTable >>};

serialize_variable(?UNSUBSCRIBE, #mqtt_packet_unsubscribe{packet_id  = PacketId,
                                                          topics = Topics }, undefined) ->
    {<<PacketId:16/big>>, serialize_topics(Topics)};

serialize_variable(?UNSUBACK, #mqtt_packet_unsuback{packet_id = PacketId}, undefined) ->
    {<<PacketId:16/big>>, <<>>};

serialize_variable(?PUBLISH, #mqtt_packet_publish{topic_name = TopicName,
                                                  packet_id  = PacketId }, PayloadBin) ->
    TopicBin = serialize_utf(TopicName),
    PacketIdBin = if
                      PacketId =:= undefined -> <<>>;
                      true -> <<PacketId:16/big>>
                  end,
    {<<TopicBin/binary, PacketIdBin/binary>>, PayloadBin};

serialize_variable(PubAck, #mqtt_packet_puback{packet_id = PacketId}, _Payload)
    when PubAck =:= ?PUBACK; PubAck =:= ?PUBREC; PubAck =:= ?PUBREL; PubAck =:= ?PUBCOMP ->
    {<<PacketId:16/big>>, <<>>};

serialize_variable(?PINGREQ, undefined, undefined) ->
    {<<>>, <<>>};

serialize_variable(?PINGRESP, undefined, undefined) ->
    {<<>>, <<>>};

serialize_variable(?DISCONNECT, undefined, undefined) ->
    {<<>>, <<>>}.

serialize_payload(undefined) ->
    undefined;
serialize_payload(Bin) when is_binary(Bin) ->
    Bin.

serialize_topics([{_Topic, _Qos}|_] = Topics) ->
    << <<(serialize_utf(Topic))/binary, ?RESERVED:6, Qos:2>> || {Topic, Qos} <- Topics >>;

serialize_topics([H|_] = Topics) when is_binary(H) ->
    << <<(serialize_utf(Topic))/binary>> || Topic <- Topics >>.

serialize_utf(String) ->
    StringBin = unicode:characters_to_binary(String),
    Len = size(StringBin),
    true = (Len =< 16#ffff),
    <<Len:16/big, StringBin/binary>>.

serialize_len(N) when N =< ?LOWBITS ->
    <<0:1, N:7>>;
serialize_len(N) ->
    <<1:1, (N rem ?HIGHBIT):7, (serialize_len(N div ?HIGHBIT))/binary>>.

opt(undefined)            -> ?RESERVED;
opt(false)                -> 0;
opt(true)                 -> 1;
opt(X) when is_integer(X) -> X;
opt(B) when is_binary(B)  -> 1.
