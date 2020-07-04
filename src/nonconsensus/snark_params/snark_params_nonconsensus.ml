(* snark_params_nonconsensus.ml *)

[%%import
"/src/config.mlh"]

[%%ifdef
consensus_mechanism]

[%%error
"Snark_params_nonconsensus should not be compiled if there's a consensus \
 mechanism"]

[%%endif]

open Snarkette

[%%if
curve_size = 753]

(* only size we should be building nonconsensus code for *)

module Mnt4 = Mnt4753
module Mnt6 = Mnt6753

[%%else]

[%%show
curve_size]

[%%error
"invalid value for \"curve_size\""]

[%%endif]

module Field0 = Mnt6.Fq

[%%inject
"ledger_depth", ledger_depth]

module Field = struct
  include Field0

  let size = order |> Snarkette.Nat.to_string |> Bigint.of_string

  let size_in_bits = length_in_bits

  let unpack t = to_bits t

  let project bits =
    Core_kernel.Option.value_exn ~message:"project: invalid bits"
      (of_bits bits)
end

module Tock = struct
  module Field = struct
    type t = Mnt4.Fq.t

    let unpack t = Mnt4.Fq.to_bits t

    let project bits =
      Core_kernel.Option.value_exn
        ~message:"Snark_params_nonconsensus.Tock.Field.project"
        (Mnt4.Fq.of_bits bits)
  end
end

module Inner_curve = struct
  type t = Mnt6.G1.t [@@deriving sexp]

  module Coefficients = Mnt6.G1.Coefficients

  let find_y x =
    let open Mnt6.Fq in
    let y2 = (x * square x) + (Coefficients.a * x) + Coefficients.b in
    if is_square y2 then Some (sqrt y2) else None

  [%%define_locally
  Mnt6.G1.(of_affine, to_affine, to_affine_exn, one, ( + ), negate)]

  module Scalar = struct
    (* though we have bin_io, not versioned here; this type exists for Private_key.t,
       where it is versioned-asserted and its serialization tested
     *)
    type t = Mnt4.Fq.t [@@deriving bin_io_unversioned, sexp]

    type _unused = unit constraint t = Tock.Field.t

    (* the Inner_curve.Scalar.size for the consensus case is derived from a C++ call; here, we inline the value *)
    [%%if
    curve_size = 753]

    let size =
      Mnt4.Fq.of_string
        "41898490967918953402344214791240637128170709919953949071783502921025352812571106773058893763790338921418070971888253786114353726529584385201591605722013126468931404347949840543007986327743462853720628051692141265303114721689601"

    [%%else]

    [%%show
    curve_size]

    [%%error
    "invalid value for \"curve_size\""]

    [%%endif]

    [%%define_locally
    Mnt4.Fq.
      ( to_string
      , of_string
      , equal
      , compare
      , size
      , zero
      , one
      , ( + )
      , ( - )
      , ( * )
      , gen_uniform_incl
      , negate
      , hash_fold_t )]

    (* Mnt4.Fq.gen uses the interval starting at zero
       here we follow the gen in Snark_params.Make_inner_curve_scalar, using
         an interval starting at one
    *)

    let gen = Mnt4.Fq.(gen_incl one (size - one))

    let gen_uniform = gen_uniform_incl one (size - one)

    let of_bits bits = Tock.Field.project bits
  end

  let scale t (scalar : Scalar.t) = Mnt6.G1.scale t (scalar :> Nat.t)

  let scale_field t x = scale t (Mnt4.Fq.of_bigint x :> Scalar.t)
end
