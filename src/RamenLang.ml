(* AST for the stream processor graph *)
open Batteries
open Stdint
open RamenHelpers
open RamenLog
module N = RamenName

type tuple_prefix =
  | TupleUnknown (* Either Record, In, Out, or Param*)
  | TupleIn
  | TupleGroup
  | TupleOutPrevious
  | TupleOut
  (* Tuple usable in sort expressions *)
  | TupleSortFirst
  | TupleSortSmallest
  | TupleSortGreatest
  (* Largest tuple from the merged streams (smallest being TupleIn),
   * usable in WHERE clause: *)
  | TupleMergeGreatest
  (* Parameters *)
  | TupleParam
  (* Environments for nullable string only parameters: *)
  | TupleEnv
  (* For when a field is from a locally opened record. To know where that
   * record is coming from one has to look through the chain of Gets. *)
  | Record
  (* TODO: TupleOthers? *)
  [@@ppp PPP_OCaml]

let string_of_prefix = function
  | TupleUnknown -> "unknown"
  | TupleIn -> "in"
  | TupleGroup -> "group"
  | TupleOutPrevious -> "out_previous"
  | TupleOut -> "out"
  | TupleSortFirst -> "sort_first"
  | TupleSortSmallest -> "sort_smallest"
  | TupleSortGreatest -> "sort_greatest"
  | TupleMergeGreatest -> "merge_greatest"
  | TupleParam -> "param"
  | TupleEnv -> "env"
  | Record -> "record"

let tuple_prefix_print oc p =
  Printf.fprintf oc "%s" (string_of_prefix p)

let parse_prefix m =
  let open RamenParsing in
  let m = "tuple prefix" :: m in
  let w s = ParseUsual.string ~case_sensitive:false s +-
            nay legit_identifier_chars in
  (
    (w "unknown" >>: fun () -> TupleUnknown) |||
    (w "in" >>: fun () -> TupleIn) |||
    (w "group" >>: fun () -> TupleGroup) |||
    (w "out_previous" >>: fun () -> TupleOutPrevious) |||
    (w "previous" >>: fun () -> TupleOutPrevious) |||
    (w "out" >>: fun () -> TupleOut) |||
    (w "sort_first" >>: fun () -> TupleSortFirst) |||
    (w "sort_smallest" >>: fun () -> TupleSortSmallest) |||
    (w "sort_greatest" >>: fun () -> TupleSortGreatest) |||
    (w "merge_greatest" >>: fun () -> TupleMergeGreatest) |||
    (w "smallest" >>: fun () -> TupleSortSmallest) |||
    (* Note that since sort.greatest and merge.greatest cannot appear in
     * the same clauses we could convert one into the other (TODO) *)
    (w "greatest" >>: fun () -> TupleSortGreatest) |||
    (w "param" >>: fun () -> TupleParam) |||
    (w "env" >>: fun () -> TupleEnv) |||
    (* Not for public consumption: *)
    (w "record" >>: fun () -> Record)
  ) m

(* Tuple that has the fields of this func input type *)
let tuple_has_type_input = function
  | TupleIn
  | TupleSortFirst | TupleSortSmallest | TupleSortGreatest
  | TupleMergeGreatest -> true
  | _ -> false

(* Tuple that has the fields of this func output type *)
let tuple_has_type_output = function
  | TupleOutPrevious | TupleOut -> true
  | _ -> false

open RamenParsing

(* Defined here as both RamenProgram and RamenOperation need to parse/print
 * function and program names: *)

let program_name ?(quoted=false) m =
  let quoted_quote = id_quote_escaped >>: fun () -> id_quote_char in
  let what = "program name" in
  let m = what :: m in
  let first_char =
    if quoted then not_id_quote ||| quoted_quote
    else letter ||| underscore ||| dot ||| slash in
  let any_char =
    if quoted then not_id_quote
              else first_char ||| decimal_digit ||| pound in
  (
    first_char ++ repeat ~sep:none ~what any_char >>:
    fun (c, s) -> N.rel_program (String.of_list (c :: s))
  ) m

let func_name ?(quoted=false) m =
  let what = "function name" in
  let m = what :: m in
  let not_quote =
    cond "quoted identifier" (fun c -> c <> id_quote_char && c <> '/') '_' in
  let first_char = if quoted then not_quote
                   else letter ||| underscore in
  let any_char = if quoted then not_quote
                 else first_char ||| decimal_digit in
  (
    first_char ++ repeat_greedy ~sep:none ~what any_char >>:
    fun (c, s) -> N.func (String.of_list (c :: s))
  ) m

let function_name =
  let unquoted = func_name
  and quoted =
    id_quote -+ func_name ~quoted:true +- id_quote in
  (quoted ||| unquoted)

let func_identifier m =
  let m = "function identifier" :: m in
  let unquoted =
    optional ~def:None
      (some program_name +- char '/') ++
    func_name
  and quoted =
    id_quote -+
    optional ~def:None
       (some (program_name ~quoted:true) +- char '/') ++
    func_name ~quoted:true +-
    id_quote in
  (quoted ||| unquoted) m

let site_identifier m =
  let what = "site identifier" in
  let m = what :: m in
  let site_char =
    letter ||| decimal_digit ||| minus |||
    underscore ||| star in
  let unquoted =
    repeat_greedy ~sep:none ~what site_char
  and quoted =
    id_quote -+ repeat_greedy ~sep:none ~what not_id_quote +- id_quote in
  (
    quoted ||| unquoted >>: String.of_list
  ) m
