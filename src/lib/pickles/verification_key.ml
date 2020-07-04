open Core
open Pickles_types
open Zexe_backend

module Data = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        { public_inputs: int
        ; variables: int
        ; constraints: int
        ; nonzero_entries: int
        ; max_degree: int }
      [@@deriving version, bin_io]

      let to_latest = Fn.id
    end
  end]

  type t = Stable.Latest.t =
    { public_inputs: int
    ; variables: int
    ; constraints: int
    ; nonzero_entries: int
    ; max_degree: int }
end

module Repr = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        { commitments:
            G.Affine.Stable.V1.t array Abc.Stable.V1.t Matrix_evals.Stable.V1.t
        ; step_domains: Domains.Stable.V1.t array
        ; data: Data.Stable.V1.t }
      [@@deriving version, bin_io]

      let to_latest = Fn.id
    end
  end]

  type t = Stable.Latest.t =
    { commitments: G.Affine.t array Abc.t Matrix_evals.t
    ; step_domains: Domains.t array
    ; data: Data.t }
end

type t =
  { commitments: G.Affine.t array Abc.t Matrix_evals.t
  ; step_domains: Domains.t array
  ; index: Impls.Dlog_based.Verification_key.t
  ; data: Data.t }

let of_repr urs {Repr.commitments= c; step_domains; data= d} =
  let u = Unsigned.Size_t.of_int in
  let g = Zexe_backend.Fq_poly_comm.without_degree_bound_to_backend in
  let t =
    Snarky_bn382.Fq_verifier_index.make (u d.public_inputs) (u d.variables)
      (u d.constraints) (u d.nonzero_entries) (u d.max_degree) urs (g c.row.a)
      (g c.col.a) (g c.value.a) (g c.rc.a) (g c.row.b) (g c.col.b)
      (g c.value.b) (g c.rc.b) (g c.row.c) (g c.col.c) (g c.value.c) (g c.rc.c)
  in
  {commitments= c; step_domains; data= d; index= t}

include Binable.Of_binable
          (Repr.Stable.Latest)
          (struct
            type nonrec t = t

            let to_binable {commitments; step_domains; data; index= _} =
              {Repr.commitments; data; step_domains}

            let of_binable r =
              of_repr (Zexe_backend.Dlog_based.Keypair.load_urs ()) r
          end)

let dummy =
  let lengths = Commitment_lengths.of_domains Common.wrap_domains in
  let g = G.(to_affine_exn one) in
  let e = Abc.map lengths.row ~f:(fun len -> Array.create ~len g) in
  { Repr.commitments= {row= e; col= e; value= e; rc= e}
  ; step_domains= [||]
  ; data=
      { public_inputs= 0
      ; variables= 0
      ; constraints= 0
      ; nonzero_entries= 0
      ; max_degree= 0 } }
  |> of_repr (Snarky_bn382.Fq_urs.create Unsigned.Size_t.one)
