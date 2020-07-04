(* masking_merkle_tree_intf.ml *)
(* the type of a Merkle tree mask associated with a parent Merkle tree *)
module type S = sig
  type t

  type unattached = t

  type parent

  type account

  type location

  type hash

  type key

  type token_id

  type token_id_set

  type account_id

  type account_id_set

  module Location : Merkle_ledger.Location_intf.S

  module Addr = Location.Addr

  (** create a mask with no parent *)
  val create : depth:int -> unit -> t

  val get_uuid : t -> Uuid.t

  module Attached : sig
    include
      Base_merkle_tree_intf.S
      with module Addr = Addr
      with module Location = Location
      with type account := account
       and type root_hash := hash
       and type hash := hash
       and type key := key
       and type token_id := token_id
       and type token_id_set := token_id_set
       and type account_id := account_id
       and type account_id_set := account_id_set

    exception Dangling_parent_reference of Uuid.t

    (** get hash from mask, if present, else from its parent *)
    val get_hash : t -> Addr.t -> hash option

    (** commit all state to the parent, flush state locally *)
    val commit : t -> unit

    (** remove parent *)
    val unset_parent : t -> unattached

    (** get mask parent *)
    val get_parent : t -> parent

    (** called when parent sets an account; update local state *)
    val parent_set_notify : t -> account -> unit

    val copy : t -> t

    (* makes new mask instance with copied tables, re-use parent *)

    (** already have module For_testing from include above *)
    module For_testing : sig
      val location_in_mask : t -> location -> bool

      val address_in_mask : t -> Addr.t -> bool

      val current_location : t -> Location.t option
    end
  end

  (** tell mask about parent *)
  val set_parent : unattached -> parent -> Attached.t
end
