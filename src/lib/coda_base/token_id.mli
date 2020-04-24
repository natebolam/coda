[%%import "/src/config.mlh"]

open Core_kernel

[%%ifdef consensus_mechanism]

open Snark_params
open Tick

[%%else]

module Random_oracle = Random_oracle_nonconsensus
open Snark_params_nonconsensus

[%%endif]

[%%versioned:
module Stable : sig
  module V1 : sig
    type t [@@deriving version, sexp, eq, hash, compare, yojson]
  end
end]

type t = Stable.Latest.t [@@deriving sexp, compare]

val to_input : t -> (Field.t, bool) Random_oracle.Input.t

val to_string : t -> string

val of_string : string -> t

(** The default token ID, associated with the native coda token.

    This ID should be used for fee and coinbase transactions.
*)
val default : t

(** An invalid token ID.

    This ID should only be used as a dummy value.
*)
val invalid : t

val next : t -> t

(** Generates a random token ID. This is guaranteed not to equal [invalid]. *)
val gen : t Quickcheck.Generator.t

(** Generates a random token ID. This is guaranteed not to equal [invalid] or
    [default].
*)
val gen_non_default : t Quickcheck.Generator.t

val unpack : t -> bool list

include Comparable.S_binable with type t := t

include Hashable.S_binable with type t := t

[%%ifdef consensus_mechanism]

type var

val typ : (var, t) Typ.t

val var_of_t : t -> var

module Checked : sig
  val to_input : var -> (Field.Var.t, Boolean.var) Random_oracle.Input.t

  val next : var -> var

  val equal : var -> var -> (Boolean.var, _) Checked.t

  val if_ : Boolean.var -> then_:var -> else_:var -> (var, _) Checked.t

  module Assert : sig
    val equal : var -> var -> (unit, _) Checked.t
  end
end

[%%endif]
