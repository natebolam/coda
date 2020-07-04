open Core_kernel

module Make
    (Inputs : Intf.Inputs_intf)
    (Lib : Intf.Lib_intf with module Inputs := Inputs) =
struct
  let work ~snark_pool ~fee ~logger ~get_protocol_state
      (staged_ledger : Inputs.Staged_ledger.t) (state : Lib.State.t) =
    let open Or_error.Let_syntax in
    let state = Lib.State.remove_old_assignments state ~logger in
    let%map unseen_jobs =
      Lib.all_unseen_works ~get_protocol_state staged_ledger state
    in
    match Lib.get_expensive_work ~snark_pool ~fee unseen_jobs with
    | [] ->
        (None, state)
    | expensive_work ->
        let i = Random.int (List.length expensive_work) in
        let x = List.nth_exn expensive_work i in
        (Some x, Lib.State.set state x)

  let remove = Lib.State.remove

  let pending_work_statements = Lib.pending_work_statements
end

let%test_module "test" =
  ( module struct
    module Test = Test.Make_test (Make)
  end )
