open Core_kernel
open Currency

module Test_inputs = struct
  module Transaction_witness = Int
  module Ledger_hash = Int
  module Sparse_ledger = Int
  module Transaction = Int
  module Ledger_proof_statement = Fee

  module Transaction_protocol_state = struct
    type 'a t = 'a
  end

  module Ledger_proof = struct
    module T = struct
      type t = Fee.t [@@deriving hash, compare, sexp]

      let of_binable = Fee.of_int

      let to_binable = Fee.to_int
    end

    include Binable.Of_binable (Core_kernel.Int.Stable.V1) (T)
    include T
  end

  module Transaction_snark_work = struct
    type t = Fee.t

    let fee = Fn.id
  end

  module Snark_pool = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = Transaction_snark.Statement.Stable.V1.t One_or_two.Stable.V1.t
        [@@deriving hash, compare, sexp]

        let to_latest = Fn.id
      end
    end]

    module Work = Hashable.Make_binable (Stable.Latest)

    type t = Currency.Fee.t Work.Table.t

    let get_completed_work (t : t) = Work.Table.find t

    let create () = Work.Table.create ()

    let add_snark t ~work ~fee =
      Work.Table.update t work ~f:(function
        | None ->
            fee
        | Some fee' ->
            Currency.Fee.min fee fee' )
  end

  module Staged_ledger = struct
    type t =
      ( int Transaction_protocol_state.t
      , int
      , Transaction_snark_work.t )
      Snark_work_lib.Work.Single.Spec.t
      List.t

    let work = Fn.id

    let all_work_pairs_exn = One_or_two.group_list
  end
end

module Implementation_inputs = struct
  open Coda_base
  module Ledger_hash = Ledger_hash
  module Sparse_ledger = Sparse_ledger
  module Transaction = Transaction
  module Transaction_witness = Transaction_witness
  module Ledger_proof = Ledger_proof
  module Transaction_snark_work = Transaction_snark_work
  module Snark_pool = Network_pool.Snark_pool
  module Staged_ledger = Staged_ledger
  module Transaction_protocol_state = Transaction_protocol_state
end
