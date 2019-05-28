(* Distributed configuration + communication with clients for timeseries
 * extraction and so on.
 *
 * For this to work we need a networked KV store with those characteristics:
 *
 * Support for some better types that just strings, but must be usable from
 * both OCaml and C at minimum. Types of interest include: rotating array of
 * last N things (when a new item is produced only it is transmitted and the
 * client update its internal last index), ...
 *
 * Clients must be authorized (ideally with TLS certificates) but not
 * necessarily authenticated.
 *
 * Some permission system (ideally ACLs) to restrict what clients can view
 * and what they can write. All access should be limited to reads and writes
 * into a set of nodes, although any RPC can be reduced to a write of the RPC
 * parameter into the key of the action, so this is not really a limitation.
 *
 * A notification mechanism so that the client views can be updated quickly.
 * Notice that feedback to action is also provided by the sync; for instance
 * there is no need to have a proper answer from a write, as long as the write
 * itself is updated or a key with the last errors is updated.
 *
 * Also a locking mechanism: users who can write onto an object can also lock.
 * It's simpler than having user able to change the permission to restrict
 * them to themselves and then put them back to whatever they were, and also
 * better as we remember who own the lock, and can therefore easily deal with
 * forgotten locks, and also we remember what the permissions were supposed to
 * be (note than perms are not supposed to ever change).
 *
 * An interesting question is: what happen to "sub-objects" when their parents
 * become read-only. For instance, can a user still edit the property of a
 * function if it has lost the capacity to write the program?
 * Solution is classic: after having locked the program but before modifying
 * it, the client willing to edit the program must also lock all its functions.
 * This is of course only advisory locking.
 *
 * Server side must be embeddable into the Ramen binary and client side in the
 * a graphical client.
 *
 * No need to be persistent on disk though. The initial content can and will
 * be populated from config files at startup.
 *
 * Looking for libraries fulfilling these requirement, here is a list of
 * contender that could help at least in part:
 *
 * Redis: not embeddable, lacks ACL and Auth (despite
 *   https://github.com/antirez/redis/pull/4855)
 *
 * etcd: not embeddable, protocol implementation requires a ton of
 *   dependencies, 500qps for 1 client and 1 server only.
 *
 * consul: not embeddable, no notifications(?), HTTP API
 *
 * riak: not embeddable, no notifications!?
 *
 * ZeroMQ: no ACLs or invalidation as it is message agnostic. Can offer
 *   some multicast but not sure how easy it is to setup on today's
 *   poorly restricted networks.
 *
 * We could implement a custom synchronization protocol, that look not that
 * hard, and leave the actual communication/authentication to some other
 * lib like ZeroMQ.
 *
 * So let's put all this into types:
 *)
open Batteries

(* We call "id" a type that identifies something and that must be comparable
 * and hashable for cheap. *)

(* For many of those modules defining a type we will want to serialize values
 * of that type.
 * Note that we use string not bytes because that's what expects zmq lib.
 * Do not mix print, which is for human friendly display (mostly in logs
 * and error messages) and to_string/of_string, which is for serialization! *)

module type CAPACITY =
sig
  type t
  val print : 'a BatIO.output -> t -> unit

  val anybody : t
  val nobody : t

  val equal : t -> t -> bool
end

module type USER =
sig
  module Capa : CAPACITY

  type t
  val print : 'a BatIO.output -> t -> unit
  val equal : t -> t -> bool

  (* The conf server itself: *)
  val internal : t

  (* Whatever the user has to transmit to authenticate, such as a TLS
   * certificate for instance: *)
  module PubCredentials :
  sig
    type t
    val print : 'a BatIO.output -> t -> unit
  end

  (* Promote the user based on some creds: *)
  val authenticate : t -> PubCredentials.t -> t
  val authenticated : t -> bool

  type id (* Something we can hash, compare, etc... *)
  val print_id : 'a BatIO.output -> id -> unit

  val id : t -> id
  val has_capa : Capa.t -> t -> bool

  val only_me : t -> Capa.t

  (* We also use ZMQ for communication, so we need to create or retrieve a
   * user from a ZMQ id and the other way around: *)
  val of_zmq_id : string -> t
  val zmq_id : t -> string
end

module type KEY =
sig
  module User : USER

  type t
  val print : 'a BatIO.output -> t -> unit

  (* Special key for error reporting: *)
  val global_errs : t
  val user_errs : User.t -> t

  val hash : t -> int
  val equal : t -> t -> bool

  (* For regexpr/prefix hooks: *)
  val to_string : t -> string
  val of_string : string -> t
end

module type SELECTOR =
sig
  module Key : KEY
  type t
  val print : 'a BatIO.output -> t -> unit

  (* Special set for optimized matches: *)
  type set
  val make_set : unit -> set
  type id
  val add : set -> t -> id
  val matches : Key.t -> set -> id Enum.t
end

module type VALUE =
sig
  type t
  val equal : t -> t -> bool
  val print : 'a BatIO.output -> t -> unit
  val dummy : t

  (* Special values for error messages, with an int and a message. : *)
  val err_msg : int -> string -> t
end

(* Now we want the user view of the store (ie. all they are allowed to view
 * and have registered interest for viewing) to be automatically synchronised.
 * This gives us a beginning of an API: *)
module Messages (Key : KEY) (Value : VALUE) (Selector : SELECTOR) =
struct

  module CltMsg =
  struct
    type cmd =
      | Auth of Key.User.PubCredentials.t
      | StartSync of Selector.t
      | SetKey of Key.t * Value.t
      (* Like SetKey but fail if the key already exists.
       * Capa will be set by the callback on server side. *)
      | NewKey of Key.t * Value.t (* TODO: and the r/w permissions *)
      | DelKey of Key.t
      | LockKey of Key.t
      | UnlockKey of Key.t

    type t = int * cmd

    let to_string (m : t) =
      Marshal.(to_string m [ No_sharing ])

    let of_string s : t =
      Marshal.from_string s 0

    let print_cmd oc = function
      | Auth creds ->
          Printf.fprintf oc "Auth %a"
            Key.User.PubCredentials.print creds
      | StartSync sel ->
          Printf.fprintf oc "StartSync %a"
            Selector.print sel
      | SetKey (k, v) ->
          Printf.fprintf oc "SetKey (%a, %a)"
            Key.print k
            Value.print v
      | NewKey (k, v) ->
          Printf.fprintf oc "NewKey (%a, %a)"
            Key.print k
            Value.print v
      | DelKey k ->
          Printf.fprintf oc "DelKey %a"
            Key.print k
      | LockKey k ->
          Printf.fprintf oc "LockKey %a"
            Key.print k
      | UnlockKey k ->
          Printf.fprintf oc "UnlockKey %a"
            Key.print k

    let print fmt (i, cmd) =
      Printf.fprintf fmt "#%d, %a" i print_cmd cmd
  end

  module SrvMsg =
  struct
    type t =
      | Auth of string
      | SetKey of (Key.t * Value.t)
      | NewKey of (Key.t * Value.t * string)
      | DelKey of Key.t
      (* With the username of the lock owner: *)
      | LockKey of (Key.t * string)
      | UnlockKey of Key.t

    let print oc = function
      | Auth creds ->
          Printf.fprintf oc "Auth %s" creds
      | SetKey (k, v) ->
          Printf.fprintf oc "SetKey (%a, %a)"
            Key.print k
            Value.print v
      | NewKey (k, v, uid) ->
          Printf.fprintf oc "NewKey (%a, %a, %s)"
            Key.print k
            Value.print v
            uid
      | DelKey k ->
          Printf.fprintf oc "DelKey %a"
            Key.print k
      | LockKey (k, uid) ->
          Printf.fprintf oc "LockKey (%a, %s)"
            Key.print k
            uid
      | UnlockKey k ->
          Printf.fprintf oc "UnlockKey %a"
            Key.print k

    let to_string (m : t) =
      Marshal.(to_string m [ No_sharing ])

    let of_string s : t =
      Marshal.from_string s 0

  end
end
