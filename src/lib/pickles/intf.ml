open Core_kernel
open Pickles_types
open Import
module Sponge_lib = Sponge

module Snarkable = struct
  module type S1 = sig
    type _ t

    val typ :
      ('var, 'value, 'f) Snarky.Typ.t -> ('var t, 'value t, 'f) Snarky.Typ.t
  end

  module type S2 = sig
    type (_, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> (('var1, 'var2) t, ('value1, 'value2) t, 'f) Snarky.Typ.t
  end

  module type S3 = sig
    type (_, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3) t
         , ('value1, 'value2, 'value3) t
         , 'f )
         Snarky.Typ.t
  end

  module type S4 = sig
    type (_, _, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ('var4, 'value4, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3, 'var4) t
         , ('value1, 'value2, 'value3, 'value4) t
         , 'f )
         Snarky.Typ.t
  end

  module type S5 = sig
    type (_, _, _, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ('var4, 'value4, 'f) Snarky.Typ.t
      -> ('var5, 'value5, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3, 'var4, 'var5) t
         , ('value1, 'value2, 'value3, 'value4, 'value5) t
         , 'f )
         Snarky.Typ.t
  end

  module type S6 = sig
    type (_, _, _, _, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ('var4, 'value4, 'f) Snarky.Typ.t
      -> ('var5, 'value5, 'f) Snarky.Typ.t
      -> ('var6, 'value6, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3, 'var4, 'var5, 'var6) t
         , ('value1, 'value2, 'value3, 'value4, 'value5, 'value6) t
         , 'f )
         Snarky.Typ.t
  end

  module type S7 = sig
    type (_, _, _, _, _, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ('var4, 'value4, 'f) Snarky.Typ.t
      -> ('var5, 'value5, 'f) Snarky.Typ.t
      -> ('var6, 'value6, 'f) Snarky.Typ.t
      -> ('var7, 'value7, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3, 'var4, 'var5, 'var6, 'var7) t
         , ('value1, 'value2, 'value3, 'value4, 'value5, 'value6, 'value7) t
         , 'f )
         Snarky.Typ.t
  end

  module type S8 = sig
    type (_, _, _, _, _, _, _, _) t

    val typ :
         ('var1, 'value1, 'f) Snarky.Typ.t
      -> ('var2, 'value2, 'f) Snarky.Typ.t
      -> ('var3, 'value3, 'f) Snarky.Typ.t
      -> ('var4, 'value4, 'f) Snarky.Typ.t
      -> ('var5, 'value5, 'f) Snarky.Typ.t
      -> ('var6, 'value6, 'f) Snarky.Typ.t
      -> ('var7, 'value7, 'f) Snarky.Typ.t
      -> ('var8, 'value8, 'f) Snarky.Typ.t
      -> ( ('var1, 'var2, 'var3, 'var4, 'var5, 'var6, 'var7, 'var8) t
         , ( 'value1
           , 'value2
           , 'value3
           , 'value4
           , 'value5
           , 'value6
           , 'value7
           , 'value8 )
           t
         , 'f )
         Snarky.Typ.t
  end
end

module Evals = struct
  module type S = sig
    type n

    val n : n Vector.nat

    include Binable.S1 with type 'a t = ('a, n) Vector.t

    include Snarkable.S1 with type 'a t := 'a t
  end
end

module Group (Impl : Snarky.Snark_intf.Run) = struct
  open Impl

  module type S = sig
    type t

    module Params : sig
      val a : Field.Constant.t

      val b : Field.Constant.t
    end

    module Constant : sig
      type t

      module Scalar : Marlin_checks.Field_intf

      val scale : t -> Scalar.t -> t

      val to_affine_exn : t -> field * field

      val of_affine : field * field -> t
    end

    val typ : (t, Constant.t, field) Snarky.Typ.t

    val ( + ) : t -> t -> t

    val double : t -> t

    val scale : t -> Boolean.var list -> t

    val if_ : Boolean.var -> then_:t -> else_:t -> t

    val negate : t -> t

    val to_field_elements : t -> Field.t list

    module Scaling_precomputation : sig
      type t

      val create : Constant.t -> t
    end

    val constant : Constant.t -> t

    val multiscale_known :
      (Boolean.var list * Scaling_precomputation.t) array -> t
  end
end

module Sponge (Impl : Snarky.Snark_intf.Run) = struct
  open Impl

  module type S =
    Sponge.Intf.Sponge
    with module Field := Field
     and module State := Sponge.State
     and type input := Field.t
     and type digest := length:int -> Boolean.var list
end

module Dlog_main_inputs = struct
  module type S = sig
    val crs_max_degree : int

    module Branching_pred : Nat.Add.Intf_transparent

    module Bulletproof_rounds : Nat.Add.Intf_transparent

    module Impl : Snarky.Snark_intf.Run with type prover_state = unit

    module Fp : sig
      type t

      val order : Bigint.t

      val size_in_bits : int

      val to_bigint : t -> Impl.Bigint.t

      val of_bigint : Impl.Bigint.t -> t
    end

    module G1 : sig
      include Group(Impl).S with type t = Impl.Field.t * Impl.Field.t

      open Impl

      module type Shifted_intf = sig
        type t

        val zero : t

        val unshift_nonzero : t -> Field.t * Field.t

        val add : t -> Field.t * Field.t -> t

        val if_ : Boolean.var -> then_:t -> else_:t -> t
      end

      val shifted : unit -> (module Shifted_intf)
    end

    module Generators : sig
      val g : G1.Constant.t
    end

    module Input_domain : sig
      val domain : Domain.t

      val self : Domain.t

      val lagrange_commitments : Domain.t -> G1.Constant.t array
    end

    val sponge_params : Impl.Field.t Sponge_lib.Params.t

    module Sponge : Sponge(Impl).S
  end
end

module Pairing_main_inputs = struct
  module type S = sig
    val crs_max_degree : int

    module Impl : Snarky.Snark_intf.Run with type prover_state = unit

    module G : sig
      open Impl

      include Group(Impl).S with type t = Field.t * Field.t

      val one : t

      val if_ : Boolean.var -> then_:t -> else_:t -> t

      val scale_inv : t -> Boolean.var list -> t

      val scale_by_quadratic_nonresidue : t -> t

      val scale_by_quadratic_nonresidue_inv : t -> t
    end

    module Fq : sig
      type t = G.Constant.Scalar.t [@@deriving sexp]

      val to_bits : t -> bool list

      val of_bits : bool list -> t

      val is_square : t -> bool

      val print : t -> unit
    end

    module Generators : sig
      val h : G.Constant.t Lazy.t
    end

    module Input_domain : sig
      val domain : Domain.t

      val self : Domain.t

      val lagrange_commitments : G.Constant.t array Lazy.t
    end

    val sponge_params : Impl.Field.t Sponge_lib.Params.t

    module Sponge : sig
      include
        Sponge_lib.Intf.Sponge
        with module Field := Impl.Field
         and module State := Sponge_lib.State
         and type input :=
                    [`Field of Impl.Field.t | `Bits of Impl.Boolean.var list]
         and type digest := length:int -> Impl.Boolean.var list

      val squeeze_field : t -> Impl.Field.t
    end
  end
end

module type Statement = sig
  type field

  type t

  val to_field_elements : t -> field array
end

module type Statement_var =
  Statement with type field := Zexe_backend.Fp.t Snarky.Cvar.t

module type Statement_value = Statement with type field := Zexe_backend.Fp.t
