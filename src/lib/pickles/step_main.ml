open Core
open Pickles_types
open Common
open Hlist
open Import

let index_commitment_length k =
  Int.round_up ~to_multiple_of:crs_max_degree (Domain.size k) / crs_max_degree

open Impls.Pairing_based
open Pairing_main_inputs
module B = Inductive_rule.B

(* The SNARK function corresponding to the input inductive rule. *)
let step_main
    : type branching self_branches prev_vars prev_values a_var a_value max_branching local_branches local_signature.
       (module Requests.Step.S
          with type local_signature = local_signature
           and type local_branches = local_branches
           and type statement = a_value
           and type prev_values = prev_values
           and type max_branching = max_branching)
    -> (module Nat.Add.Intf with type n = max_branching)
    -> self_branches:self_branches Nat.t
    -> local_signature:local_signature H1.T(Nat).t
    -> local_signature_length:(local_signature, branching) Hlist.Length.t
    -> local_branches:(* For each inner proof of type T , the number of branches that type T has. *)
       local_branches H1.T(Nat).t
    -> local_branches_length:(local_branches, branching) Hlist.Length.t
    -> branching:(prev_vars, branching) Hlist.Length.t
    -> lte:(branching, max_branching) Nat.Lte.t
    -> basic:( a_var
             , a_value
             , max_branching
             , self_branches )
             Types_map.Data.basic
    -> self:(a_var, a_value, max_branching, self_branches) Tag.t
    -> ( prev_vars
       , prev_values
       , local_signature
       , local_branches
       , a_var
       , a_value )
       Inductive_rule.t
    -> (   ( (Unfinalized.t, max_branching) Vector.t
           , Field.t
           , (Field.t, max_branching) Vector.t )
           Types.Pairing_based.Statement.t
        -> unit)
       Staged.t =
 fun (module Req) (module Max_branching) ~self_branches ~local_signature
     ~local_signature_length ~local_branches ~local_branches_length ~branching
     ~lte ~basic ~self rule ->
  let module T (F : T4) = struct
    type ('a, 'b, 'n, 'm) t =
      | Other of ('a, 'b, 'n, 'm) F.t
      | Self : (a_var, a_value, max_branching, self_branches) t
  end in
  let module D = T (Types_map.Data) in
  let module Typ_with_max_branching = struct
    type ('var, 'value, 'local_max_branching, 'local_branches) t =
      ( ('var, 'local_max_branching, 'local_branches) Per_proof_witness.t
      , ( 'value
        , 'local_max_branching
        , 'local_branches )
        Per_proof_witness.Constant.t )
      Typ.t
  end in
  let prev_typs =
    let rec join : type e pvars pvals ns1 ns2 br.
           (pvars, pvals, ns1, ns2) H4.T(Tag).t
        -> ns1 H1.T(Nat).t
        -> ns2 H1.T(Nat).t
        -> (pvars, br) Length.t
        -> (ns1, br) Length.t
        -> (ns2, br) Length.t
        -> (pvars, pvals, ns1, ns2) H4.T(Typ_with_max_branching).t =
     fun ds ns1 ns2 ld ln1 ln2 ->
      match (ds, ns1, ns2, ld, ln1, ln2) with
      | [], [], [], Z, Z, Z ->
          []
      | d :: ds, n1 :: ns1, n2 :: ns2, S ld, S ln1, S ln2 ->
          let typ =
            (fun (type var value n m) (d : (var, value, n, m) Tag.t) ->
              ( match Type_equal.Id.same_witness self d with
                | Some T ->
                    basic.typ
                | None ->
                    (Types_map.lookup d).typ
                : (var, value) Typ.t ) )
              d
          in
          let t = Per_proof_witness.typ typ n1 n2 in
          t :: join ds ns1 ns2 ld ln1 ln2
      | [], _, _, _, _, _ ->
          .
      | _ :: _, _, _, _, _, _ ->
          .
    in
    join rule.prevs local_signature local_branches branching
      local_signature_length local_branches_length
  in
  let module Prev_typ =
    H4.Typ (Impls.Pairing_based) (Typ_with_max_branching) (Per_proof_witness)
      (Per_proof_witness.Constant)
      (struct
        let f = Fn.id
      end)
  in
  let module Pseudo = Pseudo.Make (Impls.Pairing_based) in
  let main (stmt : _ Types.Pairing_based.Statement.t) =
    let open Requests.Step in
    let open Impls.Pairing_based in
    with_label "step_main" (fun () ->
        let module Prev_statement = struct
          open Impls.Pairing_based

          type 'a t =
            ( Challenge.t
            , Challenge.t Scalar_challenge.t
            , Fp.t
            , Boolean.var
            , unit
            , Digest.t
            , Digest.t )
            Types.Dlog_based.Proof_state.t
            * 'a
        end in
        let T = Max_branching.eq in
        let me_only =
          with_label "me_only" (fun () ->
              exists
                ~request:(fun () -> Req.Me_only)
                (Types.Pairing_based.Proof_state.Me_only.typ
                   (Typ.array G.typ
                      ~length:(index_commitment_length basic.wrap_domains.k))
                   G.typ basic.typ Max_branching.n) )
        in
        let datas =
          let self_data :
              ( a_var
              , a_value
              , max_branching
              , self_branches )
              Types_map.Data.For_step.t =
            { branches= self_branches
            ; max_branching= (module Max_branching)
            ; typ= basic.typ
            ; a_var_to_field_elements= basic.a_var_to_field_elements
            ; a_value_to_field_elements= basic.a_value_to_field_elements
            ; wrap_domains= basic.wrap_domains
            ; step_domains= basic.step_domains
            ; wrap_key= me_only.dlog_marlin_index }
          in
          let module M =
            H4.Map (Tag) (Types_map.Data.For_step)
              (struct
                let f : type a b n m.
                       (a, b, n, m) Tag.t
                    -> (a, b, n, m) Types_map.Data.For_step.t =
                 fun tag ->
                  match Type_equal.Id.same_witness self tag with
                  | Some T ->
                      self_data
                  | None ->
                      Types_map.Data.For_step.create (Types_map.lookup tag)
              end)
          in
          M.f rule.prevs
        in
        let prevs =
          exists (Prev_typ.f prev_typs) ~request:(fun () ->
              Req.Proof_with_datas )
        in
        let unfinalized_proofs =
          let module H = H1.Of_vector (Unfinalized) in
          H.f branching (Vector.trim stmt.proof_state.unfinalized_proofs lte)
        in
        let module Packed_digest = Field in
        let prev_statements =
          let module M =
            H3.Map1_to_H1 (Per_proof_witness) (Id)
              (struct
                let f : type a b c. (a, b, c) Per_proof_witness.t -> a =
                 fun (x, _, _, _, _, _) -> x
              end)
          in
          M.f prevs
        in
        let proofs_should_verify =
          with_label "rule_main" (fun () ->
              rule.main prev_statements me_only.app_state )
        in
        let module Proof = struct
          type t = Dlog_proof.var
        end in
        let open Pairing_main in
        let pass_throughs =
          with_label "pass_throughs" (fun () ->
              let module V = H1.Of_vector (Digest) in
              V.f branching
                (Vector.map
                   (Vector.trim stmt.pass_through lte)
                   ~f:(Field.unpack ~length:Digest.length)) )
        in
        let _prevs_verified =
          with_label "prevs_verified" (fun () ->
              let rec go : type vars vals ns1 ns2.
                     (vars, ns1, ns2) H3.T(Per_proof_witness).t
                  -> (vars, vals, ns1, ns2) H4.T(Types_map.Data.For_step).t
                  -> vars H1.T(E01(Digest)).t
                  -> vars H1.T(E01(Unfinalized)).t
                  -> vars H1.T(E01(B)).t
                  -> B.t list =
               fun proofs datas pass_throughs unfinalizeds should_verifys ->
                match
                  (proofs, datas, pass_throughs, unfinalizeds, should_verifys)
                with
                | [], [], [], [], [] ->
                    []
                | ( p :: proofs
                  , d :: datas
                  , pass_through :: pass_throughs
                  , (unfinalized, b) :: unfinalizeds
                  , should_verify :: should_verifys ) ->
                    Boolean.Assert.(b = should_verify) ;
                    let ( app_state
                        , which_index
                        , state
                        , prev_evals
                        , sg_old
                        , (opening, messages) ) =
                      p
                    in
                    let finalized =
                      let sponge_digest =
                        Fp.pack state.sponge_digest_before_evaluations
                      in
                      let sponge =
                        let open Pairing_main_inputs in
                        let sponge = Sponge.create sponge_params in
                        Sponge.absorb sponge (`Field sponge_digest) ;
                        sponge
                      in
                      let [domain_h; domain_k; input_domain] =
                        Vector.map
                          Domains.[h; k; x]
                          ~f:(fun f ->
                            Pseudo.Domain.to_domain
                              (which_index, Vector.map d.step_domains ~f) )
                      in
                      finalize_other_proof ~input_domain ~domain_k ~domain_h
                        ~sponge state.deferred_values prev_evals
                    in
                    (* TODO Use a pseudo sg old which masks out the extraneous sgs
                 for the index of this internal proof... *)
                    let statement =
                      let prev_me_only =
                        (* TODO: Don't rehash when it's not necessary *)
                        unstage
                          (hash_me_only ~index:d.wrap_key
                             d.a_var_to_field_elements)
                          {app_state; dlog_marlin_index= d.wrap_key; sg= sg_old}
                      in
                      { Types.Dlog_based.Statement.pass_through= prev_me_only
                      ; proof_state= {state with me_only= pass_through} }
                    in
                    let verified =
                      verify ~branching:d.max_branching
                        ~wrap_domains:(d.wrap_domains.h, d.wrap_domains.k)
                        ~is_base_case:should_verify ~sg_old ~opening ~messages
                        ~wrap_verification_key:d.wrap_key statement unfinalized
                    in
                    if debug then
                      as_prover
                        As_prover.(
                          fun () ->
                            let finalized = read Boolean.typ finalized in
                            let verified = read Boolean.typ verified in
                            let should_verify =
                              read Boolean.typ should_verify
                            in
                            printf "finalized: %b\n%!" finalized ;
                            printf "verified: %b\n%!" verified ;
                            printf "should_verify: %b\n\n%!" should_verify) ;
                    Boolean.((verified && finalized) || not should_verify)
                    :: go proofs datas pass_throughs unfinalizeds
                         should_verifys
              in
              Boolean.Assert.all
                (go prevs datas pass_throughs unfinalized_proofs
                   proofs_should_verify) )
        in
        let () =
          with_label "hash_me_only" (fun () ->
              let hash_me_only =
                unstage
                  (hash_me_only ~index:me_only.dlog_marlin_index
                     basic.a_var_to_field_elements)
              in
              Field.Assert.equal stmt.proof_state.me_only
                (Field.pack (hash_me_only me_only)) )
        in
        () )
  in
  stage main
