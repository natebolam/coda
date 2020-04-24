open Functor.With_private
open Core

(* TODO: generate new keypairs before public testnet *)
include Make (struct
  let accounts =
    lazy
      (let high_balances = List.init 2 ~f:(Fn.const 5_000_000) in
       let low_balances = List.init 16 ~f:(Fn.const 1_000) in
       let balances = high_balances @ low_balances in
       let keypairs = Lazy.force Coda_base.Sample_keypairs.keypairs in
       List.mapi balances ~f:(fun i b ->
           {balance= b; pk= fst keypairs.(i); sk= snd keypairs.(i)} ))
end)
