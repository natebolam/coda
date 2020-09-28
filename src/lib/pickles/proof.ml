open Core
open Pickles_types
open Import
open Types
open Common
open Backend

module Base = struct
  module Me_only = Reduced_me_only

  module Pairing_based = struct
    type ( 's
         , 'unfinalized_proofs
         , 'sgs
         , 'bp_chals
         , 'dlog_me_onlys
         , 'prev_evals )
         t =
      { statement:
          ( 'unfinalized_proofs
          , ('s, 'sgs, 'bp_chals) Me_only.Pairing_based.t
          , 'dlog_me_onlys )
          Types.Pairing_based.Statement.t
      ; index: Index.t
      ; prev_evals: 'prev_evals
      ; proof: Tick.Proof.t }
  end

  type 'a triple = 'a * 'a * 'a
  [@@deriving bin_io, compare, sexp, yojson, hash, eq]

  module Dlog_based = struct
    type ('dlog_me_only, 'pairing_me_only) t =
      { statement:
          ( Challenge.Constant.t
          , Challenge.Constant.t Scalar_challenge.Stable.Latest.t
          , Tick.Field.t
          , bool
          , Tock.Field.t
          , 'dlog_me_only
          , Digest.Constant.t
          , 'pairing_me_only
          , ( Challenge.Constant.t Scalar_challenge.Stable.Latest.t
            , bool )
            Bulletproof_challenge.t
            Step_bp_vec.t
          , Index.t )
          Types.Dlog_based.Statement.t
      ; prev_evals:
          Tick.Field.t Dlog_marlin_types.Pc_array.Stable.Latest.t
          Dlog_marlin_types.Evals.Stable.Latest.t
          triple
      ; prev_x_hat: Tick.Field.t triple
      ; proof: Tock.Proof.t }
    [@@deriving bin_io, compare, sexp, yojson, hash, eq]
  end
end

type ('s, 'mlmb, _) with_data =
  | T :
      ( 'mlmb Base.Me_only.Dlog_based.t
      , ( 's
        , (Tock.Curve.Affine.t, 'most_recent_width) Vector.t
        , ( ( Challenge.Constant.t Scalar_challenge.Stable.Latest.t
            , bool )
            Bulletproof_challenge.t
            Step_bp_vec.t
          , 'most_recent_width )
          Vector.t )
        Base.Me_only.Pairing_based.t )
      Base.Dlog_based.t
      -> ('s, 'mlmb, _) with_data

module With_data = struct
  type ('s, 'mlmb, 'w) t = ('s, 'mlmb, 'w) with_data
end

type ('max_width, 'mlmb) t = (unit, 'mlmb, 'max_width) With_data.t

let dummy (type w h r) (w : w Nat.t) (h : h Nat.t)
    (most_recent_width : r Nat.t) : (w, h) t =
  let open Ro in
  let g0 = Tock.Curve.(to_affine_exn one) in
  let g len = Array.create ~len g0 in
  let tock len = Array.init len ~f:(fun _ -> tock ()) in
  let tick_arr len = Array.init len ~f:(fun _ -> tick ()) in
  let lengths =
    Commitment_lengths.of_domains wrap_domains ~max_degree:Max_degree.wrap
  in
  T
    { statement=
        { proof_state=
            { deferred_values=
                { xi= scalar_chal ()
                ; combined_inner_product= tick ()
                ; b= tick ()
                ; which_branch= Option.value_exn (Index.of_int 0)
                ; bulletproof_challenges= Dummy.Ipa.Step.challenges
                ; marlin=
                    { sigma_2= tick ()
                    ; sigma_3= tick ()
                    ; alpha= chal ()
                    ; eta_a= chal ()
                    ; eta_b= chal ()
                    ; eta_c= chal ()
                    ; beta_1= scalar_chal ()
                    ; beta_2= scalar_chal ()
                    ; beta_3= scalar_chal () } }
            ; sponge_digest_before_evaluations=
                Digest.Constant.of_tock_field Tock.Field.zero
            ; was_base_case= true
            ; me_only=
                { sg= Lazy.force Dummy.Ipa.Step.sg
                ; old_bulletproof_challenges=
                    Vector.init h ~f:(fun _ -> Dummy.Ipa.Wrap.challenges) } }
        ; pass_through=
            { app_state= ()
            ; old_bulletproof_challenges=
                (* Not sure if this should be w or h honestly ...*)
                Vector.init most_recent_width ~f:(fun _ ->
                    Dummy.Ipa.Step.challenges )
                (* TODO: Should this be wrap? *)
            ; sg=
                Vector.init most_recent_width ~f:(fun _ ->
                    Lazy.force Dummy.Ipa.Wrap.sg ) } }
    ; proof=
        { messages=
            { w_hat= g lengths.w_hat
            ; z_hat_a= g lengths.z_hat_a
            ; z_hat_b= g lengths.z_hat_a
            ; gh_1= ({unshifted= g lengths.g_1; shifted= g0}, g lengths.h_1)
            ; sigma_gh_2=
                ( Ro.tock ()
                , ({unshifted= g lengths.g_2; shifted= g0}, g lengths.h_2) )
            ; sigma_gh_3=
                ( Ro.tock ()
                , ({unshifted= g lengths.g_3; shifted= g0}, g lengths.h_3) ) }
        ; openings=
            { proof=
                { lr=
                    Array.init (Nat.to_int Tock.Rounds.n) ~f:(fun _ -> (g0, g0))
                ; z_1= Ro.tock ()
                ; z_2= Ro.tock ()
                ; delta= g0
                ; sg= g0 }
            ; evals=
                (let e () = Dlog_marlin_types.Evals.map lengths ~f:tock in
                 (e (), e (), e ())) } }
    ; prev_evals=
        (let e () = Dlog_marlin_types.Evals.map lengths ~f:tick_arr in
         (e (), e (), e ()))
    ; prev_x_hat= (tick (), tick (), tick ()) }

module Make (W : Nat.Intf) (MLMB : Nat.Intf) = struct
  module Max_branching_at_most = At_most.With_length (W)
  module MLMB_vec = Nvector (MLMB)

  module Repr = struct
    type t =
      ( ( Tock.Inner_curve.Affine.t
        , Reduced_me_only.Dlog_based.Challenges_vector.t MLMB_vec.t )
        Dlog_based.Proof_state.Me_only.t
      , ( unit
        , Tock.Curve.Affine.t Max_branching_at_most.t
        , ( Challenge.Constant.t Scalar_challenge.Stable.Latest.t
          , bool )
          Bulletproof_challenge.t
          Step_bp_vec.t
          Max_branching_at_most.t )
        Base.Me_only.Pairing_based.t )
      Base.Dlog_based.t
    [@@deriving bin_io, compare, sexp, yojson, hash, eq]
  end

  type nonrec t = (W.n, MLMB.n) t

  let to_repr (T t) : Repr.t =
    let lte = Nat.lte_exn (Vector.length t.statement.pass_through.sg) W.n in
    { t with
      statement=
        { t.statement with
          pass_through=
            { t.statement.pass_through with
              sg= At_most.of_vector t.statement.pass_through.sg lte
            ; old_bulletproof_challenges=
                At_most.of_vector
                  t.statement.pass_through.old_bulletproof_challenges lte } }
    }

  let of_repr (r : Repr.t) : t =
    let (Vector.T sg) = At_most.to_vector r.statement.pass_through.sg in
    let (Vector.T old_bulletproof_challenges) =
      At_most.to_vector r.statement.pass_through.old_bulletproof_challenges
    in
    let T =
      Nat.eq_exn (Vector.length sg) (Vector.length old_bulletproof_challenges)
    in
    T
      { r with
        statement=
          { r.statement with
            pass_through=
              {r.statement.pass_through with sg; old_bulletproof_challenges} }
      }

  let compare t1 t2 = Repr.compare (to_repr t1) (to_repr t2)

  let equal t1 t2 = Repr.equal (to_repr t1) (to_repr t2)

  let hash_fold_t s t = Repr.hash_fold_t s (to_repr t)

  let hash t = Repr.hash (to_repr t)

  include Binable.Of_binable
            (Repr)
            (struct
              type nonrec t = t

              let to_binable = to_repr

              let of_binable = of_repr
            end)

  include Sexpable.Of_sexpable
            (Repr)
            (struct
              type nonrec t = t

              let to_sexpable = to_repr

              let of_sexpable = of_repr
            end)

  let to_yojson x = Repr.to_yojson (to_repr x)

  let of_yojson x = Result.map ~f:of_repr (Repr.of_yojson x)
end
