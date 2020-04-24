open Core
open Signature_lib
open Coda_base

let name = "transaction-snark-profiler"

(* We're just profiling, so okay to monkey-patch here *)
module Sparse_ledger = struct
  include Sparse_ledger

  let merkle_root t = Frozen_ledger_hash.of_ledger_hash @@ merkle_root t
end

let create_ledger_and_transactions num_transitions =
  let num_accounts = 4 in
  let ledger = Ledger.create () in
  let keys =
    Array.init num_accounts ~f:(fun _ -> Signature_lib.Keypair.create ())
  in
  Array.iter keys ~f:(fun k ->
      let public_key = Public_key.compress k.public_key in
      let account_id = Account_id.create public_key Token_id.default in
      Ledger.create_new_account_exn ledger account_id
        (Account.create account_id (Currency.Balance.of_int 10_000)) ) ;
  let txn (from_kp : Signature_lib.Keypair.t) (to_kp : Signature_lib.Keypair.t)
      amount fee nonce =
    let to_pk = Public_key.compress to_kp.public_key in
    let from_pk = Public_key.compress from_kp.public_key in
    let payload : User_command.Payload.t =
      User_command.Payload.create ~fee ~fee_token:Token_id.default
        ~fee_payer_pk:from_pk ~nonce ~memo:User_command_memo.dummy
        ~valid_until:Coda_numbers.Global_slot.max_value
        ~body:
          (Payment
             { source_pk= from_pk
             ; receiver_pk= to_pk
             ; token_id= Token_id.default
             ; amount })
    in
    User_command.sign from_kp payload
  in
  let nonces =
    Public_key.Compressed.Table.of_alist_exn
      (List.map (Array.to_list keys) ~f:(fun k ->
           (Public_key.compress k.public_key, Account.Nonce.zero) ))
  in
  let random_transaction () : User_command.With_valid_signature.t =
    let sender_idx = Random.int num_accounts in
    let sender = keys.(sender_idx) in
    let receiver = keys.(Random.int num_accounts) in
    let sender_pk = Public_key.compress sender.public_key in
    let nonce = Hashtbl.find_exn nonces sender_pk in
    Hashtbl.change nonces sender_pk ~f:(Option.map ~f:Account.Nonce.succ) ;
    let fee = Currency.Fee.of_int (1 + Random.int 100) in
    let amount = Currency.Amount.of_int (1 + Random.int 100) in
    txn sender receiver amount fee nonce
  in
  match num_transitions with
  | `Count n ->
      let num_transactions = n - 2 in
      let transactions =
        List.rev
          (List.init num_transactions ~f:(fun _ -> random_transaction ()))
      in
      let fee_transfer =
        let open Currency.Fee in
        let total_fee =
          List.fold transactions ~init:zero ~f:(fun acc t ->
              Option.value_exn
                (add acc
                   (User_command.Payload.fee (t :> User_command.t).payload)) )
        in
        `One (Public_key.compress keys.(0).public_key, total_fee)
      in
      let coinbase =
        Coinbase.create ~amount:Coda_compile_config.coinbase
          ~receiver:(Public_key.compress keys.(0).public_key)
          ~fee_transfer:None
        |> Or_error.ok_exn
      in
      let transitions =
        List.map transactions ~f:(fun t -> Transaction.User_command t)
        @ [Coinbase coinbase; Fee_transfer fee_transfer]
      in
      (ledger, transitions)
  | `Two_from_same ->
      let a =
        txn keys.(0) keys.(1)
          (Currency.Amount.of_int 10)
          Currency.Fee.zero Account.Nonce.zero
      in
      let b =
        txn keys.(0) keys.(1)
          (Currency.Amount.of_int 10)
          Currency.Fee.zero
          (Account.Nonce.succ Account.Nonce.zero)
      in
      (ledger, [User_command a; User_command b])

let time thunk =
  let start = Time.now () in
  let x = thunk () in
  let stop = Time.now () in
  (Time.diff stop start, x)

let rec pair_up = function
  | [] ->
      []
  | x :: y :: xs ->
      (x, y) :: pair_up xs
  | _ ->
      failwith "Expected even length list"

let state_body_hash = Quickcheck.random_value State_body_hash.gen

let pending_coinbase_stack_target (t : Transaction.t) stack =
  let stack_with_state =
    Pending_coinbase.Stack.(push_state state_body_hash stack)
  in
  let target =
    match t with
    | Coinbase c ->
        Pending_coinbase.(Stack.push_coinbase c stack_with_state)
    | _ ->
        stack_with_state
  in
  (target, state_body_hash)

(* This gives the "wall-clock time" to snarkify the given list of transactions, assuming
   unbounded parallelism. *)
let profile (module T : Transaction_snark.S) sparse_ledger0
    (transitions : Transaction.t list) preeval =
  let (base_proof_time, _, _), base_proofs =
    List.fold_map transitions
      ~init:(Time.Span.zero, sparse_ledger0, Pending_coinbase.Stack.empty)
      ~f:(fun (max_span, sparse_ledger, coinbase_stack_source) t ->
        let sparse_ledger' =
          Sparse_ledger.apply_transaction_exn sparse_ledger t
        in
        let coinbase_stack_target, state_body_hash =
          pending_coinbase_stack_target t coinbase_stack_source
        in
        let state_body_hash_opt = Some state_body_hash in
        let span, proof =
          time (fun () ->
              T.of_transaction ?preeval ~sok_digest:Sok_message.Digest.default
                ~source:(Sparse_ledger.merkle_root sparse_ledger)
                ~target:(Sparse_ledger.merkle_root sparse_ledger')
                ~pending_coinbase_stack_state:
                  {source= coinbase_stack_source; target= coinbase_stack_target}
                { Transaction_protocol_state.Poly.transaction= t
                ; block_data= state_body_hash_opt }
                (unstage (Sparse_ledger.handler sparse_ledger)) )
        in
        ( (Time.Span.max span max_span, sparse_ledger', coinbase_stack_target)
        , proof ) )
  in
  let rec merge_all serial_time proofs =
    match proofs with
    | [_] ->
        serial_time
    | _ ->
        let layer_time, new_proofs =
          List.fold_map (pair_up proofs) ~init:Time.Span.zero
            ~f:(fun max_time (x, y) ->
              let pair_time, proof =
                time (fun () ->
                    T.merge ~sok_digest:Sok_message.Digest.default x y
                    |> Or_error.ok_exn )
              in
              (Time.Span.max max_time pair_time, proof) )
        in
        merge_all (Time.Span.( + ) serial_time layer_time) new_proofs
  in
  let total_time = merge_all base_proof_time base_proofs in
  Printf.sprintf !"Total time was: %{Time.Span}" total_time

let check_base_snarks sparse_ledger0 (transitions : Transaction.t list) preeval
    =
  let _ =
    let sok_message =
      Sok_message.create ~fee:Currency.Fee.zero
        ~prover:
          Public_key.(compress (of_private_key_exn (Private_key.create ())))
    in
    List.fold transitions ~init:sparse_ledger0 ~f:(fun sparse_ledger t ->
        let sparse_ledger' =
          Sparse_ledger.apply_transaction_exn sparse_ledger t
        in
        let coinbase_stack_target, state_body_hash =
          pending_coinbase_stack_target t Pending_coinbase.Stack.empty
        in
        let state_body_hash_opt = Some state_body_hash in
        let () =
          Transaction_snark.check_transaction ?preeval ~sok_message
            ~source:(Sparse_ledger.merkle_root sparse_ledger)
            ~target:(Sparse_ledger.merkle_root sparse_ledger')
            ~pending_coinbase_stack_state:
              { source= Pending_coinbase.Stack.empty
              ; target= coinbase_stack_target }
            { Transaction_protocol_state.Poly.block_data= state_body_hash_opt
            ; transaction= t }
            (unstage (Sparse_ledger.handler sparse_ledger))
        in
        sparse_ledger' )
  in
  "Base constraint system satisfied"

let generate_base_snarks_witness sparse_ledger0
    (transitions : Transaction.t list) preeval =
  let _ =
    let sok_message =
      Sok_message.create ~fee:Currency.Fee.zero
        ~prover:
          Public_key.(compress (of_private_key_exn (Private_key.create ())))
    in
    List.fold transitions ~init:sparse_ledger0 ~f:(fun sparse_ledger t ->
        let sparse_ledger' =
          Sparse_ledger.apply_transaction_exn sparse_ledger t
        in
        let coinbase_stack_target, state_body_hash =
          pending_coinbase_stack_target t Pending_coinbase.Stack.empty
        in
        let state_body_hash_opt = Some state_body_hash in
        let () =
          Transaction_snark.generate_transaction_witness ?preeval ~sok_message
            ~source:(Sparse_ledger.merkle_root sparse_ledger)
            ~target:(Sparse_ledger.merkle_root sparse_ledger')
            { Transaction_snark.Pending_coinbase_stack_state.source=
                Pending_coinbase.Stack.empty
            ; target= coinbase_stack_target }
            { Transaction_protocol_state.Poly.transaction= t
            ; block_data= state_body_hash_opt }
            (unstage (Sparse_ledger.handler sparse_ledger))
        in
        sparse_ledger' )
  in
  "Base constraint system satisfied"

let run profiler num_transactions repeats preeval =
  let ledger, transitions = create_ledger_and_transactions num_transactions in
  let aid_of_pk pk = Account_id.create pk Token_id.default in
  let sparse_ledger =
    Coda_base.Sparse_ledger.of_ledger_subset_exn ledger
      (List.concat_map transitions ~f:(fun t ->
           match t with
           | Fee_transfer t ->
               One_or_two.map t ~f:(fun (pk, _) -> aid_of_pk pk)
               |> One_or_two.to_list
           | User_command t ->
               let t = (t :> User_command.t) in
               User_command.accounts_accessed t
           | Coinbase cb ->
               Coinbase.accounts_accessed cb ))
  in
  for i = 1 to repeats do
    let message = profiler sparse_ledger transitions preeval in
    Core.printf !"[%i] %s\n%!" i message
  done ;
  exit 0

let main num_transactions repeats preeval () =
  Snarky.Libsnark.set_no_profiling false ;
  Snarky.Libsnark.set_printing_off () ;
  Test_util.with_randomness 123456789 (fun () ->
      let keys = Transaction_snark.Keys.create () in
      let module T = Transaction_snark.Make (struct
        let keys = keys
      end) in
      run (profile (module T)) num_transactions repeats preeval )

let dry num_transactions repeats preeval () =
  Test_util.with_randomness 123456789 (fun () ->
      run check_base_snarks num_transactions repeats preeval )

let witness num_transactions repeats preeval () =
  Test_util.with_randomness 123456789 (fun () ->
      run generate_base_snarks_witness num_transactions repeats preeval )

let command =
  let open Command.Let_syntax in
  Command.basic ~summary:"transaction snark profiler"
    (let%map_open n =
       flag "k"
         ~doc:
           "count count = log_2(number of transactions to snark) or none for \
            the mocked ones"
         (optional int)
     and repeats =
       flag "repeat" ~doc:"count number of times to repeat the profile"
         (optional int)
     and preeval =
       flag "preeval"
         ~doc:
           "true/false whether to pre-evaluate the checked computation to \
            cache interpreter and computation state"
         (optional bool)
     and check_only =
       flag "check-only"
         ~doc:"Just check base snarks, don't keys or time anything" no_arg
     and witness_only =
       flag "witness-only"
         ~doc:"Just generate the witnesses for the base snarks" no_arg
     in
     let num_transactions =
       Option.map n ~f:(fun n -> `Count (Int.pow 2 n))
       |> Option.value ~default:`Two_from_same
     in
     let repeats = Option.value repeats ~default:1 in
     if witness_only then witness num_transactions repeats preeval
     else if check_only then dry num_transactions repeats preeval
     else main num_transactions repeats preeval)
