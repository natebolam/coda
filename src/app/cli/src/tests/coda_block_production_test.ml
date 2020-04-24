open Core
open Async

let name = "coda-block-production-test"

let main () =
  let logger = Logger.create () in
  let n = 1 in
  let snark_work_public_keys _ = None in
  let%bind testnet =
    Coda_worker_testnet.test ~name logger n Option.some snark_work_public_keys
      Cli_lib.Arg_type.Work_selection_method.Sequence
      ~max_concurrent_connections:None
  in
  let%bind () = after (Time.Span.of_sec 30.) in
  Coda_worker_testnet.Api.teardown testnet ~logger

let command =
  Command.async ~summary:"Test that blocks get produced"
    (Command.Param.return main)
