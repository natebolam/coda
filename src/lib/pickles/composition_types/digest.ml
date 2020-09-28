open Pickles_types
open Core_kernel
module Limbs = Nat.N4

module Constant = struct
  include Limb_vector.Constant.Make (Limbs)
  open Backend

  let to_tick_field x = Tick.Field.of_bits (to_bits x)

  let to_tock_field x = Tock.Field.of_bits (to_bits x)

  let of_tick_field x = of_bits (Tick.Field.to_bits x)

  let of_tick_field x = of_bits (Tick.Field.to_bits x)
end

module Make (Impl : Snarky_backendless.Snark_intf.Run) = struct
  open Impl

  type t = Field.t

  let to_bits = Field.choose_preimage_var ~length:Field.size_in_bits

  let () = assert (Field.size_in_bits < 64 * Nat.to_int Limbs.n)

  module Constant = struct
    include Constant

    let to_bits x = List.take (to_bits x) Field.size_in_bits
  end

  let typ =
    Typ.transport Field.typ
      ~there:(Fn.compose Field.Constant.project Constant.to_bits)
      ~back:(Fn.compose Constant.of_bits Field.Constant.unpack)
end
