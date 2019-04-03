-module(enoise_crypto_basics).

-export([padding/2, pad/3]).

padding(Key,Pad) ->
  <<PadWord:32>> = <<Pad:8, Pad:8, Pad:8, Pad:8>>,
  << <<(Word bxor PadWord):32>> || <<Word:32>> <= Key >>.

pad(Data, MinSize, PadByte) ->
    case byte_size(Data) of
        N when N >= MinSize ->
            Data;
        N ->
            PadData = << <<PadByte:8>> || _ <- lists:seq(1, MinSize - N) >>,
            <<Data/binary, PadData/binary>>
    end.

