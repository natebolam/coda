open Core
open Async

let name = "coda-shared-state-test"

let main () =
  let logger = Logger.create () in
  let n = 2 in
  let keypairs =
    List.map
      (Lazy.force Test_genesis_ledger.accounts)
      ~f:Test_genesis_ledger.keypair_of_account_record_exn
  in
  let public_keys =
    List.map ~f:Test_genesis_ledger.pk_of_account_record
      (Lazy.force Test_genesis_ledger.accounts)
  in
  let snark_work_public_keys i = Some (List.nth_exn public_keys i) in
  let%bind testnet =
    Coda_worker_testnet.test ~name logger n Option.some snark_work_public_keys
      Cli_lib.Arg_type.Work_selection_method.Sequence
      ~max_concurrent_connections:None
  in
  let%bind () =
    Coda_worker_testnet.Payments.send_several_payments testnet ~node:0
      ~keypairs ~n:3
  in
  Coda_worker_testnet.Api.teardown testnet ~logger

let command =
  Command.async ~summary:"Test that workers share states"
    (Command.Param.return main)
