%%% @author     Maxim Treskin <zerthud@gmail.com> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        SDP decoder module
%%% @end
%%% @reference  See <a href="http://erlyvideo.org/rtp" target="_top">http://erlyvideo.org</a> for common information.
%%% @end
%%%
%%% This file is part of erlang-rtp.
%%%
%%% erlang-rtp is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlang-rtp is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlang-rtp.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(sdp_encoder).
-author('Maxim Treskin <zerthud@gmail.com>').

-export([encode/2, prep_media_config/2]).

-include("../include/sdp.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/h264.hrl").
-include("log.hrl").


%%
-define(LSEP, <<$\r,$\n>>).
encode(#session_desc{connect = GConnect} = Session,
       MediaSeq) ->
  S = encode_session(Session),
  M = encode_media_seq(MediaSeq, GConnect),
  <<S/binary,M/binary>>.

encode_session(S) ->
  encode_session(S, <<>>).

encode_session(#session_desc{version = Ver,
                             originator = #sdp_o{username = UN,
                                                 sessionid = SI,
                                                 version = OV,
                                                 netaddrtype = NAT,
                                                 address = AD},
                             name = N,
                             connect = Connect,
                             time = Time,
                             attrs = Attrs
                            } = _D, _A) ->
  SV = ["v=", Ver, ?LSEP],
  SO = ["o=", UN, $ , SI, $ , OV, $ , at2bin(NAT), $ , AD, ?LSEP],
  SN = ["s=", N, ?LSEP],
  SC =
    case Connect of
      {Type, Addr} when (is_atom(Type)
                         andalso (is_list(Addr) or is_binary(Addr))) ->
        ["c=", at2bin(Type), $ , Addr, ?LSEP];
      _ -> []
    end,
  AttrL = encode_attrs(Attrs),
  TimeB =
    case Time of
      {TimeStart, TimeStop} when is_integer(TimeStart), is_integer(TimeStop) ->
        ["t=", integer_to_list(TimeStart), $ , integer_to_list(TimeStop), ?LSEP];
      _ -> []
    end,
  iolist_to_binary([SV, SO, SN, SC, TimeB, AttrL]).

%%  encode(D#session_desc{version = undefined}, <<A/binary,S/binary,?LSEP/binary>>);


%% encode_session(#session_desc{name = N} = D, A) ->
%%   S = <<"s="/binary, N/binary>>,
%%   encode(D#session_desc{name = undefined}, <<A/binary,S/binary,?LSEP/binary>>);
%% encode_session(#session_desc{connect = {Type, Addr}}, A) ->
%%   AT = at2bin(Type),
%%   S = <<"c="/binary,AT/binary,$ ,(list_to_binary(Addr))/binary>>,
%%   <<A/binary,S/binary,?LSEP/binary>>.

encode_attrs(Attrs) ->
  [begin
     ResB =
       case KV of
         {K, V} when (is_atom(K)
                      andalso (is_list(V) or is_binary(V))) ->
           [atom_to_list(K), $:, V];
         _ when is_atom(KV) ->
           atom_to_list(KV);
         _Other ->
           ?DBG("Err: ~p", [KV]),
           ""
       end,
     ["a=", ResB, ?LSEP]
   end || KV <- Attrs].

encode_media_seq(MS, GConnect) ->
  encode_media_seq(MS, GConnect, <<>>).

encode_media_seq([], _, A) ->
  A;
encode_media_seq([H|T], GConnect, A) ->
  NA = <<A/binary,(encode_media(H, GConnect))/binary>>,
  encode_media_seq(T, GConnect, NA).

encode_media(M, GConnect) ->
  encode_media(M, GConnect, <<>>).

encode_media(#media_desc{type = Type,
                         connect = _Connect,
                         port = Port,
                         payloads = PayLoads,
                         track_control = TControl,
                         config = Config,
                         attrs = Attrs
                        }, _GConnect, _A) ->
  Tb = type2bin(Type),
  M = ["m=", Tb, $ , integer_to_list(Port), $ , "RTP/AVP", $ ,
       string:join([integer_to_list(PTnum) || #payload{num = PTnum} <- PayLoads], " "), ?LSEP],
  AC = case TControl of undefined -> []; _ -> ["a=", "control:", TControl, ?LSEP] end,
  %% TODO: support of several payload types
  AR = [begin
          Codecb = codec2bin(Codec),
          CMapb = integer_to_list(ClockMap),
          MSb = ms2bin(MS),
          if is_list(PTConfig) ->
              PTC = [["a=", "fmtp:", integer_to_list(PTnum), $ , C, ?LSEP] || C <- PTConfig];
             true ->
              PTC = []
          end,
          if is_integer(PTime) ->
              PTimeS = ["a=", "ptime:", integer_to_list(PTime), ?LSEP];
             true ->
              PTimeS = []
          end,
          [["a=", "rtpmap:", integer_to_list(PTnum), $ , Codecb, $/, CMapb, MSb, ?LSEP], PTC, PTimeS]
        end || #payload{num = PTnum, codec = Codec,
                        clock_map = ClockMap, ms = MS,
                        ptime = PTime, config = PTConfig} <- PayLoads],
  ACfg = case Config of
           %% _ when (is_list(Config) or
           %%         is_binary(Config)) ->
           _ when ((is_list(Config) and (length(Config) > 0))
                   or (is_binary(Config) and (size(Config) > 0))) ->
             [["a=", "fmtp:", integer_to_list(PTnum), $ , Config, ?LSEP] || #payload{num = PTnum} <- PayLoads];
           _ ->
             []
         end,
  AttrL = encode_attrs(Attrs),
  iolist_to_binary([M, AR, ACfg, AC, AttrL]);
encode_media(_, _, _) ->
  <<>>.


type2bin(T) ->
  case T of
    audio -> <<"audio">>;
    video -> <<"video">>
  end.

at2bin(AT) ->
  case AT of
    inet4 -> <<"IN IP4">>;
    inet6 -> <<"IN IP6">>
  end.

codec2bin(C) ->
  case C of
    h264 -> <<"H264">>;
    aac -> <<"mpeg4-generic">>;
    pcma -> <<"PCMA">>;
    pcmu -> <<"PCMU">>;
    g726_16 -> <<"G726-16">>;
    mpa -> <<"MPA">>;
    mp4a -> <<"MP4A-LATM">>;
    mp4v -> <<"MP4V-ES">>;
    mp3 -> <<"mpa-robust">>;
    pcm -> <<"L16">>;
    speex -> <<"speex">>
  end.

ms2bin(MS) ->
  case MS of
    undefined -> <<>>;
    mono -> <<$/,$1>>;
    stereo -> <<$/,$2>>
  end.

prep_media_config({video,
                   #video_frame{content = video,
                                flavor = config,
                                codec = h264 = Codec,
                                body = Body}}, Opts) ->
  AFmtp = h264:to_fmtp(Body),
  #media_desc{type = video,
              port = proplists:get_value(video_port, Opts, 0),
              payloads = [#payload{num = 97, codec = Codec, clock_map = 90000,
                                   config = [iolist_to_binary(AFmtp)]
                                  }],
              track_control = proplists:get_value(video, Opts, "2")
             };
prep_media_config({audio,
                   #video_frame{content = audio,
                                flavor = config,
                                codec = aac = Codec,
                                sound = {_Channs, _Size, Rate},
                                body = <<ConfigVal:2/big-integer-unit:8>>}}, Opts) ->
  #media_desc{type = audio,
              port = proplists:get_value(audio_port, Opts, 0),
              payloads = [#payload{num = 96, codec = Codec, clock_map = rate2num(Rate),
                                   ptime = proplists:get_value(audio_ptime, Opts),
                                   config = [iolist_to_binary([
                                                               %%"streamtype=5;"
                                                               "profile-level-id=1;"
                                                               "mode=AAC-hbr;"
                                                               "config=",
                                                               erlang:integer_to_list(ConfigVal, 16) ++ ";",
                                                               "SizeLength=13;"
                                                               "IndexLength=3;"
                                                               "IndexDeltaLength=3;"
                                                               "Profile=1;"

                                                               %% "profile-level-id=1;"
                                                               %% "mode=AAC-hbr;"
                                                               %% "sizelength=13;"
                                                               %% "indexlength=3;"
                                                               %% "indexdeltalength=3;"
                                                               %% "config=", erlang:integer_to_list(ConfigVal, 16) ++ ";"
                                                              ])]}],
              track_control = proplists:get_value(audio, Opts, "1")
             };
prep_media_config({audio,
                   #video_frame{content = audio,
                                flavor = config,
                                codec = speex = Codec,
                                sound = {_Channs, _Size, Rate},
                                body = _Body}}, Opts) ->
  #media_desc{type = audio,
              port = proplists:get_value(audio_port, Opts, 0),
              payloads = [#payload{num = 111, codec = Codec,
                                   clock_map = rate2num(Rate), ms = mono,
                                   config = ["vbr=vad"]}],
              track_control = undefined};
prep_media_config({audio, _}, _) ->
    undefined;
prep_media_config({video, _}, _) ->
    undefined;
prep_media_config({data, _}, _) ->
  undefined.


rate2num(Rate) ->
  case Rate of
    rate11 -> 11025;
    rate22 -> 22050;
    rate44 -> 44100;
    R when is_integer(R) -> R
  end.