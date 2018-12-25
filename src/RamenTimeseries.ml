(* This program builds timeseries for the requested time range out of any
 * operation field.
 *
 * The operation event-time has to be known, though.
 *)
open Batteries
open RamenLog
open RamenHelpers
module C = RamenConf
module F = C.Func
module P = C.Program

(* Building timeseries with points at regular times *)

type bucket =
  (* Hopefully count will be small enough that sum can be tracked accurately *)
  { mutable count : float ; mutable sum : float ;
    mutable min : float ; mutable max : float }

let print_bucket oc b =
  Printf.fprintf oc "{ count = %f; sum = %f; min = %f; max = %f }"
    b.count b.sum b.min b.max

(* [nt] is the number of time steps while [nc] is the number of data fields: *)
let make_buckets nt nc =
  Array.init nt (fun _ ->
    Array.init nc (fun _ ->
      { count = 0. ; sum = 0. ; min = max_float ; max = min_float }))

let pour_into_bucket b bi ci v r =
  b.(bi).(ci).count <- b.(bi).(ci).count +. r ;
  b.(bi).(ci).min <- min b.(bi).(ci).min v ;
  b.(bi).(ci).max <- max b.(bi).(ci).max v ;
  b.(bi).(ci).sum <- b.(bi).(ci).sum +. v

(* Returns both the index and the ratio of this bucket on the left of t
 * (between 0 inc. and 1 excl.) *)
let bucket_of_time since dt t =
  let t = t -. since in
  let i = floor (t /. dt) in
  int_of_float i,
  (t -. (i *. dt)) /. dt

let bucket_sum b =
  if b.count = 0. then None else Some b.sum
let bucket_avg b =
  if b.count = 0. then None else Some (b.sum /. b.count)
let bucket_min b =
  if b.count = 0. then None else Some b.min
let bucket_max b =
  if b.count = 0. then None else Some b.max

(* Enumerates all the time*values.
 * Returns the array of factor-column and the Enum.t of data.
 *
 * Each factor-column is the list of values for each given factor (for
 * instance, if you ask factoring by ["ip"; "port"] then for each column
 * you will have ["ip_value"; "port_value"] for that column. If you
 * ask for no factor then you have only one column which values is the empty
 * list [].
 *
 * The enumeration of data is composed of one entry per time value in
 * increasing order, each entry being composed of the time and an array
 * of data-columns.
 *
 * A data-column is itself an array with one optional float per selected
 * field (each factor-column thus has one data-column per selected field).
 *)
(* TODO: (consolidation * data_field) list instead of a single consolidation
 * for all fields *)
type bucket_time = Begin | Middle | End
let get conf num_points since until where factors
        ?consolidation ?(bucket_time=Middle) fq data_fields =
  !logger.debug "Build timeseries for %s, data=%a, where=%a, factors=%a"
    (RamenName.string_of_fq fq)
    (List.print RamenName.field_print) data_fields
    (List.print (fun oc (field, op, value) ->
      Printf.fprintf oc "%a %s %a"
        RamenName.field_print field
        op
        RamenTypes.print value)) where
    (List.print RamenName.field_print) factors ;
  let num_data_fields = List.length data_fields
  and num_factors = List.length factors in
  (* Prepare the buckets in which to aggregate the data fields: *)
  let dt = (until -. since) /. float_of_int num_points in
  let per_factor_buckets = Hashtbl.create 11 in
  let bucket_of_time = bucket_of_time since dt
  and time_of_bucket =
    match bucket_time with
    | Begin -> fun i -> since +. dt *. float_of_int i
    | Middle -> fun i -> since +. dt *. (float_of_int i +. 0.5)
    | End -> fun i -> since +. dt *. float_of_int (i + 1)
  in
  (* And the aggregation function: *)
  let consolidate aggr_str =
    match String.lowercase aggr_str with
    | "min" -> bucket_min | "max" -> bucket_max | "sum" -> bucket_sum
    | _ -> bucket_avg
  in
  (* The data fields we are really interested about are: the data fields +
   * the factors *)
  let tuple_fields = List.rev_append factors data_fields in
  !logger.debug "tuple_fields = %a" (List.print RamenName.field_print) tuple_fields ;
  (* Must not add event time in front of factors: *)
  RamenExport.replay conf fq tuple_fields where since until
                     ~with_event_time:false (fun head ->
    (* TODO: RamenTuple.typ should be an array *)
    let head = Array.of_list head in
    (* Extract fields of interest (data fields, keys...) from a tuple: *)
    (* So tuple will be composed of rev factors then data_fields: *)
    let key_of_factors tuple =
      Array.sub tuple 0 num_factors in
    let open RamenSerialization in
    let def_aggr =
      Array.init num_data_fields (fun i ->
        match head.(num_factors + i).aggr with
        | Some str -> consolidate str
        | None ->
            (match consolidation with
            | None -> bucket_avg
            | Some str -> consolidate str))
    in
    (* If we asked for some factors and have no data, then there will be no
     * columns in the result, which is OK (cartesian product of data fields and
     * factors). But if we asked for no factors then we expect one column per
     * data field, whether there is data or not. So in that case let's create
     * the buckets in advance, in case on_tuple is not called at all: *)
    if num_factors = 0 then (
      let buckets = make_buckets num_points num_data_fields in
      Hashtbl.add per_factor_buckets [||] buckets) ;
    (fun t1 t2 tuple ->
      let k = key_of_factors tuple in
      let buckets =
        try Hashtbl.find per_factor_buckets k
        with Not_found ->
          !logger.debug "New timeseries for column key %a"
            (Array.print RamenTypes.print) k ;
          let buckets = make_buckets num_points num_data_fields in
          Hashtbl.add per_factor_buckets k buckets ;
          buckets in
      let bi1, r1 = bucket_of_time t1 and bi2, r2 = bucket_of_time t2 in
      !logger.debug "bi1=%d (r1=%f), bi2=%d (r2=%f)" bi1 r1 bi2 r2 ;
      (* If bi2 ends up right on the boundary, speed things up by shortening
       * the range: *)
      let bi2, r2 =
        if r2 = 0. && bi2 > bi1 then bi2 - 1, 1. else bi2, r2 in
      (* Iter over all data_fields, that are the last components of tuple: *)
      for i = 0 to num_data_fields - 1 do
        (* We assume that the value is "intensive" rather than "extensive",
         * and so contribute the same amount to each buckets of the interval,
         * instead of distributing the value (TODO: extensive values) *)
        let v = RamenTypes.float_of_scalar tuple.(num_factors + i) in
        Option.may (fun v ->
          let v, bi1, bi2, r =
            if bi1 = bi2 then (
              (* Special case: just soften v *)
              let r = r2 -. r1 in
              abs_float r *. v, bi1, bi2, r
            ) else (
              (* Values on the edge should contribute in proportion to overlap: *)
              let v1 = v *. (1. -. r1) and v2 = v *. r2 in
              if bi1 > 0 && bi1 < Array.length buckets then
                pour_into_bucket buckets bi1 i v1 (1. -. r1) ;
              if bi2 > 0 && bi2 < Array.length buckets then
                pour_into_bucket buckets bi2 i v2 r2 ;
              v, bi1 + 1, bi2 - 1, 1.
            ) in
          for bi = max bi1 0 to min bi2 (Array.length buckets - 1) do
            pour_into_bucket buckets bi i v r
          done
        ) v
      done),
    (fun () ->
      (* Extract the results as an Enum, one value per key *)
      let indices = Enum.range 0 ~until:(num_points - 1) in
      (* Assume keys and values will enumerate keys in the same orders: *)
      let columns =
        Hashtbl.keys per_factor_buckets |>
        Array.of_enum in
      let ts =
        Hashtbl.values per_factor_buckets |>
        Array.of_enum in
      columns,
      indices /@
      (fun i ->
        let t = time_of_bucket i
        and v =
          Array.map (fun buckets ->
            Array.mapi (fun data_field_idx bucket ->
              def_aggr.(data_field_idx) bucket
            ) buckets.(i)
          ) ts in
        t, v)))

(* [get] uses the number of points but users can specify either num-points or
 * the time-step (in which case [since] and [until] are aligned to a multiple
 * of that time-step.
 * This helper function thus computes the effective [since], [until] and
 * [num_points] based on user supplied [since], [until], [num_points] and
 * [time_step]: *)
let compute_num_points time_step num_points since until =
  (* Either num_points or time_step (but not both) must be set (>0): *)
  assert ((num_points > 0 || time_step > 0.) &&
          (num_points <= 0 || time_step <= 0.)) ;
  (* If time_step is given then align bucket times with it.
   * Internally, we use num_points though: *)
  if num_points > 0 then
    num_points, since, until
  else
    let since = align_float time_step since
    and until = align_float ~round:ceil time_step until in
    let num_points = round_to_int ((until -. since) /. time_step) in
    num_points, since, until

(*
 * Factors.
 *
 * For now let's compute the possible values cache lazily, so we can afford
 * to lose/delete them in case of need. In the future we'd like to compute
 * the caches on the fly though.
 *)

let possible_values conf ?since ?until func factor =
  !logger.debug "Retrieving possible values for factor %a of %a"
    RamenName.field_print factor
    RamenName.func_print func.F.name ;
  if not (List.mem factor func.F.factors) then
    invalid_arg "get_possible_values: not a factor" ;
  let dir =
    C.factors_of_function conf func
      ^"/"^ path_quote (RamenName.string_of_field factor) in
  (try Sys.files_of dir
  with Sys_error _ -> Enum.empty ()) //@
  (fun fname ->
    try
      let mi, ma = String.split ~by:"_" fname in
      let mi, ma = RingBufLib.(strtod mi, strtod ma) in
      if Option.map_default (fun t -> t <= ma) true since &&
         Option.map_default (fun t -> t >= mi) true until
      then Some (dir ^"/"^ fname) else None
    with (Not_found | Failure _) -> None) |>
  Enum.fold (fun s fname ->
    let s' = RamenAdvLock.with_r_lock fname marshal_from_fd in
    Set.union s s') Set.empty
