open Batteries
open RamenLog
open RamenHelpers
module C = RamenConf
module F = C.Func
module P = C.Program

(* Dequeue command *)

let dequeue conf file n () =
  logger := make_logger conf.C.log_level ;
  if file = "" then invalid_arg "dequeue" ;
  let open RingBuf in
  let rb = load file in
  let rec dequeue_loop n =
    if n > 0 then (
      (* TODO: same automatic retry-er as in CodeGenLib_IO *)
      let bytes = dequeue rb in
      Printf.printf "dequeued %d bytes\n%!" (Bytes.length bytes) ;
      dequeue_loop (n - 1)
    )
  in
  dequeue_loop n

(* Summary command *)

let summary conf files () =
  logger := make_logger conf.C.log_level ;
  List.iter (fun file ->
    let open RingBuf in
    let rb = load file in
    let s = stats rb in
    Printf.printf "%s:\n\
                   Flags:%s\n\
                   seq range: %d..%d (%d)\n\
                   time range: %f..%f (%.1fs)\n\
                   %d/%d words used (%3.1f%%)\n\
                   mmapped bytes: %d\n\
                   producers range: %d..%d\n\
                   consumers range: %d..%d\n"
      file (if s.wrap then " Wrap" else "")
      s.first_seq (s.first_seq + s.alloc_count - 1) s.alloc_count
      s.t_min s.t_max (s.t_max -. s.t_min)
      s.alloced_words s.capacity
      (float_of_int s.alloced_words *. 100. /. (float_of_int s.capacity))
      s.mem_size s.prod_tail s.prod_head s.cons_tail s.cons_head ;
    unload rb
  ) files

(* Repair Command *)

let repair conf files () =
  logger := make_logger conf.C.log_level ;
  List.iter (fun file ->
    let open RingBuf in
    let rb = load file in
    if repair rb then
      !logger.warning "Ringbuf was damaged" ;
    unload rb
  ) files

(* List all ringbuffers in use with some stats: *)

type func_status =
  | Running of F.t
  | NotRunning of RamenName.program * RamenName.func
  | ProgramError of RamenName.program * string

let links conf no_abbrev show_all pretty with_header sort_col top pattern () =
  logger := make_logger conf.C.log_level ;
  let pattern = Globs.compile pattern in
  (* Same to get the ringbuffer stats, but we never reread the stats (not
   * needed, and mtime wouldn't really work on those mmapped files *)
  let get_rb_stats = cached "links" (fun fname ->
    match RingBuf.load fname with
    | exception Failure _ -> None
    | rb ->
        let s = RingBuf.stats rb in
        RingBuf.unload rb ;
        Some s) ignore in
  let fq_name = function
    | NotRunning (pn, fn) ->
        red (RamenName.string_of_program pn ^"/"^
             RamenName.string_of_func fn)
    | ProgramError (pn, e) ->
        red (RamenName.string_of_program pn ^": "^ e)
    | Running func -> RamenName.string_of_fq (F.fq_name func) in
  let head =
    [| "parent" ; "child" ; "out_ref" ; "spec" ; "ringbuf" ;
       "fill ratio" ; "next seqs" |] in
  let line_of_link i p c =
    let parent = fq_name p and child = fq_name c in
    if Globs.matches pattern parent ||
       Globs.matches pattern child
    then
      let ringbuf, fill_ratio, next_seqs, is_err1 =
        match c with
        | NotRunning _ | ProgramError _ -> "", "0.", "", false
        | Running c ->
            let ringbuf =
              if c.F.merge_inputs then
                C.in_ringbuf_name_merging conf c i
              else
                C.in_ringbuf_name_single conf c in
            let fill_ratio, next_seqs =
              match get_rb_stats ringbuf with
              | None -> 0., ""
              | Some s ->
                  float_of_int s.alloced_words /. float_of_int s.capacity,
                  string_of_int s.cons_tail ^".."^ string_of_int s.cons_head in
            let fr = string_of_float fill_ratio in
            let fr, is_err =
              if fill_ratio < 0.33 then green fr, false else
              (* The ringbuffer will be full before the word fill ratio is 100%: *)
              if fill_ratio >= 0.9 then red fr, true else
              if fill_ratio > 0.75 then yellow fr, false else
              fr, false in
            ringbuf, fr, next_seqs, is_err
      in
      let%lwt out_ref, spec, is_err2 =
        match p with
        | NotRunning (pn, fn) ->
            Lwt.return ("", red "NOT RUNNING", true)
        | ProgramError (pn, e) ->
            Lwt.return ("", red e, true)
        | Running p ->
            let out_ref = C.out_ringbuf_names_ref conf p in
            let%lwt outs = RamenOutRef.read out_ref in
            let spec, is_err =
              if Hashtbl.mem outs ringbuf then ringbuf, false
              else red "MISSING", true in
            Lwt.return (out_ref, spec, is_err)
      in
      let is_err = is_err1 || is_err2 in
      let ap s = if no_abbrev then s else abbrev_path s in
      let parent = ap parent and child = ap child in
      let ap s = if no_abbrev then s else
                   abbrev_path ~known_prefix:conf.persist_dir s in
      let out_ref = ap out_ref and ringbuf = ap ringbuf in
      if not show_all && not is_err then Lwt.return_none else
        Some TermTable.[|
          ValStr parent ; ValStr child ; ValStr out_ref ; ValStr spec ;
          ValStr ringbuf ; ValStr fill_ratio ;
          ValStr next_seqs |] |> Lwt.return
    else
      Lwt.return_none
  in
  (* We first collect all links supposed to exist according to
   * parent/children relationships: *)
  let links =
    Lwt_main.run (
      C.with_rlock conf (fun programs ->
        (* Get rid of Lwt in AdvLock and RamenOutRef! *)
        Hashtbl.enum programs |> List.of_enum |>
        Lwt_list.fold_left_s (fun links (program_name, (_mre, get_rc)) ->
          match get_rc () with
          | exception _ -> Lwt.return_nil (* Errors have been logged already *)
          | prog ->
              Lwt_list.fold_left_s (fun links func ->
                let%lwt _, links =
                  Lwt_list.fold_left_s (fun (i, links)
                                            (par_rel_prog, par_func) ->
                    (* i is the index in the list of parents for a given
                     * child *)
                    let par_prog =
                      F.program_of_parent_prog func.F.program_name
                                               par_rel_prog in
                    let parent =
                      match Hashtbl.find programs par_prog with
                      | exception Not_found ->
                          NotRunning (par_prog, par_func)
                      | _mre, get_rc ->
                        (match get_rc () with
                        | exception e ->
                            ProgramError (par_prog, Printexc.to_string e)
                        | pprog ->
                            (match List.find (fun f ->
                                     f.F.name = par_func
                                   ) pprog.P.funcs with
                            | exception Not_found ->
                                NotRunning (par_prog, par_func)
                            | pfunc -> Running pfunc)) in
                    match%lwt line_of_link i parent (Running func) with
                    | Some line -> Lwt.return (i + 1, line :: links)
                    | None -> Lwt.return (i + 1, links)
                  ) (0, links) func.parents in
                Lwt.return links
              ) links prog.P.funcs
        ) [])) in
  TermTable.print_table ~pretty ~sort_col ~with_header ?top head links
