open Core_kernel
module H_list = Snarky.H_list

[%%versioned
module Stable = struct
  module V1 = struct
    type 'a t = {row: 'a; col: 'a; value: 'a; rc: 'a} [@@deriving sexp]
  end
end]

type 'a t = 'a Stable.Latest.t = {row: 'a; col: 'a; value: 'a; rc: 'a}
[@@deriving sexp]

let to_hlist {row; col; value; rc} = H_list.[row; col; value; rc]

let of_hlist ([row; col; value; rc] : (unit, _) H_list.t) =
  {row; col; value; rc}

let typ g =
  Snarky.Typ.of_hlistable [g; g; g; g] ~var_to_hlist:to_hlist
    ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist

let map {row; col; value; rc} ~f =
  {row= f row; col= f col; value= f value; rc= f rc}

let map2 t1 t2 ~f =
  { row= f t1.row t2.row
  ; col= f t1.col t2.col
  ; value= f t1.value t2.value
  ; rc= f t1.rc t2.rc }
