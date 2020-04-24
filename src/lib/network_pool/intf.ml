open Async_kernel
open Core_kernel
open Coda_base
open Pipe_lib
open Network_peer

(** A [Resource_pool_base_intf] is a mutable pool of resources that supports
 *  mutation via some [Resource_pool_diff_intf]. A [Resource_pool_base_intf]
 *  can only be initialized, and any interaction with it must go through
 *  its [Resource_pool_diff_intf] *)
module type Resource_pool_base_intf = sig
  type t [@@deriving sexp_of]

  type transition_frontier_diff

  type transition_frontier

  module Config : sig
    type t [@@deriving sexp_of]
  end

  (** Diff from a transition frontier extension that would update the resource pool*)
  val handle_transition_frontier_diff :
    transition_frontier_diff -> t -> unit Deferred.t

  val create :
       frontier_broadcast_pipe:transition_frontier Option.t
                               Broadcast_pipe.Reader.t
    -> config:Config.t
    -> logger:Logger.t
    -> tf_diff_writer:( transition_frontier_diff
                      , Strict_pipe.synchronous
                      , unit Deferred.t )
                      Strict_pipe.Writer.t
    -> t
end

(** A [Resource_pool_diff_intf] is a representation of a mutation to
 *  perform on a [Resource_pool_base_intf]. It includes the logic for
 *  processing this mutation and applying it to an underlying
 *  [Resource_pool_base_intf]. *)
module type Resource_pool_diff_intf = sig
  type pool

  type t [@@deriving sexp, to_yojson]

  (** Part of the diff that was not added to the resource pool*)
  type rejected [@@deriving sexp, to_yojson]

  val summary : t -> string

  (** Warning: Using this directly could corrupt the resource pool if it
  conincides with applying locally generated diffs or diffs from the network
  or diffs from transition frontier extensions.*)
  val unsafe_apply :
       pool
    -> t Envelope.Incoming.t
    -> ( t * rejected
       , [`Locally_generated of t * rejected | `Other of Error.t] )
       Result.t
       Deferred.t

  val is_empty : t -> bool
end

(** A [Resource_pool_intf] ties together an associated pair of
 *  [Resource_pool_base_intf] and [Resource_pool_diff_intf]. *)
module type Resource_pool_intf = sig
  include Resource_pool_base_intf

  module Diff : Resource_pool_diff_intf with type pool := t

  (** Locally generated items (user commands and snarks) should be periodically
      rebroadcast, to ensure network unreliability doesn't mean they're never
      included in a block. This function gets the locally generated items that
      are currently rebroadcastable. [is_expired] is a function that returns
      true if an item that was added at a given time should not be rebroadcast
      anymore. If it does, the implementation should not return that item, and
      remove it from the set of potentially-rebroadcastable item.
  *)
  val get_rebroadcastable :
    t -> is_expired:(Time.t -> [`Expired | `Ok]) -> Diff.t list
end

(** A [Network_pool_base_intf] is the core implementation of a
 *  network pool on top of a [Resource_pool_intf]. It wraps
 *  some [Resource_pool_intf] and provides a generic interface
 *  for interacting with the [Resource_pool_intf] using the
 *  network. A [Network_pool_base_intf] wires the [Resource_pool_intf]
 *  into the network using pipes of diffs and transition frontiers.
 *  It also provides a way to apply new diffs and rebroadcast them
 *  to the network if necessary. *)
module type Network_pool_base_intf = sig
  type t

  type resource_pool

  type resource_pool_diff

  type rejected_diff

  type transition_frontier_diff

  type config

  type transition_frontier

  val create :
       config:config
    -> incoming_diffs:(resource_pool_diff Envelope.Incoming.t * (bool -> unit))
                      Strict_pipe.Reader.t
    -> local_diffs:( resource_pool_diff
                   * ((resource_pool_diff * rejected_diff) Or_error.t -> unit)
                   )
                   Strict_pipe.Reader.t
    -> frontier_broadcast_pipe:transition_frontier Option.t
                               Broadcast_pipe.Reader.t
    -> logger:Logger.t
    -> t

  val of_resource_pool_and_diffs :
       resource_pool
    -> logger:Logger.t
    -> incoming_diffs:(resource_pool_diff Envelope.Incoming.t * (bool -> unit))
                      Strict_pipe.Reader.t
    -> local_diffs:( resource_pool_diff
                   * ((resource_pool_diff * rejected_diff) Or_error.t -> unit)
                   )
                   Strict_pipe.Reader.t
    -> tf_diffs:transition_frontier_diff Strict_pipe.Reader.t
    -> t

  val resource_pool : t -> resource_pool

  val broadcasts : t -> resource_pool_diff Linear_pipe.Reader.t

  val apply_and_broadcast :
       t
    -> resource_pool_diff Envelope.Incoming.t
       * (bool -> unit)
       * ((resource_pool_diff * rejected_diff) Or_error.t -> unit)
    -> unit Deferred.t
end

(** A [Snark_resource_pool_intf] is a superset of a
 *  [Resource_pool_intf] specifically for handling snarks. *)
module type Snark_resource_pool_intf = sig
  include Resource_pool_base_intf

  val make_config :
    trust_system:Trust_system.t -> verifier:Verifier.t -> Config.t

  type serializable [@@deriving bin_io]

  val of_serializable : serializable -> config:Config.t -> logger:Logger.t -> t

  val add_snark :
       ?is_local:bool
    -> t
    -> work:Transaction_snark_work.Statement.t
    -> proof:Ledger_proof.t One_or_two.t
    -> fee:Fee_with_prover.t
    -> [`Added | `Statement_not_referenced]

  val verify_and_act :
       t
    -> work:Transaction_snark_work.Statement.t
            * Ledger_proof.t One_or_two.t Priced_proof.t
    -> sender:Envelope.Sender.t
    -> unit Deferred.Or_error.t

  val request_proof :
       t
    -> Transaction_snark_work.Statement.t
    -> Ledger_proof.t One_or_two.t Priced_proof.t option

  val snark_pool_json : t -> Yojson.Safe.json

  val all_completed_work : t -> Transaction_snark_work.Info.t list

  val get_logger : t -> Logger.t
end

(** A [Snark_pool_diff_intf] is the resource pool diff for
 *  a [Snark_resource_pool_intf]. *)
module type Snark_pool_diff_intf = sig
  type resource_pool

  module Stable : sig
    module V1 : sig
      type t =
        | Add_solved_work of
            Transaction_snark_work.Statement.Stable.V1.t
            * Ledger_proof.Stable.V1.t One_or_two.Stable.V1.t
              Priced_proof.Stable.V1.t
      [@@deriving bin_io, compare, sexp, to_yojson, version]
    end

    module Latest = V1
  end

  type t = Stable.Latest.t [@@deriving compare, sexp]

  include
    Resource_pool_diff_intf with type t := t and type pool := resource_pool

  val compact_json : t -> Yojson.Safe.json

  val of_result :
       ( ('a, 'b, 'c) Snark_work_lib.Work.Single.Spec.t
         Snark_work_lib.Work.Spec.t
       , Ledger_proof.t )
       Snark_work_lib.Work.Result.t
    -> t
end

module type Transaction_pool_diff_intf = sig
  type resource_pool

  [%%versioned:
  module Stable : sig
    module V1 : sig
      type t = User_command.Stable.V1.t list [@@deriving sexp, to_yojson]
    end
  end]

  type t = Stable.Latest.t [@@deriving sexp]

  module Diff_error : sig
    module Stable : sig
      module V1 : sig
        type t =
          | Insufficient_replace_fee
          | Invalid_signature
          | Duplicate
          | Sender_account_does_not_exist
          | Insufficient_amount_for_account_creation
          | Delegate_not_found
          | Invalid_nonce
          | Insufficient_funds
          | Insufficient_fee
          | Overflow
        [@@deriving sexp, yojson, bin_io]
      end

      module Latest = V1
    end

    type t = Stable.Latest.t =
      | Insufficient_replace_fee
      | Invalid_signature
      | Duplicate
      | Sender_account_does_not_exist
      | Insufficient_amount_for_account_creation
      | Delegate_not_found
      | Invalid_nonce
      | Insufficient_funds
      | Insufficient_fee
      | Overflow
    [@@deriving sexp, yojson]
  end

  module Rejected : sig
    module Stable : sig
      module V1 : sig
        type t = (User_command.Stable.V1.t * Diff_error.Stable.V1.t) list
        [@@deriving sexp, bin_io, yojson, version]
      end

      module Latest = V1
    end

    type t = Stable.Latest.t [@@deriving sexp, yojson]
  end

  include
    Resource_pool_diff_intf
    with type t := t
     and type pool := resource_pool
     and type rejected = Rejected.t
end

module type Transaction_resource_pool_intf = sig
  type t

  include Resource_pool_base_intf with type t := t

  val make_config :
    trust_system:Trust_system.t -> pool_max_size:int -> Config.t

  val member : t -> User_command.With_valid_signature.t -> bool

  val transactions :
    logger:Logger.t -> t -> User_command.With_valid_signature.t Sequence.t

  val all_from_account :
    t -> Account_id.t -> User_command.With_valid_signature.t list
end
