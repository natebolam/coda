open Core
open Coda_transition
open Signature_lib
open Async

let name = "coda-change-snark-worker-test"

let main () =
  let snark_worker_and_block_producer_id = 0 in
  let logger = Logger.create () in
  let n = 2 in
  let block_production_keys i =
    if i = snark_worker_and_block_producer_id then Some i else None
  in
  let largest_public_key = Test_genesis_ledger.largest_account_pk_exn () in
  let snark_work_public_keys i =
    if i = snark_worker_and_block_producer_id then Some largest_public_key
    else None
  in
  let%bind testnet =
    Coda_worker_testnet.test ~name logger n block_production_keys
      snark_work_public_keys Cli_lib.Arg_type.Work_selection_method.Sequence
      ~max_concurrent_connections:None
  in
  let%bind new_block_pipe1, new_block_pipe2 =
    let%map pipe =
      Coda_worker_testnet.Api.validated_transitions_keyswaptest testnet
        snark_worker_and_block_producer_id
    in
    Pipe.fork ~pushback_uses:`Fast_consumer_only (Option.value_exn pipe).pipe
  in
  let wait_for_snark_worker_proof new_block_pipe public_key =
    let found_snark_prover_ivar = Ivar.create () in
    Pipe.iter new_block_pipe ~f:(fun transition ->
        let completed_works =
          Staged_ledger_diff.completed_works
          @@ External_transition.Validated.staged_ledger_diff transition
        in
        if
          List.exists completed_works
            ~f:(fun {Transaction_snark_work.prover; _} ->
              Logger.trace logger "Prover of completed work"
                ~module_:__MODULE__ ~location:__LOC__
                ~metadata:[("Prover", Public_key.Compressed.to_yojson prover)] ;
              Public_key.Compressed.equal prover public_key )
        then (
          Logger.trace logger "Found snark prover ivar filled"
            ~module_:__MODULE__ ~location:__LOC__
            ~metadata:
              [("public key", Public_key.Compressed.to_yojson public_key)] ;
          Ivar.fill_if_empty found_snark_prover_ivar () )
        else () ;
        Deferred.unit )
    |> don't_wait_for ;
    Ivar.read found_snark_prover_ivar
  in
  Logger.trace logger "Waiting to get snark work from largest public key"
    ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ( "largest public key"
        , Public_key.Compressed.to_yojson largest_public_key ) ] ;
  let%bind () =
    wait_for_snark_worker_proof new_block_pipe1 largest_public_key
  in
  let new_snark_worker =
    Test_genesis_ledger.find_new_account_record_exn_ [largest_public_key]
    |> Test_genesis_ledger.pk_of_account_record
  in
  Logger.trace logger "Setting new snark worker key"
    ~metadata:
      [("new snark worker", Public_key.Compressed.to_yojson new_snark_worker)]
    ~module_:__MODULE__ ~location:__LOC__ ;
  let%bind () =
    let%map opt =
      Coda_worker_testnet.Api.replace_snark_worker_key testnet
        snark_worker_and_block_producer_id (Some new_snark_worker)
    in
    Option.value_exn opt
  in
  let%bind () = wait_for_snark_worker_proof new_block_pipe2 new_snark_worker in
  Logger.trace logger "Finished waiting for snark work with updated key"
    ~module_:__MODULE__ ~location:__LOC__ ;
  (* Testing that nothing should break if the snark worker is set to None *)
  let%bind () =
    let%map opt =
      Coda_worker_testnet.Api.replace_snark_worker_key testnet
        snark_worker_and_block_producer_id None
    in
    Option.value_exn opt
  in
  let%bind () = after (Time.Span.of_sec 30.) in
  Coda_worker_testnet.Api.teardown testnet ~logger

let command =
  Command.async
    ~summary:"Test that a node can change the snark worker dynamically"
    (Async.Command.Spec.return main)
