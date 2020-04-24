open Snark_params
open Snarky
open Tick

module type S = sig
  include Data_hash.Full_size

  type path = Pedersen.Digest.t list

  type _ Request.t +=
    | Get_path : Account.Index.t -> path Request.t
    | Get_element : Account.Index.t -> (Account.t * path) Request.t
    | Set : Account.Index.t * Account.t -> unit Request.t
    | Find_index : Account_id.t -> Account.Index.t Request.t

  val get : var -> Account.Index.Unpacked.var -> (Account.var, _) Checked.t

  val merge : height:int -> t -> t -> t

  (** string representation of hash is Base58Check of bin_io representation *)
  val to_string : t -> string

  val of_string : string -> t

  val empty_hash : t

  val of_digest : Pedersen.Digest.t -> t

  val modify_account_send :
       var
    -> Account_id.var
    -> is_writeable:Boolean.var
    -> f:(   is_empty_and_writeable:Boolean.var
          -> Account.var
          -> (Account.var, 's) Checked.t)
    -> (var, 's) Checked.t

  val modify_account_recv :
       var
    -> Account_id.var
    -> f:(   is_empty_and_writeable:Boolean.var
          -> Account.var
          -> (Account.var, 's) Checked.t)
    -> (var, 's) Checked.t
end
