open Batteries

type log_level = Quiet | Normal | Debug

let string_of_log_level = function
  | Quiet -> "quiet"
  | Normal -> "normal"
  | Debug -> "debug"

let log_level_of_string = function
  | "quiet" -> Quiet
  | "debug" -> Debug
  | _ -> Normal

type 'a printer =
  ('a, unit BatIO.output, unit) format -> 'a

type log_output = Directory of string | Stdout | Syslog

let string_of_log_output = function
  | Directory s -> "directory "^ s
  | Stdout -> "stdout"
  | Syslog -> "syslog"

type logger =
  { log_level : log_level ;
    error : 'a. 'a printer ;
    warning : 'a. 'a printer ;
    info : 'a. 'a printer ;
    debug : 'a. 'a printer ;
    output : log_output ;
    prefix : string ref ;
    mutable alt : logger option }

let with_colors = ref true

let colored ansi s =
  if !with_colors then
    Printf.sprintf "\027[%sm%s\027[0m" ansi s
  else
    Printf.sprintf "%s" s

let red = colored "1;31"
let green = colored "1;32"
let yellow = colored "1;33"
let blue = colored "1;34"
let magenta = colored "1;35"
let cyan = colored "1;36"
let white = colored "1;37"
let gray = colored "2;37"

let log_file tm =
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year+1900) (tm.Unix.tm_mon+1) tm.Unix.tm_mday

let do_output =
  let ocr = ref None and fname = ref "" in
  fun output tm is_err ->
    match output with
    | Directory logdir ->
      let fname' = log_file tm in
      if fname' <> !fname then (
        let open Legacy.Unix in
        fname := fname' ;
        Option.may (ignore_exceptions @@ close_out) !ocr ;
        let path = logdir ^"/"^ !fname in
        let fd = BatUnix.openfile path
                   [O_WRONLY; O_APPEND; O_CREAT; O_CLOEXEC] 0o644 in
        (* Make sure everything that gets written to stdout/err end up
         * logged in that file too: *)
        dup2 fd stderr ;
        dup2 fd stdout ;
        let oc = BatUnix.out_channel_of_descr fd in
        ocr := Some oc
      ) ;
      Option.get !ocr
    | Stdout -> if is_err then stderr else stdout
    | Syslog -> assert false

let make_prefix s =
  if s = "" then s else (colored "1;34" (" "^s)) ^":"

let rate_limit max_rate =
  let last_sec = ref 0 and count = ref 0 in
  fun now ->
    let sec = int_of_float now in
    if sec = !last_sec then (
      incr count ;
      !count > max_rate
    ) else (
      last_sec := sec ;
      count := 0 ;
      false
    )

let make_single_logger ?logdir ?(prefix="") log_level =
  let output = match logdir with Some s -> Directory s | _ -> Stdout in
  let prefix = ref (make_prefix prefix) in
  let rate_limit = rate_limit 30 in
  let skip = ref 0 in
  let do_log is_err col fmt =
    let open Unix in
    let now = time () in
    let tm = localtime now in
    let time_pref =
      Printf.sprintf "%02dh%02dm%02d:"
        tm.tm_hour tm.tm_min tm.tm_sec in
    let oc = do_output output tm is_err in
    let p =
      if is_err && rate_limit now then (
        incr skip ;
        Printf.ifprintf
      ) else (
        if !skip > 0 then (
          Printf.fprintf oc "%d other errors skipped\n%!" !skip ;
          skip := 0
        ) ;
        Printf.fprintf
      ) in
    p oc ("%s%s " ^^ fmt ^^ "\n%!") (col time_pref) !prefix
  in
  let error fmt = do_log true red fmt
  and warning fmt = do_log true yellow fmt
  and info fmt =
    if log_level <> Quiet then do_log false green fmt
    else Printf.ifprintf stderr fmt
  and debug fmt =
    if log_level = Debug then do_log false identity fmt
    else Printf.ifprintf stderr fmt
  in
  { log_level ; error ; warning ; info ; debug ; output ; prefix ; alt = None }

let logger = ref (make_single_logger Normal)

let init_sigusr2_once =
  let inited = ref false in
  fun () ->
    if not !inited then (
      inited := true ;
      Sys.(set_signal sigusr2 (Signal_handle (fun _ ->
        match !logger.alt with
        | None ->
            !logger.info "Received SIGUSR2 but no alternate logger defined, ignoring"
        | Some alt ->
            !logger.info "Received SIGUSR2, switching into log level %s"
              (string_of_log_level alt.log_level) ;
            logger := alt))))

let init_logger ?logdir ?prefix log_level =
  logger := make_single_logger ?logdir ?prefix log_level ;
  let l2 =
    let alt_ll = if log_level = Debug then Normal else Debug in
    make_single_logger ?logdir ?prefix alt_ll in
  l2.alt <- Some !logger ;
  !logger.alt <- Some l2 ;
  init_sigusr2_once ()

let syslog =
  try Some (Syslog.openlog ~facility:`LOG_USER "ramen")
  with _ -> None

let init_syslog ?(prefix="") log_level =
  let prefix = ref (make_prefix prefix) in
  match syslog with
  | None ->
      failwith "No syslog facility on this host."
  | Some slog ->
      let do_log log_level fmt =
        Printf.ksprintf2 (fun str ->
          Syslog.syslog slog log_level str) fmt in
      let error fmt = do_log `LOG_ERR fmt
      and warning fmt = do_log `LOG_WARNING fmt
      and info fmt =
        if log_level <> Quiet then do_log `LOG_INFO fmt
        else Printf.ifprintf stderr fmt
      and debug fmt =
        if log_level = Debug then do_log `LOG_DEBUG fmt
        else Printf.ifprintf stderr fmt
      in
      logger :=
        { log_level ; error ; warning ; info ; debug ; output = Syslog ; prefix ;
          alt = None }

let set_prefix prefix =
  !logger.prefix := make_prefix prefix
