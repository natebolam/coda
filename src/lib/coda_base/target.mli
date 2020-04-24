open Core_kernel
open Snark_params
open Tick
open Snark_bits

type t = private Field.t [@@deriving sexp, eq, compare]

[%%versioned:
module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving sexp, eq, compare]
  end
end]

val bit_length : int

val max : t

val of_field : Field.t -> t

module Bits : Bits_intf.S with type t := t

include
  Snarkable.Bits.Faithful
  with type Unpacked.value = t
   and type Packed.value = t
   and type Packed.var = private Field.Var.t

val var_to_unpacked : Field.Var.t -> (Unpacked.var, _) Tick.Checked.t

val constant : Packed.value -> Packed.var

val to_bigint : t -> Bignum_bigint.t

val of_bigint : Bignum_bigint.t -> t
