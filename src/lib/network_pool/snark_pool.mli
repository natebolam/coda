open Async_kernel
open Pipe_lib
open Network_peer
open Core_kernel

module Snark_tables : sig
  [%%versioned:
  module Stable : sig
    module V1 : sig
      type t =
        { all:
            Ledger_proof.Stable.V1.t One_or_two.Stable.V1.t
            Priced_proof.Stable.V1.t
            Transaction_snark_work.Statement.Stable.V1.Table.t
        ; rebroadcastable:
            ( Ledger_proof.Stable.V1.t One_or_two.Stable.V1.t
              Priced_proof.Stable.V1.t
            * Core.Time.Stable.With_utc_sexp.V2.t )
            Transaction_snark_work.Statement.Stable.V1.Table.t }
      [@@deriving sexp]
    end
  end]

  type t = Stable.Latest.t =
    { all:
        Ledger_proof.t One_or_two.t Priced_proof.t
        Transaction_snark_work.Statement.Stable.V1.Table.t
    ; rebroadcastable:
        ( Ledger_proof.t One_or_two.t Priced_proof.t
        * Core.Time.Stable.With_utc_sexp.V2.t )
        Transaction_snark_work.Statement.Table.t }
end

module type S = sig
  type transition_frontier

  module Resource_pool : sig
    include
      Intf.Snark_resource_pool_intf
      with type transition_frontier := transition_frontier
       and type serializable := Snark_tables.t

    val remove_solved_work : t -> Transaction_snark_work.Statement.t -> unit

    module Diff : Intf.Snark_pool_diff_intf with type resource_pool := t
  end

  module For_tests : sig
    val get_rebroadcastable :
         Resource_pool.t
      -> is_expired:(Core.Time.t -> [`Expired | `Ok])
      -> Resource_pool.Diff.t list
  end

  include
    Intf.Network_pool_base_intf
    with type resource_pool := Resource_pool.t
     and type resource_pool_diff := Resource_pool.Diff.t
     and type transition_frontier := transition_frontier
     and type config := Resource_pool.Config.t
     and type transition_frontier_diff :=
                Resource_pool.transition_frontier_diff
     and type rejected_diff := Resource_pool.Diff.rejected

  val get_completed_work :
       t
    -> Transaction_snark_work.Statement.t
    -> Transaction_snark_work.Checked.t option

  val load :
       config:Resource_pool.Config.t
    -> logger:Logger.t
    -> constraint_constants:Genesis_constants.Constraint_constants.t
    -> disk_location:string
    -> incoming_diffs:( Resource_pool.Diff.t Envelope.Incoming.t
                      * (bool -> unit) )
                      Strict_pipe.Reader.t
    -> local_diffs:( Resource_pool.Diff.t
                   * (   (Resource_pool.Diff.t * Resource_pool.Diff.rejected)
                         Or_error.t
                      -> unit) )
                   Strict_pipe.Reader.t
    -> frontier_broadcast_pipe:transition_frontier option
                               Broadcast_pipe.Reader.t
    -> t Deferred.t
end

module type Transition_frontier_intf = sig
  type t

  val snark_pool_refcount_pipe :
       t
    -> (int * int Transaction_snark_work.Statement.Table.t)
       Pipe_lib.Broadcast_pipe.Reader.t
end

module Make (Transition_frontier : Transition_frontier_intf) :
  S with type transition_frontier := Transition_frontier.t

include S with type transition_frontier := Transition_frontier.t

module Diff_versioned : sig
  [%%versioned:
  module Stable : sig
    module V1 : sig
      type t = Resource_pool.Diff.t =
        | Add_solved_work of
            Transaction_snark_work.Statement.Stable.V1.t
            * Ledger_proof.Stable.V1.t One_or_two.Stable.V1.t
              Priced_proof.Stable.V1.t
      [@@deriving compare, sexp]
    end
  end]

  type t = Stable.Latest.t =
    | Add_solved_work of
        Transaction_snark_work.Statement.t
        * Ledger_proof.t One_or_two.t Priced_proof.t
end
