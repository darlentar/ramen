(* A specific Client using ZMQ, for the values/keys defined in RamenSync. *)
open Batteries
open RamenConsts
open RamenLog
open RamenHelpers

module Value = RamenSync.Value
module Client = RamenSyncClient.Make (Value) (RamenSync.Selector)
module Key = Client.Key

let retry_zmq ?while_ f =
  let on = function
    (* EWOULDBLOCK: According to 0mq documentation blocking is supposed
     * to be signaled with EAGAIN but... *)
    | Unix.(Unix_error ((EAGAIN|EWOULDBLOCK), _, _)) -> true
    | _ -> false in
  retry ~on ~first_delay:0.3 ?while_ f

let next_id = ref 0
let send_cmd zock ?while_ cmd =
    let msg = !next_id, cmd in
    incr next_id ;
    !logger.info "Sending command %a"
      Client.CltMsg.print msg ;
    let s = Client.CltMsg.to_string msg in
    match while_ with
    | None ->
        Zmq.Socket.send_all zock [ "" ; s ]
    | Some while_ ->
        retry_zmq ~while_
          (Zmq.Socket.send_all ~block:false zock) [ "" ; s ]

let recv_cmd zock =
  match Zmq.Socket.recv_all zock with
  | [ "" ; s ] ->
      !logger.info "srv message (raw): %S" s ;
      Client.SrvMsg.of_string s
  | m ->
      Printf.sprintf2 "Received unexpected message %a"
        (List.print String.print) m |>
      failwith

let unexpected_reply cmd =
  Printf.sprintf "Unexpected reply %s"
    (Client.SrvMsg.to_string cmd) |>
  failwith

module Stage =
struct
  type t = | Conn | Auth | Sync
  let to_string = function
    | Conn -> "Connecting"
    | Auth -> "Authenticating"
    | Sync -> "Synchronizing"
  let print oc s =
    String.print oc (to_string s)
end

module Status =
struct
  type t =
    | InitStart | InitOk | InitFail of string (* For the init stage *)
    | Ok of string | Fail of string
  let to_string = function
    | InitStart -> "Starting"
    | InitOk -> "Established"
    | InitFail s -> "Not established: "^ s
    | Ok s -> "Ok: "^ s
    | Fail s -> "Failed: "^ s
  let print oc s =
    String.print oc (to_string s)
end

let default_on_progress stage status =
  (match status with
  | Status.InitStart | InitOk -> !logger.info
  | InitFail _ | Fail _ -> !logger.error
  | _ -> !logger.debug)
    "%a: %a" Stage.print stage Status.print status

let init_connect ?while_ url zock on_progress =
  let url = if String.contains url ':' then url
            else url ^":"^ string_of_int Default.confserver_port in
  let connect_to = "tcp://"^ url in
  on_progress Stage.Conn Status.InitStart ;
  try
    !logger.info "Connecting to %s..." connect_to ;
    retry_zmq ?while_
      (Zmq.Socket.connect zock) connect_to ;
    on_progress Stage.Conn Status.InitOk
  with e ->
    on_progress Stage.Conn Status.(InitFail (Printexc.to_string e))

let init_auth ?while_ creds zock on_progress =
  on_progress Stage.Auth Status.InitStart ;
  try
    send_cmd zock ?while_ (Client.CltMsg.Auth creds) ;
    match retry_zmq ?while_ recv_cmd zock with
    | Client.SrvMsg.Auth "" ->
        on_progress Stage.Auth Status.InitOk
    | Client.SrvMsg.Auth err ->
        failwith err
    | rep ->
        unexpected_reply rep
  with e ->
    on_progress Stage.Auth Status.(InitFail (Printexc.to_string e))

let init_sync ?while_ zock glob on_progress =
  on_progress Stage.Sync Status.InitStart ;
  try
    let glob = Globs.compile glob in
    send_cmd zock ?while_ (Client.CltMsg.StartSync glob) ;
    on_progress Stage.Sync Status.InitOk
  with e ->
    on_progress Stage.Sync Status.(InitFail (Printexc.to_string e))

(* Will be called by the C++ on a dedicated thread, never returns: *)
let start ?while_ url creds topic ?(on_progress=default_on_progress) ?(on_sock=ignore)
          ?(conntimeo= 0) ?(recvtimeo= -1) ?(sndtimeo= -1) sync_loop =
  let ctx = Zmq.Context.create () in
  !logger.info "Subscribing to conf key %s" topic ;
  finally
    (fun () -> Zmq.Context.terminate ctx)
    (fun () ->
      let zock = Zmq.Socket.(create ctx dealer) in
      finally
        (fun () -> Zmq.Socket.close zock)
        (fun () ->
          on_sock zock ;
          (* Timeouts must be in place before connect: *)
          (* Not implemented for some reasons, although there is a
           * ZMQ_CONNECT_TIMEOUT:
           * Zmq.Socket.set_connect_timeout zock conntimeo ; *)
          ignore conntimeo ;
          Zmq.Socket.set_receive_timeout zock recvtimeo ;
          Zmq.Socket.set_send_timeout zock sndtimeo ;
          Zmq.Socket.set_send_high_water_mark zock 0 ;
          log_exceptions ~what:"init_connect"
            (fun () -> init_connect ?while_ url zock on_progress) ;
          log_exceptions ~what:"init_auth"
            (fun () -> init_auth ?while_ creds zock on_progress) ;
          log_exceptions ~what:"init_sync"
            (fun () -> init_sync ?while_ zock topic on_progress) ;
          log_exceptions ~what:"sync_loop"
            (fun () -> sync_loop zock)
        ) ()
    ) ()

(* Receive and process incoming commands until timeout.
 * Returns the number of messages that have been read. *)
let process_in zock clt =
  let rec loop msg_count =
    match recv_cmd zock with
    | exception Unix.(Unix_error (EAGAIN, _, _)) ->
        msg_count
    | msg ->
        Client.process_msg clt msg ;
        loop (msg_count + 1) in
  loop 0
