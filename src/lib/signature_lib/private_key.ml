[%%import
"/src/config.mlh"]

open Core_kernel
open Async_kernel

[%%ifdef
consensus_mechanism]

open Snark_params.Tick

[%%else]

open Snark_params_nonconsensus

[%%endif]

[%%versioned_asserted
module Stable = struct
  module V1 = struct
    type t = Inner_curve.Scalar.t [@@deriving sexp]

    let to_latest = Fn.id

    let to_yojson t = `String (Inner_curve.Scalar.to_string t)

    let of_yojson = function
      | `String s ->
          Ok (Inner_curve.Scalar.of_string s)
      | _ ->
          Error "Private_key.of_yojson expected `String"

    [%%ifdef
    consensus_mechanism]

    let gen =
      let open Snark_params.Tick.Inner_curve.Scalar in
      let size' = Bignum_bigint.to_string size |> of_string in
      gen_uniform_incl one (size' - one)

    [%%else]

    let gen = Inner_curve.Scalar.(gen_uniform_incl one (size - one))

    [%%endif]
  end

  (* see lib/module_version/README-version-asserted.md *)
  module Tests = struct
    (* these tests check not only whether the serialization of the version-asserted type has changed,
       but also whether the serializations for the consensus and nonconsensus code are identical
     *)

    [%%if
    curve_size = 298]

    let%test "private key serialization v1" =
      let pk =
        Quickcheck.random_value ~seed:(`Deterministic "private key seed v1")
          V1.gen
      in
      let known_good_digest = "4bbc6cd7832cfc67f0fe3abcd7f765df" in
      Ppx_version.Serialization.check_serialization
        (module V1)
        pk known_good_digest

    [%%elif
    curve_size = 753]

    let%test "private key serialization v1" =
      let pk =
        Quickcheck.random_value ~seed:(`Deterministic "private key seed v1")
          V1.gen
      in
      let known_good_digest = "65c75a7d10b6ce193f0c0e296611a935" in
      Ppx_version.Serialization.check_serialization
        (module V1)
        pk known_good_digest

    [%%else]

    let%test "private key serialization v1" =
      failwith "No test for this curve size"

    [%%endif]
  end
end]

type t = Stable.Latest.t [@@deriving yojson, sexp]

[%%define_locally
Stable.Latest.(gen)]

[%%ifdef
consensus_mechanism]

let create () =
  (* This calls into libsnark which uses /dev/urandom *)
  Inner_curve.Scalar.random ()

[%%else]

let create () = Quickcheck.random_value ~seed:`Nondeterministic gen

[%%endif]

let of_bigstring_exn = Binable.of_bigstring (module Stable.Latest)

let to_bigstring = Binable.to_bigstring (module Stable.Latest)

module Base58_check = Base58_check.Make (struct
  let description = "Private key"

  let version_byte = Base58_check.Version_bytes.private_key
end)

let to_base58_check t =
  Base58_check.encode (to_bigstring t |> Bigstring.to_string)

let of_base58_check_exn s =
  let decoded = Base58_check.decode_exn s in
  decoded |> Bigstring.of_string |> of_bigstring_exn
