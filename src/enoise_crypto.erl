%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%%-------------------------------------------------------------------

-module(enoise_crypto).

-include("enoise.hrl").

-export([decrypt/5, encrypt/5, rekey/2, hash/2, pad/3, hashlen/1, dhlen/1, new_key_pair/1, hmac/3, hkdf/3, dh/3]).

new_key_pair(dh25519) ->
    KeyPair = enacl:crypto_sign_ed25519_keypair(),
    #key_pair{ puk = enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))
             , pik = enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)) }.

dh(dh25519, KeyPair, PubKey) ->
    enacl:curve25519_scalarmult(KeyPair#key_pair.pik, PubKey).

hmac(Hash, Key, Data) ->
    BLen = blocklen(blake2b),
    Block1 = hmac_format_key(Hash, Key, 16#36, BLen),
    Hash1 = hash(Hash, <<Block1/binary, Data/binary>>),
    Block2 = hmac_format_key(Hash, Key, 16#5C, BLen),
    hash(Hash, <<Block2/binary, Hash1/binary>>).

hkdf(Hash, Key, Data) ->
    TempKey = hmac(Hash, Key, Data),
    Output1 = hmac(Hash, TempKey, <<1:8>>),
    Output2 = hmac(Hash, TempKey, <<Output1/binary, 2:8>>),
    Output3 = hmac(Hash, TempKey, <<Output2/binary, 3:8>>),
    [Output1, Output2, Output3].

rekey(Cipher, K) ->
    encrypt(Cipher, K, ?MAX_NONCE, <<>>, <<0:(32*8)>>).

encrypt('ChaChaPoly', K, N, Ad, PlainText) ->
    enacl:aead_chacha20poly1305_encrypt(K, N, Ad, PlainText).

-spec decrypt(Cipher ::enoise_cipher_state:noise_cipher(),
              Key :: binary(), Nonce :: non_neg_integer(),
              AD :: binary(), CipherText :: binary()) ->
                binary() | {error, term()}.
decrypt('ChaChaPoly', K, N, Ad, CipherText) ->
    enacl:aead_chacha20poly1305_decrypt(K, N, Ad, CipherText).

hash(blake2b, Data) ->
    {ok, Hash} = enacl:generichash(64, Data), Hash;
hash(Hash, _Data) ->
    error({hash_not_implemented_yet, Hash}).

pad(Data, MinSize, PadByte) ->
    case byte_size(Data) of
        N when N >= MinSize ->
            Data;
        N ->
            PadData = << <<PadByte:8>> || _ <- lists:seq(1, MinSize - N) >>,
            <<Data/binary, PadData/binary>>
    end.

hashlen(sha256)  -> 32;
hashlen(sha512)  -> 64;
hashlen(blake2s) -> 32;
hashlen(blake2b) -> 64.

blocklen(sha256)  -> 64;
blocklen(sha512)  -> 128;
blocklen(blake2s) -> 64;
blocklen(blake2b) -> 128.

dhlen(dh25519) -> 32;
dhlen(dh448)   -> 56.

%%% Local implementations


hmac_format_key(Hash, Key0, Pad, BLen) ->
    Key1 =
        case byte_size(Key0) =< BLen of
            true  -> Key0;
            false -> hash(Hash, Key0)
        end,
    Key2 = pad(Key1, BLen, 0),
    <<PadWord:32>> = <<Pad:8, Pad:8, Pad:8, Pad:8>>,
    << <<(Word bxor PadWord):32>> || <<Word:32>> <= Key2 >>.

