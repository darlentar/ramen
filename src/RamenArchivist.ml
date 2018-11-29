(* A service of its own, the archivist job is to monitor everything
 * that's running and, guided by some user configuration, to find out
 * which function should be asked to archive its history and for all
 * long (this being used by the GC eventually). *)
open Stdint
open Batteries
open RamenHelpers
open RamenLog
open RamenSmt
open RamenConsts
module C = RamenConf
module F = C.Func
module P = C.Program

let conf_dir conf =
  conf.C.persist_dir ^"/archivist/"
                     ^ RamenVersions.archivist_conf

(*
 * User configuration provides what functions we want to be able to retrieve
 * the output in the future (either directly via reading the archived output
 * or indirectly via recomputing from parents output) and what total storage
 * space we have at disposal.
 *)

(* We want to serialize globs as strings: *)
type glob = Globs.pattern
let glob_ppp_ocaml : glob PPP.t =
  let star = '*' and placeholder = '?' and escape = '\\' in
  let s2g = Globs.compile ~star ~placeholder ~escape
  and g2s = Globs.decompile in
  PPP.(string >>: (g2s, s2g))

type user_conf =
  { (* Global size limit, in byte (although the SMT uses coarser grained
       sizes): *)
    size_limit : int ;
    (* The cost to retrieve one byte of archived data, expressed in the
     * unit of CPU time (ie. the time it takes to retrieve that byte if
     * you value the IO time as much as the CPU time): *)
    recall_cost : float [@ppp_default 1e-6] ;
    (* Individual nodes we want to keep some history, none by default.
     * TODO: replaces or override the persist flag + retention length
     * that should go with it): *)
    retentions : (glob, retention) Hashtbl.t
      [@ppp_default
        let h = Hashtbl.create 1 in
        Hashtbl.add h Globs.all
          { duration = 86400. *. 365. ; query_freq = 1. /. 600. } ;
        h ] }
  [@@ppp PPP_OCaml]

and retention =
  { duration : float ;
    (* How frequently we intend to query it, in Hertz (TODO: we could
     * approximate a better value if absent): *)
    query_freq : float [@ppp_default 1. /. 600.] }
  [@@ppp PPP_OCaml]

let get_user_conf fname =
  ensure_file_exists ~min_size:14 ~contents:"{size_limit=104857600}" fname ;
  ppp_of_file user_conf_ppp_ocaml fname

let user_conf_file conf =
  conf_dir conf ^ "/config"

let retention_of_fq conf fq =
  try
    Hashtbl.enum conf.retentions |>
    Enum.find_map (fun (pat, ret) ->
      if Globs.matches pat (RamenName.string_of_fq fq) then Some ret
      else None)
  with Not_found -> { duration = 0. ; query_freq = 0. }

(*
 * Then the first stage is to gather statistics about all running workers.
 * We do this by continuously listening to the health reports and maintaining
 * a "stats" file with the best idea of the size of the output of each worker
 * and its resource consumption.
 *
 * This could be done with a dedicated worker but for now we just tail on
 * #notifs "manually".
 *)

(* Global per-func stats that are updated by the thread reading #notifs and
 * the one reading the RC, and also saved on disk while ramen is not running:
 * (TODO) *)

type func_stats =
  { running_time : float [@ppp_default 0.] ;
    tuples : int64 (* Sacrifice 1 bit for convenience *) [@ppp_default 0L] ;
    bytes : int64 [@ppp_default 0L] ;
    cpu : float (* Cumulated seconds *) [@ppp_default 0.] ;
    ram : int64 (* Max observed heap size *) [@ppp_default 0L] ;
    mutable parents : RamenName.fq list ;
    (* Also gather available history per running workers, to speed up
     * establishing query plans: *)
    mutable archives : (float * float) list [@ppp_default []] }
  [@@ppp PPP_OCaml]

let func_stats_empty =
  { running_time = 0. ; tuples = 0L ; bytes = 0L ; cpu = 0. ; ram = 0L ;
    parents = [] ; archives = [] }

(* Returns the func_stat resulting of adding the RamenPs.stats to the
 * previous func_stat [a]: *)
let add_ps_stats a s now =
  let etime_diff =
    match s.RamenPs.min_etime, s.max_etime with
    | Some t1, Some t2 -> t2 -. t1
    | _ -> now -. s.startup_time
  in
  { running_time = a.running_time +. etime_diff ;
    tuples = Int64.add a.tuples Uint64.(to_int64 (s.out_count |? zero)) ;
    bytes = Int64.add a.bytes Uint64.(to_int64 (s.bytes_out |? zero)) ;
    cpu = a.cpu +. s.cpu ;
    ram = Int64.add a.ram Uint64.(to_int64 s.max_ram) ;
    parents = a.parents ; archives = a.archives }

(* Those stats are saved on disk: *)

type per_func_stats_ser = (RamenName.fq, func_stats) Hashtbl.t
  [@@ppp PPP_OCaml]

let load_per_func_stats conf =
  let fname = conf_dir conf ^ "/stats" in
  ensure_file_exists ~contents:"{}" fname ;
  ppp_of_file per_func_stats_ser_ppp_ocaml fname

let save_per_func_stats conf stats =
  let fname = conf_dir conf ^ "/stats" in
  ppp_to_file ~pretty:true fname per_func_stats_ser_ppp_ocaml stats

(* Then we also need the RC as we also need to know the workers relationships
 * in order to estimate how expensive it is to rely on parents as opposed to
 * archival.
 *
 * So this function enriches the per_func_stats hash with parent-children
 * relationships and also compute and sets the various costs we need. *)

let update_parents s program_name func =
  s.parents <-
    List.map (fun (pprog, pfunc) ->
      let pprog =
        F.program_of_parent_prog program_name pprog in
      RamenName.fq pprog pfunc
    ) func.F.parents

let update_archives conf s func =
  let bname = C.archive_buf_name conf func in
  let lst =
    RingBufLib.(arc_dir_of_bname bname |> arc_files_of) //@
    (fun (_seq_mi, _seq_ma, t1, t2, _f) ->
      if Float.(is_nan t1 || is_nan t2) then None else Some (t1, t2)) |>
    List.of_enum |>
    List.sort (fun (ta,_) (tb,_) -> Float.compare ta tb) in
  (* Compress that list: when a gap in between two file is smaller than
   * one tenth of the duration of those two files then assume there is no
   * gap: *)
  let rec loop prev rest =
    match prev, rest with
    | (t11, t12)::prev', (t21, t22)::rest' ->
        assert (t12 >= t11 && t22 >= t21) ;
        let gap = t21 -. t12 in
        if gap < 0.1 *. abs_float (t22 -. t11) then
          loop ((t11, t22) :: prev') rest'
        else
          loop ((t21, t22) :: prev) rest'
    | [], t::rest' ->
        loop [t] rest'
    | prev, [] ->
        List.rev prev in
  s.archives <- loop [] lst

let enrich_stats conf per_func_stats =
  C.with_rlock conf identity |>
  Hashtbl.iter (fun program_name (_mre, get_rc) ->
    match get_rc () with
    | exception _ -> ()
    | prog ->
        List.iter (fun func ->
          let fq = RamenName.fq program_name func.F.name in
          match Hashtbl.find per_func_stats fq with
          | exception Not_found -> ()
          | (s, _) ->
              update_parents s program_name func ;
              update_archives conf s func
        ) prog.P.funcs)

(* tail -f the #notifs stream and update per_func_stats: *)
let update_worker_stats ?while_ conf =
  (* When running we keep both the stats and the last received health report
   * as well as the last startup_time (to detect restarts): *)
  let per_func_stats :
    (RamenName.fq, (func_stats * (float * RamenPs.t) option)) Hashtbl.t =
    load_per_func_stats conf |>
    Hashtbl.map (fun _fq s -> s, None)
  in
  let now = Unix.gettimeofday () in
  RamenPs.read_stats ?while_ conf |>
  Hashtbl.iter (fun fq s ->
    Hashtbl.modify_opt fq (function
      | None ->
          Some (func_stats_empty, Some (s.RamenPs.startup_time, s))
      | Some (tot, None) ->
          Some (tot, Some (s.RamenPs.startup_time, s))
      | Some (tot, Some (startup_time, _)) ->
          if s.RamenPs.startup_time = startup_time then (
            Some (tot, Some (startup_time, s))
          ) else (
            (* Worker has restarted. We assume it's still mostly the
             * same operation. Maybe consider the function signature
             * (and add it to the stats?) *)
            let tot = add_ps_stats tot s now in
            Some (tot, Some (s.RamenPs.startup_time, s))
          )
    ) per_func_stats
  ) ;
  enrich_stats conf per_func_stats ;

  Hashtbl.map (fun _fq -> function
    | tot, None -> tot
    | tot, Some (_, last) -> add_ps_stats tot last now
  ) per_func_stats |>
  save_per_func_stats conf

(*
 * Optimising storage:
 *
 * All the information in the stats file can then be used to compute the
 * disk shares per functions ; also to be stored in a file as a mapping
 * from FQ to number of bytes allowed on disk. This will then be read and
 * used by the GC.
 *)

(* We have constraints given by the user configuration that set a higher
 * bound on some history sizes. We need those constraints named
 * in case we have to report non-satisfiability, so we name them according
 * to their index in the file.
 * The only other constraint we have is that no function must cost more
 * than the invalid cost, which arrives only when there is no other
 * solution than to "recompute" the original values, ie there is not
 * enough storage space. *)

let constraint_name i =
  scramble ("user_" ^ string_of_int i)

(* Now we want to minimize the cost of querying the whole history of all
 * persistent functions in proportion to their query frequency, while still
 * remaining within the bounds allocated to storage.
 *
 * The cost to retrieve length L at frequency H of any function output is
 * either:
 *
 * - the IO cost of reading it: L * H * storage cost
 * - or the CPU (+ RAM?) cost of recomputing it: L * H * cpu cost
 *
 * ...depending on whether the output is archived or not.
 * Notice that here L is coming from the persistent function that's a child of
 * that one (or that very one).
 *
 * We know each cost individually, and how to relate storage and computing
 * cost thanks to user configuration.
 * We want to make the sum of all those costs as small as possible.
 *
 * Notice that we want the total storage to be below the provided limits but
 * not necessarily as small as possible (although the smaller the storage the
 * faster it is to read).
 *
 * The parameters are the history length of each function, perc_i, as a
 * percentage of available storage space between 0 (no archival whatsoever)
 * to 100 (archive only that function). The connection between the actual
 * length (in days) and that share of storage is constant and known for
 * each function.
 *
 * The constraints are thus:
 *
 * - Total sum of perc_i <= 100 (we may not use exactly 100% but certainly
 *   the solution will come close);
 *
 * - The archive size of a function is:
 *   its size per second * perc_i * size_limit/100;
 *   while its archive duration is:
 *   its archive size / its size per second, or:
 *   perc_i * (size_limit/(100 * size per second))
 *
 * - The query cost of function F for a duration L is:
 *   - if its archive length if longer than L:
 *     its read cost * L
 *   - otherwise:
 *     the query cost of each of its parent for duration L +
 *     its own cpu cost * L.
 *
 * - Note that for functions with no parent, the cpu cost is infinite, as
 *   there are actually no way to recompute it. If a function with no parent
 *   is queried directly there is no way around archiving.
 *
 * - The cost of the solution it the sum of all query costs for each function
 *   with a retention, that we want to minimize.
 *
 * TODO: Make it costly to radically change one's mind!
 *)

let list_print oc =
  List.print ~first:"" ~last:"" ~sep:" " oc

let hashkeys_print p =
  Hashtbl.print ~first:"" ~last:"" ~sep:" " ~kvsep:"" p (fun _ _ -> ())

let const pref fq =
  pref ^ scramble (RamenName.string_of_fq fq)

let perc = const "perc_"
let cost i fq = (const "cost_" fq) ^"_"^ string_of_int i

(* The "compute cost" per second is the CPU time it takes to
 * process one second worth of data. *)
let compute_cost s = s.cpu /. s.running_time

(* The "recall size" is the total size per second in bytes.
 * The recall cost of a second worth of output will be this size
 * times the user_conf.recall_cost. *)
let recall_size s = Int64.to_float s.bytes /. s.running_time

(* For each function, declare the boolean perc_f, that must be between 0
 * and 100: *)
let emit_all_vars durations oc per_func_stats =
  Hashtbl.iter (fun fq s ->
    Printf.fprintf oc
      "; Storage share of %s (compute cost: %f, recall size: %f)\n\
       (declare-const %s Int)\n\
       (assert (>= %s 0))\n\
       (assert (<= %s 100)) ; should not be required but helps\n"
      (RamenName.string_of_fq fq)
      (compute_cost s) (recall_size s)
      (perc fq) (perc fq) (perc fq) ;
    List.iteri (fun i _ ->
      Printf.fprintf oc
        "(declare-const %s Int)\n"
        (cost i fq)) durations
  ) per_func_stats

let emit_sum_of_percentages oc per_func_stats =
  Printf.fprintf oc "(+ 0 %a)"
    (hashkeys_print (fun oc fq -> String.print oc (perc fq))) per_func_stats

let secs_per_day = 86400.
let invalid_cost = "99999999999999999999"

let emit_query_costs user_conf durations oc per_func_stats =
  String.print oc "; Durations: " ;
  List.iteri (fun i d ->
    Printf.fprintf oc "%s%d:%s"
      (if i > 0 then ", " else "") i (string_of_duration d)
  ) durations ;
  String.print oc "\n" ;
  (* Now for each of these durations, instruct the solver what the query
   * cost will be: *)
  Hashtbl.iter (fun fq s ->
    Printf.fprintf oc "; Query cost of %s (parents: %a)\n"
      (RamenName.string_of_fq fq)
      (list_print (fun oc p ->
        String.print oc (RamenName.string_of_fq p))) s.parents ;
    List.iteri (fun i d ->
      let recall_size = recall_size s in
      let recall_cost =
        if recall_size < 0. then invalid_cost else
        string_of_int (
          ceil_to_int (user_conf.recall_cost *. recall_size *. d)) in
      if String.length recall_cost > String.length invalid_cost then
        (* Poor man arbitrary size integers :> *)
        !logger.error "Archivist: Got a cost of %s which is greater than invalid!"
          recall_cost ;
      let compute_cost = compute_cost s in
      let compute_cost =
        if s.parents = [] || compute_cost < 0. then invalid_cost else
        Printf.sprintf2 "(+ %d (+ 0 %a))"
          (ceil_to_int (compute_cost *. d))
          (* cost of all parents for that duration: *)
          (list_print (fun oc parent ->
             Printf.fprintf oc "%s" (cost i parent))) s.parents
      in
      Printf.fprintf oc
        "(assert (= %s\n\
            \t(ite (>= %s %d)\n\
                 \t\t%s\n\
                 \t\t%s)))\n"
      (cost i fq)
      (perc fq)
        (* Percentage of size_limit required to hold duration [d] of
         * archives: *)
        (ceil_to_int (d *. recall_size *. 100. /.
         float_of_int user_conf.size_limit))
      recall_cost
      compute_cost
    ) durations
  ) per_func_stats

let emit_no_invalid_cost user_conf durations oc per_func_stats =
  Hashtbl.iter (fun fq _ ->
    let retention = retention_of_fq user_conf fq in
    if retention.duration > 0. then (
      (* Which index is that? *)
      let i = List.index_of retention.duration durations |> Option.get in
      Printf.fprintf oc "(assert (< %s %s))\n"
        (cost i fq) invalid_cost)
  ) per_func_stats

let emit_total_query_costs user_conf durations oc per_func_stats =
  Printf.fprintf oc "(+ 0 %a)"
    (hashkeys_print (fun oc fq ->
      let retention = retention_of_fq user_conf fq in
      if retention.duration > 0. then
        (* Which index is that? *)
        let i = List.index_of retention.duration durations |> Option.get in
        (* The cost is a whole day of queries: *)
        let queries_per_days =
          ceil_to_int (retention.query_freq *. secs_per_day) in
        !logger.info
          "Must be able to query %a for a duration %s, at %d queries per day"
          RamenName.fq_print fq
          (string_of_duration retention.duration)
          queries_per_days ;
        Printf.fprintf oc "(* %s %d)"
          (cost i fq) queries_per_days))
      per_func_stats

let emit_smt2 user_conf per_func_stats oc ~optimize =
  (* To begin with, what retention durations are we interested about? *)
  let durations =
    Hashtbl.enum user_conf.retentions /@
    (fun (_fq, ret) -> ret.duration) |>
    List.of_enum |>
    List.sort_uniq Float.compare in
  Printf.fprintf oc
    "%a\
     ; What we aim to know: the percentage of available storage to be used\n\
     ; for each function:\n\
     %a\n\
     ; Of course the sum of those shares cannot exceed 100:\n\
     (assert (<= %a 100))\n\
     ; Query costs of each function:\n\
     %a\n\
     ; No actually used cost must be < invalid_cost\n\
     %a\n\
     ; Minimize the cost of querying each function with retention:\n\
     (minimize %a)\n\
     %t"
    preamble optimize
    (emit_all_vars durations) per_func_stats
    emit_sum_of_percentages per_func_stats
    (emit_query_costs user_conf durations) per_func_stats
    (emit_no_invalid_cost user_conf durations) per_func_stats
    (emit_total_query_costs user_conf durations) per_func_stats
    post_scriptum

(*
 * The results are stored in the file "allocs", which is a map from names
 * to size.
 *)

type per_func_allocs_ser = (RamenName.fq, int) Hashtbl.t
  [@@ppp PPP_OCaml]

let save_per_func_allocs conf allocs =
  let fname = conf_dir conf ^ "/allocs" in
  ppp_to_file ~pretty:true fname per_func_allocs_ser_ppp_ocaml allocs

let load_per_func_allocs conf =
  let fname = conf_dir conf ^ "/allocs" in
  ensure_file_exists ~contents:"{}" fname ;
  ppp_of_file per_func_allocs_ser_ppp_ocaml fname

let update_storage_allocation conf =
  let open RamenSmtParser in
  let solution = Hashtbl.create 17 in
  let user_conf = get_user_conf (user_conf_file conf)
  and per_func_stats = load_per_func_stats conf in
  let fname = conf_dir conf ^ "/allocations.smt2"
  and emit = emit_smt2 user_conf per_func_stats
  and parse_result sym vars sort term =
    try Scanf.sscanf sym "perc_%s%!" (fun s ->
      let fq = unscramble s |> RamenName.fq_of_string in
      match vars, sort, term with
      | [], NonParametricSort (Identifier "Int"),
        ConstantTerm perc ->
          let perc = int_of_constant perc in
          if perc <> 0 then !logger.info "%a: %d%%"
            RamenName.fq_print fq perc ;
          Hashtbl.replace solution fq perc
      | _ ->
          !logger.warning "  of some sort...?")
    with Scanf.Scan_failure _ -> ()
  and unsat _syms _output = ()
  in
  run_smt2 ~fname ~emit ~parse_result ~unsat ;
  (* Scale it up to 100% and convert to bytes: *)
  let tot_perc = Hashtbl.fold (fun _ p s -> s + p) solution 0 in
  assert (tot_perc <= 100) ;
  let scale = float_of_int user_conf.size_limit /. float_of_int tot_perc in
  Hashtbl.map (fun _ p ->
    if tot_perc = 0 then user_conf.size_limit
    else round_to_int (float_of_int p *. scale)) solution |>
  save_per_func_allocs conf

(*
 * The allocs are used to update the workers out_ref to make them archive.
 * If not refreshed periodically (see
 * [RamenConst.Defaults.archivist_export_duration]) any worker will stop
 * exporting at some point.
 *)

let update_workers_export conf =
  let programs = C.with_rlock conf identity in (* Best effort *)
  load_per_func_allocs conf |>
  Hashtbl.iter (fun fq max_size ->
    match C.find_func programs fq with
    | exception e ->
        !logger.debug "Cannot find function %a: %s, skipping"
          RamenName.fq_print fq
          (Printexc.to_string e)
    | _prog, func ->
        if max_size > 0 then
          let duration=Default.archivist_export_duration in
          RamenExport.start ~duration conf func |> ignore)

(*
 * CLI
 *)

let run_once conf ?while_ no_stats no_allocs no_reconf =
  (* Start by gathering (more) workers stats: *)
  if not no_stats then (
    !logger.info "Updating workers stats" ;
    update_worker_stats ?while_ conf) ;
  (* Then use those to answer the big questions about queries, the storage
   * and everything: *)
  if not no_allocs then (
    !logger.info "Updating storage allocations" ;
    update_storage_allocation conf) ;
  (* Now update the archiving configuration of running workers: *)
  if not no_reconf then (
    !logger.info "Updating workers export configuration" ;
    update_workers_export conf)

let run_loop conf ?while_ sleep_time no_stats no_allocs no_reconf =
  let watchdog =
    let timeout = sleep_time *. 2. in
    RamenWatchdog.make ~timeout "Archiver" RamenProcesses.quit in
  RamenWatchdog.enable watchdog ;
  forever (fun () ->
    run_once conf ?while_ no_stats no_allocs no_reconf ;
    RamenWatchdog.reset watchdog ;
    Unix.sleepf (jitter sleep_time)) ()
