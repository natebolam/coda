open Core
open Async
open Signature_lib
open Coda_base
open O1trace
module Graphql_cohttp_async =
  Graphql_internal.Make (Graphql_async.Schema) (Cohttp_async.Io)
    (Cohttp_async.Body)

let snark_job_list_json t =
  let open Participating_state.Let_syntax in
  let%map sl = Coda_lib.best_staged_ledger t in
  Staged_ledger.Scan_state.snark_job_list_json (Staged_ledger.scan_state sl)

let snark_pool_list t =
  Coda_lib.snark_pool t |> Network_pool.Snark_pool.resource_pool
  |> Network_pool.Snark_pool.Resource_pool.snark_pool_json
  |> Yojson.Safe.to_string

(* create reader, writer for protocol versions, but really for any one-line item in conf_dir *)
let make_conf_dir_item_io ~conf_dir ~filename =
  let item_file = conf_dir ^/ filename in
  let read_item () =
    let open Stdlib in
    let inp = open_in item_file in
    let res = input_line inp in
    close_in inp ; res
  in
  let write_item item =
    let open Stdlib in
    let outp = open_out item_file in
    output_string outp (item ^ "\n") ;
    close_out outp
  in
  (read_item, write_item)

let get_current_protocol_version ~compile_time_current_protocol_version
    ~conf_dir ~logger =
  let read_protocol_version, write_protocol_version =
    make_conf_dir_item_io ~conf_dir ~filename:"current_protocol_version"
  in
  function
  | None -> (
    try
      (* not provided on command line, try to read from config dir *)
      let protocol_version = read_protocol_version () in
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        "Setting current protocol version to $protocol_version from config"
        ~metadata:[("protocol_version", `String protocol_version)] ;
      Protocol_version.of_string_exn protocol_version
    with Sys_error _ ->
      (* not on command-line, not in config dir, use compile-time value *)
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        "Setting current protocol version to $protocol_version from \
         compile-time config"
        ~metadata:
          [("protocol_version", `String compile_time_current_protocol_version)] ;
      Protocol_version.of_string_exn compile_time_current_protocol_version )
  | Some protocol_version -> (
    try
      (* it's an error if the command line value disagrees with the value in the config *)
      let config_protocol_version = read_protocol_version () in
      if String.equal config_protocol_version protocol_version then (
        Logger.info logger ~module_:__MODULE__ ~location:__LOC__
          "Using current protocol version $protocol_version from command \
           line, which matches the one in the config"
          ~metadata:[("protocol_version", `String protocol_version)] ;
        Protocol_version.of_string_exn config_protocol_version )
      else (
        Logger.fatal logger ~module_:__MODULE__ ~location:__LOC__
          "Current protocol version $protocol_version from the command line \
           disagrees with $config_protocol_version from the Coda config"
          ~metadata:
            [ ("protocol_version", `String protocol_version)
            ; ("config_protocol_version", `String config_protocol_version) ] ;
        failwith
          "Current protocol version from command line disagrees with protocol \
           version in Coda config; please delete your Coda config if you wish \
           to use a new protocol version" )
    with Sys_error _ -> (
      (* use value provided on command line, write to config dir *)
      match Protocol_version.of_string_opt protocol_version with
      | None ->
          Logger.fatal logger ~module_:__MODULE__ ~location:__LOC__
            "Protocol version provided on command line is invalid"
            ~metadata:[("protocol_version", `String protocol_version)] ;
          failwith "Protocol version from command line is invalid"
      | Some pv ->
          write_protocol_version protocol_version ;
          Logger.info logger ~module_:__MODULE__ ~location:__LOC__
            "Using current protocol_version $protocol_version from command \
             line, writing to config"
            ~metadata:[("protocol_version", `String protocol_version)] ;
          pv ) )

let get_proposed_protocol_version_opt ~conf_dir ~logger =
  let read_protocol_version, write_protocol_version =
    make_conf_dir_item_io ~conf_dir ~filename:"proposed_protocol_version"
  in
  function
  | None -> (
    try
      (* not provided on command line, try to read from config dir *)
      let protocol_version = read_protocol_version () in
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        "Setting proposed protocol version to $protocol_version from config"
        ~metadata:[("protocol_version", `String protocol_version)] ;
      Some (Protocol_version.of_string_exn protocol_version)
    with Sys_error _ ->
      (* not on command-line, not in config dir, there's no proposed protocol version *)
      None )
  | Some protocol_version -> (
      let validate_cli_protocol_version protocol_version =
        if Option.is_none (Protocol_version.of_string_opt protocol_version)
        then (
          Logger.fatal logger ~module_:__MODULE__ ~location:__LOC__
            "Proposed protocol version provided on command line is invalid"
            ~metadata:[("proposed_protocol_version", `String protocol_version)] ;
          failwith "Proposed protocol version from command line is invalid" )
      in
      try
        (* overwrite if the command line value disagrees with the value in the config *)
        let config_protocol_version = read_protocol_version () in
        if String.equal config_protocol_version protocol_version then (
          Logger.info logger ~module_:__MODULE__ ~location:__LOC__
            "Using proposed protocol version $protocol_version from command \
             line, which matches the one in the config"
            ~metadata:[("protocol_version", `String protocol_version)] ;
          Some (Protocol_version.of_string_exn config_protocol_version) )
        else (
          validate_cli_protocol_version protocol_version ;
          write_protocol_version protocol_version ;
          Logger.info logger ~module_:__MODULE__ ~location:__LOC__
            "Overwriting Coda config proposed protocol version \
             $config_proposed_protocol_version with proposed protocol version \
             $protocol_version from the command line"
            ~metadata:
              [ ( "config_proposed_protocol_version"
                , `String config_protocol_version )
              ; ("proposed_protocol_version", `String protocol_version) ] ;
          Some (Protocol_version.of_string_exn protocol_version) )
      with Sys_error _ ->
        (* use value provided on command line, write to config dir *)
        validate_cli_protocol_version protocol_version ;
        write_protocol_version protocol_version ;
        Logger.info logger ~module_:__MODULE__ ~location:__LOC__
          "Using proposed protocol version from command line, writing to config"
          ~metadata:[("protocol_version", `String protocol_version)] ;
        Some (Protocol_version.of_string_exn protocol_version) )

(*TODO check deferred now and copy theose files to the temp directory*)
let log_shutdown ~conf_dir ~top_logger coda_ref =
  let logger =
    Logger.extend top_logger
      [("coda_run", `String "Logging state before program ends")]
  in
  let frontier_file = conf_dir ^/ "frontier.dot" in
  let mask_file = conf_dir ^/ "registered_masks.dot" in
  (* ledger visualization *)
  Logger.debug logger ~module_:__MODULE__ ~location:__LOC__ "%s"
    (Visualization_message.success "registered masks" mask_file) ;
  Coda_base.Ledger.Debug.visualize ~filename:mask_file ;
  match !coda_ref with
  | None ->
      Logger.trace logger ~module_:__MODULE__ ~location:__LOC__
        "Shutdown before Coda instance was created, not saving a visualization"
  | Some t -> (
    (*Transition frontier visualization*)
    match Coda_lib.visualize_frontier ~filename:frontier_file t with
    | `Active () ->
        Logger.debug logger ~module_:__MODULE__ ~location:__LOC__ "%s"
          (Visualization_message.success "transition frontier" frontier_file)
    | `Bootstrapping ->
        Logger.debug logger ~module_:__MODULE__ ~location:__LOC__ "%s"
          (Visualization_message.bootstrap "transition frontier") )

let remove_prev_crash_reports ~conf_dir =
  Core.Sys.command (sprintf "rm -rf %s/coda_crash_report*" conf_dir)

let summary exn_str =
  let uname = Core.Unix.uname () in
  let daemon_command = sprintf !"Command: %{sexp: string array}" Sys.argv in
  `Assoc
    [ ("OS_type", `String Sys.os_type)
    ; ("Release", `String (Core.Unix.Utsname.release uname))
    ; ("Machine", `String (Core.Unix.Utsname.machine uname))
    ; ("Sys_name", `String (Core.Unix.Utsname.sysname uname))
    ; ("Exception", `String exn_str)
    ; ("Command", `String daemon_command)
    ; ("Coda_branch", `String Coda_version.branch)
    ; ("Coda_commit", `String Coda_version.commit_id) ]

let coda_status coda_ref =
  Option.value_map coda_ref
    ~default:
      (Deferred.return (`String "Shutdown before Coda instance was created"))
    ~f:(fun t ->
      Coda_commands.get_status ~flag:`Performance t
      >>| Daemon_rpcs.Types.Status.to_yojson )

let make_report exn_str ~conf_dir ~top_logger coda_ref =
  (* TEMP MAKE REPORT TRACE *)
  Logger.trace top_logger ~module_:__MODULE__ ~location:__LOC__
    "make_report: enter" ;
  let _ = remove_prev_crash_reports ~conf_dir in
  let crash_time = Time.to_filename_string ~zone:Time.Zone.utc (Time.now ()) in
  let temp_config = conf_dir ^/ "coda_crash_report_" ^ crash_time in
  let () = Core.Unix.mkdir temp_config in
  (*Transition frontier and ledger visualization*)
  log_shutdown ~conf_dir:temp_config ~top_logger coda_ref ;
  let report_file = temp_config ^ ".tar.gz" in
  (*Coda status*)
  let status_file = temp_config ^/ "coda_status.json" in
  let%map status = coda_status !coda_ref in
  Yojson.Safe.to_file status_file status ;
  (* TEMP MAKE REPORT TRACE *)
  Logger.trace top_logger ~module_:__MODULE__ ~location:__LOC__
    "make_report: acquired and wrote status" ;
  (*coda logs*)
  let coda_log = conf_dir ^/ "coda.log" in
  let () =
    match Core.Sys.file_exists coda_log with
    | `Yes ->
        let coda_short_log = temp_config ^/ "coda_short.log" in
        (*get the last 4MB of the log*)
        let log_size = 4 * 1024 * 1024 |> Int64.of_int in
        let log =
          In_channel.with_file coda_log ~f:(fun in_chan ->
              let len = In_channel.length in_chan in
              In_channel.seek in_chan
                Int64.(max 0L (Int64.( + ) len (Int64.neg log_size))) ;
              In_channel.input_all in_chan )
        in
        Out_channel.write_all coda_short_log ~data:log
    | _ ->
        ()
  in
  (*System info/crash summary*)
  let summary = summary exn_str in
  Yojson.to_file (temp_config ^/ "crash_summary.json") summary ;
  (*copy daemon_json to the temp dir *)
  let daemon_config = conf_dir ^/ "daemon.json" in
  let _ =
    if Core.Sys.file_exists daemon_config = `Yes then
      Core.Sys.command
        (sprintf "cp %s %s" daemon_config (temp_config ^/ "daemon.json"))
      |> ignore
  in
  (*Zip them all up*)
  let tmp_files =
    [ "coda_short.log"
    ; "registered_mask.dot"
    ; "frontier.dot"
    ; "coda_status.json"
    ; "crash_summary.json"
    ; "daemon.json" ]
    |> List.filter ~f:(fun f -> Core.Sys.file_exists (temp_config ^/ f) = `Yes)
  in
  let files = tmp_files |> String.concat ~sep:" " in
  let tar_command =
    sprintf "tar  -C %s -czf %s %s" temp_config report_file files
  in
  let exit = Core.Sys.command tar_command in
  if exit = 2 then (
    Logger.fatal top_logger ~module_:__MODULE__ ~location:__LOC__
      "Error making the crash report. Exit code: %d" exit ;
    None )
  else Some (report_file, temp_config)

(* TODO: handle participation_status more appropriately than doing participate_exn *)
let setup_local_server ?(client_trustlist = []) ?rest_server_port
    ?(insecure_rest_server = false) coda =
  let client_trustlist =
    ref
      (Unix.Cidr.Set.of_list
         ( Unix.Cidr.create ~base_address:Unix.Inet_addr.localhost ~bits:8
         :: client_trustlist ))
  in
  (* Setup RPC server for client interactions *)
  let implement rpc f =
    Rpc.Rpc.implement rpc (fun () input ->
        trace_recurring (Rpc.Rpc.name rpc) (fun () -> f () input) )
  in
  let implement_notrace = Rpc.Rpc.implement in
  let logger =
    Logger.extend
      (Coda_lib.top_level_logger coda)
      [("coda_run", `String "Setting up server logs")]
  in
  let client_impls =
    [ implement Daemon_rpcs.Send_user_commands.rpc (fun () ts ->
          Deferred.map
            ( Coda_commands.setup_and_submit_user_commands coda ts
            |> Participating_state.to_deferred_or_error )
            ~f:Or_error.join )
    ; implement Daemon_rpcs.Get_balance.rpc (fun () aid ->
          return
            ( Coda_commands.get_balance coda aid
            |> Participating_state.active_error ) )
    ; implement Daemon_rpcs.Get_trust_status.rpc (fun () ip_address ->
          return (Coda_commands.get_trust_status coda ip_address) )
    ; implement Daemon_rpcs.Get_trust_status_all.rpc (fun () () ->
          return (Coda_commands.get_trust_status_all coda) )
    ; implement Daemon_rpcs.Reset_trust_status.rpc (fun () ip_address ->
          return (Coda_commands.reset_trust_status coda ip_address) )
    ; implement Daemon_rpcs.Verify_proof.rpc (fun () (aid, tx, proof) ->
          return
            ( Coda_commands.verify_payment coda aid tx proof
            |> Participating_state.active_error |> Or_error.join ) )
    ; implement Daemon_rpcs.Prove_receipt.rpc (fun () (proving_receipt, aid) ->
          let open Deferred.Or_error.Let_syntax in
          let%bind acc_opt =
            Coda_commands.get_account coda aid
            |> Participating_state.active_error |> Deferred.return
          in
          let%bind account =
            Result.of_option acc_opt
              ~error:
                (Error.of_string
                   (sprintf
                      !"Could not find account of public key %{sexp: \
                        Account_id.t}"
                      aid))
            |> Deferred.return
          in
          Coda_commands.prove_receipt coda ~proving_receipt
            ~resulting_receipt:account.Account.Poly.receipt_chain_hash )
    ; implement Daemon_rpcs.Get_public_keys_with_details.rpc (fun () () ->
          return
            ( Coda_commands.get_keys_with_details coda
            |> Participating_state.active_error ) )
    ; implement Daemon_rpcs.Get_public_keys.rpc (fun () () ->
          return
            ( Coda_commands.get_public_keys coda
            |> Participating_state.active_error ) )
    ; implement Daemon_rpcs.Get_nonce.rpc (fun () aid ->
          return
            ( Coda_commands.get_nonce coda aid
            |> Participating_state.active_error ) )
    ; implement Daemon_rpcs.Get_inferred_nonce.rpc (fun () aid ->
          return
            ( Coda_lib.get_inferred_nonce_from_transaction_pool_and_ledger coda
                aid
            |> Participating_state.active_error ) )
    ; implement_notrace Daemon_rpcs.Get_status.rpc (fun () flag ->
          Coda_commands.get_status ~flag coda )
    ; implement Daemon_rpcs.Clear_hist_status.rpc (fun () flag ->
          Coda_commands.clear_hist_status ~flag coda )
    ; implement Daemon_rpcs.Get_ledger.rpc (fun () lh ->
          Coda_lib.get_ledger coda lh )
    ; implement Daemon_rpcs.Stop_daemon.rpc (fun () () ->
          Scheduler.yield () >>= (fun () -> exit 0) |> don't_wait_for ;
          Deferred.unit )
    ; implement Daemon_rpcs.Snark_job_list.rpc (fun () () ->
          return (snark_job_list_json coda |> Participating_state.active_error)
      )
    ; implement Daemon_rpcs.Snark_pool_list.rpc (fun () () ->
          return (snark_pool_list coda) )
    ; implement Daemon_rpcs.Start_tracing.rpc (fun () () ->
          let open Coda_lib.Config in
          Coda_tracing.start (Coda_lib.config coda).conf_dir )
    ; implement Daemon_rpcs.Stop_tracing.rpc (fun () () ->
          Coda_tracing.stop () ; Deferred.unit )
    ; implement Daemon_rpcs.Visualization.Frontier.rpc (fun () filename ->
          return (Coda_lib.visualize_frontier ~filename coda) )
    ; implement Daemon_rpcs.Visualization.Registered_masks.rpc
        (fun () filename -> return (Coda_base.Ledger.Debug.visualize ~filename)
      )
    ; implement Daemon_rpcs.Set_staking.rpc (fun () keypairs ->
          let keypair_and_compressed_key =
            List.map keypairs
              ~f:(fun ({Keypair.Stable.Latest.public_key; _} as keypair) ->
                (keypair, Public_key.compress public_key) )
          in
          Coda_lib.replace_block_production_keypairs coda
            (Keypair.And_compressed_pk.Set.of_list keypair_and_compressed_key) ;
          Deferred.unit )
    ; implement Daemon_rpcs.Add_trustlist.rpc (fun () cidr ->
          return
            (let cidr_str = Unix.Cidr.to_string cidr in
             if Unix.Cidr.Set.mem !client_trustlist cidr then
               Or_error.errorf "%s already present in trustlist" cidr_str
             else (
               client_trustlist := Unix.Cidr.Set.add !client_trustlist cidr ;
               Ok () )) )
    ; implement Daemon_rpcs.Remove_trustlist.rpc (fun () cidr ->
          return
            (let cidr_str = Unix.Cidr.to_string cidr in
             if not @@ Unix.Cidr.Set.mem !client_trustlist cidr then
               Or_error.errorf "%s not present in trustlist" cidr_str
             else (
               client_trustlist := Unix.Cidr.Set.remove !client_trustlist cidr ;
               Ok () )) )
    ; implement Daemon_rpcs.Get_trustlist.rpc (fun () () ->
          return (Set.to_list !client_trustlist) )
    ; implement Daemon_rpcs.Get_telemetry_data.rpc (fun () peers ->
          Telemetry.get_telemetry_data_from_peers (Coda_lib.net coda) peers )
    ]
  in
  let snark_worker_impls =
    [ implement Snark_worker.Rpcs_versioned.Get_work.Latest.rpc (fun () () ->
          Deferred.return
            (let open Option.Let_syntax in
            let%bind snark_worker_key = Coda_lib.snark_worker_key coda in
            let%map r = Coda_lib.request_work coda in
            Logger.trace logger ~module_:__MODULE__ ~location:__LOC__
              ~metadata:[("work_spec", Snark_worker.Work.Spec.to_yojson r)]
              "responding to a Get_work request with some new work" ;
            Coda_metrics.(Counter.inc_one Snark_work.snark_work_assigned_rpc) ;
            (r, snark_worker_key)) )
    ; implement Snark_worker.Rpcs_versioned.Submit_work.Latest.rpc
        (fun () (work : Snark_worker.Work.Result.t) ->
          Coda_metrics.(
            Counter.inc_one Snark_work.completed_snark_work_received_rpc) ;
          Logger.trace logger ~module_:__MODULE__ ~location:__LOC__
            "received completed work from a snark worker"
            ~metadata:
              [("work_spec", Snark_worker.Work.Spec.to_yojson work.spec)] ;
          One_or_two.iter work.metrics ~f:(fun (total, tag) ->
              match tag with
              | `Merge ->
                  Perf_histograms.add_span ~name:"snark_worker_merge_time"
                    total
              | `Transition ->
                  Perf_histograms.add_span ~name:"snark_worker_transition_time"
                    total ) ;
          Deferred.return @@ Coda_lib.add_work coda work ) ]
  in
  Option.iter rest_server_port ~f:(fun rest_server_port ->
      trace_task "REST server" (fun () ->
          let graphql_callback =
            Graphql_cohttp_async.make_callback
              (fun _req -> coda)
              Coda_graphql.schema
          in
          Cohttp_async.(
            Server.create_expert
              ~on_handler_error:
                (`Call
                  (fun _net exn ->
                    Logger.error logger ~module_:__MODULE__ ~location:__LOC__
                      "Exception while handling REST server request: $error"
                      ~metadata:
                        [ ("error", `String (Exn.to_string_mach exn))
                        ; ("context", `String "rest_server") ] ))
              (Tcp.Where_to_listen.bind_to
                 (if insecure_rest_server then All_addresses else Localhost)
                 (On_port rest_server_port))
              (fun ~body _sock req ->
                let uri = Cohttp.Request.uri req in
                let status flag =
                  let%bind status = Coda_commands.get_status ~flag coda in
                  Server.respond_string
                    ( status |> Daemon_rpcs.Types.Status.to_yojson
                    |> Yojson.Safe.pretty_to_string )
                in
                let lift x = `Response x in
                match Uri.path uri with
                | "/graphql" ->
                    Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
                      "Received graphql request. Uri: $uri"
                      ~metadata:
                        [ ("uri", `String (Uri.to_string uri))
                        ; ("context", `String "rest_server") ] ;
                    graphql_callback () req body
                | "/status" ->
                    status `None >>| lift
                | "/status/performance" ->
                    status `Performance >>| lift
                | _ ->
                    Server.respond_string ~status:`Not_found "Route not found"
                    >>| lift ))
          |> Deferred.map ~f:(fun _ ->
                 Logger.info logger
                   !"Created GraphQL server at: http://localhost:%i/graphql"
                   rest_server_port ~module_:__MODULE__ ~location:__LOC__ ) )
  ) ;
  let where_to_listen =
    Tcp.Where_to_listen.bind_to All_addresses
      (On_port (Coda_lib.client_port coda))
  in
  don't_wait_for
    (Deferred.ignore
       (trace "client RPC handling" (fun () ->
            Tcp.Server.create
              ~on_handler_error:
                (`Call
                  (fun _net exn ->
                    Logger.error logger ~module_:__MODULE__ ~location:__LOC__
                      "Exception while handling TCP server request: $error"
                      ~metadata:
                        [ ("error", `String (Exn.to_string_mach exn))
                        ; ("context", `String "rpc_tcp_server") ] ))
              where_to_listen
              (fun address reader writer ->
                let address = Socket.Address.Inet.addr address in
                if
                  not
                    (Set.exists !client_trustlist ~f:(fun cidr ->
                         Unix.Cidr.does_match cidr address ))
                then (
                  Logger.error logger ~module_:__MODULE__ ~location:__LOC__
                    !"Rejecting client connection from $address, it is not \
                      present in the trustlist."
                    ~metadata:
                      [("$address", `String (Unix.Inet_addr.to_string address))] ;
                  Deferred.unit )
                else
                  Rpc.Connection.server_with_close reader writer
                    ~implementations:
                      (Rpc.Implementations.create_exn
                         ~implementations:(client_impls @ snark_worker_impls)
                         ~on_unknown_rpc:`Raise)
                    ~connection_state:(fun _ -> ())
                    ~on_handshake_error:
                      (`Call
                        (fun exn ->
                          Logger.error logger ~module_:__MODULE__
                            ~location:__LOC__
                            "Exception while handling RPC server request from \
                             $address: $error"
                            ~metadata:
                              [ ("error", `String (Exn.to_string_mach exn))
                              ; ("context", `String "rpc_server")
                              ; ( "address"
                                , `String (Unix.Inet_addr.to_string address) )
                              ] ;
                          Deferred.unit )) ) )))

let coda_crash_message ~log_issue ~action ~error =
  let followup =
    if log_issue then
      sprintf
        !{err| The Coda Protocol developers would like to know why!

    Please:
      Open an issue:
        <https://github.com/CodaProtocol/coda/issues/new>

      Briefly describe what you were doing and %s

    %!|err}
        action
    else action
  in
  sprintf !{err|

  ☠  Coda Daemon %s.
  %s
%!|err} error followup

let no_report exn_str status =
  sprintf
    "include the last 20 lines from .coda-config/coda.log and then paste the \
     following:\n\
     Summary:\n\
     %s\n\
     Status:\n\
     %s\n"
    (Yojson.Safe.to_string status)
    (Yojson.Safe.to_string (summary exn_str))

let handle_crash e ~time_controller ~conf_dir ~top_logger coda_ref =
  let exn_str = Exn.to_string e in
  Logger.fatal top_logger ~module_:__MODULE__ ~location:__LOC__
    "Unhandled top-level exception: $exn\nGenerating crash report"
    ~metadata:[("exn", `String exn_str)] ;
  let%bind status = coda_status !coda_ref in
  (* TEMP MAKE REPORT TRACE *)
  Logger.trace top_logger ~module_:__MODULE__ ~location:__LOC__
    "handle_crash: acquired coda status" ;
  let%map action_string =
    match%map
      Block_time.Timeout.await
        ~timeout_duration:(Block_time.Span.of_ms 30_000L)
        time_controller
        ( try
            make_report exn_str ~conf_dir coda_ref ~top_logger
            >>| fun k -> Ok k
          with exn -> return (Error (Error.of_exn exn)) )
    with
    | `Ok (Ok (Some (report_file, temp_config))) ->
        ( try Core.Sys.command (sprintf "rm -rf %s" temp_config) |> ignore
          with _ -> () ) ;
        sprintf "attach the crash report %s" report_file
    | `Ok (Ok None) ->
        (*TODO: tar failed, should we ask people to zip the temp directory themselves?*)
        no_report exn_str status
    | `Ok (Error e) ->
        Logger.fatal top_logger ~module_:__MODULE__ ~location:__LOC__
          "Exception when generating crash report: $exn"
          ~metadata:[("exn", `String (Error.to_string_hum e))] ;
        no_report exn_str status
    | `Timeout ->
        Logger.fatal top_logger ~module_:__MODULE__ ~location:__LOC__
          "Timed out while generated crash report" ;
        no_report exn_str status
  in
  let message =
    coda_crash_message ~error:"crashed" ~action:action_string ~log_issue:true
  in
  Core.print_string message

let handle_shutdown ~monitor ~time_controller ~conf_dir ~top_logger coda_ref =
  Monitor.detach_and_iter_errors monitor ~f:(fun exn ->
      don't_wait_for
        (let%bind () =
           match Monitor.extract_exn exn with
           | Coda_networking.No_initial_peers ->
               let message =
                 coda_crash_message
                   ~error:"failed to connect to any initial peers"
                   ~action:
                     "You might be trying to connect to a different network \
                      version, or need to troubleshoot your configuration. \
                      See https://codaprotocol.com/docs/troubleshooting/ for \
                      details."
                   ~log_issue:false
               in
               Core.print_string message ; Deferred.unit
           | Genesis_ledger_helper.Genesis_state_initialization_error ->
               let message =
                 coda_crash_message
                   ~error:"failed to initialize the genesis state"
                   ~action:
                     "include the last 50 lines from .coda-config/coda.log"
                   ~log_issue:true
               in
               Core.print_string message ; Deferred.unit
           | _ ->
               handle_crash exn ~time_controller ~conf_dir ~top_logger coda_ref
         in
         Stdlib.exit 1) ) ;
  Async_unix.Signal.(
    handle terminating ~f:(fun signal ->
        log_shutdown ~conf_dir ~top_logger coda_ref ;
        let logger =
          Logger.extend top_logger
            [("coda_run", `String "Program was killed by signal")]
        in
        Logger.info logger ~module_:__MODULE__ ~location:__LOC__
          !"Coda process was interrupted by $signal"
          ~metadata:[("signal", `String (to_string signal))] ;
        (* causes async shutdown and at_exit handlers to run *)
        Async.shutdown 130 ))
