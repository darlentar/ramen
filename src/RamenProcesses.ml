open Batteries
open Lwt
open RamenLog
module C = RamenConf
module N = RamenConf.Func
module L = RamenConf.Program
module SN = RamenSharedTypes.Info.Func
open RamenSharedTypesJS

let fd_of_int : int -> Unix.file_descr = Obj.magic

let close_fd i =
  Unix.close (fd_of_int i)

let run_background cmd args env =
  let open Unix in
  (* prog name should be first arg *)
  let prog_name = Filename.basename cmd in
  let args = Array.init (Array.length args + 1) (fun i ->
      if i = 0 then prog_name else args.(i-1))
  in
  !logger.info "Running %s with args %a and env %a"
    cmd
    (Array.print String.print) args
    (Array.print String.print) env ;
  flush_all () ;
  match fork () with
  | 0 ->
    close_fd 0 ;
    for i = 3 to 255 do
      try close_fd i with Unix.Unix_error (Unix.EBADF, _, _) -> ()
    done ;
    execve cmd args env
  | pid -> pid

exception NotYetCompiled
exception AlreadyRunning
exception StillCompiling

let input_spec conf parent func =
  C.in_ringbuf_name conf func,
  let out_type = C.tuple_ser_type parent.N.out_type
  and in_type = C.tuple_ser_type func.N.in_type in
  RingBufLib.skip_list ~out_type ~in_type

(* Takes a locked conf.
 * FIXME: a phantom type for this *)
let rec run_func conf programs program func =
  let command = C.exec_of_func conf.C.persist_dir func
  and output_ringbufs =
    (* Start to output to funcs of this program. They have all been
     * created above (in [run]), and we want to allow loops in a program. Avoids
     * outputting to other programs, unless they are already running (in
     * which case their ring-buffer exists already), otherwise we would
     * hang. *)
    C.fold_funcs programs Map.empty (fun outs l n ->
      (* Select all func's children that are either running or in the same
       * program *)
      if (n.N.program = program.L.name || l.L.status = Running) &&
         List.exists (fun (pl, pn) ->
           pl = program.L.name && pn = func.N.name
         ) n.N.parents
      then (
        !logger.debug "%s will output to %s" (N.fq_name func) (N.fq_name n) ;
        let k, v = input_spec conf func n in
        Map.add k v outs
      ) else outs) in
  let out_ringbuf_ref = C.out_ringbuf_names_ref conf func in
  let%lwt () = RamenOutRef.set out_ringbuf_ref output_ringbufs in
  (* Now that the out_ref exists, but before we actually fork the worker,
   * we can start importing: *)
  let%lwt () =
    if Lang.Operation.is_exporting func.N.operation then
      let%lwt _ = RamenExport.get_or_start conf func in
      return_unit
    else return_unit in
  !logger.info "Start %s" func.N.name ;
  let input_ringbuf = C.in_ringbuf_name conf func in
  let env = [|
    "OCAMLRUNPARAM="^ if conf.C.debug then "b" else "" ;
    "debug="^ string_of_bool conf.C.debug ;
    "name="^ N.fq_name func ;
    "input_ringbuf="^ input_ringbuf ;
    "output_ringbufs_ref="^ out_ringbuf_ref ;
    "report_ringbuf="^ C.report_ringbuf conf ;
    "notify_ringbuf="^ C.notify_ringbuf conf ;
    (* We need to change this dir whenever the func signature change
     * to prevent it to reload an incompatible state: *)
    "persist_dir="^ conf.C.persist_dir ^"/workers/tmp/"
                  ^ RamenVersions.worker_state
                  ^"/"^ (N.fq_name func)
                  ^"/"^ func.N.signature ;
    (match !logger.logdir with
      | Some _ ->
        "log_dir="^ conf.C.persist_dir ^"/workers/log/"
                  ^ (N.fq_name func)
      | None -> "no_log_dir=") |] in
  let%lwt pid =
    wrap (fun () -> run_background command [||] env) in
  func.N.pid <- Some pid ;
  (* Monitor this worker, wait for its termination, restart...: *)
  async (fun () ->
    let rec wait_child () =
      match%lwt Lwt_unix.waitpid [] pid with
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_child ()
      | exception exn ->
        (* This should not be used *)
        (* TODO: save this error on the func record *)
        !logger.error "Cannot wait for pid %d: %s"
          pid (Printexc.to_string exn) ;
        return_unit
      | _, status ->
        let status_str = Helpers.string_of_process_status status in
        !logger.info "Operation %s (pid %d) %s."
          (N.fq_name func) pid status_str ;
        (* First and foremost we want to set the error status and clean
         * the PID of this process (if only because another thread might
         * wait for the result of its own kill) *)
        C.with_wlock conf (fun programs ->
          (* Look again for that program by name: *)
          match C.find_func programs func.N.program func.N.name with
          | exception Not_found ->
              !logger.error "Operation %s (pid %d) %s is not \
                             in the configuration any more!"
                (N.fq_name func) pid status_str ;
              return_unit
          | program, func ->
              (* Check this is still the same program: *)
              if func.pid <> Some pid then (
                !logger.error "Operation %s (pid %d) %s is in \
                               the configuration under pid %a!"
                  (N.fq_name func) pid status_str
                  (Option.print Int.print) func.pid ;
                return_unit
              ) else (
                func.pid <- None ;
                func.last_exit <- status_str ;
                (* Now we might want to restart it: *)
                (match status with Unix.WSIGNALED signal
                  when signal <> Sys.sigterm && signal <> Sys.sigkill ->
                    if program.status <> Running then return_unit else (
                      !logger.info "Restarting func %s which is supposed to be running."
                        (N.fq_name func) ;
                      let%lwt () = Lwt_unix.sleep (Random.float 2.) in
                      (* Note: run_func will start another waiter for that
                       * other worker so our job is done. *)
                      run_func conf programs program func)
                | _ -> return_unit)))
    in
    wait_child ()) ;
  (* Update the parents out_ringbuf_ref if it's in another program (otherwise
   * we have set the correct out_ringbuf_ref just above already) *)
  Lwt_list.iter_p (fun (parent_program, parent_name) ->
      if parent_program = program.name then
        return_unit
      else
        match C.find_func programs parent_program parent_name with
        | exception Not_found ->
          !logger.warning "Starting func %s which parent %s/%s does not \
                           exist yet"
            (N.fq_name func)
            parent_program parent_name ;
          return_unit
        | _, parent ->
          let out_ref =
            C.out_ringbuf_names_ref conf parent in
          (* The parent ringbuf might not exist yet if it has never been
           * started. If the parent is not running then it will overwrite
           * it when it starts, with whatever running children it will
           * have at that time (including us, if we are still running).  *)
          RamenOutRef.add out_ref (input_spec conf parent func)
    ) func.N.parents

(* We take _programs as a sign that we have the lock *)
let kill_worker conf _programs func pid =
  let try_kill pid signal =
    try Unix.kill pid signal
    with Unix.Unix_error _ as e ->
      !logger.error "Cannot kill pid %d: %s" pid (Printexc.to_string e)
  in
  (* First ask politely: *)
  !logger.info "Killing worker %s (pid %d)" (N.fq_name func) pid ;
  try_kill pid Sys.sigterm ;
  (* No the worker is supposed to tidy up everything and terminate.
   * Then we have a thread that is waiting for him, perform a quick
   * autopsy and clear the pid ; as soon as he get a chance because
   * we are currently holding the conf.
   * We want to check in a few seconds that this had happened: *)
  async (fun () ->
    let%lwt () = Lwt_unix.sleep (1. +. Random.float 1.) in
    C.with_rlock conf (fun programs ->
      !logger.debug "Checking that pid %d is not around any longer." pid ;
      (* Find that program again, and if it's still having the same pid
       * then shoot him down: *)
      match C.find_func programs func.N.program func.N.name with
      | exception Not_found -> return_unit (* that's fine *)
      | program, func ->
        (* Here it is assumed that the program was not launched again
         * within 2 seconds with the same pid. In a world where this
         * assumption wouldn't hold we would have to increment a counter
         * in the func for instance... *)
        if func.N.pid = Some pid then (
          !logger.warning "Killing worker %s (pid %d) with bigger guns"
            (N.fq_name func) pid ;
          try_kill pid Sys.sigkill ;
        ) ;
        return_unit))

let stop conf programs program =
  match program.L.status with
  | Edition _ | Compiled -> return_unit
  | Compiling ->
    (* FIXME: do as for Running and make sure run() check the status hasn't
     * changed before launching workers. *)
    return_unit
  | Running ->
    !logger.info "Stopping program %s" program.L.name ;
    let now = Unix.gettimeofday () in
    let program_funcs =
      Hashtbl.values program.L.funcs |> List.of_enum in
    let%lwt () = Lwt_list.iter_p (fun func ->
        let%lwt () = RamenExport.stop conf func in
        match func.N.pid with
        | None ->
          !logger.error "Function %s has no pid?!" func.N.name ;
          return_unit
        | Some pid ->
          !logger.debug "Stopping func %s, pid %d" func.N.name pid ;
          (* Start by removing this worker ringbuf from all its parent output
           * references *)
          let this_in = C.in_ringbuf_name conf func in
          let%lwt () = Lwt_list.iter_p (fun (parent_program, parent_name) ->
              match C.find_func programs parent_program parent_name with
              | exception Not_found -> return_unit
              | _, parent ->
                let out_ref = C.out_ringbuf_names_ref conf parent in
                RamenOutRef.remove out_ref this_in
            ) func.N.parents in
          (* Get rid of the worker *)
          kill_worker conf programs func pid ;
          return_unit
      ) program_funcs in
    L.set_status program Compiled ;
    program.L.last_stopped <- Some now ;
    return_unit

let run conf programs program =
  let open L in
  match program.status with
  | Edition _ -> fail NotYetCompiled
  | Running -> fail AlreadyRunning
  | Compiling -> fail StillCompiling
  | Compiled ->
    !logger.info "Starting program %s" program.L.name ;
    (* First prepare all the required ringbuffers *)
    !logger.debug "Creating ringbuffers..." ;
    let program_funcs =
      Hashtbl.values program.funcs |> List.of_enum in
    (* Be sure to cancel everything (threads/execs) we started in case of
     * failure: *)
    try%lwt
      (* We must create all the ringbuffers before starting any worker
       * because there is no good order in which to start them: *)
      let%lwt () = Lwt_list.iter_p (fun func ->
        wrap (fun () ->
          let rb_name = C.in_ringbuf_name conf func in
          RingBuf.create rb_name RingBufLib.rb_default_words
        )) program_funcs in
      (* Now run everything in any order: *)
      !logger.debug "Launching generated programs..." ;
      let now = Unix.gettimeofday () in
      let%lwt () =
        Lwt_list.iter_p (run_func conf programs program) program_funcs in
      L.set_status program Running ;
      program.L.last_started <- Some now ;
      return_unit
    with exn ->
      let%lwt () = stop conf programs program in
      fail exn

(* Timeout unused programs.
 * By unused, we mean either: no program depends on it, or no one cares for
 * what it exports. *)

let use_program now program =
  program.L.last_used <- now

let use_program_by_name programs now program_name =
  Hashtbl.find programs program_name |>
  use_program now

let timeout_programs conf programs =
  (* Build the set of all defined and all used programs *)
  let defined, used =
    Hashtbl.fold (fun program_name program (defined, used) ->
      Set.add program_name defined,
      Hashtbl.fold (fun _func_name func used ->
          List.fold_left (fun used (parent_program, _parent_func) ->
              if parent_program = program_name then used
              else Set.add parent_program used
            ) used func.N.parents
        ) program.L.funcs used
    ) programs (Set.empty, Set.empty) in
  let now = Unix.gettimeofday () in
  Set.iter (use_program_by_name programs now) used ;
  let unused = Set.diff defined used |>
               Set.to_list in
  Lwt_list.iter_p (fun program_name ->
      let program = Hashtbl.find programs program_name in
      if program.L.timeout > 0. &&
         now > program.L.last_used +. program.L.timeout
      then (
        !logger.info "Deleting unused program %s after a %gs timeout"
          program_name program.L.timeout ;
        (* Kill first, and only then forget about it. *)
        let%lwt () = stop conf programs program in
        Hashtbl.remove programs program_name ;
        return_unit
      ) else return_unit
    ) unused

(* Instrumentation: Reading workers stats *)

open Stdint

let reports_lock = RWLock.make ()
let last_reports = Hashtbl.create 31

let read_reports rb =
  RingBuf.read_ringbuf rb (fun tx ->
    let worker, time, ic, sc, oc, gc, cpu, ram, wi, wo, bi, bo =
      RamenBinocle.unserialize tx in
    RingBuf.dequeue_commit tx ;
    RWLock.with_w_lock reports_lock (fun () ->
      Hashtbl.replace last_reports worker SN.{
        time ;
        in_tuple_count = Option.map Uint64.to_int ic ;
        selected_tuple_count = Option.map Uint64.to_int sc ;
        out_tuple_count = Option.map Uint64.to_int oc ;
        group_count = Option.map Uint64.to_int gc ;
        cpu_time = cpu ; ram_usage = Uint64.to_int ram ;
        in_sleep = wi ; out_sleep = wo ;
        in_bytes = Option.map Uint64.to_int bi ;
        out_bytes = Option.map Uint64.to_int bo } ;
      return_unit))

let last_report fq_name =
  RWLock.with_r_lock reports_lock (fun () ->
    Hashtbl.find_option last_reports fq_name |?
    { time = 0. ;
      in_tuple_count = None ; selected_tuple_count = None ;
      out_tuple_count = None ; group_count = None ;
      cpu_time = 0. ; ram_usage = 0 ;
      in_sleep = None ; out_sleep = None ;
      in_bytes = None ; out_bytes = None } |>
    return)

(* Notifications:
 * To alleviate workers from the hassle to send HTTP notifications, those are
 * sent to Ramen via a ringbuffer. Advantages are many:
 * Workers do not need an HTTP client and are therefore smaller, faster to
 * link, and easier to port to another language.
 * Also, they might as well be easier to link with the libraries bundle. *)

let read_notifications rb =
  let unserialize tx =
    let offs = 0 in (* Nothing can be null in this tuple *)
    let worker = RingBuf.read_string tx offs in
    let offs = offs + RingBufLib.sersize_of_string worker in
    let url = RingBuf.read_string tx offs in
    worker, url
  in
  RingBuf.read_ringbuf rb (fun tx ->
    let worker, url = unserialize tx in
    !logger.info "Received notify instruction from %s to %s"
      worker url ;
    RingBuf.dequeue_commit tx ;
    RamenHttpHelpers.http_notify url)
