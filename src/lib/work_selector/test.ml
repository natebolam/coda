open Core_kernel
open Async
open Currency

module Make_test (Make_selection_method : Intf.Make_selection_method_intf) =
struct
  module T = Inputs.Test_inputs

  let reassignment_wait = 2000

  module Lib = Work_lib.Make (T)
  module Selection_method = Make_selection_method (T) (Lib)

  let gen_staged_ledger =
    (*Staged_ledger for tests is a list of work specs*)
    Quickcheck.Generator.list
    @@ Snark_work_lib.Work.Single.Spec.gen Int.quickcheck_generator
         Int.quickcheck_generator Fee.gen

  let precomputed_values = Precomputed_values.for_unit_tests

  let%test_unit "Workspec chunk doesn't send same things again" =
    Backtrace.elide := false ;
    let p = 50 in
    let snark_pool = T.Snark_pool.create () in
    let fee = Currency.Fee.zero in
    let logger = Logger.null () in
    Quickcheck.test gen_staged_ledger ~trials:100 ~f:(fun sl ->
        Async.Thread_safe.block_on_async_exn (fun () ->
            let open Deferred.Let_syntax in
            let rec go i seen =
              [%test_result: Bool.t]
                ~message:"Exceeded time expected to exhaust work" ~expect:true
                (i <= p) ;
              let stuff, seen =
                Selection_method.work ~snark_pool ~fee sl seen ~logger
                  ~get_protocol_state:(fun _ ->
                    Ok
                      (Lazy.force precomputed_values).protocol_state_with_hash
                        .data )
                |> Or_error.ok_exn
              in
              match stuff with None -> return () | _ -> go (i + 1) seen
            in
            go 0 (Lib.State.init ~reassignment_wait) ) )

  let%test_unit "Reassign work after the wait time" =
    Backtrace.elide := false ;
    let snark_pool = T.Snark_pool.create () in
    let fee = Currency.Fee.zero in
    let logger = Logger.null () in
    let send_work sl seen =
      let rec go seen all_work =
        let stuff, seen =
          Selection_method.work ~snark_pool ~fee sl seen ~logger
            ~get_protocol_state:(fun _ ->
              Ok (Lazy.force precomputed_values).protocol_state_with_hash.data
          )
          |> Or_error.ok_exn
        in
        match stuff with
        | None ->
            (all_work, seen)
        | Some work ->
            go seen (One_or_two.to_list work @ all_work)
      in
      go seen []
    in
    Quickcheck.test gen_staged_ledger ~trials:10 ~f:(fun sl ->
        Async.Thread_safe.block_on_async_exn (fun () ->
            let open Deferred.Let_syntax in
            let work_sent, seen =
              send_work sl (Lib.State.init ~reassignment_wait)
            in
            (*wait for wait_time after which all the work will be reassigned*)
            let%map () =
              Async.after (Time.Span.of_ms (Float.of_int reassignment_wait))
            in
            let work_sent_again, _seen = send_work sl seen in
            assert (List.length work_sent = List.length work_sent_again) ) )

  let gen_snark_pool (works : ('a, 'b, 'c) Lib.Work_spec.t One_or_two.t list)
      fee =
    let open Quickcheck.Generator.Let_syntax in
    let cheap_work_fee = Option.value_exn Fee.(sub fee one) in
    let expensive_work_fee = Option.value_exn Fee.(add fee one) in
    let snark_pool = T.Snark_pool.create () in
    let rec add_works = function
      | [] ->
          return ()
      | work :: rest ->
          let%bind fee =
            Quickcheck.Generator.of_list [cheap_work_fee; expensive_work_fee]
          in
          T.Snark_pool.add_snark snark_pool ~work ~fee ;
          add_works rest
    in
    let%map () =
      add_works (List.map ~f:(One_or_two.map ~f:Lib.Work_spec.statement) works)
    in
    snark_pool

  let%test_unit "selector shouldn't get work that it cannot outbid" =
    Backtrace.elide := false ;
    let my_fee = Currency.Fee.of_int 2 in
    let p = 50 in
    let logger = Logger.null () in
    let g =
      let open Quickcheck.Generator.Let_syntax in
      let%bind sl = gen_staged_ledger in
      let%map pool =
        gen_snark_pool
          ( T.Staged_ledger.all_work_pairs sl ~get_state:(fun _ ->
                Ok
                  (Lazy.force precomputed_values).protocol_state_with_hash.data
            )
          |> Or_error.ok_exn )
          (Currency.Fee.of_int 2)
      in
      (sl, pool)
    in
    Quickcheck.test g
      ~sexp_of:
        [%sexp_of:
          (int, int, Fee.t) Lib.Work_spec.t list
          * Fee.t T.Snark_pool.Work.Table.t] ~trials:100
      ~f:(fun (sl, snark_pool) ->
        Async.Thread_safe.block_on_async_exn (fun () ->
            let open Deferred.Let_syntax in
            let rec go i seen =
              [%test_result: Bool.t]
                ~message:"Exceeded time expected to exhaust work" ~expect:true
                (i <= p) ;
              let work, seen =
                Selection_method.work ~snark_pool ~fee:my_fee sl seen ~logger
                  ~get_protocol_state:(fun _ ->
                    Ok
                      (Lazy.force precomputed_values).protocol_state_with_hash
                        .data )
                |> Or_error.ok_exn
              in
              match work with
              | None ->
                  return ()
              | Some job ->
                  [%test_result: Bool.t]
                    ~message:"Should not get any cheap jobs" ~expect:true
                    (Lib.For_tests.does_not_have_better_fee ~snark_pool
                       ~fee:my_fee
                       (One_or_two.map job ~f:Lib.Work_spec.statement)) ;
                  go (i + 1) seen
            in
            go 0 (Lib.State.init ~reassignment_wait) ) )
end
