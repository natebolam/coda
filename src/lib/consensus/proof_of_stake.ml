open Async_kernel
open Core_kernel
open Signed
open Unsigned
open Currency
open Fold_lib
open Signature_lib
open Snark_params
open Bitstring_lib
open Num_util
module Time = Block_time
module Run = Snark_params.Tick.Run
module Graphql_base_types = Graphql_lib.Base_types
module Length = Coda_numbers.Length

let m = Snark_params.Tick.m

let make_checked t =
  let open Snark_params.Tick in
  with_state (As_prover.return ()) (Run.make_checked t)

let name = "proof_of_stake"

let genesis_ledger_total_currency ~ledger =
  Coda_base.Ledger.to_list (Lazy.force ledger)
  |> List.fold_left ~init:Balance.zero ~f:(fun sum account ->
         Balance.add_amount sum
           (Balance.to_amount @@ account.Coda_base.Account.Poly.balance)
         |> Option.value_exn ?here:None ?error:None
              ~message:"failed to calculate total currency in genesis ledger"
     )
  |> Balance.to_amount

let genesis_ledger_hash ~ledger =
  Coda_base.Ledger.merkle_root (Lazy.force ledger)
  |> Coda_base.Frozen_ledger_hash.of_ledger_hash

let compute_delegatee_table keys ~iter_accounts =
  let open Coda_base in
  let outer_table = Public_key.Compressed.Table.create () in
  iter_accounts (fun i (acct : Account.t) ->
      if
        Public_key.Compressed.Set.mem keys acct.delegate
        (* Only default tokens may delegate. *)
        && Token_id.equal acct.token_id Token_id.default
      then
        Public_key.Compressed.Table.update outer_table acct.delegate
          ~f:(function
          | None ->
              Account.Index.Table.of_alist_exn [(i, acct)]
          | Some table ->
              Account.Index.Table.add_exn table ~key:i ~data:acct ;
              table ) ) ;
  (* TODO: this metric tracking currently assumes that the result of
     compute_delegatee_table is called with the full set of block production
     keypairs every time the set changes, which is true right now, but this
     should be control flow should be refactored to make this clearer *)
  let num_delegators =
    Public_key.Compressed.Table.fold outer_table ~init:0
      ~f:(fun ~key:_ ~data sum -> sum + Account.Index.Table.length data)
  in
  Coda_metrics.Gauge.set Coda_metrics.Consensus.staking_keypairs
    (Float.of_int @@ Public_key.Compressed.Set.length keys) ;
  Coda_metrics.Gauge.set Coda_metrics.Consensus.stake_delegators
    (Float.of_int num_delegators) ;
  outer_table

let compute_delegatee_table_sparse_ledger keys ledger =
  compute_delegatee_table keys ~iter_accounts:(fun f ->
      Coda_base.Sparse_ledger.iteri ledger ~f:(fun i acct -> f i acct) )

module Segment_id = Coda_numbers.Nat.Make32 ()

module Typ = Crypto_params.Tick0.Typ

module Configuration = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        { delta: int
        ; k: int
        ; c: int
        ; c_times_k: int
        ; slots_per_epoch: int
        ; slot_duration: int
        ; epoch_duration: int
        ; genesis_state_timestamp: Block_time.Stable.V1.t
        ; acceptable_network_delay: int }
      [@@deriving yojson, fields]

      let to_latest = Fn.id
    end
  end]

  type t = Stable.Latest.t =
    { delta: int
    ; k: int
    ; c: int
    ; c_times_k: int
    ; slots_per_epoch: int
    ; slot_duration: int
    ; epoch_duration: int
    ; genesis_state_timestamp: Block_time.t
    ; acceptable_network_delay: int }
  [@@deriving yojson, fields]

  let t ~constraint_constants ~protocol_constants =
    let constants =
      Constants.create ~constraint_constants ~protocol_constants
    in
    let of_int32 = UInt32.to_int in
    let of_span = Fn.compose Int64.to_int Block_time.Span.to_ms in
    { delta= of_int32 constants.delta
    ; k= of_int32 constants.k
    ; c= of_int32 constants.c
    ; c_times_k= of_int32 constants.c * of_int32 constants.k
    ; slots_per_epoch= of_int32 constants.epoch_size
    ; slot_duration= of_span constants.slot_duration_ms
    ; epoch_duration= of_span constants.epoch_duration
    ; genesis_state_timestamp= constants.genesis_state_timestamp
    ; acceptable_network_delay= of_span constants.delta_duration }
end

module Constants = Constants

module Data = struct
  module Epoch_seed = struct
    include Coda_base.Data_hash.Make_full_size (struct
      let version_byte = Base58_check.Version_bytes.epoch_seed

      let description = "Epoch Seed"
    end)

    (* Data hash versioned boilerplate below *)

    [%%versioned
    module Stable = struct
      module V1 = struct
        module T = struct
          type t = Snark_params.Tick.Field.t
          [@@deriving sexp, compare, hash, version {asserted}]
        end

        include T

        let to_latest = Core.Fn.id

        [%%define_from_scope
        to_yojson, of_yojson]

        include Comparable.Make (T)
        include Hashable.Make_binable (T)
      end
    end]

    type _unused = unit constraint t = Stable.Latest.t

    let initial : t = of_hash Outside_hash_image.t

    let update (seed : t) vrf_result =
      let open Random_oracle in
      hash ~init:Hash_prefix_states.epoch_seed
        [|(seed :> Tick.Field.t); vrf_result|]
      |> of_hash

    let update_var (seed : var) vrf_result =
      let open Random_oracle.Checked in
      make_checked (fun () ->
          hash ~init:Hash_prefix_states.epoch_seed
            [|var_to_hash_packed seed; vrf_result|]
          |> var_of_hash_packed )
  end

  module Epoch_and_slot = struct
    type t = Epoch.t * Slot.t [@@deriving eq, sexp]

    let of_time_exn ~(constants : Constants.t) tm : t =
      let epoch = Epoch.of_time_exn tm ~constants in
      let time_since_epoch =
        Time.diff tm (Epoch.start_time epoch ~constants)
      in
      let slot =
        uint32_of_int64
        @@ Int64.Infix.(
             Time.Span.to_ms time_since_epoch
             / Time.Span.to_ms constants.slot_duration_ms)
      in
      (epoch, slot)
  end

  module Block_data = struct
    type t =
      { stake_proof: Stake_proof.t
      ; global_slot: Coda_numbers.Global_slot.t
      ; vrf_result: Random_oracle.Digest.t }

    let prover_state {stake_proof; _} = stake_proof

    let global_slot {global_slot; _} = global_slot
  end

  module Local_state = struct
    module Snapshot = struct
      type t =
        { ledger: Coda_base.Sparse_ledger.t
        ; delegatee_table:
            Coda_base.Account.t Coda_base.Account.Index.Table.t
            Public_key.Compressed.Table.t }
      [@@deriving sexp]

      let delegators t key =
        Public_key.Compressed.Table.find t.delegatee_table key

      let to_yojson {ledger; delegatee_table} =
        `Assoc
          [ ( "ledger_hash"
            , Coda_base.(
                Sparse_ledger.merkle_root ledger |> Ledger_hash.to_yojson) )
          ; ( "delegators"
            , `Assoc
                ( Hashtbl.to_alist delegatee_table
                |> List.map ~f:(fun (key, delegators) ->
                       ( Public_key.Compressed.to_string key
                       , `Assoc
                           ( Hashtbl.to_alist delegators
                           |> List.map ~f:(fun (addr, account) ->
                                  ( Int.to_string addr
                                  , Coda_base.Account.to_yojson account ) ) )
                       ) ) ) ) ]

      let ledger t = t.ledger
    end

    module Data = struct
      (* Invariant: Snapshot's delegators are taken from accounts in block_production_pubkeys *)
      type t =
        { mutable staking_epoch_snapshot: Snapshot.t
        ; mutable next_epoch_snapshot: Snapshot.t
        ; last_checked_slot_and_epoch:
            (Epoch.t * Slot.t) Public_key.Compressed.Table.t
        ; genesis_epoch_snapshot: Snapshot.t
        ; mutable last_epoch_delegatee_table:
            Coda_base.Account.t Coda_base.Account.Index.Table.t
            Public_key.Compressed.Table.t
            Option.t }
      [@@deriving sexp]

      let to_yojson t =
        `Assoc
          [ ( "staking_epoch_snapshot"
            , [%to_yojson: Snapshot.t] t.staking_epoch_snapshot )
          ; ( "next_epoch_snapshot"
            , [%to_yojson: Snapshot.t] t.next_epoch_snapshot )
          ; ( "last_checked_slot_and_epoch"
            , `Assoc
                ( Public_key.Compressed.Table.to_alist
                    t.last_checked_slot_and_epoch
                |> List.map ~f:(fun (key, epoch_and_slot) ->
                       ( Public_key.Compressed.to_string key
                       , [%to_yojson: Epoch.t * Slot.t] epoch_and_slot ) ) ) )
          ; ( "genesis_epoch_snapshot"
            , [%to_yojson: Snapshot.t] t.genesis_epoch_snapshot ) ]
    end

    (* The outer ref changes whenever we swap in new staker set; all the snapshots are recomputed *)
    type t = Data.t ref [@@deriving sexp, to_yojson]

    let current_epoch_delegatee_table ~(local_state : t) =
      !local_state.staking_epoch_snapshot.delegatee_table

    let last_epoch_delegatee_table ~(local_state : t) =
      !local_state.last_epoch_delegatee_table

    let current_block_production_keys t =
      Public_key.Compressed.Table.keys !t.Data.last_checked_slot_and_epoch
      |> Public_key.Compressed.Set.of_list

    let make_last_checked_slot_and_epoch_table old_table new_keys ~default =
      let module Set = Public_key.Compressed.Set in
      let module Table = Public_key.Compressed.Table in
      let last_checked_slot_and_epoch = Table.create () in
      Set.iter new_keys ~f:(fun pk ->
          let data = Option.value (Table.find old_table pk) ~default in
          Table.add_exn last_checked_slot_and_epoch ~key:pk ~data ) ;
      last_checked_slot_and_epoch

    let create block_producer_pubkeys ~genesis_ledger =
      (* TODO: remove this duplicate of the genesis ledger *)
      let ledger =
        Coda_base.Sparse_ledger.of_any_ledger
          (Coda_base.Ledger.Any_ledger.cast
             (module Coda_base.Ledger)
             (Lazy.force genesis_ledger))
      in
      let delegatee_table =
        compute_delegatee_table_sparse_ledger block_producer_pubkeys ledger
      in
      let genesis_epoch_snapshot = {Snapshot.delegatee_table; ledger} in
      ref
        { Data.staking_epoch_snapshot= genesis_epoch_snapshot
        ; next_epoch_snapshot= genesis_epoch_snapshot
        ; genesis_epoch_snapshot
        ; last_checked_slot_and_epoch=
            make_last_checked_slot_and_epoch_table
              (Public_key.Compressed.Table.create ())
              block_producer_pubkeys ~default:(Epoch.zero, Slot.zero)
        ; last_epoch_delegatee_table= Some delegatee_table }

    let block_production_keys_swap ~(constants : Constants.t) t
        block_production_pubkeys now =
      let old : Data.t = !t in
      let s {Snapshot.ledger; delegatee_table= _} =
        { Snapshot.ledger
        ; delegatee_table=
            compute_delegatee_table_sparse_ledger block_production_pubkeys
              ledger }
      in
      t :=
        { Data.staking_epoch_snapshot= s old.staking_epoch_snapshot
        ; next_epoch_snapshot= s old.next_epoch_snapshot
        ; genesis_epoch_snapshot=
            s old.genesis_epoch_snapshot
            (* assume these keys are different and therefore we haven't checked any
         * slots or epochs *)
        ; last_checked_slot_and_epoch=
            make_last_checked_slot_and_epoch_table
              !t.Data.last_checked_slot_and_epoch block_production_pubkeys
              ~default:
                ((* TODO: Be smarter so that we don't have to look at the slot before again *)
                 let epoch, slot = Epoch_and_slot.of_time_exn now ~constants in
                 (epoch, UInt32.(if slot > zero then sub slot one else slot)))
        ; last_epoch_delegatee_table= None }

    type snapshot_identifier = Staking_epoch_snapshot | Next_epoch_snapshot
    [@@deriving to_yojson]

    let get_snapshot (t : t) id =
      match id with
      | Staking_epoch_snapshot ->
          !t.staking_epoch_snapshot
      | Next_epoch_snapshot ->
          !t.next_epoch_snapshot

    let set_snapshot (t : t) id v =
      match id with
      | Staking_epoch_snapshot ->
          !t.staking_epoch_snapshot <- v
      | Next_epoch_snapshot ->
          !t.next_epoch_snapshot <- v

    let seen_slot (t : t) epoch slot =
      let module Table = Public_key.Compressed.Table in
      let unseens =
        Table.to_alist !t.last_checked_slot_and_epoch
        |> List.filter_map ~f:(fun (pk, last_checked_epoch_and_slot) ->
               let i =
                 Tuple2.compare ~cmp1:Epoch.compare ~cmp2:Slot.compare
                   last_checked_epoch_and_slot (epoch, slot)
               in
               if i >= 0 then None
               else (
                 Table.set !t.last_checked_slot_and_epoch ~key:pk
                   ~data:(epoch, slot) ;
                 Some pk ) )
      in
      match unseens with
      | [] ->
          `All_seen
      | nel ->
          `Unseen (Public_key.Compressed.Set.of_list nel)
  end

  module Epoch_ledger = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ('ledger_hash, 'amount) t =
            {hash: 'ledger_hash; total_currency: 'amount}
          [@@deriving sexp, eq, compare, hash, to_yojson]
        end
      end]

      type ('ledger_hash, 'amount) t =
            ('ledger_hash, 'amount) Stable.Latest.t =
        {hash: 'ledger_hash; total_currency: 'amount}
      [@@deriving sexp, eq, compare, hash, to_yojson]
    end

    module Value = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            ( Coda_base.Frozen_ledger_hash.Stable.V1.t
            , Amount.Stable.V1.t )
            Poly.Stable.V1.t
          [@@deriving sexp, eq, compare, hash, to_yojson]

          let to_latest = Fn.id
        end
      end]

      type t = Stable.Latest.t [@@deriving sexp, eq, compare, hash, to_yojson]
    end

    let graphql_type () : ('ctx, Value.t option) Graphql_async.Schema.typ =
      let open Graphql_async in
      let open Schema in
      obj "epochLedger" ~fields:(fun _ ->
          [ field "hash" ~typ:(non_null string)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.hash; _} ->
                Coda_base.Frozen_ledger_hash.to_string hash )
          ; field "totalCurrency"
              ~typ:(non_null @@ Graphql_base_types.uint64 ())
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.total_currency; _} ->
                Amount.to_uint64 total_currency ) ] )

    let to_input ({hash; total_currency} : Value.t) =
      let open Snark_params.Tick in
      { Random_oracle.Input.field_elements= [|(hash :> Field.t)|]
      ; bitstrings= [|Amount.to_bits total_currency|] }

    type var = (Coda_base.Frozen_ledger_hash.var, Amount.var) Poly.t

    let to_hlist {Poly.hash; total_currency} =
      Coda_base.H_list.[hash; total_currency]

    let of_hlist :
           (unit, 'ledger_hash -> 'total_currency -> unit) Coda_base.H_list.t
        -> ('ledger_hash, 'total_currency) Poly.t =
     fun Coda_base.H_list.[hash; total_currency] -> {hash; total_currency}

    let data_spec =
      Tick.Data_spec.[Coda_base.Frozen_ledger_hash.typ; Amount.typ]

    let typ : (var, Value.t) Typ.t =
      Tick.Typ.of_hlistable data_spec ~var_to_hlist:to_hlist
        ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist

    let var_to_input ({Poly.hash; total_currency} : var) =
      { Random_oracle.Input.field_elements=
          [|Coda_base.Frozen_ledger_hash.var_to_hash_packed hash|]
      ; bitstrings=
          [|Bitstring.Lsb_first.to_list (Amount.var_to_bits total_currency)|]
      }

    let if_ cond
        ~(then_ : (Coda_base.Frozen_ledger_hash.var, Amount.var) Poly.t)
        ~(else_ : (Coda_base.Frozen_ledger_hash.var, Amount.var) Poly.t) =
      let open Tick.Checked.Let_syntax in
      let%map hash =
        Coda_base.Frozen_ledger_hash.if_ cond ~then_:then_.hash
          ~else_:else_.hash
      and total_currency =
        Amount.Checked.if_ cond ~then_:then_.total_currency
          ~else_:else_.total_currency
      in
      {Poly.hash; total_currency}

    let genesis ~ledger =
      { Poly.hash= genesis_ledger_hash ~ledger
      ; total_currency= genesis_ledger_total_currency ~ledger }
  end

  module Vrf = struct
    module Scalar = struct
      type value = Tick.Inner_curve.Scalar.t

      type var = Tick.Inner_curve.Scalar.var

      let typ : (var, value) Typ.t = Tick.Inner_curve.Scalar.typ
    end

    module Group = struct
      open Tick

      type value = Inner_curve.t

      type var = Inner_curve.var

      let scale = Inner_curve.scale

      module Checked = struct
        include Inner_curve.Checked

        let scale_generator shifted s ~init =
          scale_known shifted Inner_curve.one s ~init
      end
    end

    module Message = struct
      module Global_slot = Coda_numbers.Global_slot

      type ('global_slot, 'epoch_seed, 'delegator) t =
        {global_slot: 'global_slot; seed: 'epoch_seed; delegator: 'delegator}

      type value = (Global_slot.t, Epoch_seed.t, Coda_base.Account.Index.t) t

      type var =
        ( Global_slot.Checked.t
        , Epoch_seed.var
        , Coda_base.Account.Index.Unpacked.var )
        t

      let to_input
          ~(constraint_constants : Genesis_constants.Constraint_constants.t)
          ({global_slot; seed; delegator} : value) =
        { Random_oracle.Input.field_elements= [|(seed :> Tick.field)|]
        ; bitstrings=
            [| Global_slot.Bits.to_bits global_slot
             ; Coda_base.Account.Index.to_bits
                 ~ledger_depth:constraint_constants.ledger_depth delegator |]
        }

      let to_hlist {global_slot; seed; delegator} =
        Coda_base.H_list.[global_slot; seed; delegator]

      let of_hlist :
             ( unit
             , 'global_slot -> 'epoch_seed -> 'del -> unit )
             Coda_base.H_list.t
          -> ('global_slot, 'epoch_seed, 'del) t =
       fun Coda_base.H_list.[global_slot; seed; delegator] ->
        {global_slot; seed; delegator}

      let data_spec
          ~(constraint_constants : Genesis_constants.Constraint_constants.t) =
        let open Tick.Data_spec in
        [ Global_slot.typ
        ; Epoch_seed.typ
        ; Coda_base.Account.Index.Unpacked.typ
            ~ledger_depth:constraint_constants.ledger_depth ]

      let typ ~constraint_constants : (var, value) Typ.t =
        Tick.Typ.of_hlistable
          (data_spec ~constraint_constants)
          ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
          ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist

      let hash_to_group ~constraint_constants msg =
        Group_map.to_group
          (Random_oracle.hash ~init:Coda_base.Hash_prefix.vrf_message
             (Random_oracle.pack_input (to_input ~constraint_constants msg)))
        |> Tick.Inner_curve.of_affine

      module Checked = struct
        open Tick

        let to_input ({global_slot; seed; delegator} : var) =
          let open Tick.Checked.Let_syntax in
          let%map global_slot = Global_slot.Checked.to_bits global_slot in
          let s = Bitstring_lib.Bitstring.Lsb_first.to_list in
          { Random_oracle.Input.field_elements=
              [|Epoch_seed.var_to_hash_packed seed|]
          ; bitstrings= [|s global_slot; delegator|] }

        let hash_to_group msg =
          let%bind input = to_input msg in
          Tick.make_checked (fun () ->
              Group_map.Checked.to_group
                (Random_oracle.Checked.hash
                   ~init:Coda_base.Hash_prefix.vrf_message
                   (Random_oracle.Checked.pack_input input)) )
      end

      let gen
          ~(constraint_constants : Genesis_constants.Constraint_constants.t) =
        let open Quickcheck.Let_syntax in
        let%map global_slot = Global_slot.gen
        and seed = Epoch_seed.gen
        and delegator =
          Coda_base.Account.Index.gen
            ~ledger_depth:constraint_constants.ledger_depth
        in
        {global_slot; seed; delegator}
    end

    module Output = struct
      module Truncated = struct
        [%%versioned
        module Stable = struct
          module V1 = struct
            type t = string [@@deriving sexp, eq, compare, hash, yojson]

            let to_latest = Fn.id
          end
        end]

        type t = Stable.Latest.t [@@deriving sexp, compare, hash, yojson]

        include Codable.Make_base58_check (struct
          type t = Stable.Latest.t [@@deriving bin_io_unversioned]

          let version_byte = Base58_check.Version_bytes.vrf_truncated_output

          let description = "Vrf Truncated Output"
        end)

        let length_in_bytes = 32

        let length_in_bits = 8 * length_in_bytes

        open Tick

        type var = Boolean.var array

        let typ : (var, t) Typ.t =
          Typ.array ~length:length_in_bits Boolean.typ
          |> Typ.transport ~there:Blake2.string_to_bits
               ~back:Blake2.bits_to_string

        let dummy = String.init length_in_bytes ~f:(fun _ -> '\000')

        let to_bits t = Fold.(to_list (string_bits t))
      end

      open Tick

      let typ = Field.typ

      let gen = Field.gen

      let truncate x =
        Random_oracle.Digest.to_bits ~length:Truncated.length_in_bits x
        |> Array.of_list |> Blake2.bits_to_string

      let hash ~constraint_constants msg g =
        let x, y = Non_zero_curve_point.of_inner_curve_exn g in
        let input =
          Random_oracle.Input.(
            append
              (Message.to_input ~constraint_constants msg)
              (field_elements [|x; y|]))
        in
        let open Random_oracle in
        hash ~init:Hash_prefix_states.vrf_output (pack_input input)

      module Checked = struct
        let truncate x =
          Tick.make_checked (fun () ->
              Random_oracle.Checked.Digest.to_bits
                ~length:Truncated.length_in_bits x
              |> Array.of_list )

        let hash msg (x, y) =
          let%bind msg = Message.Checked.to_input msg in
          let input =
            Random_oracle.Input.(append msg (field_elements [|x; y|]))
          in
          make_checked (fun () ->
              let open Random_oracle.Checked in
              hash ~init:Hash_prefix_states.vrf_output (pack_input input) )
      end

      let%test_unit "hash unchecked vs. checked equality" =
        let constraint_constants =
          Genesis_constants.Constraint_constants.for_unit_tests
        in
        let gen_inner_curve_point =
          let open Quickcheck.Generator.Let_syntax in
          let%map compressed = Non_zero_curve_point.gen in
          Non_zero_curve_point.to_inner_curve compressed
        in
        let gen_message_and_curve_point =
          let open Quickcheck.Generator.Let_syntax in
          let%map msg = Message.gen ~constraint_constants
          and g = gen_inner_curve_point in
          (msg, g)
        in
        Quickcheck.test ~trials:10 gen_message_and_curve_point
          ~f:
            (Test_util.test_equal ~equal:Field.equal
               Snark_params.Tick.Typ.(
                 Message.typ ~constraint_constants
                 * Snark_params.Tick.Inner_curve.typ)
               typ
               (fun (msg, g) -> Checked.hash msg g)
               (fun (msg, g) -> hash ~constraint_constants msg g))
    end

    module Threshold = struct
      open Bignum_bigint

      (* TEMPORARY HACK FOR TESTNETS: c should be 1 (or possibly 2) otherwise *)
      let c = `Two_to_the 1

      let base = Bignum.(one / of_int 2)

      let c_bias =
        let (`Two_to_the i) = c in
        fun xs -> List.drop xs i

      let params =
        Snarky_taylor.Exp.params ~base
          ~field_size_in_bits:Snark_params.Tick.Field.size_in_bits

      let bigint_of_uint64 = Fn.compose Bigint.of_string UInt64.to_string

      (*  Check if
          vrf_output / 2^256 <= c * my_stake / total_currency

          So that we don't have to do division we check

          vrf_output * total_currency <= c * my_stake * 2^256
      *)
      let is_satisfied ~my_stake ~total_stake vrf_output =
        let input =
          (* get first params.per_term_precision bits of top / bottom.

            This is equal to

            floor(2^params.per_term_precision * top / bottom) / 2^params.per_term_precision
          *)
          let k = params.per_term_precision in
          let top = bigint_of_uint64 (Balance.to_uint64 my_stake) in
          let bottom = bigint_of_uint64 (Amount.to_uint64 total_stake) in
          Bignum.(
            of_bigint Bignum_bigint.(shift_left top k / bottom)
            / of_bigint Bignum_bigint.(shift_left one k))
        in
        let rhs = Snarky_taylor.Exp.Unchecked.one_minus_exp params input in
        let lhs =
          let n =
            of_bits_lsb
              (c_bias (Array.to_list (Blake2.string_to_bits vrf_output)))
          in
          Bignum.(
            of_bigint n
            / of_bigint
                Bignum_bigint.(shift_left one Output.Truncated.length_in_bits))
        in
        Bignum.(lhs <= rhs)

      module Checked = struct
        let is_satisfied ~my_stake ~total_stake
            (vrf_output : Output.Truncated.var) =
          let open Snarky_integer in
          let open Snarky_taylor in
          make_checked (fun () ->
              let open Run in
              let rhs =
                Exp.one_minus_exp ~m params
                  (Floating_point.of_quotient ~m
                     ~precision:params.per_term_precision
                     ~top:(Integer.of_bits ~m (Balance.var_to_bits my_stake))
                     ~bottom:
                       (Integer.of_bits ~m (Amount.var_to_bits total_stake))
                     ~top_is_less_than_bottom:())
              in
              let vrf_output =
                Array.to_list (vrf_output :> Boolean.var array)
              in
              let lhs = c_bias vrf_output in
              Floating_point.(
                le ~m
                  (of_bits ~m lhs ~precision:Output.Truncated.length_in_bits)
                  rhs) )
      end
    end

    module T =
      Vrf_lib.Integrated.Make (Snark_params.Tick) (Scalar) (Group) (Message)
        (struct
          type value = Snark_params.Tick.Field.t

          type var = Random_oracle.Checked.Digest.t

          let hash = Output.hash

          module Checked = struct
            let hash = Output.Checked.hash
          end
        end)

    type _ Snarky.Request.t +=
      | Winner_address : Coda_base.Account.Index.t Snarky.Request.t
      | Private_key : Scalar.value Snarky.Request.t
      | Public_key : Public_key.t Snarky.Request.t

    let%snarkydef get_vrf_evaluation
        ~(constraint_constants : Genesis_constants.Constraint_constants.t)
        shifted ~ledger ~message =
      let open Coda_base in
      let open Snark_params.Tick in
      let%bind private_key =
        request_witness Scalar.typ (As_prover.return Private_key)
      in
      let%bind public_key =
        request_witness Public_key.typ (As_prover.return Public_key)
      in
      let staker_addr = message.Message.delegator in
      let%bind account =
        with_label __LOC__
          (Frozen_ledger_hash.get ~depth:constraint_constants.ledger_depth
             ledger staker_addr)
      in
      let%bind () =
        [%with_label "Account is for the default token"]
          Token_id.(Checked.Assert.equal account.token_id (var_of_t default))
      in
      let%bind delegate =
        with_label __LOC__ (Public_key.decompress_var account.delegate)
      in
      let%bind () =
        with_label __LOC__ (Public_key.assert_equal public_key delegate)
      in
      let%map evaluation =
        with_label __LOC__
          (T.Checked.eval_and_check_public_key shifted ~private_key
             ~public_key:delegate message)
      in
      (evaluation, account.balance)

    module Checked = struct
      let%snarkydef check
          ~(constraint_constants : Genesis_constants.Constraint_constants.t)
          shifted ~(epoch_ledger : Epoch_ledger.var) ~global_slot ~seed =
        let open Snark_params.Tick in
        let%bind winner_addr =
          request_witness
            (Coda_base.Account.Index.Unpacked.typ
               ~ledger_depth:constraint_constants.ledger_depth)
            (As_prover.return Winner_address)
        in
        let%bind result, my_stake =
          get_vrf_evaluation ~constraint_constants shifted
            ~ledger:epoch_ledger.hash
            ~message:{Message.global_slot; seed; delegator= winner_addr}
        in
        let%bind truncated_result = Output.Checked.truncate result in
        let%map satisifed =
          Threshold.Checked.is_satisfied ~my_stake
            ~total_stake:epoch_ledger.total_currency truncated_result
        in
        (satisifed, result, truncated_result)
    end

    let eval = T.eval

    module Precomputed = struct
      let keypairs = Lazy.force Coda_base.Sample_keypairs.keypairs

      let genesis_winner = keypairs.(0)

      let handler :
             constraint_constants:Genesis_constants.Constraint_constants.t
          -> genesis_ledger:Coda_base.Ledger.t Lazy.t
          -> Snark_params.Tick.Handler.t =
       fun ~constraint_constants ~genesis_ledger ->
        let pk, sk = genesis_winner in
        let dummy_sparse_ledger =
          Coda_base.Sparse_ledger.of_ledger_subset_exn
            (Lazy.force genesis_ledger)
            [Coda_base.(Account_id.create pk Token_id.default)]
        in
        let empty_pending_coinbase =
          Coda_base.Pending_coinbase.create
            ~depth:constraint_constants.pending_coinbase_depth ()
          |> Or_error.ok_exn
        in
        let ledger_handler =
          unstage (Coda_base.Sparse_ledger.handler dummy_sparse_ledger)
        in
        let pending_coinbase_handler =
          unstage
            (Coda_base.Pending_coinbase.handler
               ~depth:constraint_constants.pending_coinbase_depth
               empty_pending_coinbase ~is_new_stack:true)
        in
        let handlers =
          Snarky.Request.Handler.(
            push
              (push fail (create_single pending_coinbase_handler))
              (create_single ledger_handler))
        in
        fun (With {request; respond}) ->
          match request with
          | Winner_address ->
              respond (Provide 0)
          | Private_key ->
              respond (Provide sk)
          | Public_key ->
              respond (Provide (Public_key.decompress_exn pk))
          | _ ->
              respond
                (Provide
                   (Snarky.Request.Handler.run handlers
                      ["Ledger Handler"; "Pending Coinbase Handler"]
                      request))
    end

    let check ~constraint_constants ~global_slot ~seed ~private_key ~public_key
        ~public_key_compressed ~total_stake ~logger ~epoch_snapshot =
      let open Message in
      let open Local_state in
      let open Snapshot in
      with_return (fun {return} ->
          Hashtbl.iteri
            ( Snapshot.delegators epoch_snapshot public_key_compressed
            |> Option.value ~default:(Core_kernel.Int.Table.create ()) )
            ~f:(fun ~key:delegator ~data:account ->
              let vrf_result =
                T.eval ~constraint_constants ~private_key
                  {global_slot; seed; delegator}
              in
              let truncated_vrf_result = Output.truncate vrf_result in
              Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
                "VRF result for delegator: $delegator, balance: $balance, \
                 amount: $amount, result: $result"
                ~metadata:
                  [ ( "delegator"
                    , `Int (Coda_base.Account.Index.to_int delegator) )
                  ; ("balance", `Int (Balance.to_int account.balance))
                  ; ("amount", `Int (Amount.to_int total_stake))
                  ; ( "result"
                    , `String
                        (* use sexp representation; int might be too small *)
                        ( Fold.string_bits truncated_vrf_result
                        |> Bignum_bigint.of_bit_fold_lsb
                        |> Bignum_bigint.sexp_of_t |> Sexp.to_string ) ) ] ;
              Coda_metrics.Counter.inc_one
                Coda_metrics.Consensus.vrf_evaluations ;
              if
                Threshold.is_satisfied ~my_stake:account.balance ~total_stake
                  truncated_vrf_result
              then
                return
                  (Some
                     { Block_data.stake_proof=
                         { private_key
                         ; public_key
                         ; delegator
                         ; ledger= epoch_snapshot.ledger }
                     ; global_slot
                     ; vrf_result }) ) ;
          None )
  end

  module Optional_state_hash = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = Coda_base.State_hash.Stable.V1.t option
        [@@deriving sexp, compare, hash, to_yojson]

        let to_latest = Fn.id
      end
    end]

    type t = Stable.Latest.t [@@deriving sexp, compare, hash, to_yojson]
  end

  module Epoch_data = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ( 'epoch_ledger
               , 'epoch_seed
               , 'start_checkpoint
               , 'lock_checkpoint
               , 'length )
               t =
            { ledger: 'epoch_ledger
            ; seed: 'epoch_seed
            ; start_checkpoint: 'start_checkpoint
                  (* The lock checkpoint is the hash of the latest state in the seed update range, not including
              the current state. *)
            ; lock_checkpoint: 'lock_checkpoint
            ; epoch_length: 'length }
          [@@deriving sexp, eq, compare, hash, to_yojson, fields]
        end
      end]

      type ( 'epoch_ledger
           , 'epoch_seed
           , 'start_checkpoint
           , 'lock_checkpoint
           , 'length )
           t =
            ( 'epoch_ledger
            , 'epoch_seed
            , 'start_checkpoint
            , 'lock_checkpoint
            , 'length )
            Stable.Latest.t =
        { ledger: 'epoch_ledger
        ; seed: 'epoch_seed
        ; start_checkpoint: 'start_checkpoint
        ; lock_checkpoint: 'lock_checkpoint
        ; epoch_length: 'length }
      [@@deriving sexp, compare, hash, to_yojson, fields]
    end

    type var =
      ( Epoch_ledger.var
      , Epoch_seed.var
      , Coda_base.State_hash.var
      , Coda_base.State_hash.var
      , Length.Checked.t )
      Poly.t

    let if_ cond ~(then_ : var) ~(else_ : var) =
      let open Snark_params.Tick.Checked.Let_syntax in
      let%map ledger =
        Epoch_ledger.if_ cond ~then_:then_.ledger ~else_:else_.ledger
      and seed = Epoch_seed.if_ cond ~then_:then_.seed ~else_:else_.seed
      and start_checkpoint =
        Coda_base.State_hash.if_ cond ~then_:then_.start_checkpoint
          ~else_:else_.start_checkpoint
      and lock_checkpoint =
        Coda_base.State_hash.if_ cond ~then_:then_.lock_checkpoint
          ~else_:else_.lock_checkpoint
      and epoch_length =
        Length.Checked.if_ cond ~then_:then_.epoch_length
          ~else_:else_.epoch_length
      in
      {Poly.ledger; seed; start_checkpoint; lock_checkpoint; epoch_length}

    let to_hlist
        {Poly.ledger; seed; start_checkpoint; lock_checkpoint; epoch_length} =
      Coda_base.H_list.
        [ledger; seed; start_checkpoint; lock_checkpoint; epoch_length]

    let of_hlist :
           ( unit
           ,    'ledger
             -> 'seed
             -> 'start_checkpoint
             -> 'lock_checkpoint
             -> 'length
             -> unit )
           Coda_base.H_list.t
        -> ( 'ledger
           , 'seed
           , 'start_checkpoint
           , 'lock_checkpoint
           , 'length )
           Poly.t =
     fun Coda_base.H_list.
           [ledger; seed; start_checkpoint; lock_checkpoint; epoch_length] ->
      {ledger; seed; start_checkpoint; lock_checkpoint; epoch_length}

    module Make (Lock_checkpoint : sig
      type t [@@deriving sexp, compare, hash, to_yojson]

      val typ : (Coda_base.State_hash.var, t) Typ.t

      type graphql_type

      val graphql_type : unit -> ('ctx, graphql_type) Graphql_async.Schema.typ

      val resolve : t -> graphql_type

      val to_input :
        t -> (Snark_params.Tick.Field.t, bool) Random_oracle.Input.t

      val null : t
    end) =
    struct
      open Snark_params

      module Value = struct
        type t =
          ( Epoch_ledger.Value.t
          , Epoch_seed.t
          , Coda_base.State_hash.t
          , Lock_checkpoint.t
          , Length.t )
          Poly.t
        [@@deriving sexp, compare, hash, to_yojson]
      end

      let data_spec =
        let open Tick.Data_spec in
        [ Epoch_ledger.typ
        ; Epoch_seed.typ
        ; Coda_base.State_hash.typ
        ; Lock_checkpoint.typ
        ; Length.typ ]

      let typ : (var, Value.t) Typ.t =
        Typ.of_hlistable data_spec ~var_to_hlist:to_hlist
          ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
          ~value_of_hlist:of_hlist

      let graphql_type name =
        let open Graphql_async in
        let open Schema in
        obj name ~fields:(fun _ ->
            [ field "ledger"
                ~typ:(non_null @@ Epoch_ledger.graphql_type ())
                ~args:Arg.[]
                ~resolve:(fun _ {Poly.ledger; _} -> ledger)
            ; field "seed" ~typ:(non_null string)
                ~args:Arg.[]
                ~resolve:(fun _ {Poly.seed; _} ->
                  Epoch_seed.to_base58_check seed )
            ; field "startCheckpoint" ~typ:(non_null string)
                ~args:Arg.[]
                ~resolve:(fun _ {Poly.start_checkpoint; _} ->
                  Coda_base.State_hash.to_base58_check start_checkpoint )
            ; field "lockCheckpoint"
                ~typ:(Lock_checkpoint.graphql_type ())
                ~args:Arg.[]
                ~resolve:(fun _ {Poly.lock_checkpoint; _} ->
                  Lock_checkpoint.resolve lock_checkpoint )
            ; field "epochLength"
                ~typ:(non_null @@ Graphql_base_types.uint32 ())
                ~args:Arg.[]
                ~resolve:(fun _ {Poly.epoch_length; _} ->
                  Coda_numbers.Length.to_uint32 epoch_length ) ] )

      let to_input
          ({ledger; seed; start_checkpoint; lock_checkpoint; epoch_length} :
            Value.t) =
        let input =
          { Random_oracle.Input.field_elements=
              [|(seed :> Tick.Field.t); (start_checkpoint :> Tick.Field.t)|]
          ; bitstrings= [|Length.Bits.to_bits epoch_length|] }
        in
        List.reduce_exn ~f:Random_oracle.Input.append
          [ input
          ; Epoch_ledger.to_input ledger
          ; Lock_checkpoint.to_input lock_checkpoint ]

      let var_to_input
          ({ledger; seed; start_checkpoint; lock_checkpoint; epoch_length} :
            var) =
        let open Tick in
        let%map epoch_length = Length.Checked.to_bits epoch_length in
        let open Random_oracle.Input in
        let input =
          { field_elements=
              [| Epoch_seed.var_to_hash_packed seed
               ; Coda_base.State_hash.var_to_hash_packed start_checkpoint |]
          ; bitstrings= [|Bitstring.Lsb_first.to_list epoch_length|] }
        in
        List.reduce_exn ~f:Random_oracle.Input.append
          [ input
          ; Epoch_ledger.var_to_input ledger
          ; field (Coda_base.State_hash.var_to_hash_packed lock_checkpoint) ]

      let genesis ~genesis_ledger =
        { Poly.ledger=
            Epoch_ledger.genesis ~ledger:genesis_ledger
            (* TODO: epoch_seed needs to be non-determinable by o1-labs before mainnet launch *)
        ; seed= Epoch_seed.initial
        ; start_checkpoint= Coda_base.State_hash.(of_hash zero)
        ; lock_checkpoint= Lock_checkpoint.null
        ; epoch_length= Length.of_int 1 }
    end

    module T = struct
      include Coda_base.State_hash

      let to_input (t : t) = Random_oracle.Input.field (t :> Tick.Field.t)

      let null = Coda_base.State_hash.(of_hash zero)

      open Graphql_async
      open Schema

      type graphql_type = string

      let graphql_type () = non_null string

      let resolve = to_base58_check
    end

    module Staking = Make (T)
    module Next = Make (T)

    (* stable-versioned types are disallowed as functor application results
       we create them outside the results, and make sure they match the corresponding non-versioned types
    *)

    module Staking_value_versioned = struct
      module Value = struct
        module Lock_checkpoint = Coda_base.State_hash

        [%%versioned
        module Stable = struct
          module V1 = struct
            type t =
              ( Epoch_ledger.Value.Stable.V1.t
              , Epoch_seed.Stable.V1.t
              , Coda_base.State_hash.Stable.V1.t
              , Lock_checkpoint.Stable.V1.t
              , Length.Stable.V1.t )
              Poly.Stable.V1.t
            [@@deriving sexp, compare, eq, hash, to_yojson]

            let to_latest = Fn.id
          end
        end]

        type _unused = unit constraint Stable.Latest.t = Staking.Value.t
      end
    end

    module Next_value_versioned = struct
      module Value = struct
        module Lock_checkpoint = Coda_base.State_hash

        [%%versioned
        module Stable = struct
          module V1 = struct
            type t =
              ( Epoch_ledger.Value.Stable.V1.t
              , Epoch_seed.Stable.V1.t
              , Coda_base.State_hash.Stable.V1.t
              , Lock_checkpoint.Stable.V1.t
              , Length.Stable.V1.t )
              Poly.Stable.V1.t
            [@@deriving sexp, compare, eq, hash, to_yojson]

            let to_latest = Fn.id
          end
        end]

        type _unused = unit constraint Stable.Latest.t = Next.Value.t
      end
    end

    let next_to_staking (next : Next.Value.t) : Staking.Value.t = next

    let update_pair
        ((staking_data, next_data) : Staking.Value.t * Next.Value.t)
        epoch_count ~prev_epoch ~next_epoch ~next_slot
        ~prev_protocol_state_hash ~producer_vrf_result ~snarked_ledger_hash
        ~total_currency ~(constants : Constants.t) =
      let staking_data', next_data', epoch_count' =
        if next_epoch > prev_epoch then
          ( next_to_staking next_data
          , { Poly.seed= next_data.seed
            ; ledger=
                {Epoch_ledger.Poly.hash= snarked_ledger_hash; total_currency}
            ; start_checkpoint=
                prev_protocol_state_hash
                (* TODO: We need to make sure issue #2328 is properly addressed. *)
            ; lock_checkpoint= Coda_base.State_hash.(of_hash zero)
            ; epoch_length= Length.of_int 1 }
          , Length.succ epoch_count )
        else (
          assert (Epoch.equal next_epoch prev_epoch) ;
          ( staking_data
          , Poly.
              {next_data with epoch_length= Length.succ next_data.epoch_length}
          , epoch_count ) )
      in
      let curr_seed, curr_lock_checkpoint =
        if Slot.in_seed_update_range next_slot ~constants then
          ( Epoch_seed.update next_data'.seed producer_vrf_result
          , prev_protocol_state_hash )
        else (next_data'.seed, next_data'.lock_checkpoint)
      in
      let next_data'' =
        Poly.
          { next_data' with
            seed= curr_seed
          ; lock_checkpoint= curr_lock_checkpoint }
      in
      (staking_data', next_data'', epoch_count')
  end

  module Consensus_transition = struct
    include Coda_numbers.Global_slot
    module Value = Coda_numbers.Global_slot

    type var = Checked.t

    let genesis = zero
  end

  module Consensus_time = struct
    include Global_slot

    let to_string_hum = time_hum

    (* externally, we are only interested in when the slot starts *)
    let to_time ~(constants : Constants.t) t = start_time ~constants t

    open UInt32
    open Infix

    (* create dummy block to split map on *)
    let get_old ~constants (t : Global_slot.t) : Global_slot.t =
      let ( `Acceptable_network_delay _
          , `Gc_width _
          , `Gc_width_epoch gc_width_epoch
          , `Gc_width_slot gc_width_slot
          , `Gc_interval _ ) =
        Constants.gc_parameters constants
      in
      let gs = of_epoch_and_slot ~constants (gc_width_epoch, gc_width_slot) in
      if Global_slot.(t < gs) then
        (* block not beyond gc_width *)
        Global_slot.zero ~constants
      else
        let open Int in
        (* subtract epoch, slot components of gc_width *)
        Global_slot.diff ~constants t (gc_width_epoch, gc_width_slot)

    let to_uint32 t = Global_slot.slot_number t
  end

  [%%if
  false]

  module Min_window_density = struct
    (* Three cases for updating the lengths of sub_windows
       - same sub_window, then add 1 to the sub_window_densities
       - passed a few sub_windows, but didn't skip a window, then
         assign 0 to all the skipped sub_window, then mark next_sub_window_length to be 1
       - skipped more than a window, set every sub_windows to be 0 and mark next_sub_window_length to be 1
     *)

    let update_min_window_density ~constants ~prev_global_slot
        ~next_global_slot ~prev_sub_window_densities ~prev_min_window_density =
      let prev_global_sub_window =
        Global_sub_window.of_global_slot ~constants prev_global_slot
      in
      let next_global_sub_window =
        Global_sub_window.of_global_slot ~constants next_global_slot
      in
      let prev_relative_sub_window =
        Global_sub_window.sub_window ~constants prev_global_sub_window
      in
      let next_relative_sub_window =
        Global_sub_window.sub_window ~constants next_global_sub_window
      in
      let same_sub_window =
        Global_sub_window.equal prev_global_sub_window next_global_sub_window
      in
      let same_window =
        Global_sub_window.(
          add prev_global_sub_window
            (constant constants.sub_windows_per_window)
          >= next_global_sub_window)
      in
      let new_sub_window_densities =
        List.mapi prev_sub_window_densities ~f:(fun i length ->
            let gt_prev_sub_window =
              Sub_window.(of_int i > prev_relative_sub_window)
            in
            let lt_next_sub_window =
              Sub_window.(of_int i < next_relative_sub_window)
            in
            let within_range =
              if prev_relative_sub_window < next_relative_sub_window then
                gt_prev_sub_window && lt_next_sub_window
              else gt_prev_sub_window || lt_next_sub_window
            in
            if same_sub_window then length
            else if same_window && not within_range then length
            else Length.zero )
      in
      let new_window_length =
        List.fold new_sub_window_densities ~init:Length.zero ~f:Length.add
      in
      let min_window_density =
        if same_sub_window then prev_min_window_density
        else Length.min new_window_length prev_min_window_density
      in
      let sub_window_densities =
        List.mapi new_sub_window_densities ~f:(fun i length ->
            let is_next_sub_window =
              Sub_window.(of_int i = next_relative_sub_window)
            in
            if is_next_sub_window then
              if same_sub_window then Length.(succ length)
              else Length.(succ zero)
            else length )
      in
      (min_window_density, sub_window_densities)

    module Checked = struct
      open Tick.Checked
      open Tick.Checked.Let_syntax

      let%snarkydef update_min_window_density ~(constants : Constants.var)
          ~prev_global_slot ~next_global_slot ~prev_sub_window_densities
          ~prev_min_window_density =
        let open Tick in
        let open Tick.Checked.Let_syntax in
        let%bind prev_global_sub_window =
          Global_sub_window.Checked.of_global_slot ~constants prev_global_slot
        in
        let%bind next_global_sub_window =
          Global_sub_window.Checked.of_global_slot ~constants next_global_slot
        in
        let%bind prev_relative_sub_window =
          Global_sub_window.Checked.sub_window ~constants
            prev_global_sub_window
        in
        let%bind next_relative_sub_window =
          Global_sub_window.Checked.sub_window ~constants
            next_global_sub_window
        in
        let%bind same_sub_window =
          Global_sub_window.Checked.equal prev_global_sub_window
            next_global_sub_window
        in
        let%bind same_window =
          Global_sub_window.Checked.(
            add prev_global_sub_window constants.sub_windows_per_window
            >= next_global_sub_window)
        in
        let if_ cond ~then_ ~else_ =
          let%bind cond = cond and then_ = then_ and else_ = else_ in
          Length.Checked.if_ cond ~then_ ~else_
        in
        let%bind new_sub_window_densities =
          Checked.List.mapi prev_sub_window_densities ~f:(fun i length ->
              let%bind gt_prev_sub_window =
                Sub_window.Checked.(
                  constant (UInt32.of_int i) > prev_relative_sub_window)
              in
              let%bind lt_next_sub_window =
                Sub_window.Checked.(
                  constant (UInt32.of_int i) < next_relative_sub_window)
              in
              let%bind within_range =
                Sub_window.Checked.(
                  let if_ cond ~then_ ~else_ =
                    let%bind cond = cond and then_ = then_ and else_ = else_ in
                    Boolean.if_ cond ~then_ ~else_
                  in
                  if_
                    (prev_relative_sub_window < next_relative_sub_window)
                    ~then_:Boolean.(gt_prev_sub_window && lt_next_sub_window)
                    ~else_:Boolean.(gt_prev_sub_window || lt_next_sub_window))
              in
              if_
                (Checked.return same_sub_window)
                ~then_:(Checked.return length)
                ~else_:
                  (if_
                     Boolean.(same_window && not within_range)
                     ~then_:(Checked.return length)
                     ~else_:(Checked.return Length.Checked.zero)) )
        in
        let%bind new_window_length =
          Checked.List.fold new_sub_window_densities ~init:Length.Checked.zero
            ~f:Length.Checked.add
        in
        let%bind min_window_density =
          if_
            (Checked.return same_sub_window)
            ~then_:(Checked.return prev_min_window_density)
            ~else_:
              (Length.Checked.min new_window_length prev_min_window_density)
        in
        let%bind sub_window_densities =
          Checked.List.mapi new_sub_window_densities ~f:(fun i length ->
              let%bind is_next_sub_window =
                Sub_window.Checked.(
                  constant (UInt32.of_int i) = next_relative_sub_window)
              in
              if_
                (Checked.return is_next_sub_window)
                ~then_:
                  (if_
                     (Checked.return same_sub_window)
                     ~then_:Length.Checked.(succ length)
                     ~else_:Length.Checked.(succ zero))
                ~else_:(Checked.return length) )
        in
        return (min_window_density, sub_window_densities)
    end

    let%test_module "Min window length tests" =
      ( module struct
        (* This is the reference implementation, which is much more readable than
           the actual implementation. The reason this one is not implemented is because
           array-indexing is not supported in Snarky. We could use list-indexing, but it
           takes O(n) instead of O(1).
         *)

        let update_min_window_density_reference_implementation ~constants
            ~prev_global_slot ~next_global_slot ~prev_sub_window_densities
            ~prev_min_window_density =
          let prev_global_sub_window =
            Global_sub_window.of_global_slot ~constants prev_global_slot
          in
          let next_global_sub_window =
            Global_sub_window.of_global_slot ~constants next_global_slot
          in
          let sub_window_diff =
            UInt32.(
              to_int
              @@ min (succ constants.sub_windows_per_window)
              @@ Global_sub_window.sub next_global_sub_window
                   prev_global_sub_window)
          in
          let n = Array.length prev_sub_window_densities in
          let new_sub_window_densities =
            Array.init n ~f:(fun i ->
                if i + sub_window_diff < n then
                  prev_sub_window_densities.(i + sub_window_diff)
                else Length.zero )
          in
          let new_window_length =
            Array.fold new_sub_window_densities ~init:Length.zero ~f:Length.add
          in
          let min_window_density =
            if sub_window_diff = 0 then prev_min_window_density
            else Length.min new_window_length prev_min_window_density
          in
          new_sub_window_densities.(n - 1)
          <- Length.succ new_sub_window_densities.(n - 1) ;
          (min_window_density, new_sub_window_densities)

        let constants = Constants.for_unit_tests

        (* converting the input for actual implementation to the input required by the
           reference implementation *)
        let actual_to_reference ~prev_global_slot ~prev_sub_window_densities =
          let prev_global_sub_window =
            Global_sub_window.of_global_slot ~constants prev_global_slot
          in
          let prev_relative_sub_window =
            Sub_window.to_int
            @@ Global_sub_window.sub_window ~constants prev_global_sub_window
          in
          List.to_array
          @@ List.drop prev_sub_window_densities prev_relative_sub_window
          @ List.take prev_sub_window_densities prev_relative_sub_window
          @ [List.nth_exn prev_sub_window_densities prev_relative_sub_window]

        (* slot_diff are generated in such a way so that we can test different cases
           in the update function, I use a weighted union to generate it.
           weight | range of the slot diff
           1      | [0*slots_per_sub_window, 1*slots_per_sub_window)
           1/4    | [1*slots_per_sub_window, 2*slots_per_sub_window)
           1/9    | [2*slots_per_sub_window, 3*slots_per_sub_window)
           ...
           1/n^2  | [n*slots_per_sub_window, (n+1)*slots_per_sub_window)
         *)
        let gen_slot_diff =
          let open Quickcheck.Generator in
          let to_int = Length.to_int in
          Quickcheck.Generator.weighted_union
          @@ List.init
               (2 * to_int constants.sub_windows_per_window)
               ~f:(fun i ->
                 ( 1.0 /. (Float.of_int (i + 1) ** 2.)
                 , Core.Int.gen_incl
                     (i * to_int constants.slots_per_sub_window)
                     ((i + 1) * to_int constants.slots_per_sub_window) ) )

        let num_global_slots_to_test = 1

        (* generate an initial global_slot and a list of successive global_slot following
           the initial slot. The length of the list is fixed because this same list would
           also passed into a snarky computation, and the *Typ* of the list requires a
           fixed length. *)
        let gen_global_slots :
            (Global_slot.t * Global_slot.t list) Quickcheck.Generator.t =
          let open Quickcheck.Generator in
          let open Quickcheck.Generator.Let_syntax in
          let module GS = Coda_numbers.Global_slot in
          let%bind prev_global_slot = small_positive_int in
          let%bind slot_diffs =
            Core.List.gen_with_length num_global_slots_to_test gen_slot_diff
          in
          let _, global_slots =
            List.fold slot_diffs ~init:(prev_global_slot, [])
              ~f:(fun (prev_global_slot, acc) slot_diff ->
                let next_global_slot = prev_global_slot + slot_diff in
                (next_global_slot, next_global_slot :: acc) )
          in
          return
            ( Global_slot.of_slot_number ~constants (GS.of_int prev_global_slot)
            , List.map global_slots ~f:(fun s ->
                  Global_slot.of_slot_number ~constants (GS.of_int s) )
              |> List.rev )

        let gen_length =
          Quickcheck.Generator.union
          @@ List.init (Length.to_int constants.slots_per_sub_window)
               ~f:(fun n -> Quickcheck.Generator.return @@ Length.of_int n)

        let gen_min_window_density =
          let open Quickcheck.Generator in
          let open Quickcheck.Generator.Let_syntax in
          let%bind prev_sub_window_densities =
            list_with_length
              (Length.to_int constants.sub_windows_per_window)
              gen_length
          in
          let min_window_density =
            let initial xs = List.(rev (tl_exn (rev xs))) in
            List.fold
              (initial prev_sub_window_densities)
              ~init:Length.zero ~f:Length.add
          in
          return (min_window_density, prev_sub_window_densities)

        let gen =
          Quickcheck.Generator.tuple2 gen_global_slots gen_min_window_density

        let update_several_times ~f ~prev_global_slot ~next_global_slots
            ~prev_sub_window_densities ~prev_min_window_density ~constants =
          List.fold next_global_slots
            ~init:
              ( prev_global_slot
              , prev_sub_window_densities
              , prev_min_window_density )
            ~f:(fun ( prev_global_slot
                    , prev_sub_window_densities
                    , prev_min_window_density )
               next_global_slot
               ->
              let min_window_density, sub_window_densities =
                f ~constants ~prev_global_slot ~next_global_slot
                  ~prev_sub_window_densities ~prev_min_window_density
              in
              (next_global_slot, sub_window_densities, min_window_density) )

        let update_several_times_checked ~f ~prev_global_slot
            ~next_global_slots ~prev_sub_window_densities
            ~prev_min_window_density ~constants =
          let open Tick.Checked in
          let open Tick.Checked.Let_syntax in
          List.fold next_global_slots
            ~init:
              ( prev_global_slot
              , prev_sub_window_densities
              , prev_min_window_density )
            ~f:(fun ( prev_global_slot
                    , prev_sub_window_densities
                    , prev_min_window_density )
               next_global_slot
               ->
              let%bind min_window_density, sub_window_densities =
                f ~constants ~prev_global_slot ~next_global_slot
                  ~prev_sub_window_densities ~prev_min_window_density
              in
              return
                (next_global_slot, sub_window_densities, min_window_density) )

        let%test_unit "the actual implementation is equivalent to the \
                       reference implementation" =
          Quickcheck.test ~trials:100 gen
            ~f:(fun ( ((prev_global_slot : Global_slot.t), next_global_slots)
                    , (prev_min_window_density, prev_sub_window_densities) )
               ->
              let _, _, min_window_density1 =
                update_several_times ~f:update_min_window_density
                  ~prev_global_slot ~next_global_slots
                  ~prev_sub_window_densities ~prev_min_window_density
                  ~constants
              in
              let _, _, min_window_density2 =
                update_several_times
                  ~f:update_min_window_density_reference_implementation
                  ~prev_global_slot ~next_global_slots
                  ~prev_sub_window_densities:
                    (actual_to_reference ~prev_global_slot
                       ~prev_sub_window_densities)
                  ~prev_min_window_density ~constants
              in
              assert (Length.(equal min_window_density1 min_window_density2))
          )

        let%test_unit "Inside snark computation is equivalent to outside \
                       snark computation" =
          Quickcheck.test ~trials:100 gen
            ~f:(fun (slots, min_window_densities) ->
              Test_util.test_equal
                (Typ.tuple3
                   (Typ.tuple2 Global_slot.typ
                      (Typ.list ~length:num_global_slots_to_test
                         Global_slot.typ))
                   (Typ.tuple2 Length.typ
                      (Typ.list
                         ~length:
                           (Length.to_int constants.sub_windows_per_window)
                         Length.typ))
                   Constants.typ)
                (Typ.tuple3 Global_slot.typ
                   (Typ.list
                      ~length:(Length.to_int constants.sub_windows_per_window)
                      Length.typ)
                   Length.typ)
                (fun ( (prev_global_slot, next_global_slots)
                     , (prev_min_window_density, prev_sub_window_densities)
                     , constants ) ->
                  update_several_times_checked
                    ~f:Checked.update_min_window_density ~prev_global_slot
                    ~next_global_slots ~prev_sub_window_densities
                    ~prev_min_window_density ~constants )
                (fun ( (prev_global_slot, next_global_slots)
                     , (prev_min_window_density, prev_sub_window_densities)
                     , constants ) ->
                  update_several_times ~f:update_min_window_density
                    ~prev_global_slot ~next_global_slots
                    ~prev_sub_window_densities ~prev_min_window_density
                    ~constants )
                (slots, min_window_densities, constants) )
      end )
  end

  [%%else]

  module Min_window_density = struct
    let update_min_window_density ~constants ~prev_global_slot
        ~next_global_slot ~prev_sub_window_densities ~prev_min_window_density =
      (prev_min_window_density, prev_sub_window_densities)

    module Checked = struct
      let update_min_window_density ~constants ~prev_global_slot
          ~next_global_slot ~prev_sub_window_densities ~prev_min_window_density
          =
        Tick.Checked.return (prev_min_window_density, prev_sub_window_densities)
    end
  end

  [%%endif]

  (* We have a list of state hashes. When we extend the blockchain,
     we see if the **previous** state should be saved as a checkpoint.
     This is because we have convenient access to the entire previous
     protocol state hash.

     We divide the slots of an epoch into "checkpoint windows": chunks of
     size [checkpoint_window_size]. The goal is to record the first block
     in a given window as a check-point if there are any blocks in that
     window, and zero checkpoints if the window was empty.

     To that end, we store in each state a bit [checkpoint_window_filled] which
     is true iff there has already been a state in the history of the given state
     which is in the same checkpoint window as the given state.
  *)
  module Consensus_state = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ( 'length
               , 'vrf_output
               , 'amount
               , 'global_slot
               , 'staking_epoch_data
               , 'next_epoch_data
               , 'bool )
               t =
            { blockchain_length: 'length
            ; epoch_count: 'length
            ; min_window_density: 'length
            ; sub_window_densities: 'length list
            ; last_vrf_output: 'vrf_output
            ; total_currency: 'amount
            ; curr_global_slot: 'global_slot
            ; staking_epoch_data: 'staking_epoch_data
            ; next_epoch_data: 'next_epoch_data
            ; has_ancestor_in_same_checkpoint_window: 'bool }
          [@@deriving
            sexp, bin_io, eq, compare, hash, to_yojson, version, fields]
        end
      end]

      type ( 'length
           , 'vrf_output
           , 'amount
           , 'global_slot
           , 'staking_epoch_data
           , 'next_epoch_data
           , 'bool )
           t =
            ( 'length
            , 'vrf_output
            , 'amount
            , 'global_slot
            , 'staking_epoch_data
            , 'next_epoch_data
            , 'bool )
            Stable.Latest.t =
        { blockchain_length: 'length
        ; epoch_count: 'length
        ; min_window_density: 'length
        ; sub_window_densities: 'length list
        ; last_vrf_output: 'vrf_output
        ; total_currency: 'amount
        ; curr_global_slot: 'global_slot
        ; staking_epoch_data: 'staking_epoch_data
        ; next_epoch_data: 'next_epoch_data
        ; has_ancestor_in_same_checkpoint_window: 'bool }
      [@@deriving sexp, compare, hash, to_yojson, fields]
    end

    module Value = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            ( Length.Stable.V1.t
            , Vrf.Output.Truncated.Stable.V1.t
            , Amount.Stable.V1.t
            , Global_slot.Stable.V1.t
            , Epoch_data.Staking_value_versioned.Value.Stable.V1.t
            , Epoch_data.Next_value_versioned.Value.Stable.V1.t
            , bool )
            Poly.Stable.V1.t
          [@@deriving sexp, eq, compare, hash]

          let to_latest = Fn.id

          let to_yojson t =
            `Assoc
              [ ("blockchain_length", Length.to_yojson t.Poly.blockchain_length)
              ; ("epoch_count", Length.to_yojson t.epoch_count)
              ; ("min_window_density", Length.to_yojson t.min_window_density)
              ; ( "sub_window_densities"
                , `List (List.map ~f:Length.to_yojson t.sub_window_densities)
                )
              ; ("last_vrf_output", `String "<opaque>")
              ; ("total_currency", Amount.to_yojson t.total_currency)
              ; ("curr_global_slot", Global_slot.to_yojson t.curr_global_slot)
              ; ( "staking_epoch_data"
                , Epoch_data.Staking.Value.to_yojson t.staking_epoch_data )
              ; ( "next_epoch_data"
                , Epoch_data.Next.Value.to_yojson t.next_epoch_data )
              ; ( "has_ancestor_in_same_checkpoint_window"
                , `Bool t.has_ancestor_in_same_checkpoint_window ) ]
        end
      end]

      type t = Stable.Latest.t [@@deriving sexp, eq, compare, hash]

      let to_yojson = Stable.Latest.to_yojson

      module For_tests = struct
        let with_curr_global_slot (state : t) slot_number =
          let curr_global_slot : Global_slot.t =
            Global_slot.For_tests.of_global_slot state.curr_global_slot
              slot_number
          in
          {state with curr_global_slot}
      end
    end

    open Snark_params.Tick

    type var =
      ( Length.Checked.t
      , Vrf.Output.Truncated.var
      , Amount.var
      , Global_slot.Checked.t
      , Epoch_data.var
      , Epoch_data.var
      , Boolean.var )
      Poly.t

    let to_hlist
        { Poly.blockchain_length
        ; epoch_count
        ; min_window_density
        ; sub_window_densities
        ; last_vrf_output
        ; total_currency
        ; curr_global_slot
        ; staking_epoch_data
        ; next_epoch_data
        ; has_ancestor_in_same_checkpoint_window } =
      let open Coda_base.H_list in
      [ blockchain_length
      ; epoch_count
      ; min_window_density
      ; sub_window_densities
      ; last_vrf_output
      ; total_currency
      ; curr_global_slot
      ; staking_epoch_data
      ; next_epoch_data
      ; has_ancestor_in_same_checkpoint_window ]

    let of_hlist :
           ( unit
           ,    'length
             -> 'length
             -> 'length
             -> 'length list
             -> 'vrf_output
             -> 'amount
             -> 'global_slot
             -> 'staking_epoch_data
             -> 'next_epoch_data
             -> 'bool
             -> unit )
           Coda_base.H_list.t
        -> ( 'length
           , 'vrf_output
           , 'amount
           , 'global_slot
           , 'staking_epoch_data
           , 'next_epoch_data
           , 'bool )
           Poly.t =
     fun Coda_base.H_list.
           [ blockchain_length
           ; epoch_count
           ; min_window_density
           ; sub_window_densities
           ; last_vrf_output
           ; total_currency
           ; curr_global_slot
           ; staking_epoch_data
           ; next_epoch_data
           ; has_ancestor_in_same_checkpoint_window ] ->
      { blockchain_length
      ; epoch_count
      ; min_window_density
      ; sub_window_densities
      ; last_vrf_output
      ; total_currency
      ; curr_global_slot
      ; staking_epoch_data
      ; next_epoch_data
      ; has_ancestor_in_same_checkpoint_window }

    let data_spec
        ~(constraint_constants : Genesis_constants.Constraint_constants.t) =
      let open Snark_params.Tick.Data_spec in
      let sub_windows_per_window = constraint_constants.c in
      [ Length.typ
      ; Length.typ
      ; Length.typ
      ; Typ.list ~length:sub_windows_per_window Length.typ
      ; Vrf.Output.Truncated.typ
      ; Amount.typ
      ; Global_slot.typ
      ; Epoch_data.Staking.typ
      ; Epoch_data.Next.typ
      ; Boolean.typ ]

    let typ ~constraint_constants : (var, Value.t) Typ.t =
      Snark_params.Tick.Typ.of_hlistable
        (data_spec ~constraint_constants)
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist

    let to_input
        ({ Poly.blockchain_length
         ; epoch_count
         ; min_window_density
         ; sub_window_densities
         ; last_vrf_output
         ; total_currency
         ; curr_global_slot
         ; staking_epoch_data
         ; next_epoch_data
         ; has_ancestor_in_same_checkpoint_window } :
          Value.t) =
      let input =
        { Random_oracle.Input.bitstrings=
            [| Length.Bits.to_bits blockchain_length
             ; Length.Bits.to_bits epoch_count
             ; Length.Bits.to_bits min_window_density
             ; List.concat_map ~f:Length.Bits.to_bits sub_window_densities
             ; Vrf.Output.Truncated.to_bits last_vrf_output
             ; Amount.to_bits total_currency
             ; Global_slot.to_bits curr_global_slot
             ; [has_ancestor_in_same_checkpoint_window] |]
        ; field_elements= [||] }
      in
      List.reduce_exn ~f:Random_oracle.Input.append
        [ input
        ; Epoch_data.Staking.to_input staking_epoch_data
        ; Epoch_data.Next.to_input next_epoch_data ]

    let var_to_input
        ({ Poly.blockchain_length
         ; epoch_count
         ; min_window_density
         ; sub_window_densities
         ; last_vrf_output
         ; total_currency
         ; curr_global_slot
         ; staking_epoch_data
         ; next_epoch_data
         ; has_ancestor_in_same_checkpoint_window } :
          var) =
      let open Tick.Checked.Let_syntax in
      let%map input =
        let bs = Bitstring.Lsb_first.to_list in
        let up k x = k x >>| Bitstring.Lsb_first.to_list in
        let length = up Length.Checked.to_bits in
        let%map blockchain_length = length blockchain_length
        and epoch_count = length epoch_count
        and min_window_density = length min_window_density
        and curr_global_slot = up Global_slot.Checked.to_bits curr_global_slot
        and sub_window_densities =
          Checked.List.fold sub_window_densities ~init:[] ~f:(fun acc l ->
              let%map res = length l in
              List.append acc res )
        in
        { Random_oracle.Input.bitstrings=
            [| blockchain_length
             ; epoch_count
             ; min_window_density
             ; sub_window_densities
             ; Array.to_list last_vrf_output
             ; bs (Amount.var_to_bits total_currency)
             ; curr_global_slot
             ; [has_ancestor_in_same_checkpoint_window] |]
        ; field_elements= [||] }
      and staking_epoch_data =
        Epoch_data.Staking.var_to_input staking_epoch_data
      and next_epoch_data = Epoch_data.Next.var_to_input next_epoch_data in
      List.reduce_exn ~f:Random_oracle.Input.append
        [input; staking_epoch_data; next_epoch_data]

    let global_slot {Poly.curr_global_slot; _} = curr_global_slot

    let checkpoint_window ~(constants : Constants.t) (slot : Global_slot.t) =
      UInt32.Infix.(
        Global_slot.slot_number slot
        / constants.checkpoint_window_size_in_slots)

    let same_checkpoint_window_unchecked ~constants slot1 slot2 =
      UInt32.Infix.(
        checkpoint_window slot1 ~constants = checkpoint_window slot2 ~constants)

    let time_hum (t : Value.t) =
      let epoch, slot = Global_slot.to_epoch_and_slot t.curr_global_slot in
      sprintf "epoch=%d, slot=%d" (Epoch.to_int epoch) (Slot.to_int slot)

    let update ~(constants : Constants.t) ~(previous_consensus_state : Value.t)
        ~(consensus_transition : Consensus_transition.t)
        ~(previous_protocol_state_hash : Coda_base.State_hash.t)
        ~(supply_increase : Currency.Amount.t)
        ~(snarked_ledger_hash : Coda_base.Frozen_ledger_hash.t)
        ~(producer_vrf_result : Random_oracle.Digest.t) : Value.t Or_error.t =
      let open Or_error.Let_syntax in
      let prev_epoch, prev_slot =
        Global_slot.to_epoch_and_slot previous_consensus_state.curr_global_slot
      in
      let next_global_slot =
        Global_slot.of_slot_number consensus_transition ~constants
      in
      let next_epoch, next_slot =
        Global_slot.to_epoch_and_slot next_global_slot
      in
      let%map total_currency =
        Amount.add previous_consensus_state.total_currency supply_increase
        |> Option.map ~f:Or_error.return
        |> Option.value
             ~default:(Or_error.error_string "failed to add total_currency")
      and () =
        if
          Consensus_transition.(
            equal consensus_transition Consensus_transition.genesis)
          || Global_slot.(
               previous_consensus_state.curr_global_slot < next_global_slot)
        then Ok ()
        else
          Or_error.errorf
            !"(epoch, slot) did not increase. prev=%{sexp:Epoch.t * Slot.t}, \
              next=%{sexp:Epoch.t * Slot.t}"
            (prev_epoch, prev_slot) (next_epoch, next_slot)
      in
      let staking_epoch_data, next_epoch_data, epoch_count =
        Epoch_data.update_pair ~constants
          ( previous_consensus_state.staking_epoch_data
          , previous_consensus_state.next_epoch_data )
          previous_consensus_state.epoch_count ~prev_epoch ~next_epoch
          ~next_slot ~prev_protocol_state_hash:previous_protocol_state_hash
          ~producer_vrf_result ~snarked_ledger_hash ~total_currency
      in
      let min_window_density, sub_window_densities =
        Min_window_density.update_min_window_density ~constants
          ~prev_global_slot:previous_consensus_state.curr_global_slot
          ~next_global_slot
          ~prev_sub_window_densities:
            previous_consensus_state.sub_window_densities
          ~prev_min_window_density:previous_consensus_state.min_window_density
      in
      { Poly.blockchain_length=
          Length.succ previous_consensus_state.blockchain_length
      ; epoch_count
      ; min_window_density
      ; sub_window_densities
      ; last_vrf_output= Vrf.Output.truncate producer_vrf_result
      ; total_currency
      ; curr_global_slot= next_global_slot
      ; staking_epoch_data
      ; next_epoch_data
      ; has_ancestor_in_same_checkpoint_window=
          same_checkpoint_window_unchecked ~constants
            (Global_slot.create ~constants ~epoch:prev_epoch ~slot:prev_slot)
            (Global_slot.create ~constants ~epoch:next_epoch ~slot:next_slot)
      }

    let same_checkpoint_window ~(constants : Constants.var)
        ~prev:(slot1 : Global_slot.Checked.t)
        ~next:(slot2 : Global_slot.Checked.t) =
      let open Snarky_integer in
      let open Run in
      let module Slot = Coda_numbers.Global_slot in
      let slot1 = Slot.Checked.to_integer (Global_slot.slot_number slot1) in
      let checkpoint_window_size_in_slots =
        Length.Checked.to_integer constants.checkpoint_window_size_in_slots
      in
      let _q1, r1 = Integer.div_mod ~m slot1 checkpoint_window_size_in_slots in
      let next_window_start =
        Field.(
          Integer.to_field slot1 - Integer.to_field r1
          + Integer.to_field checkpoint_window_size_in_slots)
      in
      (Field.compare ~bit_length:Slot.length_in_bits
         ( Global_slot.slot_number slot2
         |> Slot.Checked.to_integer |> Integer.to_field )
         next_window_start)
        .less

    let same_checkpoint_window ~constants ~prev ~next =
      make_checked (fun () -> same_checkpoint_window ~constants ~prev ~next)

    let negative_one ~genesis_ledger ~(constants : Constants.t) =
      let max_sub_window_density = constants.slots_per_sub_window in
      let max_window_density = constants.slots_per_window in
      { Poly.blockchain_length= Length.zero
      ; epoch_count= Length.zero
      ; min_window_density= max_window_density
      ; sub_window_densities=
          Length.zero
          :: List.init
               (Length.to_int constants.sub_windows_per_window - 1)
               ~f:(Fn.const max_sub_window_density)
      ; last_vrf_output= Vrf.Output.Truncated.dummy
      ; total_currency= genesis_ledger_total_currency ~ledger:genesis_ledger
      ; curr_global_slot= Global_slot.zero ~constants
      ; staking_epoch_data= Epoch_data.Staking.genesis ~genesis_ledger
      ; next_epoch_data= Epoch_data.Next.genesis ~genesis_ledger
      ; has_ancestor_in_same_checkpoint_window= false }

    let create_genesis_from_transition ~negative_one_protocol_state_hash
        ~consensus_transition ~genesis_ledger ~constraint_constants ~constants
        : Value.t =
      let producer_vrf_result =
        let _, sk = Vrf.Precomputed.genesis_winner in
        Vrf.eval ~constraint_constants ~private_key:sk
          { Vrf.Message.global_slot= consensus_transition
          ; seed= Epoch_seed.initial
          ; delegator= 0 }
      in
      let snarked_ledger_hash =
        Lazy.force genesis_ledger |> Coda_base.Ledger.merkle_root
        |> Coda_base.Frozen_ledger_hash.of_ledger_hash
      in
      Or_error.ok_exn
        (update ~constants ~producer_vrf_result
           ~previous_consensus_state:(negative_one ~genesis_ledger ~constants)
           ~previous_protocol_state_hash:negative_one_protocol_state_hash
           ~consensus_transition ~supply_increase:Currency.Amount.zero
           ~snarked_ledger_hash)

    let create_genesis ~negative_one_protocol_state_hash ~genesis_ledger
        ~constraint_constants ~constants : Value.t =
      create_genesis_from_transition ~negative_one_protocol_state_hash
        ~consensus_transition:Consensus_transition.genesis ~genesis_ledger
        ~constraint_constants ~constants

    (* Check that both epoch and slot are zero.
    *)
    let is_genesis_state (t : Value.t) =
      Coda_numbers.Global_slot.(
        equal zero (Global_slot.slot_number t.curr_global_slot))

    let is_genesis (global_slot : Global_slot.Checked.t) =
      let open Coda_numbers.Global_slot in
      Checked.equal (Checked.constant zero)
        (Global_slot.slot_number global_slot)

    let is_genesis_state_var (t : var) = is_genesis t.curr_global_slot

    let%snarkydef update_var (previous_state : var)
        (transition_data : Consensus_transition.var)
        (previous_protocol_state_hash : Coda_base.State_hash.var)
        ~(supply_increase : Currency.Amount.var)
        ~(previous_blockchain_state_ledger_hash :
           Coda_base.Frozen_ledger_hash.var) ~constraint_constants
        ~(protocol_constants : Coda_base.Protocol_constants_checked.var) =
      let open Snark_params.Tick in
      let%bind constants =
        Constants.Checked.create ~constraint_constants ~protocol_constants
      in
      let {Poly.curr_global_slot= prev_global_slot; _} = previous_state in
      let next_global_slot =
        Global_slot.Checked.of_slot_number ~constants transition_data
      in
      let%bind () =
        let%bind global_slot_increased =
          Global_slot.Checked.(prev_global_slot < next_global_slot)
        in
        let%bind is_genesis = is_genesis next_global_slot in
        Boolean.Assert.any [global_slot_increased; is_genesis]
      in
      let%bind next_epoch, next_slot =
        Global_slot.Checked.to_epoch_and_slot next_global_slot
      and prev_epoch, prev_slot =
        Global_slot.Checked.to_epoch_and_slot prev_global_slot
      in
      let%bind epoch_increased = Epoch.Checked.(prev_epoch < next_epoch) in
      let%bind staking_epoch_data =
        Epoch_data.if_ epoch_increased ~then_:previous_state.next_epoch_data
          ~else_:previous_state.staking_epoch_data
      in
      let%bind threshold_satisfied, vrf_result, truncated_vrf_result =
        let%bind (module M) = Inner_curve.Checked.Shifted.create () in
        Vrf.Checked.check ~constraint_constants
          (module M)
          ~epoch_ledger:staking_epoch_data.ledger
          ~global_slot:(Global_slot.slot_number next_global_slot)
          ~seed:staking_epoch_data.seed
      in
      let%bind new_total_currency =
        Currency.Amount.Checked.add previous_state.total_currency
          supply_increase
      in
      let%bind has_ancestor_in_same_checkpoint_window =
        same_checkpoint_window ~constants ~prev:prev_global_slot
          ~next:next_global_slot
      in
      let%bind in_seed_update_range =
        Slot.Checked.in_seed_update_range next_slot ~constants
      in
      let%bind next_epoch_data =
        let%map seed =
          let base = previous_state.next_epoch_data.seed in
          let%bind updated = Epoch_seed.update_var base vrf_result in
          Epoch_seed.if_ in_seed_update_range ~then_:updated ~else_:base
        and epoch_length =
          let open Length.Checked in
          let%bind base =
            if_ epoch_increased ~then_:zero
              ~else_:previous_state.next_epoch_data.epoch_length
          in
          succ base
        and ledger =
          Epoch_ledger.if_ epoch_increased
            ~then_:
              { total_currency= new_total_currency
              ; hash= previous_blockchain_state_ledger_hash }
            ~else_:previous_state.next_epoch_data.ledger
        and start_checkpoint =
          Coda_base.State_hash.if_ epoch_increased
            ~then_:previous_protocol_state_hash
            ~else_:previous_state.next_epoch_data.start_checkpoint
        (* Want this to be the protocol state hash once we leave the seed
           update range. *)
        and lock_checkpoint =
          let%bind base =
            (* TODO: Should this be zero or some other sentinel value? *)
            Coda_base.State_hash.if_ epoch_increased
              ~then_:Coda_base.State_hash.(var_of_t (of_hash zero))
              ~else_:previous_state.next_epoch_data.lock_checkpoint
          in
          Coda_base.State_hash.if_ in_seed_update_range
            ~then_:previous_protocol_state_hash ~else_:base
        in
        { Epoch_data.Poly.seed
        ; epoch_length
        ; ledger
        ; start_checkpoint
        ; lock_checkpoint }
      and blockchain_length =
        Length.Checked.succ previous_state.blockchain_length
      (* TODO: keep track of total_currency in transaction snark. The current_slot
       * implementation would allow an adversary to make then total_currency incorrect by
       * not adding the coinbase to their account. *)
      and new_total_currency =
        Amount.Checked.add previous_state.total_currency supply_increase
      and epoch_count =
        Length.Checked.succ_if previous_state.epoch_count epoch_increased
      and min_window_density, sub_window_densities =
        Min_window_density.Checked.update_min_window_density ~constants
          ~prev_global_slot ~next_global_slot
          ~prev_sub_window_densities:previous_state.sub_window_densities
          ~prev_min_window_density:previous_state.min_window_density
      in
      Checked.return
        ( `Success threshold_satisfied
        , { Poly.blockchain_length
          ; epoch_count
          ; min_window_density
          ; sub_window_densities
          ; last_vrf_output= truncated_vrf_result
          ; curr_global_slot= next_global_slot
          ; total_currency= new_total_currency
          ; staking_epoch_data
          ; next_epoch_data
          ; has_ancestor_in_same_checkpoint_window } )

    let to_lite = None

    type display =
      { blockchain_length: int
      ; epoch_count: int
      ; curr_epoch: int
      ; curr_slot: int
      ; total_currency: int }
    [@@deriving yojson]

    let display (t : Value.t) =
      let epoch, slot = Global_slot.to_epoch_and_slot t.curr_global_slot in
      { blockchain_length= Length.to_int t.blockchain_length
      ; epoch_count= Length.to_int t.epoch_count
      ; curr_epoch= Segment_id.to_int epoch
      ; curr_slot= Segment_id.to_int slot
      ; total_currency= Amount.to_int t.total_currency }

    let curr_global_slot (t : Value.t) = t.curr_global_slot

    let curr_ f = Fn.compose f curr_global_slot

    let curr_epoch_and_slot = curr_ Global_slot.to_epoch_and_slot

    let curr_epoch = curr_ Global_slot.epoch

    let curr_slot = curr_ Global_slot.slot

    let curr_global_slot_var (t : var) =
      Global_slot.slot_number t.curr_global_slot

    let curr_global_slot (t : Value.t) =
      Global_slot.slot_number t.curr_global_slot

    let consensus_time (t : Value.t) = t.curr_global_slot

    [%%define_locally
    Poly.
      ( blockchain_length
      , epoch_count
      , min_window_density
      , last_vrf_output
      , total_currency
      , staking_epoch_data
      , next_epoch_data
      , has_ancestor_in_same_checkpoint_window )]

    module Unsafe = struct
      (* TODO: very unsafe, do not use unless you know what you are doing *)
      let dummy_advance (t : Value.t) ?(increase_epoch_count = false)
          ~new_global_slot : Value.t =
        let new_epoch_count =
          if increase_epoch_count then Length.succ t.epoch_count
          else t.epoch_count
        in
        {t with epoch_count= new_epoch_count; curr_global_slot= new_global_slot}
    end

    let graphql_type () : ('ctx, Value.t option) Graphql_async.Schema.typ =
      let open Graphql_async in
      let open Schema in
      let uint32, uint64 =
        (Graphql_base_types.uint32 (), Graphql_base_types.uint64 ())
      in
      obj "ConsensusState" ~fields:(fun _ ->
          [ field "blockchainLength" ~typ:(non_null uint32)
              ~doc:"Length of the blockchain at this block"
              ~deprecated:(Deprecated (Some "use blockHeight instead"))
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.blockchain_length; _} ->
                Coda_numbers.Length.to_uint32 blockchain_length )
          ; field "blockHeight" ~typ:(non_null uint32)
              ~doc:"Height of the blockchain at this block"
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.blockchain_length; _} ->
                Coda_numbers.Length.to_uint32 blockchain_length )
          ; field "epochCount" ~typ:(non_null uint32)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.epoch_count; _} ->
                Coda_numbers.Length.to_uint32 epoch_count )
          ; field "minWindowDensity" ~typ:(non_null uint32)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.min_window_density; _} ->
                Coda_numbers.Length.to_uint32 min_window_density )
          ; field "lastVrfOutput" ~typ:(non_null string)
              ~args:Arg.[]
              ~resolve:
                (fun (_ : 'ctx resolve_info) {Poly.last_vrf_output; _} ->
                Vrf.Output.Truncated.to_base58_check last_vrf_output )
          ; field "totalCurrency"
              ~doc:"Total currency in circulation at this block"
              ~typ:(non_null uint64)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.total_currency; _} ->
                Amount.to_uint64 total_currency )
          ; field "stakingEpochData"
              ~typ:
                (non_null @@ Epoch_data.Staking.graphql_type "StakingEpochData")
              ~args:Arg.[]
              ~resolve:
                (fun (_ : 'ctx resolve_info) {Poly.staking_epoch_data; _} ->
                staking_epoch_data )
          ; field "nextEpochData"
              ~typ:(non_null @@ Epoch_data.Next.graphql_type "NextEpochData")
              ~args:Arg.[]
              ~resolve:
                (fun (_ : 'ctx resolve_info) {Poly.next_epoch_data; _} ->
                next_epoch_data )
          ; field "hasAncestorInSameCheckpointWindow" ~typ:(non_null bool)
              ~args:Arg.[]
              ~resolve:
                (fun _ {Poly.has_ancestor_in_same_checkpoint_window; _} ->
                has_ancestor_in_same_checkpoint_window )
          ; field "slot" ~doc:"Slot in which this block was created"
              ~typ:(non_null uint32)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.curr_global_slot; _} ->
                Global_slot.slot curr_global_slot )
          ; field "epoch" ~doc:"Epoch in which this block was created"
              ~typ:(non_null uint32)
              ~args:Arg.[]
              ~resolve:(fun _ {Poly.curr_global_slot; _} ->
                Global_slot.epoch curr_global_slot ) ] )
  end

  module Prover_state = struct
    include Stake_proof

    let precomputed_handler = Vrf.Precomputed.handler

    let handler {delegator; ledger; private_key; public_key}
        ~(constraint_constants : Genesis_constants.Constraint_constants.t)
        ~pending_coinbase:{ Coda_base.Pending_coinbase_witness.pending_coinbases
                          ; is_new_stack } : Snark_params.Tick.Handler.t =
      let ledger_handler = unstage (Coda_base.Sparse_ledger.handler ledger) in
      let pending_coinbase_handler =
        unstage
          (Coda_base.Pending_coinbase.handler
             ~depth:constraint_constants.pending_coinbase_depth
             pending_coinbases ~is_new_stack)
      in
      let handlers =
        Snarky.Request.Handler.(
          push
            (push fail (create_single pending_coinbase_handler))
            (create_single ledger_handler))
      in
      fun (With {request; respond}) ->
        match request with
        | Vrf.Winner_address ->
            respond (Provide delegator)
        | Vrf.Private_key ->
            respond (Provide private_key)
        | Vrf.Public_key ->
            respond (Provide public_key)
        | _ ->
            respond
              (Provide
                 (Snarky.Request.Handler.run handlers
                    ["Ledger Handler"; "Pending Coinbase Handler"]
                    request))

    let ledger_depth {ledger; _} = ledger.depth
  end
end

module Hooks = struct
  open Data

  module Rpcs = struct
    open Async

    module Get_epoch_ledger = struct
      module Master = struct
        let name = "get_epoch_ledger"

        module T = struct
          type query = Coda_base.Ledger_hash.t

          type response = (Coda_base.Sparse_ledger.t, string) Result.t
        end

        module Caller = T
        module Callee = T
      end

      include Master.T
      module M = Versioned_rpc.Both_convert.Plain.Make (Master)
      include M

      include Perf_histograms.Rpc.Plain.Extend (struct
        include M
        include Master
      end)

      module V1 = struct
        module T = struct
          type query = Coda_base.Ledger_hash.Stable.V1.t
          [@@deriving bin_io, version {rpc}]

          type response =
            ( Coda_base.Sparse_ledger.Stable.V1.t
            , string )
            Core_kernel.Result.Stable.V1.t
          [@@deriving bin_io, version {rpc}]

          let query_of_caller_model = Fn.id

          let callee_model_of_query = Fn.id

          let response_of_callee_model = Fn.id

          let caller_model_of_response = Fn.id
        end

        module T' =
          Perf_histograms.Rpc.Plain.Decorate_bin_io (struct
              include M
              include Master
            end)
            (T)

        include T'
        include Register (T')
      end

      let implementation ~logger ~local_state ~genesis_ledger_hash conn
          ~version:_ ledger_hash =
        let open Coda_base in
        let open Local_state in
        let open Snapshot in
        Deferred.create (fun ivar ->
            Logger.info logger ~module_:__MODULE__ ~location:__LOC__
              ~metadata:
                [ ("peer", Network_peer.Peer.to_yojson conn)
                ; ("ledger_hash", Coda_base.Ledger_hash.to_yojson ledger_hash)
                ]
              "Serving epoch ledger query with hash $ledger_hash from $peer" ;
            let response =
              if
                Ledger_hash.equal ledger_hash
                  (Frozen_ledger_hash.to_ledger_hash genesis_ledger_hash)
              then Error "refusing to serve genesis epoch ledger"
              else
                let candidate_snapshots =
                  [ !local_state.Data.staking_epoch_snapshot
                  ; !local_state.Data.next_epoch_snapshot ]
                in
                List.find_map candidate_snapshots ~f:(fun snapshot ->
                    if
                      Ledger_hash.equal ledger_hash
                        (Sparse_ledger.merkle_root snapshot.ledger)
                    then Some snapshot.ledger
                    else None )
                |> Result.of_option ~error:"epoch ledger not found"
            in
            Result.iter_error response ~f:(fun err ->
                Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                  ~metadata:
                    [ ("peer", Network_peer.Peer.to_yojson conn)
                    ; ("error", `String err)
                    ; ( "ledger_hash"
                      , Coda_base.Ledger_hash.to_yojson ledger_hash ) ]
                  "Failed to serve epoch ledger query with hash $ledger_hash \
                   from $peer: $error" ) ;
            Ivar.fill ivar response )
    end

    open Coda_base.Rpc_intf

    type ('query, 'response) rpc =
      | Get_epoch_ledger
          : (Get_epoch_ledger.query, Get_epoch_ledger.response) rpc

    type rpc_handler =
      | Rpc_handler : ('q, 'r) rpc * ('q, 'r) rpc_fn -> rpc_handler

    type query =
      { query:
          'q 'r.    Network_peer.Peer.t -> ('q, 'r) rpc -> 'q
          -> 'r Coda_base.Rpc_intf.rpc_response Deferred.t }

    let implementation_of_rpc : type q r.
        (q, r) rpc -> (q, r) rpc_implementation = function
      | Get_epoch_ledger ->
          (module Get_epoch_ledger)

    let match_handler : type q r.
        rpc_handler -> (q, r) rpc -> do_:((q, r) rpc_fn -> 'a) -> 'a option =
     fun handler rpc ~do_ ->
      match (rpc, handler) with
      | Get_epoch_ledger, Rpc_handler (Get_epoch_ledger, f) ->
          Some (do_ f)

    let rpc_handlers ~logger ~local_state ~genesis_ledger_hash =
      [ Rpc_handler
          ( Get_epoch_ledger
          , Get_epoch_ledger.implementation ~logger ~local_state
              ~genesis_ledger_hash ) ]
  end

  let is_genesis_epoch ~(constants : Constants.t) time =
    Epoch.(equal (of_time_exn ~constants time) zero)

  (* Select the correct epoch data to use from a consensus state for a given epoch.
   * The rule for selecting the correct epoch data changes based on whether or not
   * the consensus state we are selecting from is in the epoch we want to select.
   * There is also a special case for when the consensus state we are selecting
   * from is in the genesis epoch.
  *)
  let select_epoch_data ~(consensus_state : Consensus_state.Value.t) ~epoch =
    let curr_epoch = Consensus_state.curr_epoch consensus_state in
    (* are we in the same epoch as the consensus state? *)
    let in_same_epoch = Epoch.equal epoch curr_epoch in
    (* are we in the next epoch after the consensus state? *)
    let in_next_epoch = Epoch.equal epoch (Epoch.succ curr_epoch) in
    (* is the consensus state from the genesis epoch? *)
    let from_genesis_epoch =
      Length.equal consensus_state.epoch_count Length.zero
    in
    if in_next_epoch then
      Ok (Epoch_data.next_to_staking consensus_state.next_epoch_data)
    else if in_same_epoch || from_genesis_epoch then
      Ok consensus_state.staking_epoch_data
    else Error ()

  let epoch_snapshot_name = function
    | `Genesis ->
        "genesis"
    | `Curr ->
        "curr"
    | `Last ->
        "last"

  (* Select the correct epoch snapshot to use from local state for an epoch.
   * The rule for selecting the correct epoch snapshot is predicated off of
   * whether or not the first transition in the epoch in question has been
   * finalized yet, as the local state epoch snapshot pointers are not
   * updated until the consensus state reaches the root of the transition frontier.
   * This function does not guarantee that the selected epoch snapshot is valid
   * (i.e. it does not check that the epoch snapshot's ledger hash is the same
   * as the ledger hash specified by the epoch data).
  *)
  let select_epoch_snapshot ~(constants : Constants.t)
      ~(consensus_state : Consensus_state.Value.t) ~local_state ~epoch =
    let open Local_state in
    let open Epoch_data.Poly in
    (* are we in the next epoch after the consensus state? *)
    let in_next_epoch =
      Epoch.equal epoch
        (Epoch.succ (Consensus_state.curr_epoch consensus_state))
    in
    (* has the first transition in the epoch reached finalization? *)
    let epoch_is_finalized =
      consensus_state.next_epoch_data.epoch_length > constants.k
    in
    if in_next_epoch || not epoch_is_finalized then
      (`Curr, !local_state.Data.next_epoch_snapshot)
    else (`Last, !local_state.staking_epoch_snapshot)

  let get_epoch_ledger ~constants ~(consensus_state : Consensus_state.Value.t)
      ~local_state =
    let _, snapshot =
      select_epoch_snapshot ~constants ~consensus_state
        ~epoch:(Data.Consensus_state.curr_epoch consensus_state)
        ~local_state
    in
    Data.Local_state.Snapshot.ledger snapshot

  type local_state_sync =
    { snapshot_id: Local_state.snapshot_identifier
    ; expected_root: Coda_base.Frozen_ledger_hash.t }
  [@@deriving to_yojson]

  let required_local_state_sync ~constants
      ~(consensus_state : Consensus_state.Value.t) ~local_state =
    let open Coda_base in
    let epoch = Consensus_state.curr_epoch consensus_state in
    let source, _snapshot =
      select_epoch_snapshot ~constants ~consensus_state ~local_state ~epoch
    in
    let required_snapshot_sync snapshot_id expected_root =
      Option.some_if
        (not
           (Ledger_hash.equal
              (Frozen_ledger_hash.to_ledger_hash expected_root)
              (Sparse_ledger.merkle_root
                 (Local_state.get_snapshot local_state snapshot_id).ledger)))
        {snapshot_id; expected_root}
    in
    match source with
    | `Curr ->
        Option.map
          (required_snapshot_sync Next_epoch_snapshot
             consensus_state.staking_epoch_data.ledger.hash)
          ~f:Non_empty_list.singleton
    | `Last -> (
      match
        Core.List.filter_map
          [ required_snapshot_sync Next_epoch_snapshot
              consensus_state.next_epoch_data.ledger.hash
          ; required_snapshot_sync Staking_epoch_snapshot
              consensus_state.staking_epoch_data.ledger.hash ]
          ~f:Fn.id
      with
      | [] ->
          None
      | ls ->
          Non_empty_list.of_list_opt ls )

  let sync_local_state ~logger ~trust_system ~local_state ~random_peers
      ~(query_peer : Rpcs.query) requested_syncs =
    let open Local_state in
    let open Snapshot in
    let open Deferred.Let_syntax in
    let requested_syncs = Non_empty_list.to_list requested_syncs in
    Logger.info logger
      "Syncing local state; requesting $num_requested snapshots from peers"
      ~location:__LOC__ ~module_:__MODULE__
      ~metadata:
        [ ("num_requested", `Int (List.length requested_syncs))
        ; ( "requested_syncs"
          , `List (List.map requested_syncs ~f:local_state_sync_to_yojson) )
        ; ("local_state", Local_state.to_yojson local_state) ] ;
    let sync {snapshot_id; expected_root= target_ledger_hash} =
      (* if requested last epoch ledger is equal to the current epoch ledger
         then we don't need make a rpc call to the peers. *)
      if
        snapshot_id = Staking_epoch_snapshot
        && Coda_base.(
             Ledger_hash.equal
               (Frozen_ledger_hash.to_ledger_hash target_ledger_hash)
               (Sparse_ledger.merkle_root
                  !local_state.next_epoch_snapshot.ledger))
      then (
        set_snapshot local_state Staking_epoch_snapshot
          { ledger= !local_state.next_epoch_snapshot.ledger
          ; delegatee_table= !local_state.next_epoch_snapshot.delegatee_table
          } ;
        return true )
      else
        let%bind peers = random_peers 3 in
        Deferred.List.exists peers ~f:(fun peer ->
            match%bind
              query_peer.query peer Rpcs.Get_epoch_ledger
                (Coda_base.Frozen_ledger_hash.to_ledger_hash target_ledger_hash)
            with
            | Connected {data= Ok (Ok snapshot_ledger); _} ->
                let%bind () =
                  Trust_system.(
                    record trust_system logger peer.host
                      Actions.(Epoch_ledger_provided, None))
                in
                let delegatee_table =
                  compute_delegatee_table_sparse_ledger
                    (Local_state.current_block_production_keys local_state)
                    snapshot_ledger
                in
                set_snapshot local_state snapshot_id
                  {ledger= snapshot_ledger; delegatee_table} ;
                return true
            | Connected {data= Ok (Error err); _} ->
                (* TODO figure out punishments here. *)
                Logger.faulty_peer_without_punishment logger
                  ~module_:__MODULE__ ~location:__LOC__
                  ~metadata:
                    [ ("peer", Network_peer.Peer.to_yojson peer)
                    ; ("error", `String err) ]
                  "Peer $peer failed to serve requested epoch ledger: $error" ;
                return false
            | Connected {data= Error err; _} ->
                Logger.faulty_peer_without_punishment logger
                  ~module_:__MODULE__ ~location:__LOC__
                  ~metadata:
                    [ ("peer", Network_peer.Peer.to_yojson peer)
                    ; ("error", `String (Error.to_string_mach err)) ]
                  "Peer $peer failed to serve requested epoch ledger: $error" ;
                return false
            | Failed_to_connect err ->
                Logger.faulty_peer_without_punishment logger
                  ~module_:__MODULE__ ~location:__LOC__
                  ~metadata:
                    [ ("peer", Network_peer.Peer.to_yojson peer)
                    ; ("error", `String (Error.to_string_hum err)) ]
                  "Failed to connect to $peer to retrieve epoch ledger: $error" ;
                return false )
    in
    if%map Deferred.List.for_all requested_syncs ~f:sync then Ok ()
    else Error (Error.of_string "failed to synchronize epoch ledger")

  let received_within_window ~constants (epoch, slot) ~time_received =
    let open Time in
    let open Int64 in
    let ( < ) x y = Pervasives.(compare x y < 0) in
    let ( >= ) x y = Pervasives.(compare x y >= 0) in
    let time_received =
      of_span_since_epoch (Span.of_ms (Unix_timestamp.to_int64 time_received))
    in
    let slot_diff =
      Epoch.diff_in_slots ~constants
        (Epoch_and_slot.of_time_exn time_received ~constants)
        (epoch, slot)
    in
    if slot_diff < 0L then Error `Too_early
    else if slot_diff >= UInt32.to_int64 constants.delta then
      Error (`Too_late (sub slot_diff (UInt32.to_int64 constants.delta)))
    else Ok ()

  let received_at_valid_time ~(constants : Constants.t)
      (consensus_state : Consensus_state.Value.t) ~time_received =
    received_within_window ~constants
      (Consensus_state.curr_epoch_and_slot consensus_state)
      ~time_received

  let is_short_range ~constants =
    let open Consensus_state in
    let is_pred x1 x2 = Epoch.equal (Epoch.succ x1) x2 in
    let pred_case c1 c2 =
      let e1, e2 = (curr_epoch c1, curr_epoch c2) in
      let c1_next_is_finalized =
        not (Slot.in_seed_update_range ~constants (Slot.succ (curr_slot c1)))
      in
      is_pred e1 e2 && c1_next_is_finalized
      && Coda_base.State_hash.equal c1.next_epoch_data.lock_checkpoint
           c2.staking_epoch_data.lock_checkpoint
    in
    fun c1 c2 ->
      if Epoch.equal (curr_epoch c1) (curr_epoch c2) then
        Coda_base.State_hash.equal c1.staking_epoch_data.lock_checkpoint
          c2.staking_epoch_data.lock_checkpoint
      else pred_case c1 c2 || pred_case c2 c1

  let select ~constants ~existing ~candidate ~logger =
    let string_of_choice = function `Take -> "Take" | `Keep -> "Keep" in
    let log_result choice msg =
      Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
        "Select result: $choice -- $message"
        ~metadata:
          [ ("choice", `String (string_of_choice choice))
          ; ("message", `String msg) ]
    in
    let log_choice ~precondition_msg ~choice_msg choice =
      let choice_msg =
        match choice with
        | `Take ->
            choice_msg
        | `Keep ->
            Printf.sprintf "not (%s)" choice_msg
      in
      let msg = Printf.sprintf "(%s) && (%s)" precondition_msg choice_msg in
      log_result choice msg
    in
    Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
      "Selecting best consensus state"
      ~metadata:
        [ ("existing", Consensus_state.Value.to_yojson existing)
        ; ("candidate", Consensus_state.Value.to_yojson candidate) ] ;
    (* TODO: add fork_before_checkpoint check *)
    (* Each branch contains a precondition predicate and a choice predicate,
     * which takes the new state when true. Each predicate is also decorated
     * with a string description, used for debugging messages *)
    let candidate_vrf_is_bigger =
      let d x = Blake2.(to_raw_string (digest_string x)) in
      String.( > ) (d candidate.last_vrf_output) (d existing.last_vrf_output)
    in
    let ( << ) a b =
      let c = Length.compare a b in
      (* TODO: I'm not sure we should throw away our current chain if they compare equal *)
      c < 0 || (c = 0 && candidate_vrf_is_bigger)
    in
    let precondition_msg, choice_msg, should_take =
      if is_short_range existing candidate ~constants then
        ( "most recent finalized checkpoints are equal"
        , "candidate length is longer than existing length "
        , existing.blockchain_length << candidate.blockchain_length )
      else
        ( "most recent finalized checkpoints are not equal"
        , "candidate virtual min-length is longer than existing virtual \
           min-length"
        , let newest_epoch =
            Epoch.max
              (Consensus_state.curr_epoch existing)
              (Consensus_state.curr_epoch candidate)
          in
          let virtual_min_length (s : Consensus_state.Value.t) =
            let curr_epoch = Consensus_state.curr_epoch s in
            if Epoch.(succ curr_epoch < newest_epoch) then Length.zero
              (* There is a gap of an entire epoch *)
            else if Epoch.(succ curr_epoch = newest_epoch) then
              Length.(min s.min_window_density s.next_epoch_data.epoch_length)
              (* Imagine the latest epoch was padded out with zeros to reach the newest_epoch *)
            else s.min_window_density
          in
          Length.(virtual_min_length existing < virtual_min_length candidate)
        )
    in
    let choice = if should_take then `Take else `Keep in
    log_choice ~precondition_msg ~choice_msg choice ;
    choice

  type block_producer_timing =
    [ `Check_again of Unix_timestamp.t
    | `Produce_now of Signature_lib.Keypair.t * Block_data.t
    | `Produce of Unix_timestamp.t * Signature_lib.Keypair.t * Block_data.t ]

  let next_producer_timing ~constraint_constants ~(constants : Constants.t) now
      (state : Consensus_state.Value.t) ~local_state ~keypairs ~logger =
    let info_if_producing =
      if Keypair.And_compressed_pk.Set.is_empty keypairs then Logger.debug
      else Logger.info
    in
    info_if_producing logger ~module_:__MODULE__ ~location:__LOC__
      "Determining next slot to produce block" ;
    let curr_epoch, curr_slot =
      Epoch.epoch_and_slot_of_time_exn ~constants
        (Block_time.of_span_since_epoch (Block_time.Span.of_ms now))
    in
    let epoch, slot =
      if
        Epoch.equal curr_epoch (Consensus_state.curr_epoch state)
        && Slot.equal curr_slot (Consensus_state.curr_slot state)
      then Epoch.incr ~constants (curr_epoch, curr_slot)
      else (curr_epoch, curr_slot)
    in
    Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
      "Systime: %d, epoch-slot@systime: %08d-%04d, starttime@epoch@systime: %d"
      (Int64.to_int now) (Epoch.to_int epoch) (Slot.to_int slot)
      ( Int64.to_int @@ Time.Span.to_ms @@ Time.to_span_since_epoch
      @@ Epoch.start_time ~constants epoch ) ;
    let next_slot =
      Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
        !"Selecting correct epoch data from state -- epoch by time: %d, state \
          epoch: %d, state epoch count: %d"
        (Epoch.to_int epoch)
        (Epoch.to_int (Consensus_state.curr_epoch state))
        (Length.to_int state.epoch_count) ;
      let epoch_data =
        match select_epoch_data ~consensus_state:state ~epoch with
        | Ok epoch_data ->
            epoch_data
        | Error () ->
            Logger.fatal logger ~module_:__MODULE__ ~location:__LOC__
              "An empty epoch is detected! This could be caused by the \
               following reasons: system time is out of sync with protocol \
               state time; or internet connection is down or unstable; or the \
               testnet has crashed. If it is the first case, please setup \
               NTP. If it is the second case, please check the internet \
               connection. If it is the last case, in our current version of \
               testnet this is unrecoverable, but we will fix it in future \
               versions once the planned change to consensus is finished." ;
            exit 99
      in
      let total_stake = epoch_data.ledger.total_currency in
      let epoch_snapshot =
        let source, snapshot =
          select_epoch_snapshot ~constants ~consensus_state:state ~local_state
            ~epoch
        in
        Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
          !"Using %s_epoch_snapshot root hash %{sexp:Coda_base.Ledger_hash.t}"
          (epoch_snapshot_name source)
          (Coda_base.Sparse_ledger.merkle_root snapshot.ledger) ;
        snapshot
      in
      let block_data unseen_pks slot =
        (* Try vrfs for all keypairs that are unseen within this slot until one wins or all lose *)
        (* TODO: Don't do this, and instead pick the one that has the highest
         * chance of winning. See #2573 *)
        Keypair.And_compressed_pk.Set.fold_until keypairs ~init:()
          ~f:(fun () (keypair, public_key_compressed) ->
            if
              not
              @@ Public_key.Compressed.Set.mem unseen_pks public_key_compressed
            then Continue_or_stop.Continue ()
            else
              let global_slot =
                Global_slot.of_epoch_and_slot ~constants (epoch, slot)
              in
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                "Checking VRF evaluations at epoch: $epoch, slot: $slot"
                ~metadata:
                  [ ("epoch", `Int (Epoch.to_int epoch))
                  ; ("slot", `Int (Slot.to_int slot)) ] ;
              match
                Vrf.check ~constraint_constants
                  ~global_slot:(Global_slot.slot_number global_slot)
                  ~seed:epoch_data.seed ~epoch_snapshot
                  ~private_key:keypair.private_key
                  ~public_key:keypair.public_key ~public_key_compressed
                  ~total_stake ~logger
              with
              | None ->
                  Continue_or_stop.Continue ()
              | Some data ->
                  Continue_or_stop.Stop (Some (keypair, data)) )
          ~finish:(fun () -> None)
      in
      let rec find_winning_slot (slot : Slot.t) =
        if slot >= constants.epoch_size then None
        else
          match Local_state.seen_slot local_state epoch slot with
          | `All_seen ->
              find_winning_slot (Slot.succ slot)
          | `Unseen pks -> (
            match block_data pks slot with
            | None ->
                find_winning_slot (Slot.succ slot)
            | Some (keypair, data) ->
                Some (slot, keypair, data) )
      in
      find_winning_slot slot
    in
    let ms_since_epoch = Fn.compose Time.Span.to_ms Time.to_span_since_epoch in
    match next_slot with
    | Some (next_slot, keypair, data) ->
        info_if_producing logger ~module_:__MODULE__ ~location:__LOC__
          "Producing block in %d slots"
          (Slot.to_int next_slot - Slot.to_int slot) ;
        if Slot.equal curr_slot next_slot then `Produce_now (keypair, data)
        else
          `Produce
            ( Epoch.slot_start_time ~constants epoch next_slot
              |> Time.to_span_since_epoch |> Time.Span.to_ms
            , keypair
            , data )
    | None ->
        let epoch_end_time =
          Epoch.end_time ~constants epoch |> ms_since_epoch
        in
        info_if_producing logger ~module_:__MODULE__ ~location:__LOC__
          "No slots won in this epoch. Waiting for next epoch to check again, \
           @%d"
          (Int64.to_int epoch_end_time) ;
        `Check_again epoch_end_time

  let frontier_root_transition (prev : Consensus_state.Value.t)
      (next : Consensus_state.Value.t) ~local_state ~snarked_ledger =
    if
      not
        (Epoch.equal
           (Consensus_state.curr_epoch prev)
           (Consensus_state.curr_epoch next))
    then (
      let delegatee_table =
        compute_delegatee_table
          (Local_state.current_block_production_keys local_state)
          ~iter_accounts:(fun f ->
            Coda_base.Ledger.Any_ledger.M.iteri snarked_ledger ~f )
      in
      let ledger = Coda_base.Sparse_ledger.of_any_ledger snarked_ledger in
      let epoch_snapshot = {Local_state.Snapshot.delegatee_table; ledger} in
      !local_state.last_epoch_delegatee_table
      <- Some !local_state.staking_epoch_snapshot.delegatee_table ;
      !local_state.staking_epoch_snapshot <- !local_state.next_epoch_snapshot ;
      !local_state.next_epoch_snapshot <- epoch_snapshot )

  let should_bootstrap_len ~(constants : Constants.t) ~existing ~candidate =
    let open UInt32.Infix in
    candidate - existing > (UInt32.of_int 2 * constants.k) + constants.delta

  let should_bootstrap ~(constants : Constants.t) ~existing ~candidate ~logger
      =
    match select ~constants ~existing ~candidate ~logger with
    | `Keep ->
        false
    | `Take ->
        should_bootstrap_len ~constants
          ~existing:(Consensus_state.blockchain_length existing)
          ~candidate:(Consensus_state.blockchain_length candidate)

  let%test "should_bootstrap is sane" =
    (* Even when consensus constants are of prod sizes, candidate should still trigger a bootstrap *)
    should_bootstrap_len
      ~constants:(Lazy.force Constants.for_unit_tests)
      ~existing:Length.zero
      ~candidate:(Length.of_int 100_000_000)

  let to_unix_timestamp recieved_time =
    recieved_time |> Time.to_span_since_epoch |> Time.Span.to_ms
    |> Unix_timestamp.of_int64

  let%test "Receive a valid consensus_state with a bit of delay" =
    let constants = Lazy.force Constants.for_unit_tests in
    let genesis_ledger = Genesis_ledger.(Packed.t for_unit_tests) in
    let negative_one =
      Consensus_state.negative_one ~genesis_ledger ~constants
    in
    let curr_epoch, curr_slot =
      Consensus_state.curr_epoch_and_slot negative_one
    in
    let delay = UInt32.(div constants.delta (of_int 2)) in
    let new_slot = UInt32.Infix.(curr_slot + delay) in
    let time_received = Epoch.slot_start_time ~constants curr_epoch new_slot in
    received_at_valid_time ~constants negative_one
      ~time_received:(to_unix_timestamp time_received)
    |> Result.is_ok

  let%test "Receive an invalid consensus_state" =
    let epoch = Epoch.of_int 5 in
    let constants = Lazy.force Constants.for_unit_tests in
    let genesis_ledger = Genesis_ledger.(Packed.t for_unit_tests) in
    let negative_one =
      Consensus_state.negative_one ~genesis_ledger ~constants
    in
    let start_time = Epoch.start_time ~constants epoch in
    let ((curr_epoch, curr_slot) as curr) =
      Epoch_and_slot.of_time_exn ~constants start_time
    in
    let consensus_state =
      { negative_one with
        curr_global_slot= Global_slot.of_epoch_and_slot ~constants curr }
    in
    let too_early =
      (* TODO: Does this make sense? *)
      Epoch.start_time ~constants (Consensus_state.curr_slot negative_one)
    in
    let too_late =
      let delay = UInt32.(mul constants.delta (of_int 2)) in
      let delayed_slot = UInt32.Infix.(curr_slot + delay) in
      Epoch.slot_start_time ~constants curr_epoch delayed_slot
    in
    let times = [too_late; too_early] in
    List.for_all times ~f:(fun time ->
        not
          ( received_at_valid_time ~constants consensus_state
              ~time_received:(to_unix_timestamp time)
          |> Result.is_ok ) )

  module type State_hooks_intf =
    Intf.State_hooks
    with type consensus_state := Consensus_state.Value.t
     and type consensus_state_var := Consensus_state.var
     and type consensus_transition := Consensus_transition.t
     and type block_data := Block_data.t

  module Make_state_hooks
      (Blockchain_state : Intf.Blockchain_state)
      (Protocol_state : Intf.Protocol_state
                        with type blockchain_state := Blockchain_state.Value.t
                         and type blockchain_state_var := Blockchain_state.var
                         and type consensus_state := Consensus_state.Value.t
                         and type consensus_state_var := Consensus_state.var)
      (Snark_transition : Intf.Snark_transition
                          with type blockchain_state_var :=
                                      Blockchain_state.var
                           and type consensus_transition_var :=
                                      Consensus_transition.var) :
    State_hooks_intf
    with type blockchain_state := Blockchain_state.Value.t
     and type protocol_state := Protocol_state.Value.t
     and type protocol_state_var := Protocol_state.var
     and type snark_transition_var := Snark_transition.var = struct
    (* TODO: only track total currency from accounts > 1% of the currency using transactions *)

    let genesis_winner = Vrf.Precomputed.genesis_winner

    let check_block_data ~constants ~logger (block_data : Block_data.t)
        global_slot =
      if
        not
          (Coda_numbers.Global_slot.equal
             (Global_slot.slot_number global_slot)
             block_data.global_slot)
      then
        Logger.error ~module_:__MODULE__ ~location:__LOC__ logger
          !"VRF was evaluated at (epoch, slot) %{sexp:Epoch_and_slot.t} but \
            the corresponding block was produced at a time corresponding to \
            %{sexp:Epoch_and_slot.t}. This means that generating the block \
            took more time than expected."
          (Global_slot.to_epoch_and_slot
             (Global_slot.of_slot_number ~constants block_data.global_slot))
          (Global_slot.to_epoch_and_slot global_slot)

    let generate_transition ~(previous_protocol_state : Protocol_state.Value.t)
        ~blockchain_state ~current_time ~(block_data : Block_data.t)
        ~transactions:_ ~snarked_ledger_hash ~supply_increase ~logger
        ~constraint_constants =
      let previous_consensus_state =
        Protocol_state.consensus_state previous_protocol_state
      in
      let constants =
        Constants.create ~constraint_constants
          ~protocol_constants:
            ( Protocol_state.constants previous_protocol_state
            |> Coda_base.Protocol_constants_checked.t_of_value )
      in
      (let actual_global_slot =
         let time = Time.of_span_since_epoch (Time.Span.of_ms current_time) in
         Global_slot.of_epoch_and_slot ~constants
           (Epoch_and_slot.of_time_exn ~constants time)
       in
       check_block_data ~constants ~logger block_data actual_global_slot) ;
      let consensus_transition = block_data.global_slot in
      let previous_protocol_state_hash =
        Protocol_state.hash previous_protocol_state
      in
      let consensus_state =
        Or_error.ok_exn
          (Consensus_state.update ~constants ~previous_consensus_state
             ~consensus_transition
             ~producer_vrf_result:block_data.Block_data.vrf_result
             ~previous_protocol_state_hash ~supply_increase
             ~snarked_ledger_hash)
      in
      let genesis_state_hash =
        Protocol_state.genesis_state_hash
          ~state_hash:(Some previous_protocol_state_hash)
          previous_protocol_state
      in
      let protocol_state =
        Protocol_state.create_value ~genesis_state_hash
          ~previous_state_hash:(Protocol_state.hash previous_protocol_state)
          ~blockchain_state ~consensus_state
          ~constants:(Protocol_state.constants previous_protocol_state)
      in
      (protocol_state, consensus_transition)

    include struct
      let%snarkydef next_state_checked ~constraint_constants
          ~(prev_state : Protocol_state.var)
          ~(prev_state_hash : Coda_base.State_hash.var) transition
          supply_increase =
        Consensus_state.update_var ~constraint_constants
          (Protocol_state.consensus_state prev_state)
          (Snark_transition.consensus_transition transition)
          prev_state_hash ~supply_increase
          ~previous_blockchain_state_ledger_hash:
            ( Protocol_state.blockchain_state prev_state
            |> Blockchain_state.snarked_ledger_hash )
          ~protocol_constants:(Protocol_state.constants prev_state)
    end

    module For_tests = struct
      let gen_consensus_state
          ~(constraint_constants : Genesis_constants.Constraint_constants.t)
          ~constants ~(gen_slot_advancement : int Quickcheck.Generator.t) :
          (   previous_protocol_state:( Protocol_state.Value.t
                                      , Coda_base.State_hash.t )
                                      With_hash.t
           -> snarked_ledger_hash:Coda_base.Frozen_ledger_hash.t
           -> Consensus_state.Value.t)
          Quickcheck.Generator.t =
        let open Consensus_state in
        let open Quickcheck.Let_syntax in
        let%bind slot_advancement = gen_slot_advancement in
        let%map producer_vrf_result = Vrf.Output.gen in
        fun ~(previous_protocol_state :
               (Protocol_state.Value.t, Coda_base.State_hash.t) With_hash.t)
            ~(snarked_ledger_hash : Coda_base.Frozen_ledger_hash.t) ->
          let prev =
            Protocol_state.consensus_state
              (With_hash.data previous_protocol_state)
          in
          let blockchain_length = Length.succ prev.blockchain_length in
          let curr_global_slot =
            Global_slot.(prev.curr_global_slot + slot_advancement)
          in
          let curr_epoch, curr_slot =
            Global_slot.to_epoch_and_slot curr_global_slot
          in
          let total_currency =
            Option.value_exn
              (Amount.add prev.total_currency
                 constraint_constants.coinbase_amount)
          in
          let prev_epoch, prev_slot =
            Consensus_state.curr_epoch_and_slot prev
          in
          let staking_epoch_data, next_epoch_data, epoch_count =
            Epoch_data.update_pair ~constants
              (prev.staking_epoch_data, prev.next_epoch_data)
              prev.epoch_count ~prev_epoch ~next_epoch:curr_epoch
              ~next_slot:curr_slot
              ~prev_protocol_state_hash:
                (With_hash.hash previous_protocol_state)
              ~producer_vrf_result ~snarked_ledger_hash ~total_currency
          in
          let min_window_density, sub_window_densities =
            Min_window_density.update_min_window_density ~constants
              ~prev_global_slot:prev.curr_global_slot
              ~next_global_slot:curr_global_slot
              ~prev_sub_window_densities:prev.sub_window_densities
              ~prev_min_window_density:prev.min_window_density
          in
          { Poly.blockchain_length
          ; epoch_count
          ; min_window_density
          ; sub_window_densities
          ; last_vrf_output= Vrf.Output.truncate producer_vrf_result
          ; total_currency
          ; curr_global_slot
          ; staking_epoch_data
          ; next_epoch_data
          ; has_ancestor_in_same_checkpoint_window=
              same_checkpoint_window_unchecked ~constants
                (Global_slot.create ~constants ~epoch:prev_epoch
                   ~slot:prev_slot)
                (Global_slot.create ~constants ~epoch:curr_epoch
                   ~slot:curr_slot) }
    end
  end
end

let time_hum ~(constants : Constants.t) (now : Block_time.t) =
  let epoch, slot = Epoch.epoch_and_slot_of_time_exn ~constants now in
  Printf.sprintf "epoch=%d, slot=%d" (Epoch.to_int epoch) (Slot.to_int slot)

let%test_module "Proof of stake tests" =
  ( module struct
    open Coda_base
    open Data
    open Consensus_state

    let constraint_constants =
      Genesis_constants.Constraint_constants.for_unit_tests

    let constants = Lazy.force Constants.for_unit_tests

    module Genesis_ledger = (val Genesis_ledger.for_unit_tests)

    let%test_unit "update, update_var agree starting from same genesis state" =
      (* build pieces needed to apply "update" *)
      let snarked_ledger_hash =
        Frozen_ledger_hash.of_ledger_hash
          (Ledger.merkle_root (Lazy.force Genesis_ledger.t))
      in
      let previous_protocol_state_hash = State_hash.(of_hash zero) in
      let previous_consensus_state =
        Consensus_state.create_genesis
          ~negative_one_protocol_state_hash:previous_protocol_state_hash
          ~genesis_ledger:Genesis_ledger.t ~constraint_constants ~constants
      in
      let global_slot =
        Core_kernel.Time.now () |> Time.of_time
        |> Epoch_and_slot.of_time_exn ~constants
        |> Global_slot.of_epoch_and_slot ~constants
      in
      let consensus_transition : Consensus_transition.t =
        Global_slot.slot_number global_slot
      in
      let supply_increase = Currency.Amount.of_int 42 in
      (* setup ledger, needed to compute producer_vrf_result here and handler below *)
      let open Coda_base in
      (* choose largest account as most likely to produce a block *)
      let ledger_data = Lazy.force Genesis_ledger.t in
      let ledger = Ledger.Any_ledger.cast (module Ledger) ledger_data in
      let pending_coinbases =
        Pending_coinbase.create
          ~depth:constraint_constants.pending_coinbase_depth ()
        |> Or_error.ok_exn
      in
      let maybe_sk, account = Genesis_ledger.largest_account_exn () in
      let private_key = Option.value_exn maybe_sk in
      let public_key_compressed = Account.public_key account in
      let account_id =
        Account_id.create public_key_compressed Token_id.default
      in
      let location =
        Ledger.Any_ledger.M.location_of_account ledger account_id
      in
      let delegator =
        Option.value_exn location |> Ledger.Any_ledger.M.Location.to_path_exn
        |> Ledger.Addr.to_int
      in
      let producer_vrf_result =
        let seed =
          let next_epoch, _ = Global_slot.to_epoch_and_slot global_slot in
          let prev_epoch, _ =
            Global_slot.to_epoch_and_slot
              previous_consensus_state.curr_global_slot
          in
          if next_epoch > prev_epoch then
            previous_consensus_state.next_epoch_data.seed
          else previous_consensus_state.staking_epoch_data.seed
        in
        Vrf.eval ~constraint_constants ~private_key
          {global_slot= Global_slot.slot_number global_slot; seed; delegator}
      in
      let next_consensus_state =
        update ~constants ~previous_consensus_state ~consensus_transition
          ~previous_protocol_state_hash ~supply_increase ~snarked_ledger_hash
          ~producer_vrf_result
        |> Or_error.ok_exn
      in
      (* build pieces needed to apply "update_var" *)
      let checked_computation =
        let open Snark_params.Tick in
        (* work in Checked monad *)
        let%bind previous_state =
          exists
            (typ ~constraint_constants)
            ~compute:(As_prover.return previous_consensus_state)
        in
        let%bind transition_data =
          exists Consensus_transition.typ
            ~compute:(As_prover.return consensus_transition)
        in
        let%bind previous_protocol_state_hash =
          exists State_hash.typ
            ~compute:(As_prover.return previous_protocol_state_hash)
        in
        let%bind supply_increase =
          exists Amount.typ ~compute:(As_prover.return supply_increase)
        in
        let%bind previous_blockchain_state_ledger_hash =
          exists Coda_base.Frozen_ledger_hash.typ
            ~compute:(As_prover.return snarked_ledger_hash)
        in
        let%bind constants_checked =
          exists Coda_base.Protocol_constants_checked.typ
            ~compute:
              (As_prover.return
                 (Coda_base.Protocol_constants_checked.value_of_t
                    Genesis_constants.for_unit_tests.protocol))
        in
        let result =
          update_var previous_state transition_data
            previous_protocol_state_hash ~supply_increase
            ~previous_blockchain_state_ledger_hash ~constraint_constants
            ~protocol_constants:constants_checked
        in
        (* setup handler *)
        let indices =
          Ledger.Any_ledger.M.foldi ~init:[] ledger ~f:(fun i accum _acct ->
              Ledger.Any_ledger.M.Addr.to_int i :: accum )
        in
        let sparse_ledger =
          Sparse_ledger.of_ledger_index_subset_exn ledger indices
        in
        let public_key = Public_key.decompress_exn public_key_compressed in
        let handler =
          Prover_state.handler ~constraint_constants
            {delegator; ledger= sparse_ledger; private_key; public_key}
            ~pending_coinbase:
              {Pending_coinbase_witness.pending_coinbases; is_new_stack= true}
        in
        let%map `Success _, var = Snark_params.Tick.handle result handler in
        As_prover.read (typ ~constraint_constants) var
      in
      let (), checked_value =
        Or_error.ok_exn
        @@ Snark_params.Tick.run_and_check checked_computation ()
      in
      let diff =
        Sexp_diff_kernel.Algo.diff
          ~original:(Value.sexp_of_t checked_value)
          ~updated:(Value.sexp_of_t next_consensus_state)
          ()
      in
      if not (Value.equal checked_value next_consensus_state) then (
        eprintf "Different states:\n%s\n%!"
          (Sexp_diff_kernel.Display.display_with_ansi_colors
             ~display_options:
               (Sexp_diff_kernel.Display.Display_options.create
                  ~collapse_threshold:1000 ())
             diff) ;
        failwith "Test failed" )
  end )

module Exported = struct
  module Global_slot = Global_slot
  module Block_data = Data.Block_data
  module Consensus_state = Data.Consensus_state
end
