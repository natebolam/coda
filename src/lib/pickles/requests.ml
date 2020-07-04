open Core
open Import
open Types
open Pickles_types
open Hlist
open Snarky.Request
open Common

module Wrap = struct
  module type S = sig
    type max_branching

    type max_local_max_branchings

    open Impls.Dlog_based
    open Dlog_main_inputs
    open Snarky.Request

    type _ t +=
      | Evals :
          ( ( Field.Constant.t array Dlog_marlin_types.Evals.t
            * Field.Constant.t )
            Tuple_lib.Triple.t
          , max_branching )
          Vector.t
          t
      | Index : int t
      | Pairing_accs : (Pairing_acc.t, max_branching) Vector.t t
      | Old_bulletproof_challenges :
          max_local_max_branchings H1.T(Challenges_vector.Constant).t t
      | Proof_state :
          ( ( ( Challenge.Constant.t
              , Challenge.Constant.t Scalar_challenge.t
              , Field.Constant.t
              , ( ( Challenge.Constant.t Scalar_challenge.t
                  , bool )
                  Bulletproof_challenge.t
                , Rounds.n )
                Vector.t
              , Digest.Constant.t )
              Types.Pairing_based.Proof_state.Per_proof.t
              * bool
            , max_branching )
            Vector.t
          , Digest.Constant.t )
          Types.Pairing_based.Proof_state.t
          t
      | Messages :
          (G1.Constant.t, Zexe_backend.Fp.t) Pairing_marlin_types.Messages.t t
      | Openings_proof : G1.Constant.t Tuple_lib.Triple.t t
  end

  type ('mb, 'ml) t =
    (module S
       with type max_branching = 'mb
        and type max_local_max_branchings = 'ml)

  let create : type mb ml. unit -> (mb, ml) t =
   fun () ->
    let module R = struct
      type nonrec max_branching = mb

      type nonrec max_local_max_branchings = ml

      open Zexe_backend
      open Snarky.Request

      type 'a vec = ('a, max_branching) Vector.t

      type _ t +=
        | Evals :
            (Fq.t array Dlog_marlin_types.Evals.t * Fq.t) Tuple_lib.Triple.t
            vec
            t
        | Index : int t
        | Pairing_accs :
            ( G1.Affine.t
            , G1.Affine.t Int.Map.t )
            Pairing_marlin_types.Accumulator.t
            vec
            t
        | Old_bulletproof_challenges :
            max_local_max_branchings H1.T(Challenges_vector.Constant).t t
        | Proof_state :
            ( ( ( Challenge.Constant.t
                , Challenge.Constant.t Scalar_challenge.t
                , Fq.t
                , ( ( Challenge.Constant.t Scalar_challenge.t
                    , bool )
                    Bulletproof_challenge.t
                  , Rounds.n )
                  Vector.t
                , Digest.Constant.t )
                Types.Pairing_based.Proof_state.Per_proof.t
                * bool
              , max_branching )
              Vector.t
            , Digest.Constant.t )
            Types.Pairing_based.Proof_state.t
            t
        | Messages : (G1.Affine.t, Fp.t) Pairing_marlin_types.Messages.t t
        | Openings_proof : G1.Affine.t Tuple_lib.Triple.t t
    end in
    (module R)
end

module Step = struct
  open Zexe_backend

  module type S = sig
    type statement

    type prev_values

    (* TODO: As an optimization this can be the local branching size *)
    type max_branching

    type local_signature

    type local_branches

    type _ t +=
      | Proof_with_datas :
          ( prev_values
          , local_signature
          , local_branches )
          H3.T(Per_proof_witness.Constant).t
          t
      | Me_only :
          ( G.Affine.t
          , statement
          , (G.Affine.t, max_branching) Vector.t )
          Types.Pairing_based.Proof_state.Me_only.t
          t
  end

  let create
      : type local_signature local_branches statement prev_values max_branching.
         unit
      -> (module S
            with type local_signature = local_signature
             and type local_branches = local_branches
             and type statement = statement
             and type prev_values = prev_values
             and type max_branching = max_branching) =
   fun () ->
    let module R = struct
      type nonrec max_branching = max_branching

      type nonrec statement = statement

      type nonrec prev_values = prev_values

      type nonrec local_signature = local_signature

      type nonrec local_branches = local_branches

      type _ t +=
        | Proof_with_datas :
            ( prev_values
            , local_signature
            , local_branches )
            H3.T(Per_proof_witness.Constant).t
            t
        | Me_only :
            ( G.Affine.t
            , statement
            , (G.Affine.t, max_branching) Vector.t )
            Types.Pairing_based.Proof_state.Me_only.t
            t
    end in
    (module R)
end
