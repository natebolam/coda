(** The data structure underlying the transaction pool. We want to efficently
    support all the operations necessary. We also need to make sure that an
    attacker can't craft transactions or sequences thereof that take up an
    unacceptable amount of resources leading to a DoS.
*)
open Core

open Coda_base
open Coda_numbers

val replace_fee : Currency.Fee.t

(** Transaction pool. This is a purely functional data structure. *)
type t [@@deriving sexp_of]

(* TODO sexp is debug only, remove *)

(** Empty pool *)
val empty : constraint_constants:Genesis_constants.Constraint_constants.t -> t

(** How many transactions are currently in the pool *)
val size : t -> int

(** What is the lowest fee transaction in the pool *)
val min_fee : t -> Currency.Fee.t option

(** Remove the lowest fee command from the pool, along with any others from the
    same account with higher nonces. *)
val remove_lowest_fee : t -> User_command.With_valid_signature.t Sequence.t * t

(** Get the highest fee applicable command in the pool *)
val get_highest_fee : t -> User_command.With_valid_signature.t option

(** Call this when a transaction is added to the best tip or when generating a
    sequence of transactions to apply. This will drop any transactions at that
    nonce from the pool. May also drop queued commands for that sender if there
    was a different queued transaction from that sender at that nonce, and the
    committed one consumes more currency than the queued one. In that case it'll
    return the dropped ones in the sequence, including the one with the same
    nonce as the committed one if it's different.
*)
val handle_committed_txn :
     t
  -> User_command.With_valid_signature.t
  -> fee_payer_balance:Currency.Amount.t
  -> ( t * User_command.With_valid_signature.t Sequence.t
     , [ `Queued_txns_by_sender of
         string * User_command.With_valid_signature.t Sequence.t ] )
     Result.t

(** Add a command to the pool. Pass the current nonce for the account and
    its current balance. Throws if the contents of the pool before adding the
    new command are invalid given the supplied current nonce and balance - you
    are required to keep the pool in sync with the ledger you are applying
    transactions against.
*)
val add_from_gossip_exn :
     t
  -> User_command.With_valid_signature.t
  -> Account_nonce.t
  -> Currency.Amount.t
  -> ( t * User_command.With_valid_signature.t Sequence.t
     , [> `Invalid_nonce of
          [ `Expected of Account.Nonce.t
          | `Between of Account.Nonce.t * Account.Nonce.t ]
          * Account.Nonce.t
       | `Insufficient_funds of
         [`Balance of Currency.Amount.t] * Currency.Amount.t
       | (* NOTE: don't punish for this, attackers can induce nodes to banlist
          each other that way! *)
         `Insufficient_replace_fee of
         [`Replace_fee of Currency.Fee.t] * Currency.Fee.t
       | `Overflow ] )
     Result.t
(** Returns the commands dropped as a result of adding the command, which will
    be empty unless we're replacing one. *)

(** Add a command to the pool that was removed from the best tip because we're
    switching chains. Must be called in reverse order i.e. newest-to-oldest.
*)
val add_from_backtrack : t -> User_command.With_valid_signature.t -> t

(** Check whether a command is in the pool *)
val member : t -> User_command.With_valid_signature.t -> bool

(* Get all the user commands sent by a user with a particular account *)
val all_from_account :
  t -> Account_id.t -> User_command.With_valid_signature.t list

(** Check the contents of the pool are valid against the current ledger. Call
    this whenever the transition frontier is (re)created.
*)
val revalidate :
     t
  -> (Account_id.t -> Account_nonce.t * Currency.Amount.t)
     (** Lookup an account in the new ledger *)
  -> t * User_command.With_valid_signature.t Sequence.t

module For_tests : sig
  (** Checks the invariants of the data structure. If this throws an exception
      there is a bug. *)
  val assert_invariants : t -> unit
end
