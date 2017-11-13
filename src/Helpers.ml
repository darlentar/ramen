open Batteries
open RamenLog

(*$inject open Batteries *)

(* Small helper to return the ith entry of an array, capped to the last one.
 * Useful when we reach the last defined attempt while escalating an alert. *)
let get_cap a i =
  let len = Array.length a in
  assert (len > 0) ;
  a.(min i (len - 1))

let round_to_int f =
  int_of_float (Float.round f)

let retry
    ~on ?(first_delay=1.0) ?(min_delay=0.000001) ?(max_delay=10.0)
    ?(delay_adjust_ok=0.2) ?(delay_adjust_nok=1.1) ?delay_rec f =
  let open Lwt in
  let next_delay = ref first_delay in
  let rec loop x =
    (match%lwt f x with
    | exception e ->
      if on e then (
        let delay = !next_delay in
        let delay = min delay max_delay in
        let delay = max delay min_delay in
        next_delay := !next_delay *. delay_adjust_nok ;
        if delay > 1. then
          !logger.debug "Retryable error: %s, pausing %gs"
            (Printexc.to_string e) delay ;
        Option.may (fun f -> f delay) delay_rec ;
        let%lwt () = Lwt_unix.sleep delay in
        loop x
      ) else (
        !logger.error "Non-retryable error: %s"
          (Printexc.to_string e) ;
        fail e
      )
    | r ->
      next_delay := !next_delay *. delay_adjust_ok ;
      return r)
  in
  loop

let shell_quote s =
  "'"^ String.nreplace s "'" "'\\''" ^"'"

let print_exception e =
  !logger.error "Exception: %s\n%s"
    (Printexc.to_string e)
    (Printexc.get_backtrace ())

exception HttpError of (int * string)
let () =
  Printexc.register_printer (function
    | HttpError (code, text) -> Some (
      Printf.sprintf "HttpError (%d, %S)" code text)
    | _ -> None)

(* List of condvars to signal to terminate all the HTTP servers: *)
let http_server_done = ref []

let http_service port cert_opt key_opt router =
  let open Lwt in
  let open Cohttp in
  let open Cohttp_lwt_unix in
  let dec = Uri.pct_decode in
  let callback _conn req body =
    let path = Uri.path (Request.uri req) in
    !logger.debug "Requested %S" req.Request.resource ;
    (* Make "/path" equivalent to "path" *)
    let path =
      if String.starts_with path "/" then String.lchop path else path in
    (* Make "path/" equivalent to "path" for convenience. Beware that in
     * general "foo//bar" is not equivalent to "foo/bar" so not seemingly
     * spurious slashes can be omitted! *)
    let path =
      if String.ends_with path "/" then String.rchop path else path in
    let path =
      String.nsplit path "/" |>
      List.map dec in
    let params = Hashtbl.create 7 in
    (match String.split ~by:"?" req.Request.resource with
    | exception Not_found -> ()
    | _, param_str ->
      String.nsplit ~by:"&" param_str |>
      List.iter (fun p ->
        match String.split ~by:"=" p with
        | exception Not_found -> ()
        | pn, pv -> Hashtbl.add params (dec pn) (dec pv))) ;
    let headers = Request.headers req in
    let%lwt body = Cohttp_lwt_body.to_string body
    in
    catch
      (fun () ->
        try router (Request.meth req) path params headers body
        with exn -> fail exn)
      (function
        HttpError (code, msg) as exn ->
        print_exception exn ;
        let status = Code.status_of_code code in
        let headers =
          Header.init_with "Access-Control-Allow-Origin" "*" in
        let headers =
          Header.add headers "Content-Type" Consts.json_content_type in
        let body =
          Printf.sprintf "{\"success\": false, \"error\": %S}\n" msg in
        Server.respond_string ~headers ~status ~body ()
      | exn ->
        print_exception exn ;
        let body = Printexc.to_string exn ^ "\n" in
        let headers = Header.init_with "Access-Control-Allow-Origin" "*" in
        Server.respond_error ~headers ~body ())
  in
  let entry_point = Server.make ~callback () in
  let tcp_mode = `TCP (`Port port) in
  let on_exn = print_exception in
  let http_stop_thread () =
    let cond = Lwt_condition.create () in
    let stop = Lwt_condition.wait cond in
    http_server_done := cond :: !http_server_done ;
    stop in
  let t1 =
    !logger.info "Starting http server on port %d" port ;
    let stop = http_stop_thread () in
    Server.create ~on_exn ~stop ~mode:tcp_mode entry_point
  and t2 =
    match cert_opt, key_opt with
    | Some cert, Some key ->
      let port = port + 1 in
      let ssl_mode = `TLS (`Crt_file_path cert, `Key_file_path key, `No_password, `Port port) in
      !logger.info "Starting https server on port %d" port ;
      let stop = http_stop_thread () in
      Server.create ~on_exn ~stop ~mode:ssl_mode entry_point
    | None, None ->
      return (!logger.debug "Not starting https server")
    | _ ->
      return (!logger.info "Missing some of SSL configuration")
  in
  join [ t1 ; t2 ]

let looks_like_true s =
  s = "1" || (
    String.length s > 1 &&
    let lc = Char.lowercase s.[0] in lc = 'y' || lc = 't')

let time what f =
  let start = Unix.gettimeofday () in
  let res = f () in
  let dt = Unix.gettimeofday () -. start in
  !logger.info "%s in %gs." what dt ;
  res

(* TODO: add this into batteries *)

let mkdir_all ?(is_file=false) dir =
  let dir_exist d =
    try Sys.is_directory d with Sys_error _ -> false in
  let dir = if is_file then Filename.dirname dir else dir in
  let rec ensure_exist d =
    if String.length d > 0 && not (dir_exist d) then (
      ensure_exist (Filename.dirname d) ;
      !logger.debug "mkdir %S" d ;
      try Unix.mkdir d 0o755
      with Unix.Unix_error (Unix.EEXIST, "mkdir", _) ->
        (* Happens when we have "somepath//someother" (dirname should handle this IMHO) *)
        ()
    ) in
  ensure_exist dir

let file_exists ?(maybe_empty=true) ?(has_perms=0) fname =
  let open Unix in
  match stat fname with
  | exception Unix_error (ENOENT, _, _) -> false
  | s ->
    (maybe_empty || s.st_size > 0) &&
    s.st_perm land has_perms = has_perms

let name_of_signal s =
  let open Sys in
  if s = sigabrt then "ABORT"
  else if s = sigalrm then "ALRM"
  else if s = sigfpe then "FPE"
  else if s = sighup then "HUP"
  else if s = sigill then "ILL"
  else if s = sigint then "INT"
  else if s = sigkill then "KILL"
  else if s = sigpipe then "PIPE"
  else if s = sigquit then "QUIT"
  else if s = sigsegv then "SEGV"
  else if s = sigterm then "TERM"
  else if s = sigusr1 then "USR1"
  else if s = sigusr2 then "USR2"
  else if s = sigchld then "CHLD"
  else if s = sigcont then "CONT"
  else if s = sigstop then "STOP"
  else if s = sigtstp then "TSTP"
  else if s = sigttin then "TTIN"
  else if s = sigttou then "TTOU"
  else if s = sigvtalrm then "VTALRM"
  else if s = sigprof then "PROF"
  else if s = sigbus then "BUS"
  else if s = sigpoll then "POLL"
  else if s = sigsys then "SYS"
  else if s = sigtrap then "TRAP"
  else if s = sigurg then "URG"
  else if s = sigxcpu then "XCPU"
  else if s = sigxfsz then "XFSZ"
  else "Unknown OCaml signal number "^ string_of_int s

let string_of_process_status = function
  | Unix.WEXITED 127 -> "shell couldn't be executed"
  | Unix.WEXITED code -> Printf.sprintf "terminated with code %d" code
  | Unix.WSIGNALED sign -> Printf.sprintf "killed by signal %s" (name_of_signal sign)
  | Unix.WSTOPPED sign -> Printf.sprintf "stopped by signal %s" (name_of_signal sign)

exception RunFailure of Unix.process_status
let () = Printexc.register_printer (function
  | RunFailure st -> Some ("RunFailure "^ string_of_process_status st)
  | _ -> None)

(* Low level stuff: run jobs and return lines: *)
let run ?timeout ?(to_stdin="") cmd =
  let open Lwt in
  let string_of_array a =
    Array.fold_left (fun s v ->
        s ^ (if String.length s > 0 then " " else "") ^ v
      ) "" a in
  if Array.length cmd < 1 then invalid_arg "cmd" ;
  !logger.debug "Running command %s" (string_of_array cmd) ;
  let%lwt lines =
    Lwt_process.with_process_full ?timeout (cmd.(0), cmd) (fun process ->
      (* What we write to stdin: *)
      let write_stdin =
        let%lwt () = Lwt_io.write process#stdin to_stdin in
        Lwt_io.close process#stdin in
      (* We need to read both stdout and stderr simultaneously or risk
       * interlocking: *)
      let lines = ref [] in
      let read_lines =
        match%lwt Lwt_io.read_lines process#stdout |>
                  Lwt_stream.to_list with
        | exception exc ->
          (* when this happens for some reason we are left with (null) *)
          let msg = Printexc.to_string exc in
          !logger.error "%s exception: %s"
            (string_of_array cmd) msg ;
          return_unit
        | l -> lines := l ; return_unit in
      let monitor_stderr =
        catch (fun () ->
          Lwt_io.read_lines process#stderr |>
          Lwt_stream.iter (fun l ->
              !logger.error "%s stderr: %s" (string_of_array cmd) l
            ))
          (fun exc ->
            !logger.error "Error while running %s: %s"
              (string_of_array cmd) (Printexc.to_string exc) ;
            return_unit) in
      join [ write_stdin ; read_lines ; monitor_stderr ] >>
      match%lwt process#status with
      | Unix.WEXITED 0 ->
        return !lines
      | x ->
        !logger.error "Command '%s' %s"
          (string_of_array cmd)
          (string_of_process_status x) ;
        fail (RunFailure x)
    ) in
  return (String.concat "\n" lines)

let quote_at_start s =
  String.length s > 0 && s.[0] = '"'

let quote_at_end s =
  String.length s > 0 && s.[String.length s - 1] = '"'

exception InvalidCSVQuoting

let strings_of_csv separator line =
  (* If line is the empty string, String.nsplit returns an empty list
   * instead of a list with a single empty value. *)
  let strings =
    if line = "" then [ "" ]
    else String.nsplit line separator in
  (* Handle quoting in CSV values. TODO: enable/disable based on operation flag *)
  let strings', rem_s, has_quote =
    List.fold_left (fun (lst, prev_s, has_quote) s ->
      if prev_s = "" then (
        if quote_at_start s then (
          if quote_at_end s then (
            let len = String.length s in
            if len > 1 then String.sub s 1 (len - 2) :: lst, "", true
            else s :: lst, "", has_quote
          ) else lst, s, true
        ) else s :: lst, "", has_quote
      ) else (
        if quote_at_end s then (String.(lchop prev_s ^ rchop s) :: lst, "", true)
        else lst, prev_s ^ s, true
      )) ([], "", false) strings in
  if rem_s <> "" then raise InvalidCSVQuoting ;
  if has_quote then List.rev strings' else strings

(*$= strings_of_csv & ~printer:(IO.to_string (List.print String.print))
  [ "glop" ; "glop" ] (strings_of_csv " " "glop glop")
  [ "John" ; "+500" ] (strings_of_csv "," "\"John\",+500")
 *)

let read_whole_file fname =
  let open Lwt_io in
  let%lwt len = file_length fname in
  let len = Int64.to_int len in
  with_file ~mode:Input fname (fun ic ->
    let buf = Bytes.create len in
    let%lwt () = read_into_exactly ic buf 0 len in
    Lwt.return (Bytes.to_string buf))

let file_print oc fname =
  let content = File.lines_of fname |> List.of_enum |> String.concat "\n" in
  String.print oc content

let getenv ?def n =
  try Sys.getenv n
  with Not_found ->
    match def with
    | Some d -> d
    | None ->
      Printf.sprintf "Cannot find envvar %s" n |>
      failwith

(* Trick from LWT: how to exit without executing the at_exit hooks: *)
external sys_exit : int -> 'a = "caml_sys_exit"

let do_daemonize () =
  let open Unix in
  if fork () > 0 then sys_exit 0 ;
  setsid () |> ignore ;
  (* Close all fds, ignoring errors in case they have been closed already: *)
  let null = openfile "/dev/null" [O_RDONLY] 0 in
  dup2 null stdin ;
  close null ;
  let null = openfile "/dev/null" [O_WRONLY; O_APPEND] 0 in
  dup2 null stdout ;
  dup2 null stderr ;
  close null

let random_string =
  let chars = "0123456789abcdefghijklmnopqrstuvwxyz" in
  let random_char _ =
    let i = Random.int (String.length chars) in chars.[i]
  in
  fun len ->
    Bytes.init len random_char |>
    Bytes.to_string

let max_simult ~max_count =
  let open Lwt in
  fun f ->
    let rec wait () =
      if !max_count <= 0 then
        Lwt_unix.sleep 0.3 >>= wait
      else (
        decr max_count ;
        finalize f (fun () ->
          incr max_count ; return_unit)) in
    wait ()

let max_coprocesses = ref max_int

(* Run given command using Lwt, logging its output in our log-file *)
let run_coprocess ?(max_count=max_coprocesses)
                  ?timeout ?(to_stdin="") cmd_name cmd =
  let prog, cmdline = cmd in
  !logger.debug "Executing: %s, %a" prog
    (Array.print String.print) cmdline ;
  max_simult ~max_count:max_count (fun () ->
    let open Lwt in
    Lwt_process.with_process_full ?timeout cmd (fun process ->
      let write_stdin =
        let%lwt () = Lwt_io.write process#stdin to_stdin in
        Lwt_io.close process#stdin
      and read_lines c =
        try%lwt
          Lwt_io.read_lines c |>
          Lwt_stream.iter (fun line ->
            !logger.info "%s: %s" cmd_name line)
        with exc ->
          let msg = Printexc.to_string exc in
          !logger.error "%s: Cannot read output: %s" cmd_name msg ;
          return_unit in
      join [ write_stdin ;
             read_lines process#stdout ;
             read_lines process#stderr ] >>
      process#status))

let start_with c f =
  String.length f > 0 && f.[0] = c

let is_virtual_field = start_with '#'

let is_private_field = start_with '_'

let string_of_time ts =
  let open Unix in
  let tm = localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02dh%02dm%02ds"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(* HTTP helpers: *)

let ok_body = "{\"success\": true}"

let respond_ok ?(body=ok_body) ?(ct=Consts.json_content_type) () =
  let open Cohttp in
  let open Cohttp_lwt_unix in
  let status = `Code 200 in
  let headers = Header.init_with "Content-Type" ct in
  let headers = Header.add headers "Access-Control-Allow-Origin" "*" in
  let body = body ^"\n" in
  Server.respond_string ~status ~headers ~body ()

let content_type_of_ext = function
  | "html" -> Consts.html_content_type
  | "js" -> Consts.js_content_type
  | "css" -> Consts.css_content_type
  | _ -> "I_dont_know/Good_luck"

let ext_of_file fname =
  let _, ext = String.rsplit fname ~by:"." in ext

let serve_file path file replace =
  let fname = path ^"/"^ file in
  let%lwt body = read_whole_file fname in
  let%lwt body = replace body in
  let ct = content_type_of_ext (ext_of_file file) in
  respond_ok ~body ~ct ()
