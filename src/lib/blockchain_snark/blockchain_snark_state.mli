open Coda_base
open Coda_state
open Snark_params.Tick

module type Update_intf = sig
  module Checked : sig
    val update :
         logger:Logger.t
      -> proof_level:Genesis_constants.Proof_level.t
      -> constraint_constants:Genesis_constants.Constraint_constants.t
      -> State_hash.var * State_body_hash.var * Protocol_state.var
      -> Snark_transition.var
      -> ( State_hash.var * Protocol_state.var * [`Success of Boolean.var]
         , _ )
         Checked.t
  end
end

module Make_update (T : Transaction_snark.Verification.S) : Update_intf

module Checked : sig
  val hash :
    Protocol_state.var -> (State_hash.var * State_body_hash.var, _) Checked.t

  val is_base_case : Protocol_state.var -> (Boolean.var, _) Checked.t
end
