(* TODO: flush on timeout interval in addition to meeting flush capacity *)
open Async_kernel
open Core_kernel
open Frontier_base

let max_latency
    {Genesis_constants.Constraint_constants.block_window_duration_ms; _} =
  Block_time.Span.(
    (block_window_duration_ms |> Int64.of_int |> Block_time.Span.of_ms)
    * of_ms 5L)

module Capacity = struct
  let flush = 30

  let max = flush * 4
end

(* TODO: lift up as Block_time utility *)
module Timer = struct
  open Block_time

  type t =
    { time_controller: Controller.t
    ; f: unit -> unit
    ; span: Span.t
    ; mutable timeout: unit Timeout.t option }

  let create ~time_controller ~f span =
    {time_controller; span; f; timeout= None}

  let start t =
    assert (Option.is_none t.timeout) ;
    let rec run_timeout t =
      t.timeout
      <- Some
           (Timeout.create t.time_controller t.span ~f:(fun _ ->
                t.f () ; run_timeout t ))
    in
    run_timeout t

  let stop t =
    Option.iter t.timeout ~f:(fun timeout ->
        Timeout.cancel t.time_controller timeout () ) ;
    t.timeout <- None

  let reset t = stop t ; start t
end

type work = {diffs: Diff.Lite.E.t list; target_hash: Frontier_hash.t}

type t =
  { diff_array: Diff.Lite.E.t DynArray.t
  ; worker: Worker.t
        (* timer unfortunately needs to be mutable to break recursion *)
  ; mutable timer: Timer.t option
  ; mutable target_hash: Frontier_hash.t
  ; mutable flush_job: unit Deferred.t option
  ; mutable closed: bool }

let check_for_overflow t =
  if DynArray.length t.diff_array > Capacity.max then
    failwith "persistence buffer overflow"

let should_flush t = DynArray.length t.diff_array >= Capacity.flush

let flush t =
  let rec flush_job t =
    let diffs = DynArray.to_list t.diff_array in
    DynArray.clear t.diff_array ;
    DynArray.compact t.diff_array ;
    let%bind () = Worker.dispatch t.worker (diffs, t.target_hash) in
    if should_flush t then flush_job t
    else (
      t.flush_job <- None ;
      Deferred.unit )
  in
  assert (t.flush_job = None) ;
  if DynArray.length t.diff_array > 0 then t.flush_job <- Some (flush_job t)

let create ~(constraint_constants : Genesis_constants.Constraint_constants.t)
    ~time_controller ~base_hash ~worker =
  let t =
    { diff_array= DynArray.create ()
    ; worker
    ; timer= None
    ; target_hash= base_hash
    ; flush_job= None
    ; closed= false }
  in
  let timer =
    Timer.create ~time_controller
      ~f:(fun () -> if t.flush_job = None then flush t)
      (max_latency constraint_constants)
  in
  t.timer <- Some timer ;
  t

let write t ~diffs ~hash_transition =
  let open Frontier_hash in
  if t.closed then failwith "attempt to write to diff buffer after closed" ;
  if not (Frontier_hash.equal t.target_hash hash_transition.source) then
    failwith "invalid hash transition received by persistence buffer" ;
  t.target_hash <- hash_transition.target ;
  List.iter diffs ~f:(DynArray.add t.diff_array) ;
  if should_flush t && t.flush_job = None then flush t
  else check_for_overflow t

let close_and_finish_copy t =
  ( match t.timer with
  | None ->
      failwith "diff buffer timer was never initialized"
  | Some timer ->
      Timer.stop timer ) ;
  t.closed <- true ;
  let%bind () = Option.value t.flush_job ~default:Deferred.unit in
  flush t ;
  Option.value t.flush_job ~default:Deferred.unit
