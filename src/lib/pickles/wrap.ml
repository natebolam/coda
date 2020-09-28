module SC = Scalar_challenge
module P = Proof
open Pickles_types
open Hlist
open Tuple_lib
open Common
open Core
open Import
open Types
open Backend

(* This contains the "wrap" prover *)

let vector_of_list (type a t)
    (module V : Snarky_intf.Vector.S with type elt = a and type t = t)
    (xs : a list) : t =
  let r = V.create () in
  List.iter xs ~f:(V.emplace_back r) ;
  r

let b_poly = Tick.Field.(Dlog_main.b_poly ~add ~mul ~inv)

let combined_inner_product (type actual_branching)
    ~actual_branching:(module AB : Nat.Add.Intf with type n = actual_branching)
    (e1, e2, e3) ~(old_bulletproof_challenges : (_, actual_branching) Vector.t)
    ~r ~xi ~beta_1 ~beta_2 ~beta_3 ~x_hat:(x_hat_1, x_hat_2, x_hat_3)
    ~(step_branch_domains : Domains.t) =
  let T = AB.eq in
  let b_polys =
    Vector.map
      ~f:(fun chals -> unstage (b_poly (Vector.to_array chals)))
      old_bulletproof_challenges
  in
  let pi = AB.add Nat.N19.n in
  let combine (x_hat : Tick.Field.t) pt e =
    let a, b = Dlog_marlin_types.Evals.(to_vectors (e : _ array t)) in
    let v : (Tick.Field.t array, _) Vector.t =
      Vector.append
        (Vector.map b_polys ~f:(fun f -> [|f pt|]))
        ([|x_hat|] :: a) (snd pi)
    in
    let open Tick.Field in
    Pcs_batch.combine_split_evaluations
      (Common.dlog_pcs_batch (AB.add Nat.N19.n)
         ~h_minus_1:Int.(Domain.size step_branch_domains.h - 1)
         ~k_minus_1:Int.(Domain.size step_branch_domains.k - 1))
      ~xi ~init:Fn.id ~mul
      ~mul_and_add:(fun ~acc ~xi fx -> fx + (xi * acc))
      ~last:Array.last ~evaluation_point:pt
      ~shifted_pow:(fun deg x ->
        Pcs_batch.pow ~one ~mul x
          Int.(Max_degree.step - (deg mod Max_degree.step)) )
      v b
  in
  let open Tick.Field in
  combine x_hat_1 beta_1 e1
  + (r * (combine x_hat_2 beta_2 e2 + (r * combine x_hat_3 beta_3 e3)))

module Pairing_acc = Tock.Inner_curve.Affine

(* The prover for wrapping a proof *)
let wrap (type actual_branching max_branching max_local_max_branchings)
    ~(max_branching : max_branching Nat.t)
    (module Max_local_max_branchings : Hlist.Maxes.S
      with type ns = max_local_max_branchings
       and type length = max_branching)
    ((module Req) : (max_branching, max_local_max_branchings) Requests.Wrap.t)
    ~dlog_marlin_index wrap_main to_field_elements ~pairing_vk ~step_domains
    ~wrap_domains ~pairing_marlin_indices pk
    ({statement= prev_statement; prev_evals; proof; index= which_index} :
      ( _
      , _
      , (_, actual_branching) Vector.t
      , (_, actual_branching) Vector.t
      , max_local_max_branchings H1.T(P.Base.Me_only.Dlog_based).t
      , ( (Tock.Field.t array Dlog_marlin_types.Evals.t * Tock.Field.t) Triple.t
        , max_branching )
        Vector.t )
      P.Base.Pairing_based.t) =
  (*
  let pairing_marlin_index =
    (Vector.to_array pairing_marlin_indices).(Index.to_int which_index)
  in
*)
  let prev_me_only =
    let module M =
      H1.Map (P.Base.Me_only.Dlog_based) (P.Base.Me_only.Dlog_based.Prepared)
        (struct
          let f = P.Base.Me_only.Dlog_based.prepare
        end)
    in
    M.f prev_statement.pass_through
  in
  let prev_statement_with_hashes : _ Types.Pairing_based.Statement.t =
    { proof_state=
        { prev_statement.proof_state with
          me_only=
            (* TODO: Careful here... the length of
               old_buletproof_challenges inside the me_only
               might not be correct *)
            Common.hash_pairing_me_only ~app_state:to_field_elements
              (P.Base.Me_only.Pairing_based.prepare ~dlog_marlin_index
                 prev_statement.proof_state.me_only) }
    ; pass_through=
        (let module M =
           H1.Map
             (P.Base.Me_only.Dlog_based.Prepared)
             (E01 (Digest.Constant))
             (struct
               let f (type n) (m : n P.Base.Me_only.Dlog_based.Prepared.t) =
                 let T =
                   Nat.eq_exn max_branching
                     (Vector.length m.old_bulletproof_challenges)
                 in
                 Common.hash_dlog_me_only max_branching m
             end)
         in
        let module V = H1.To_vector (Digest.Constant) in
        V.f Max_local_max_branchings.length (M.f prev_me_only)) }
  in
  let handler (Snarky_backendless.Request.With {request; respond}) =
    let open Req in
    let k x = respond (Provide x) in
    match request with
    | Evals ->
        k prev_evals
    | Step_accs ->
        let module M =
          H1.Map
            (P.Base.Me_only.Dlog_based.Prepared)
            (E01 (Pairing_acc))
            (struct
              let f : type a.
                  a P.Base.Me_only.Dlog_based.Prepared.t -> Pairing_acc.t =
               fun t -> t.sg
            end)
        in
        let module V = H1.To_vector (Pairing_acc) in
        k (V.f Max_local_max_branchings.length (M.f prev_me_only))
    | Old_bulletproof_challenges ->
        let module M =
          H1.Map
            (P.Base.Me_only.Dlog_based.Prepared)
            (Challenges_vector.Constant)
            (struct
              let f (t : _ P.Base.Me_only.Dlog_based.Prepared.t) =
                t.old_bulletproof_challenges
            end)
        in
        k (M.f prev_me_only)
    | Messages ->
        k proof.messages
    | Openings_proof ->
        k proof.openings.proof
    | Proof_state ->
        k prev_statement_with_hashes.proof_state
    | _ ->
        Snarky_backendless.Request.unhandled
  in
  let module O = Tick.Oracles in
  let public_input =
    tick_public_input_of_statement ~max_branching prev_statement_with_hashes
  in
  let prev_challenges =
    Vector.map ~f:Ipa.Step.compute_challenges
      prev_statement.proof_state.me_only.old_bulletproof_challenges
  in
  let actual_branching = Vector.length prev_challenges in
  let lte =
    Nat.lte_exn actual_branching
      (Length.to_nat Max_local_max_branchings.length)
  in
  let o =
    let sgs =
      let module M =
        H1.Map
          (P.Base.Me_only.Dlog_based.Prepared)
          (E01 (Tick.Curve.Affine))
          (struct
            let f : type n. n P.Base.Me_only.Dlog_based.Prepared.t -> _ =
             fun t -> t.sg
          end)
      in
      let module V = H1.To_vector (Tick.Curve.Affine) in
      V.f Max_local_max_branchings.length (M.f prev_me_only)
    in
    O.create pairing_vk
      Vector.(
        map2 (Vector.trim sgs lte) prev_challenges ~f:(fun commitment cs ->
            { Tick.Proof.Challenge_polynomial.commitment
            ; challenges= Vector.to_array cs } )
        |> to_list)
      public_input proof
  in
  let x_hat = O.x_hat o in
  let next_statement : _ Types.Dlog_based.Statement.t =
    let scalar_chal f =
      Scalar_challenge.map ~f:Challenge.Constant.of_tick_field (f o)
    in
    let sponge_digest_before_evaluations = O.digest_before_evaluations o in
    let r = scalar_chal O.evals in
    let xi = scalar_chal O.polys in
    let beta_1 = scalar_chal O.beta1 in
    let beta_2 = scalar_chal O.beta2 in
    let beta_3 = scalar_chal O.beta3 in
    let alpha = O.alpha o in
    let eta_a = O.eta_a o in
    let eta_b = O.eta_b o in
    let eta_c = O.eta_c o in
    let to_field =
      SC.to_field_constant (module Tick.Field) ~endo:Endo.Dum.scalar
    in
    let module As_field = struct
      let r = to_field r

      let xi = to_field xi

      let beta_1 = to_field beta_1

      let beta_2 = to_field beta_2

      let beta_3 = to_field beta_3
    end in
    let combined_inner_product =
      let open As_field in
      combined_inner_product (* Note: We do not pad here. *)
        ~actual_branching:(Nat.Add.create actual_branching)
        proof.openings.evals ~x_hat ~r ~xi ~beta_1 ~beta_2 ~beta_3
        ~step_branch_domains:step_domains
        ~old_bulletproof_challenges:prev_challenges
    in
    let me_only : _ P.Base.Me_only.Dlog_based.t =
      { sg= proof.openings.proof.sg
      ; old_bulletproof_challenges=
          Vector.map prev_statement.proof_state.unfinalized_proofs
            ~f:(fun (t, _) -> t.deferred_values.bulletproof_challenges) }
    in
    let chal = Challenge.Constant.of_tick_field in
    let new_bulletproof_challenges, b =
      let prechals =
        Array.map (O.opening_prechallenges o) ~f:(fun x ->
            let x =
              Scalar_challenge.map ~f:Challenge.Constant.of_tick_field x
            in
            (x, Tick.Field.is_square (to_field x)) )
      in
      let chals =
        Array.map prechals ~f:(fun (x, is_square) ->
            Ipa.Step.compute_challenge ~is_square x )
      in
      let b_poly = unstage (b_poly chals) in
      let open As_field in
      let b =
        let open Tick.Field in
        b_poly beta_1 + (r * (b_poly beta_2 + (r * b_poly beta_3)))
      in
      let prechals =
        Array.map prechals ~f:(fun (x, is_square) ->
            {Bulletproof_challenge.prechallenge= x; is_square} )
      in
      (prechals, b)
    in
    { proof_state=
        { deferred_values=
            { xi
            ; b
            ; bulletproof_challenges=
                Vector.of_array_and_length_exn new_bulletproof_challenges
                  Tick.Rounds.n
            ; combined_inner_product
            ; which_branch= which_index
            ; marlin=
                { sigma_2= fst proof.messages.sigma_gh_2
                ; sigma_3= fst proof.messages.sigma_gh_3
                ; alpha= chal alpha
                ; eta_a= chal eta_a
                ; eta_b= chal eta_b
                ; eta_c= chal eta_c
                ; beta_1
                ; beta_2
                ; beta_3 } }
        ; was_base_case=
            List.for_all
              ~f:(fun (_, should_verify) -> not should_verify)
              (Vector.to_list prev_statement.proof_state.unfinalized_proofs)
        ; sponge_digest_before_evaluations=
            Digest.Constant.of_tick_field sponge_digest_before_evaluations
        ; me_only }
    ; pass_through= prev_statement.proof_state.me_only }
  in
  let me_only_prepared =
    P.Base.Me_only.Dlog_based.prepare next_statement.proof_state.me_only
  in
  let next_proof =
    let (T (input, conv)) = Impls.Wrap.input () in
    Common.time "wrap proof" (fun () ->
        Impls.Wrap.prove pk
          ~message:
            ( Vector.map2
                (Vector.extend_exn prev_statement.proof_state.me_only.sg
                   max_branching
                   (Lazy.force Dummy.Ipa.Wrap.sg))
                me_only_prepared.old_bulletproof_challenges
                ~f:(fun sg chals ->
                  { Tock.Proof.Challenge_polynomial.commitment= sg
                  ; challenges= Vector.to_array chals } )
            |> Vector.to_list )
          [input]
          (fun x () ->
            ( Impls.Wrap.handle (fun () -> (wrap_main (conv x) : unit)) handler
              : unit ) )
          ()
          { pass_through= prev_statement_with_hashes.proof_state.me_only
          ; proof_state=
              { next_statement.proof_state with
                me_only=
                  Common.hash_dlog_me_only max_branching me_only_prepared } }
    )
  in
  ( { proof= next_proof
    ; statement= next_statement
    ; prev_evals= proof.openings.evals
    ; prev_x_hat= x_hat }
    : _ P.Base.Dlog_based.t )
