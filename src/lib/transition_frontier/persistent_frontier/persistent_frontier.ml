open Async_kernel
open Core
open Coda_base
open Coda_state
open Coda_transition
open Frontier_base
module Database = Database

exception Invalid_genesis_state_hash of External_transition.Validated.t

let construct_staged_ledger_at_root
    ~(precomputed_values : Precomputed_values.t) ~root_ledger ~root_transition
    ~root ~protocol_states ~logger =
  let open Deferred.Or_error.Let_syntax in
  let open Root_data.Minimal in
  let snarked_ledger_hash =
    External_transition.Validated.blockchain_state root_transition
    |> Blockchain_state.snarked_ledger_hash
  in
  let snarked_next_available_token =
    External_transition.Validated.blockchain_state root_transition
    |> Blockchain_state.snarked_next_available_token
  in
  let scan_state = scan_state root in
  let pending_coinbase = pending_coinbase root in
  let protocol_states_map =
    List.fold protocol_states ~init:State_hash.Map.empty
      ~f:(fun acc protocol_state ->
        Map.add_exn acc
          ~key:(Protocol_state.hash protocol_state)
          ~data:protocol_state )
  in
  let get_state hash =
    match Map.find protocol_states_map hash with
    | None ->
        Logger.error logger ~module_:__MODULE__ ~location:__LOC__
          ~metadata:[("state_hash", State_hash.to_yojson hash)]
          "Protocol state (for scan state transactions) for $state_hash not \
           found when loading persisted transition frontier" ;
        Or_error.errorf
          !"Protocol state (for scan state transactions) for \
            %{sexp:State_hash.t} not found when loading persisted transition \
            frontier"
          hash
    | Some protocol_state ->
        Ok protocol_state
  in
  let%bind transactions_with_protocol_state =
    Deferred.return
      (Staged_ledger.Scan_state.staged_transactions_with_protocol_states
         scan_state ~get_state)
  in
  let mask = Ledger.of_database root_ledger in
  let%bind () =
    Deferred.return
      (List.fold transactions_with_protocol_state ~init:(Or_error.return ())
         ~f:(fun acc (txn, protocol_state) ->
           let open Or_error.Let_syntax in
           let%bind () = acc in
           let%map _ =
             Ledger.apply_transaction
               ~constraint_constants:precomputed_values.constraint_constants
               mask
               ~txn_global_slot:
                 ( Protocol_state.consensus_state protocol_state
                 |> Consensus.Data.Consensus_state.curr_global_slot )
               txn
           in
           () ))
  in
  Staged_ledger.of_scan_state_and_ledger_unchecked ~snarked_ledger_hash
    ~snarked_next_available_token ~ledger:mask ~scan_state
    ~constraint_constants:precomputed_values.constraint_constants
    ~pending_coinbase_collection:pending_coinbase

module rec Instance_type : sig
  type t =
    {db: Database.t; mutable sync: Sync.t option; factory: Factory_type.t}
end =
  Instance_type

and Factory_type : sig
  type t =
    { logger: Logger.t
    ; directory: string
    ; verifier: Verifier.t
    ; time_controller: Block_time.Controller.t
    ; mutable instance: Instance_type.t option }
end =
  Factory_type

open Instance_type
open Factory_type

module Instance = struct
  type t = Instance_type.t

  let create factory =
    let db =
      Database.create ~logger:factory.logger ~directory:factory.directory
    in
    {db; sync= None; factory}

  let assert_no_sync t =
    if Option.is_some t.sync then Error `Sync_cannot_be_running else Ok ()

  let assert_sync t ~f =
    match t.sync with
    | None ->
        return (Error `Sync_must_be_running)
    | Some sync ->
        f sync

  let start_sync ~constraint_constants t =
    let open Result.Let_syntax in
    let%bind () = assert_no_sync t in
    let%map base_hash = Database.get_frontier_hash t.db in
    t.sync
    <- Some
         (Sync.create ~constraint_constants ~logger:t.factory.logger
            ~time_controller:t.factory.time_controller ~base_hash ~db:t.db)

  let stop_sync t =
    let open Deferred.Let_syntax in
    assert_sync t ~f:(fun sync ->
        let%map () = Sync.close sync in
        t.sync <- None ;
        Ok () )

  let notify_sync t ~diffs ~hash_transition =
    assert_sync t ~f:(fun sync ->
        Sync.notify sync ~diffs ~hash_transition ;
        Deferred.Result.return () )

  let destroy t =
    let open Deferred.Let_syntax in
    Logger.trace t.factory.logger ~module_:__MODULE__ ~location:__LOC__
      "Destroying transition frontier persistence instance" ;
    let%map () =
      if Option.is_some t.sync then
        stop_sync t
        >>| Fn.compose Result.ok_or_failwith
              (Result.map_error ~f:(Fn.const "impossible"))
      else return ()
    in
    Database.close t.db ;
    t.factory.instance <- None

  let factory {factory; _} = factory

  let check_database t = Database.check t.db

  let get_root_transition t =
    let open Result.Let_syntax in
    Database.get_root_hash t.db
    >>= Database.get_transition t.db
    |> Result.map_error ~f:Database.Error.message

  let set_frontier_hash t = Database.set_frontier_hash t.db

  let fast_forward t target_root :
      (unit, [> `Failure of string | `Bootstrap_required]) Result.t =
    let open Root_identifier.Stable.Latest in
    let open Result.Let_syntax in
    let%bind () = assert_no_sync t in
    let lift_error r msg = Result.map_error r ~f:(Fn.const (`Failure msg)) in
    let%bind root =
      lift_error (Database.get_root t.db) "failed to get root hash"
    in
    let root_hash = Root_data.Minimal.hash root in
    if State_hash.equal root_hash target_root.state_hash then
      (* If the target hash is already the root hash, no fast forward required, but we should check the frontier hash. *)
      let%bind frontier_hash =
        lift_error
          (Database.get_frontier_hash t.db)
          "failed to get frontier hash"
      in
      Result.ok_if_true
        (Frontier_hash.equal frontier_hash target_root.frontier_hash)
        ~error:`Frontier_hash_does_not_match
    else (
      Logger.warn t.factory.logger ~module_:__MODULE__ ~location:__LOC__
        ~metadata:
          [ ("current_root", State_hash.to_yojson root_hash)
          ; ("target_root", State_hash.to_yojson target_root.state_hash) ]
        "Cannot fast forward persistent frontier's root: bootstrap is \
         required ($current_root --> $target_root)" ;
      Error `Bootstrap_required )

  let load_full_frontier t ~root_ledger ~consensus_local_state ~max_length
      ~ignore_consensus_local_state ~precomputed_values =
    let open Deferred.Result.Let_syntax in
    let downgrade_transition transition genesis_state_hash :
        ( External_transition.Almost_validated.t
        , [`Invalid_genesis_protocol_state] )
        Result.t =
      let open Result.Let_syntax in
      let transition, _ = External_transition.Validated.erase transition in
      let%map t =
        External_transition.Validation.wrap transition
        |> External_transition.skip_time_received_validation
             `This_transition_was_not_received_via_gossip
        |> External_transition.validate_genesis_protocol_state
             ~genesis_state_hash
      in
      External_transition.skip_proof_validation
        `This_transition_was_generated_internally t
      |> External_transition.skip_delta_transition_chain_validation
           `This_transition_was_not_received_via_gossip
      |> External_transition.skip_frontier_dependencies_validation
           `This_transition_was_loaded_from_persistence
      |> External_transition.skip_protocol_versions_validation
           `This_transition_has_valid_protocol_versions
    in
    let%bind () = Deferred.return (assert_no_sync t) in
    (* read basic information from the database *)
    let%bind ( root
             , root_transition
             , best_tip
             , base_hash
             , protocol_states
             , root_hash ) =
      (let open Result.Let_syntax in
      let%bind root = Database.get_root t.db in
      let root_hash = Root_data.Minimal.hash root in
      let%bind root_transition = Database.get_transition t.db root_hash in
      let%bind best_tip = Database.get_best_tip t.db in
      let%bind protocol_states =
        Database.get_protocol_states_for_root_scan_state t.db
      in
      let%map base_hash = Database.get_frontier_hash t.db in
      (root, root_transition, best_tip, base_hash, protocol_states, root_hash))
      |> Result.map_error ~f:(fun err ->
             `Failure (Database.Error.not_found_message err) )
      |> Deferred.return
    in
    let root_genesis_state_hash =
      External_transition.Validated.protocol_state root_transition
      |> Protocol_state.genesis_state_hash
    in
    (* construct the root staged ledger in memory *)
    let%bind root_staged_ledger =
      let open Deferred.Let_syntax in
      match%map
        construct_staged_ledger_at_root ~precomputed_values ~root_ledger
          ~root_transition ~root ~protocol_states ~logger:t.factory.logger
      with
      | Error err ->
          Error (`Failure (Error.to_string_hum err))
      | Ok staged_ledger ->
          Ok staged_ledger
    in
    (* initialize the new in memory frontier and extensions *)
    let frontier =
      Full_frontier.create ~logger:t.factory.logger ~base_hash
        ~root_data:
          { transition= root_transition
          ; staged_ledger= root_staged_ledger
          ; protocol_states=
              (*TODO: store the hashes as well?*)
              List.map protocol_states ~f:(fun s -> (Protocol_state.hash s, s))
          }
        ~root_ledger:(Ledger.Any_ledger.cast (module Ledger.Db) root_ledger)
        ~consensus_local_state ~max_length ~precomputed_values
    in
    let%bind extensions =
      Deferred.map
        (Extensions.create ~logger:t.factory.logger frontier)
        ~f:Result.return
    in
    let apply_diff diff =
      let (`New_root_and_diffs_with_mutants (_, diffs_with_mutants)) =
        Full_frontier.apply_diffs frontier [diff] ~ignore_consensus_local_state
      in
      Extensions.notify extensions ~frontier ~diffs_with_mutants
      |> Deferred.map ~f:Result.return
    in
    (* crawl through persistent frontier and load transitions into in memory frontier *)
    let%bind () =
      Deferred.map
        (Database.crawl_successors t.db root_hash
           ~init:(Full_frontier.root frontier) ~f:(fun parent transition ->
             let%bind transition =
               match
                 downgrade_transition transition root_genesis_state_hash
               with
               | Ok t ->
                   Deferred.Result.return t
               | Error `Invalid_genesis_protocol_state ->
                   Error (`Fatal_error (Invalid_genesis_state_hash transition))
                   |> Deferred.return
             in
             let%bind breadcrumb =
               Breadcrumb.build ~logger:t.factory.logger ~precomputed_values
                 ~verifier:t.factory.verifier
                 ~trust_system:(Trust_system.null ()) ~parent ~transition
                 ~sender:None
             in
             let%map () = apply_diff Diff.(E (New_node (Full breadcrumb))) in
             breadcrumb ))
        ~f:
          (Result.map_error ~f:(function
            | `Crawl_error err ->
                let msg =
                  match err with
                  | `Fatal_error exn ->
                      "fatal error -- " ^ Exn.to_string exn
                  | `Invalid_staged_ledger_diff err
                  | `Invalid_staged_ledger_hash err ->
                      "staged ledger diff application failed -- "
                      ^ Error.to_string_hum err
                in
                `Failure
                  ( "error rebuilding transition frontier from persistence: "
                  ^ msg )
            | `Not_found _ as err ->
                `Failure (Database.Error.not_found_message err) ))
    in
    let%map () = apply_diff Diff.(E (Best_tip_changed best_tip)) in
    (* reset the frontier hash at the end so it matches the persistent frontier hash (for future sanity checks) *)
    Logger.trace t.factory.logger ~module_:__MODULE__ ~location:__LOC__
      "Pinning frontier hash at %s"
      (Frontier_hash.to_string base_hash) ;
    Full_frontier.set_hash_unsafe frontier (`I_promise_this_is_safe base_hash) ;
    (frontier, extensions)
end

type t = Factory_type.t

let create ~logger ~verifier ~time_controller ~directory =
  {logger; verifier; time_controller; directory; instance= None}

let destroy_database_exn t =
  assert (t.instance = None) ;
  File_system.remove_dir t.directory

let create_instance_exn t =
  assert (t.instance = None) ;
  let instance = Instance.create t in
  t.instance <- Some instance ;
  instance

let with_instance_exn t ~f =
  let instance = create_instance_exn t in
  let x = f instance in
  let%map () = Instance.destroy instance in
  x

let reset_database_exn t ~root_data =
  let open Root_data.Limited in
  let open Deferred.Let_syntax in
  Logger.info t.logger ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ( "state_hash"
        , State_hash.to_yojson
            (External_transition.Validated.state_hash (transition root_data))
        ) ]
    "Resetting transition frontier database to new root" ;
  let%bind () = destroy_database_exn t in
  with_instance_exn t ~f:(fun instance ->
      Database.initialize instance.db ~root_data ~base_hash:Frontier_hash.empty ;
      (* sanity check database after initialization on debug builds *)
      Debug_assert.debug_assert (fun () ->
          Database.check instance.db
          |> Result.map_error ~f:(function
               | `Invalid_version ->
                   "invalid version"
               | `Not_initialized ->
                   "not initialized"
               | `Corrupt err ->
                   Database.Error.message err )
          |> Result.ok_or_failwith ) )
