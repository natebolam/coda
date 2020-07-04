[%%import
"/src/config.mlh"]

open Core_kernel

[%%ifndef
consensus_mechanism]

open Import

[%%endif]

module T = Coda_numbers.Nat.Make64 ()

[%%versioned
module Stable = struct
  module V1 = struct
    type t = Unsigned_extended.UInt64.Stable.V1.t
    [@@deriving sexp, eq, compare, hash, yojson]

    let to_latest = Fn.id
  end
end]

type t = Stable.Latest.t [@@deriving sexp, compare, yojson]

let to_input = T.to_input

let to_string = T.to_string

let of_string = T.of_string

let next = T.succ

let invalid = T.of_uint64 Unsigned.UInt64.zero

let default = T.of_uint64 Unsigned.UInt64.one

let gen_ge minimum =
  Quickcheck.Generator.map
    Int64.(gen_incl (min_value + minimum) max_value)
    ~f:(fun x ->
      Int64.(x - min_value) |> Unsigned.UInt64.of_int64 |> T.of_uint64 )

let gen = gen_ge 1L

let gen_non_default = gen_ge 2L

let unpack = T.to_bits

include Hashable.Make_binable (Stable.Latest)
include Comparable.Make_binable (Stable.Latest)

[%%ifdef
consensus_mechanism]

type var = T.Checked.t

let typ = T.typ

let var_of_t = T.Checked.constant

module Checked = struct
  open Snark_params.Tick

  let next = T.Checked.succ

  let next_if = T.Checked.succ_if

  let to_input = T.Checked.to_input

  let equal = T.Checked.equal

  let if_ = T.Checked.if_

  module Assert = struct
    let equal x y =
      let x = T.Checked.to_integer x |> Snarky_integer.Integer.to_field in
      let y = T.Checked.to_integer y |> Snarky_integer.Integer.to_field in
      Field.Checked.Assert.equal x y
  end
end

let%test_unit "var_of_t preserves the underlying value" =
  let open Snark_params.Tick in
  Quickcheck.test gen ~f:(fun tid ->
      [%test_eq: t] tid
        (Test_util.checked_to_unchecked Typ.unit typ
           (fun () -> Snark_params.Tick.Checked.return (var_of_t tid))
           ()) )

[%%endif]
