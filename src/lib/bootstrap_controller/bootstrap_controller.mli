open Async_kernel
open Coda_transition
open Pipe_lib
open Network_peer

val run :
     logger:Logger.t
  -> trust_system:Trust_system.t
  -> verifier:Verifier.t
  -> network:Coda_networking.t
  -> consensus_local_state:Consensus.Data.Local_state.t
  -> transition_reader:External_transition.Initial_validated.t
                       Envelope.Incoming.t
                       Strict_pipe.Reader.t
  -> persistent_root:Transition_frontier.Persistent_root.t
  -> persistent_frontier:Transition_frontier.Persistent_frontier.t
  -> initial_root_transition:External_transition.Validated.t
  -> genesis_state_hash:Coda_base.State_hash.t
  -> genesis_ledger:Coda_base.Ledger.t Lazy.t
  -> genesis_constants:Genesis_constants.t
  -> ( Transition_frontier.t
     * External_transition.Initial_validated.t Envelope.Incoming.t list )
     Deferred.t
