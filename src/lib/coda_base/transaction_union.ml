open Core_kernel
open Signature_lib
open Snark_params.Tick
open Currency
module Tag = Transaction_union_tag
module Payload = Transaction_union_payload

type ('payload, 'pk, 'signature) t_ =
  {payload: 'payload; signer: 'pk; signature: 'signature}
[@@deriving eq, sexp, hash]

type t = (Payload.t, Public_key.t, Signature.t) t_

type var = (Payload.var, Public_key.var, Signature.var) t_

let typ : (var, t) Typ.t =
  let spec = Data_spec.[Payload.typ; Public_key.typ; Schnorr.Signature.typ] in
  let of_hlist
        : 'a 'b 'c. (unit, 'a -> 'b -> 'c -> unit) H_list.t -> ('a, 'b, 'c) t_
      =
    H_list.(fun [payload; signer; signature] -> {payload; signer; signature})
  in
  let to_hlist {payload; signer; signature} =
    H_list.[payload; signer; signature]
  in
  Typ.of_hlistable spec ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
    ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist

(** For SNARK purposes, we inject [Transaction.t]s into a single-variant 'tagged-union' record capable of
    representing all the variants. We interpret the fields of this union in different ways depending on
    the value of the [payload.body.tag] field, which represents which variant of [Transaction.t] the value
    corresponds to.

    Sometimes we interpret fields in surprising ways in different cases to save as much space in the SNARK as possible (e.g.,
    [payload.body.public_key] is interpreted as the recipient of a payment, the new delegate of a stake
    delegation command, and a fee transfer recipient for both coinbases and fee-transfers.
*)
let of_transaction : Transaction.t -> t = function
  | User_command cmd ->
      let User_command.Poly.{payload; signer; signature} =
        (cmd :> User_command.t)
      in
      { payload= Transaction_union_payload.of_user_command_payload payload
      ; signer
      ; signature }
  | Coinbase {receiver; fee_transfer; amount} ->
      let {Coinbase.Fee_transfer.receiver_pk= other_pk; fee= other_amount} =
        Option.value
          ~default:
            (Coinbase.Fee_transfer.create ~receiver_pk:receiver ~fee:Fee.zero)
          fee_transfer
      in
      { payload=
          { common=
              { fee= other_amount
              ; fee_token= Token_id.default
              ; fee_payer_pk= other_pk
              ; nonce= Account.Nonce.zero
              ; valid_until= Coda_numbers.Global_slot.max_value
              ; memo= User_command_memo.empty }
          ; body=
              { source_pk= other_pk
              ; receiver_pk= receiver
              ; token_id= Token_id.default
              ; amount
              ; tag= Tag.Coinbase } }
      ; signer= Public_key.decompress_exn other_pk
      ; signature= Signature.dummy }
  | Fee_transfer tr -> (
      let two {Fee_transfer.receiver_pk= pk1; fee= fee1; fee_token}
          {Fee_transfer.receiver_pk= pk2; fee= fee2; fee_token= token_id} : t =
        { payload=
            { common=
                { fee= fee2
                ; fee_token
                ; fee_payer_pk= pk2
                ; nonce= Account.Nonce.zero
                ; valid_until= Coda_numbers.Global_slot.max_value
                ; memo= User_command_memo.empty }
            ; body=
                { source_pk= pk1
                ; receiver_pk= pk1
                ; token_id
                ; amount= Amount.of_fee fee1
                ; tag= Tag.Fee_transfer } }
        ; signer= Public_key.decompress_exn pk2
        ; signature= Signature.dummy }
      in
      match Fee_transfer.to_singles tr with
      | `One ({receiver_pk; fee= _; fee_token} as t) ->
          two t
            (Fee_transfer.Single.create ~receiver_pk ~fee:Fee.zero ~fee_token)
      | `Two (t1, t2) ->
          two t1 t2 )

let fee_excess (t : t) = Transaction_union_payload.fee_excess t.payload

let supply_increase (t : t) =
  Transaction_union_payload.supply_increase t.payload

let next_available_token (t : t) tid =
  Transaction_union_payload.next_available_token t.payload tid
