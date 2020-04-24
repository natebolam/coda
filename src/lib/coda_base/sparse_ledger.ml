open Core
open Import
open Snark_params.Tick

[%%versioned
module Stable = struct
  module V1 = struct
    type t =
      ( Ledger_hash.Stable.V1.t
      , Account_id.Stable.V1.t
      , Account.Stable.V1.t )
      Sparse_ledger_lib.Sparse_ledger.T.Stable.V1.t
    [@@deriving to_yojson, sexp]

    let to_latest = Fn.id
  end
end]

type t = Stable.Latest.t [@@deriving sexp]

module Hash = struct
  include Ledger_hash

  let merge = Ledger_hash.merge
end

module Account = struct
  include Account

  let data_hash = Fn.compose Ledger_hash.of_digest Account.digest
end

module M = Sparse_ledger_lib.Sparse_ledger.Make (Hash) (Account_id) (Account)

[%%define_locally
M.
  ( of_hash
  , to_yojson
  , get_exn
  , path_exn
  , set_exn
  , find_index_exn
  , add_path
  , merkle_root
  , iteri )]

let of_root (h : Ledger_hash.t) =
  of_hash ~depth:Ledger.depth (Ledger_hash.of_digest (h :> Pedersen.Digest.t))

let of_ledger_root ledger = of_root (Ledger.merkle_root ledger)

let of_any_ledger (ledger : Ledger.Any_ledger.witness) =
  Ledger.Any_ledger.M.foldi ledger
    ~init:(of_root (Ledger.Any_ledger.M.merkle_root ledger))
    ~f:(fun _addr sparse_ledger account ->
      let loc =
        Option.value_exn
          (Ledger.Any_ledger.M.location_of_account ledger
             (Account.identifier account))
      in
      add_path sparse_ledger
        (Ledger.Any_ledger.M.merkle_path ledger loc)
        (Account.identifier account)
        (Option.value_exn (Ledger.Any_ledger.M.get ledger loc)) )

let of_ledger_subset_exn (oledger : Ledger.t) keys =
  let ledger = Ledger.copy oledger in
  let _, sparse =
    List.fold keys
      ~f:(fun (new_keys, sl) key ->
        match Ledger.location_of_account ledger key with
        | Some loc ->
            ( new_keys
            , add_path sl
                (Ledger.merkle_path ledger loc)
                key
                ( Ledger.get ledger loc
                |> Option.value_exn ?here:None ?error:None ?message:None ) )
        | None ->
            let path, acct = Ledger.create_empty ledger key in
            (key :: new_keys, add_path sl path key acct) )
      ~init:([], of_ledger_root ledger)
  in
  Debug_assert.debug_assert (fun () ->
      [%test_eq: Ledger_hash.t]
        (Ledger.merkle_root ledger)
        ((merkle_root sparse :> Pedersen.Digest.t) |> Ledger_hash.of_hash) ) ;
  sparse

let of_ledger_index_subset_exn (ledger : Ledger.Any_ledger.witness) indexes =
  List.fold indexes
    ~init:(of_root (Ledger.Any_ledger.M.merkle_root ledger))
    ~f:(fun acc i ->
      let account = Ledger.Any_ledger.M.get_at_index_exn ledger i in
      add_path acc
        (Ledger.Any_ledger.M.merkle_path_at_index_exn ledger i)
        (Account.identifier account)
        account )

let%test_unit "of_ledger_subset_exn with keys that don't exist works" =
  let keygen () =
    let privkey = Private_key.create () in
    (privkey, Public_key.of_private_key_exn privkey |> Public_key.compress)
  in
  Ledger.with_ledger ~f:(fun ledger ->
      let _, pub1 = keygen () in
      let _, pub2 = keygen () in
      let aid1 = Account_id.create pub1 Token_id.default in
      let aid2 = Account_id.create pub2 Token_id.default in
      let sl = of_ledger_subset_exn ledger [aid1; aid2] in
      [%test_eq: Ledger_hash.t]
        (Ledger.merkle_root ledger)
        ((merkle_root sl :> Pedersen.Digest.t) |> Ledger_hash.of_hash) )

let get_or_initialize_exn account_id t idx =
  let account = get_exn t idx in
  if Public_key.Compressed.(equal empty account.public_key) then
    let public_key = Account_id.public_key account_id in
    ( `Added
    , { account with
        delegate= public_key
      ; public_key
      ; token_id= Account_id.token_id account_id } )
  else (`Existed, account)

let sub_account_creation_fee action (amount : Currency.Amount.t) =
  if action = `Added then
    Option.value_exn
      Currency.Amount.(
        sub amount (of_fee Coda_compile_config.account_creation_fee))
  else amount

let apply_user_command_exn t
    ({signer; payload; signature= _} as user_command : User_command.t) =
  let open Currency in
  let signer_pk = Public_key.compress signer in
  (* TODO: Put actual value here. See issue #4036. *)
  let current_global_slot = Coda_numbers.Global_slot.zero in
  (* Fee-payer information *)
  let fee_token = User_command.fee_token user_command in
  let fee_payer = User_command.fee_payer user_command in
  let nonce = User_command.nonce user_command in
  assert (
    Public_key.Compressed.equal (Account_id.public_key fee_payer) signer_pk ) ;
  assert (Token_id.equal fee_token Token_id.default) ;
  let fee_payer_idx, fee_payer_account =
    let idx = find_index_exn t fee_payer in
    let account = get_exn t idx in
    assert (Account.Nonce.equal account.nonce nonce) ;
    let fee = User_command.fee user_command in
    let timing =
      Or_error.ok_exn
      @@ Transaction_logic.validate_timing ~txn_amount:(Amount.of_fee fee)
           ~txn_global_slot:current_global_slot ~account
    in
    ( idx
    , { account with
        nonce= Account.Nonce.succ account.nonce
      ; balance=
          Balance.sub_amount account.balance (Amount.of_fee fee)
          |> Option.value_exn ?here:None ?error:None ?message:None
      ; receipt_chain_hash=
          Receipt.Chain_hash.cons payload account.receipt_chain_hash
      ; timing } )
  in
  (* Charge the fee. *)
  let t = set_exn t fee_payer_idx fee_payer_account in
  let source = User_command.source user_command in
  let receiver = User_command.receiver user_command in
  let exception Reject of exn in
  let compute_updates () =
    (* Raise an exception if any of the invariants for the user command are not
       satisfied, so that the command will not go through.

       This must re-check the conditions in Transaction_logic, to ensure that
       the failure cases are consistent.
    *)
    let () =
      (* TODO: Predicates. *)
      assert (
        Public_key.Compressed.equal
          (User_command.fee_payer_pk user_command)
          (User_command.source_pk user_command) )
    in
    match User_command.Payload.body payload with
    | Stake_delegation _ ->
        let receiver_account = get_exn t @@ find_index_exn t receiver in
        (* Check that receiver account exists. *)
        assert (
          not Public_key.Compressed.(equal empty receiver_account.public_key)
        ) ;
        let source_idx = find_index_exn t source in
        let source_account = get_exn t source_idx in
        (* Check that source account exists. *)
        assert (
          not Public_key.Compressed.(equal empty source_account.public_key) ) ;
        let source_account =
          {source_account with delegate= Account_id.public_key receiver}
        in
        [(source_idx, source_account)]
    | Payment {amount; token_id= token; _} ->
        let receiver_idx = find_index_exn t receiver in
        let action, receiver_account =
          get_or_initialize_exn receiver t receiver_idx
        in
        let receiver_amount, creation_fee =
          if Token_id.equal fee_token token then
            (sub_account_creation_fee action amount, Amount.zero)
          else if action = `Added then
            let account_creation_fee =
              Amount.of_fee Coda_compile_config.account_creation_fee
            in
            (amount, account_creation_fee)
          else (amount, Amount.zero)
        in
        let fee_payer_account =
          { fee_payer_account with
            balance=
              Balance.sub_amount fee_payer_account.balance creation_fee
              |> Option.value_exn ?here:None ?error:None ?message:None
          ; timing=
              Or_error.ok_exn
              @@ Transaction_logic.validate_timing ~txn_amount:creation_fee
                   ~txn_global_slot:current_global_slot
                   ~account:fee_payer_account }
        in
        let receiver_account =
          { receiver_account with
            balance=
              Balance.add_amount receiver_account.balance receiver_amount
              |> Option.value_exn ?here:None ?error:None ?message:None }
        in
        let source_idx = find_index_exn t source in
        let source_account =
          let account =
            if Account_id.equal source receiver then (
              assert (action = `Existed) ;
              receiver_account )
            else get_exn t source_idx
          in
          (* Check that source account exists. *)
          assert (not Public_key.Compressed.(equal empty account.public_key)) ;
          try
            { account with
              balance=
                Balance.sub_amount account.balance amount
                |> Option.value_exn ?here:None ?error:None ?message:None
            ; timing=
                Or_error.ok_exn
                @@ Transaction_logic.validate_timing ~txn_amount:amount
                     ~txn_global_slot:current_global_slot ~account }
          with exn when Account_id.equal fee_payer source ->
            (* Don't process transactions with insufficient balance from the
               fee-payer.
            *)
            raise (Reject exn)
        in
        [ (fee_payer_idx, fee_payer_account)
        ; (receiver_idx, receiver_account)
        ; (source_idx, source_account) ]
  in
  try
    let indexed_accounts = compute_updates () in
    (* User command succeeded, update accounts in the ledger. *)
    List.fold ~init:t indexed_accounts ~f:(fun t (idx, account) ->
        set_exn t idx account )
  with
  | Reject exn ->
      (* TODO: These transactions should never reach this stage, this error
         should be fatal.
      *)
      raise exn
  | _ ->
      (* Not able to apply the user command successfully, charge fee only. *)
      t

let apply_fee_transfer_exn =
  let apply_single t ((pk, fee) : Fee_transfer.Single.t) =
    let account_id = Account_id.create pk Token_id.default in
    let index = find_index_exn t account_id in
    let action, account = get_or_initialize_exn account_id t index in
    let open Currency in
    let amount = Amount.of_fee fee in
    let balance =
      let amount' = sub_account_creation_fee action amount in
      Option.value_exn (Balance.add_amount account.balance amount')
    in
    set_exn t index {account with balance}
  in
  fun t transfer -> One_or_two.fold transfer ~f:apply_single ~init:t

let apply_coinbase_exn t
    ({receiver; fee_transfer; amount= coinbase_amount} : Coinbase.t) =
  let open Currency in
  let add_to_balance t pk amount =
    let idx = find_index_exn t pk in
    let action, a = get_or_initialize_exn pk t idx in
    let balance =
      let amount' = sub_account_creation_fee action amount in
      Option.value_exn (Balance.add_amount a.balance amount')
    in
    set_exn t idx {a with balance}
  in
  let receiver_reward, t =
    match fee_transfer with
    | None ->
        (coinbase_amount, t)
    | Some ({receiver_pk= _; fee} as ft) ->
        let fee = Amount.of_fee fee in
        let reward =
          Amount.sub coinbase_amount fee
          |> Option.value_exn ?here:None ?message:None ?error:None
        in
        let transferee_id = Coinbase.Fee_transfer.receiver ft in
        (reward, add_to_balance t transferee_id fee)
  in
  let receiver_id = Account_id.create receiver Token_id.default in
  add_to_balance t receiver_id receiver_reward

let apply_transaction_exn t (transition : Transaction.t) =
  match transition with
  | Fee_transfer tr ->
      apply_fee_transfer_exn t tr
  | User_command cmd ->
      apply_user_command_exn t (cmd :> User_command.t)
  | Coinbase c ->
      apply_coinbase_exn t c

let merkle_root t = Ledger_hash.of_hash (merkle_root t :> Pedersen.Digest.t)

let handler t =
  let ledger = ref t in
  let path_exn idx =
    List.map (path_exn !ledger idx) ~f:(function `Left h -> h | `Right h -> h)
  in
  stage (fun (With {request; respond}) ->
      match request with
      | Ledger_hash.Get_element idx ->
          let elt = get_exn !ledger idx in
          let path = (path_exn idx :> Pedersen.Digest.t list) in
          respond (Provide (elt, path))
      | Ledger_hash.Get_path idx ->
          let path = (path_exn idx :> Pedersen.Digest.t list) in
          respond (Provide path)
      | Ledger_hash.Set (idx, account) ->
          ledger := set_exn !ledger idx account ;
          respond (Provide ())
      | Ledger_hash.Find_index pk ->
          let index = find_index_exn !ledger pk in
          respond (Provide index)
      | _ ->
          unhandled )
