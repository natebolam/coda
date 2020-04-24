open Core_kernel
open Coda_base
open Snark_params.Tick

module Poly : sig
  module Stable : sig
    module V1 : sig
      type ('state_hash, 'body) t =
        {previous_state_hash: 'state_hash; body: 'body}
      [@@deriving eq, ord, bin_io, hash, sexp, to_yojson, version]
    end

    module Latest = V1
  end

  type ('state_hash, 'body) t = ('state_hash, 'body) Stable.Latest.t
  [@@deriving sexp]
end

val hash_abstract :
     hash_body:('body -> State_body_hash.t)
  -> (State_hash.t, 'body) Poly.t
  -> State_hash.t

module Body : sig
  module Poly : sig
    [%%versioned:
    module Stable : sig
      module V1 : sig
        type ('a, 'b, 'c, 'd) t [@@deriving sexp]
      end
    end]

    type ('a, 'b, 'c, 'd) t = ('a, 'b, 'c, 'd) Stable.V1.t [@@deriving sexp]
  end

  module Value : sig
    [%%versioned:
    module Stable : sig
      module V1 : sig
        type t =
          ( State_hash.Stable.V1.t
          , Blockchain_state.Value.Stable.V1.t
          , Consensus.Data.Consensus_state.Value.Stable.V1.t
          , Protocol_constants_checked.Value.Stable.V1.t )
          Poly.Stable.V1.t
        [@@deriving eq, ord, hash, sexp, to_yojson]
      end
    end]

    type t = Stable.Latest.t [@@deriving sexp, to_yojson]
  end

  type var =
    ( State_hash.var
    , Blockchain_state.var
    , Consensus.Data.Consensus_state.var
    , Protocol_constants_checked.var )
    Poly.t

  type ('a, 'b, 'c, 'd) t = ('a, 'b, 'c, 'd) Poly.t

  val hash : Value.t -> State_body_hash.t

  val hash_checked : var -> (State_body_hash.var, _) Checked.t
end

module Value : sig
  [%%versioned:
  module Stable : sig
    module V1 : sig
      type t =
        (State_hash.Stable.V1.t, Body.Value.Stable.V1.t) Poly.Stable.V1.t
      [@@deriving sexp, compare, eq, to_yojson]
    end
  end]

  type t = Stable.Latest.t [@@deriving sexp, compare, eq, to_yojson]

  include Hashable.S with type t := t
end

type value = Value.t [@@deriving sexp, to_yojson]

type var = (State_hash.var, Body.var) Poly.t

include Snarkable.S with type value := Value.t and type var := var

val create : previous_state_hash:'a -> body:'b -> ('a, 'b) Poly.t

val create_value :
     previous_state_hash:State_hash.t
  -> genesis_state_hash:State_hash.t
  -> blockchain_state:Blockchain_state.Value.t
  -> consensus_state:Consensus.Data.Consensus_state.Value.t
  -> constants:Protocol_constants_checked.Value.t
  -> Value.t

val create_var :
     previous_state_hash:State_hash.var
  -> genesis_state_hash:State_hash.var
  -> blockchain_state:Blockchain_state.var
  -> consensus_state:Consensus.Data.Consensus_state.var
  -> constants:Protocol_constants_checked.var
  -> var

val previous_state_hash : ('a, _) Poly.t -> 'a

val body : (_, 'a) Poly.t -> 'a

val blockchain_state : (_, (_, 'a, _, _) Body.t) Poly.t -> 'a

val genesis_state_hash :
  ?state_hash:State_hash.t option -> Value.t -> State_hash.t

val genesis_state_hash_checked :
  state_hash:State_hash.var -> var -> (State_hash.var, _) Checked.t

val consensus_state : (_, (_, _, 'a, _) Body.t) Poly.t -> 'a

val constants : (_, (_, _, _, 'a) Body.t) Poly.t -> 'a

val negative_one :
     genesis_ledger:Coda_base.Ledger.t Lazy.t
  -> protocol_constants:Genesis_constants.Protocol.t
  -> Value.t

val hash_checked : var -> (State_hash.var * State_body_hash.var, _) Checked.t

val hash : Value.t -> State_hash.t
