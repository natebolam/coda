module type Inputs_intf = sig
  open Intf

  val name : string

  module Rounds : Pickles_types.Nat.Intf

  module Constraint_matrix : T0

  module Urs : sig
    type t

    val read : string -> t

    val write : t -> string -> unit

    val create :
      Unsigned.Size_t.t -> Unsigned.Size_t.t -> Unsigned.Size_t.t -> t
  end

  module Index : sig
    type t

    val delete : t -> unit

    val create :
         Constraint_matrix.t
      -> Constraint_matrix.t
      -> Constraint_matrix.t
      -> Unsigned.Size_t.t
      -> Unsigned.Size_t.t
      -> Urs.t
      -> t
  end

  module Curve : sig
    module Affine : sig
      type t
    end
  end

  module Poly_comm : sig
    module Backend : T0

    type t = Curve.Affine.t Poly_comm.t

    val of_backend : Backend.t -> t
  end

  module Verifier_index : sig
    type t

    val create : Index.t -> t

    val a_row_comm : t -> Poly_comm.Backend.t

    val a_col_comm : t -> Poly_comm.Backend.t

    val a_val_comm : t -> Poly_comm.Backend.t

    val a_rc_comm : t -> Poly_comm.Backend.t

    val b_row_comm : t -> Poly_comm.Backend.t

    val b_col_comm : t -> Poly_comm.Backend.t

    val b_val_comm : t -> Poly_comm.Backend.t

    val b_rc_comm : t -> Poly_comm.Backend.t

    val c_row_comm : t -> Poly_comm.Backend.t

    val c_col_comm : t -> Poly_comm.Backend.t

    val c_val_comm : t -> Poly_comm.Backend.t

    val c_rc_comm : t -> Poly_comm.Backend.t
  end
end

module Make (Inputs : Inputs_intf) = struct
  open Core_kernel
  open Inputs

  type t = Index.t

  include Dlog_urs.Make (struct
    include Inputs

    let public_inputs = lazy (Unsigned.Size_t.of_int 0)

    let size = lazy (Unsigned.Size_t.of_int 0)
  end)

  let create
      { R1cs_constraint_system.public_input_size
      ; auxiliary_input_size
      ; constraints
      ; m= {a; b; c}
      ; weight } =
    let vars = 1 + public_input_size + auxiliary_input_size in
    let t =
      Index.create a b c
        (Unsigned.Size_t.of_int vars)
        (Unsigned.Size_t.of_int (public_input_size + 1))
        (load_urs ())
    in
    Caml.Gc.finalise Index.delete t ;
    t

  let vk t = Verifier_index.create t

  let pk = Fn.id

  open Pickles_types

  let vk_commitments t :
      Curve.Affine.t Dlog_marlin_types.Poly_comm.Without_degree_bound.t Abc.t
      Matrix_evals.t =
    let f (t : Poly_comm.Backend.t) =
      match Poly_comm.of_backend t with
      | `Without_degree_bound a ->
          a
      | _ ->
          assert false
    in
    let open Verifier_index in
    { row= {Abc.a= a_row_comm t; b= b_row_comm t; c= c_row_comm t}
    ; col= {a= a_col_comm t; b= b_col_comm t; c= c_col_comm t}
    ; value= {a= a_val_comm t; b= b_val_comm t; c= c_val_comm t}
    ; rc= {a= a_rc_comm t; b= b_rc_comm t; c= c_rc_comm t} }
    |> Matrix_evals.map ~f:(Abc.map ~f)
end
