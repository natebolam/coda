open Core_kernel
open Coda_base
open Signature_lib
open Currency

let pk = Public_key.Compressed.of_base58_check_exn

let sk = Private_key.of_base58_check_exn

module type Base_intf = sig
  val accounts : (Private_key.t option * Account.t) list Lazy.t
end

module Make_from_base (Base : Base_intf) : Intf.S = struct
  include Base

  (* TODO: #1488 compute this at compile time instead of lazily *)
  let t =
    let open Lazy.Let_syntax in
    let%map accounts = accounts in
    let ledger = Ledger.create_ephemeral () in
    List.iter accounts ~f:(fun (_, account) ->
        Ledger.create_new_account_exn ledger
          (Account.identifier account)
          account ) ;
    ledger

  let find_account_record_exn ~f =
    List.find_exn (Lazy.force accounts) ~f:(fun (_, account) -> f account)

  let find_new_account_record_exn old_account_pks =
    find_account_record_exn ~f:(fun new_account ->
        not
          (List.exists old_account_pks ~f:(fun old_account_pk ->
               Public_key.equal
                 (Public_key.decompress_exn (Account.public_key new_account))
                 old_account_pk )) )

  let keypair_of_account_record_exn (private_key, account) =
    let open Account in
    let sk_error_msg =
      "cannot access genesis ledger account private key "
      ^ "(HINT: did you forget to compile with `--profile=test`?)"
    in
    let pk_error_msg = "failed to decompress a genesis ledger public key" in
    let private_key = Option.value_exn private_key ~message:sk_error_msg in
    let public_key =
      Option.value_exn
        (Public_key.decompress account.Poly.Stable.Latest.public_key)
        ~message:pk_error_msg
    in
    {Keypair.public_key; private_key}

  let largest_account_exn =
    let error_msg =
      "cannot calculate largest account in genesis ledger: "
      ^ "genesis ledger has no accounts"
    in
    Memo.unit (fun () ->
        List.max_elt (Lazy.force accounts) ~compare:(fun (_, a) (_, b) ->
            Balance.compare a.balance b.balance )
        |> Option.value_exn ?here:None ?error:None ~message:error_msg )

  let largest_account_keypair_exn =
    Memo.unit (fun () -> keypair_of_account_record_exn (largest_account_exn ()))
end

module With_private = struct
  type account_data =
    {pk: Public_key.Compressed.t; sk: Private_key.t; balance: int}

  module type Source_intf = sig
    val accounts : account_data list Lazy.t
  end

  module Make (Source : Source_intf) : Intf.S = struct
    include Make_from_base (struct
      let accounts =
        let open Lazy.Let_syntax in
        let%map accounts = Source.accounts in
        List.map accounts ~f:(fun {pk; sk; balance} ->
            ( Some sk
            , Account.create
                (Account_id.create pk Token_id.default)
                (Balance.of_formatted_string (Int.to_string balance)) ) )
    end)
  end
end

module Without_private = struct
  type account_data =
    { pk: Public_key.Compressed.t
    ; balance: int
    ; delegate: Public_key.Compressed.t option }

  module type Source_intf = sig
    val accounts : account_data list Lazy.t
  end

  module Make (Source : Source_intf) : Intf.S = struct
    include Make_from_base (struct
      let accounts =
        let open Lazy.Let_syntax in
        let%map accounts = Source.accounts in
        List.map accounts ~f:(fun {pk; balance; delegate} ->
            let account_id = Account_id.create pk Token_id.default in
            let base_acct =
              Account.create account_id (Balance.of_int balance)
            in
            (None, {base_acct with delegate= Option.value ~default:pk delegate})
        )
    end)
  end
end
