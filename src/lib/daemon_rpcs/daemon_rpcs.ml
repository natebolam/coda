open Core_kernel
open Async
open Coda_base
open Signature_lib
module Types = Types
module Client = Client

module Get_transaction_status = struct
  type query = User_command.Stable.Latest.t [@@deriving bin_io_unversioned]

  type response = Transaction_status.State.Stable.Latest.t Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_transaction_status" ~version:0 ~bin_query
      ~bin_response
end

module Send_user_commands = struct
  type query = User_command_input.Stable.Latest.t list
  [@@deriving bin_io_unversioned]

  type response =
    ( Network_pool.Transaction_pool.Diff_versioned.Stable.Latest.t
    * Network_pool.Transaction_pool.Diff_versioned.Rejected.Stable.Latest.t )
    Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Send_user_commands" ~version:0 ~bin_query
      ~bin_response
end

module Get_ledger = struct
  type query = Staged_ledger_hash.Stable.Latest.t option
  [@@deriving bin_io_unversioned]

  type response = Account.Stable.Latest.t list Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_ledger" ~version:0 ~bin_query ~bin_response
end

module Get_balance = struct
  type query = Account_id.Stable.Latest.t [@@deriving bin_io_unversioned]

  type response = Currency.Balance.Stable.Latest.t option Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_balance" ~version:0 ~bin_query ~bin_response
end

module Get_trust_status = struct
  type query = Unix.Inet_addr.t [@@deriving bin_io_unversioned]

  type response = Trust_system.Peer_status.Stable.Latest.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_trust_status" ~version:0 ~bin_query ~bin_response
end

module Get_trust_status_all = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response =
    (Unix.Inet_addr.t * Trust_system.Peer_status.Stable.Latest.t) list
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_trust_status_all" ~version:0 ~bin_query
      ~bin_response
end

module Reset_trust_status = struct
  type query = Unix.Inet_addr.t [@@deriving bin_io_unversioned]

  type response = Trust_system.Peer_status.Stable.Latest.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Reset_trust_status" ~version:0 ~bin_query
      ~bin_response
end

module Verify_proof = struct
  type query =
    Account_id.Stable.Latest.t
    * User_command.Stable.Latest.t
    * (Receipt.Chain_hash.Stable.Latest.t * User_command.Stable.Latest.t list)
  [@@deriving bin_io_unversioned]

  type response = unit Or_error.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Verify_proof" ~version:0 ~bin_query ~bin_response
end

module Prove_receipt = struct
  type query = Receipt.Chain_hash.Stable.Latest.t * Account_id.Stable.Latest.t
  [@@deriving bin_io_unversioned]

  type response =
    (Receipt.Chain_hash.Stable.Latest.t * User_command.Stable.Latest.t list)
    Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Prove_receipt" ~version:0 ~bin_query ~bin_response
end

module Get_inferred_nonce = struct
  type query = Account_id.Stable.Latest.t [@@deriving bin_io_unversioned]

  type response = Account.Nonce.Stable.Latest.t option Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_inferred_nonce" ~version:0 ~bin_query
      ~bin_response
end

module Get_nonce = struct
  type query = Account_id.Stable.Latest.t [@@deriving bin_io_unversioned]

  type response = Account.Nonce.Stable.Latest.t option Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_nonce" ~version:0 ~bin_query ~bin_response
end

module Get_status = struct
  type query = [`Performance | `None] [@@deriving bin_io_unversioned]

  type response = Types.Status.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_status" ~version:0 ~bin_query ~bin_response
end

module Clear_hist_status = struct
  type query = [`Performance | `None] [@@deriving bin_io_unversioned]

  type response = Types.Status.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Clear_hist_status" ~version:0 ~bin_query
      ~bin_response
end

module Get_public_keys_with_details = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = (string * int * int) list Or_error.t
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_public_keys_with_details" ~version:0 ~bin_query
      ~bin_response
end

module Get_public_keys = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = string list Or_error.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_public_keys" ~version:0 ~bin_query ~bin_response
end

module Stop_daemon = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = unit [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Stop_daemon" ~version:0 ~bin_query ~bin_response
end

module Snark_job_list = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = string Or_error.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Snark_job_list" ~version:0 ~bin_query ~bin_response
end

module Snark_pool_list = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = string [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Snark_pool_list" ~version:0 ~bin_query ~bin_response
end

module Start_tracing = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = unit [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Start_tracing" ~version:0 ~bin_query ~bin_response
end

module Stop_tracing = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = unit [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Stop_tracing" ~version:0 ~bin_query ~bin_response
end

module Set_staking = struct
  type query = Keypair.Stable.Latest.t list [@@deriving bin_io_unversioned]

  type response = unit [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Set_staking" ~version:0 ~bin_query ~bin_response
end

module Visualization = struct
  module Frontier = struct
    type query = string [@@deriving bin_io_unversioned]

    type response = [`Active of unit | `Bootstrapping]
    [@@deriving bin_io_unversioned]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Visualize_frontier" ~version:0 ~bin_query
        ~bin_response
  end

  module Registered_masks = struct
    type query = string [@@deriving bin_io_unversioned]

    type response = unit [@@deriving bin_io_unversioned]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Visualize_registered_masks" ~version:0 ~bin_query
        ~bin_response
  end
end

module Add_trustlist = struct
  type query = Unix.Cidr.t [@@deriving bin_io_unversioned]

  type response = unit Or_error.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Add_trustlist" ~version:0 ~bin_query ~bin_response
end

module Remove_trustlist = struct
  type query = Unix.Cidr.t [@@deriving bin_io_unversioned]

  type response = unit Or_error.t [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Remove_trustlist" ~version:0 ~bin_query ~bin_response
end

module Get_trustlist = struct
  type query = unit [@@deriving bin_io_unversioned]

  type response = Unix.Cidr.t list [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_trustlist" ~version:0 ~bin_query ~bin_response
end

(** daemon-level Get_telemetry_data; implementation invokes
    Coda_networking's Get_telemetry_data for each provided peer
*)
module Get_telemetry_data = struct
  type query = Network_peer.Peer.Id.Stable.Latest.t list option
  [@@deriving bin_io_unversioned]

  type response =
    Coda_networking.Rpcs.Get_telemetry_data.Telemetry_data.Stable.Latest.t
    Or_error.t
    list
  [@@deriving bin_io_unversioned]

  let rpc : (query, response) Rpc.Rpc.t =
    Rpc.Rpc.create ~name:"Get_telemetry_data" ~version:0 ~bin_query
      ~bin_response
end
