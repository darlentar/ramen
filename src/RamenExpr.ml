(* This module deals with expressions.
 * Expressions are the flesh of ramen programs.
 * Every expression is typed.
 *
 * Immediate values are parsed in RamenTypes.
 *)
open Batteries
open Stdint
open RamenLang
open RamenHelpers
open RamenLog
module T = RamenTypes

(*$inject
  open TestHelpers
  open RamenLang
  open Stdint
*)

(* Stateful function can have either a unique global state a one state per
 * aggregation group (local). Each function has its own default (functions
 * that tends to be used mostly for aggregation have a local default state,
 * while others have a global state), but you can select explicitly using
 * the "locally" and "globally" keywords. For instance: "sum globally 1". *)
type state_lifespan = LocalState | GlobalState
  [@@ppp PPP_OCaml]

type skip_nulls = bool
  [@@ppp PPP_OCaml]

(* Each expression come with a type and a uniq identifier attached (to build
 * var names, record field names or identify SAT variables).
 * Starting at Any, types are set during compilation. *)
type t =
  { text : text ;
    uniq_num : int ;
    mutable typ : T.t (* FIXME: doc should come back here *) }
  [@@ppp PPP_OCaml]

(* The type of an expression. Each is accompanied with a typ
 * (TODO: not for long!) *)
and text =
  (* TODO: Those should go into Stateless0: *)
  (* Immediate value: *)
  | Const of T.value
  (* A tuple of expression (not to be confounded with an immediate tuple).
   * (1; "two"; 3.0) is a T.VTup (an immediate constant of type
   * T.TTup...) whereas (3-2; "t"||"wo"; sqrt(9)) is an expression
   * (Tuple of...). *)
  | Tuple of t list
  (* Literal records where fields are constant but values can be any other
   * expression. Note that the same field name can appear several time in the
   * definition but only the last occurrence will be present in the final
   * value (handy for refining the value of some field).
   * The bool indicates the presence of a STAR selector, which is always
   * cleared after a program is parsed. *)
  | Record of bool * selected_field list
  (* The same distinction applies to vectors.
   * Notice there are no list expressions though, for the same reason that
   * there is no such thing as a list immediate, but only vectors. Lists, ie
   * vectors which dimensions are variable, appear only at typing. *)
  | Vector of t list
  (* Variables can refer to a value in the environment. Most of the time it's
   * going to be "in", "out", etc, which we treat as a fieldname of some
   * opened record. Sometime it's just the field name of an opened immediate
   * record (which is being constructed and not complete yet).
   *
   * This is unrelated to elision of the get in the syntax: when one write
   * for instance "counter" instead of "in.counter" (or "get("counter", in)")
   * then it is first parsed as a variable which name is counter, but early
   * during compilation it is found that this variable is actually unbound
   * and therefore the compiler will try to guess what this name is referring
   * to, and will silently change this unbound variable into the proper  Get.
   *)
  | Variable of RamenName.field
  (* Bindings are met only late in the game in the code generator. They are
   * used at code generation time to pass around an ocaml identifier as an
   * expression. *)
  | Binding of string
  (* A conditional with all conditions and consequents, and finally an optional
   * "else" clause. *)
  | Case of case_alternative list * t option
  (* On functions, internal states, and aggregates:
   *
   * Functions come in three variety:
   * - pure functions: their value depends solely on their parameters, and
   *   is computed whenever it is required.
   * - functions with an internal state, which need to be:
   *   - initialized when the window starts
   *   - updated with the new values of their parameter at each step
   *   - finalize a result when they need to be evaluated - this can be
   *     done several times, ie the same internal state can "fire" several
   *     values
   *   - clean their initial state when the window is moved (we currently
   *     handle this automatically by resetting the state to its initial
   *     value and replay the kept tuples, but this could be improved with
   *     some support from the functions).
   *
   * Aggregate functions have an internal state, but not all functions with
   * an internal state are aggregate functions. There is actually little
   * need to distinguish.
   *
   * skip_nulls is a flag (default: true to ressemble SQL) controlling whether
   * the operator should not update its state on NULL values. This is valid
   * regardless of the nullability of that parameters (or we would need a None
   * default).  This does not change the nullability of the result of the
   * operator (so has no effect on typing), as even when NULLs are skipped the
   * result can still be NULL, when all inputs were NULLs. And if no input are
   * nullable, then skip null does nothing
   *
   * When a parameter to a function with state is another function with state
   * then this second function must deliver a value at every step. This is OK
   * as we have said that a stateful function can fire several times. So for
   * example we could write "min(max(data))", which of course would be equal
   * to "first(data)", or "lag(1, lag(1, data))" equivalently to
   * "lag(2, data)", or more interestingly "lag(1, max(data))", which would
   * return the previous max within the group. Due to the fact that we
   * initialize an internal state only when the first value is met, we must
   * also get the inner function's value when initializing the outer one,
   * which requires initializing in depth first order as well.  *)
  | Stateless of stateless
  | Stateful of (state_lifespan * skip_nulls * stateful)
  | Generator of generator
  [@@ppp PPP_OCaml]

and stateless =
  | SL0 of stateless0
  | SL1 of stateless1 * t
  | SL1s of stateless1s * t list
  | SL2 of stateless2 * t * t
  [@@ppp PPP_OCaml]

and stateless0 =
  | Now
  | Random
  | EventStart
  | EventStop
  [@@ppp PPP_OCaml]

and stateless1 =
  (* TODO: Other functions: date_part... *)
  | Age
  | Cast of T.t
  (* String functions *)
  | Length (* Also for lists *)
  | Lower
  | Upper
  (* Unary Ops on scalars *)
  | Not
  | Abs
  | Minus
  | Defined
  | Exp
  | Log
  | Log10
  | Sqrt
  | Ceil
  | Floor
  | Round
  | Hash
  (* Give the bounds of a CIDR: *)
  | BeginOfRange
  | EndOfRange
  | Sparkline
  | Strptime
  (* Return the name of the variant we are in, or NULL: *)
  | Variant
  (* a LIKE operator using globs, infix *)
  | Like of string (* pattern (using %, _ and \) *)
  [@@ppp PPP_OCaml]

and stateless1s =
  (* Min/Max of the given values. Not like AggrMin/AggrMax, which are
   * aggregate functions! The parser distinguish the cases due to the
   * number of arguments: just 1 and that's the aggregate function, more
   * and that's the min/max of the given arguments. *)
  (* FIXME: those two are useless now that any aggregate function can be
   * used on lists: *)
  | Max
  | Min
  (* For debug: prints all its arguments, and output its first. *)
  | Print
  (* A coalesce expression as a list of expression: *)
  | Coalesce
  [@@ppp PPP_OCaml]

and stateless2 =
  (* Binary Ops scalars *)
  | Add
  | Sub
  | Mul
  | Div
  | IDiv
  | Mod
  | Pow
  (* truncate a float to a multiple of the given interval: *)
  | Trunc
  (* Compare a and b by computing:
   *   min(abs(a-b), max(a, b)) / max(abs(a-b), max(a, b))
   * Returns 0 when a = b. *)
  | Reldiff
  | And
  | Or
  | Ge
  | Gt
  | Eq
  | Concat
  | StartsWith
  | EndsWith
  | BitAnd
  | BitOr
  | BitXor
  (* Negative does shift right. Will be signed for signed integers: *)
  | BitShift
  | Get
  (* For network address range test membership, or for an efficient constant
   * set membership test, or for a non-efficient sequence of OR kind of
   * membership test if the set is not constant: *)
  | In
  (* Takes format then time: *)
  | Strftime
  (* TODO: several percentiles. Requires multi values returns. *)
  | Percentile
  [@@ppp PPP_OCaml]

and stateful =
  | SF1 of stateful1 * t
  | SF2 of stateful2 * t * t
  | SF3 of stateful3 * t * t * t
  | SF4s of stateful4s * t * t * t * t list
  (* Top-k operation *)
  | Top of { want_rank : bool ; c : t ; max_size : t option ; what : t list ;
             by : t ; time : t ; duration : t }
  (* Last based on time, with integrated sampling: *)
  | Past of { what : t ; time : t ; max_age : t ; sample_size : t option }
  (* Last N e1 [BY e2, e3...] - or by arrival.
   * Note: BY followed by more than one expression will require to parentheses
   * the whole expression to avoid ambiguous parsing. *)
  (* Note: Should be in stateful3s but would be alone and PPP does not allow
   * that (FIXME) *)
  | Last of t * t * t list
  (* Accurate version of the above, remembering all instances of the given
   * tuple and returning a boolean. Only for when number of expected values
   * is small, obviously: *)
  (* Note: Should be in stateful1s but... See above. (FIXME) *)
  | Distinct of t list
  [@@ppp PPP_OCaml]

and stateful1 =
  (* TODO: Add stddev... *)
  | AggrMin
  | AggrMax
  | AggrSum
  | AggrAvg
  | AggrAnd
  | AggrOr
  (* Returns the first/last value in the aggregation: *)
  | AggrFirst
  | AggrLast (* FIXME: Should be stateless *)
  (* FIXME: those float should be expressions so we could use params *)
  | AggrHistogram of float * float * int
  (* Build a list with all values from the group *)
  | Group
  [@@ppp PPP_OCaml]

and stateful2 =
  (* value retarded by k steps. If we have had less than k past values
   * then return NULL. *)
  | Lag
  (* Simple exponential smoothing *)
  | ExpSmooth (* coef between 0 and 1 and expression *)
  (* Sample(n, e) -> Keep max n values of e and return them as a list. *)
  | Sample
  [@@ppp PPP_OCaml]

and stateful3 =
  (* If the current time is t, the seasonal, moving average of period p on k
   * seasons is the average of v(t-p), v(t-2p), ... v(t-kp). Note the absence
   * of v(t).  This is because we want to compare v(t) with this season
   * average.  Notice that lag is a special case of season average with p=k
   * and k=1, but with a universal type for the data (while season-avg works
   * only on numbers).  For instance, a moving average of order 5 would be
   * period=1, count=5.
   * When we have not enough history then the result will be NULL. *)
  | MovingAvg (* period, how many seasons to keep, expression *)
  (* Simple linear regression *)
  | LinReg (* as above: period, how many seasons to keep, expression *)
  (* Hysteresis *)
  | Hysteresis (* measured value, acceptable, maximum *)
  [@@ppp PPP_OCaml]

and stateful4s =
  (* TODO: in (most) functions below it should be doable to replace the
   * variadic lists of expressions by a single expression that's a tuple. *)
  (* Multiple linear regression - and our first variadic function (the
   * last parameter being a list of expressions to use for the predictors) *)
  | MultiLinReg
  (* Rotating bloom filters. First parameter is the false positive rate we
   * aim at, second is an expression providing the "time", third a
   * "duration", and finally expressions whose values to remember. The function
   * will return true if it *thinks* this combination of values has been seen
   * the at a time not older than the given duration. This is based on
   * bloom-filters so there can be false positives but not false negatives.
   * Note: If possible, it might save a lot of space to aim for a high false
   * positive rate and account for it in the surrounding calculations than to
   * aim for a low false positive rate. *)
  | Remember
  [@@ppp PPP_OCaml]

and generator =
  (* First function returning more than once (Generator). Here the typ is
   * type of a single value but the function is a generator and can return
   * from 0 to N such values. *)
  | Split of t * t
  [@@ppp PPP_OCaml]

and selected_field =
  { expr : t ;
    alias : RamenName.field ;
    doc : string ;
    (* FIXME: Have a variant and use it in RamenTimeseries as well. *)
    aggr : string option }
  [@@ppp PPP_OCaml]

and case_alternative =
  { case_cond : t (* Must be bool *) ;
    case_cons : t (* All alternatives must share a type *) }
  [@@ppp PPP_OCaml]

let uniq_num_seq = ref 0

let make ?(structure=T.TAny) ?nullable ?units ?doc text =
  incr uniq_num_seq ;
  { text ; uniq_num = !uniq_num_seq ;
    typ = T.make ?nullable ?units ?doc structure }

(* Constant expressions must be typed independently and therefore have
 * a distinct uniq_num for each occurrence: *)
let null () =
  make (Const T.VNull)

let of_bool b =
  make ~structure:T.TBool ~nullable:false (Const (T.VBool b))

let of_u8 ?units n =
  make ~structure:T.TU8 ~nullable:false ?units
    (Const (T.VU8 (Uint8.of_int n)))

let of_float ?units n =
  make ~structure:T.TFloat ~nullable:false ?units (Const (T.VFloat n))

let of_string s =
  make ~structure:T.TString ~nullable:false (Const (VString s))

let zero () = of_u8 0
let one () = of_u8 1
let one_hour () = of_float ~units:RamenUnits.seconds 3600.

let is_true e =
  match e.text with
  | Const (VBool true) -> true
  | _ -> false

let string_of_const e =
  match e.text with
  | Const (VString s) -> Some s
  | _ -> None

let float_of_const e =
  match e.text with
  | Const v ->
      (* float_of_scalar and int_of_scalar returns an option because they
       * accept nullable numeric values; they fail on non-numerics, while
       * we want to merely return None here: *)
      (try T.float_of_scalar v
      with Invalid_argument _ -> None)
  | _ -> None

let int_of_const e =
  match e.text with
  | Const v ->
      (try T.int_of_scalar v
      with Invalid_argument _ -> None)
  | _ -> None

(* Often time we want to iter through the possible fields of a record: *)
let fields_of_expression e =
  match e.text with
  | Record (_, sfs) -> List.enum sfs
  | _ -> Enum.empty ()

(* Return the set of all unique fields in the record expression, ordered
 * in serialization order: *)
let ser_array_of_record sfs =
  let a =
    List.fold_left (fun s sf ->
      Set.add sf.alias s
    ) Set.empty sfs |>
    Set.to_array in
  Array.fast_sort RamenName.compare a ;
  a

let rec print ?(max_depth=max_int) with_types oc e =
  let st g n =
    (* TODO: do not display default *)
    (match g with LocalState -> " locally" | GlobalState -> " globally") ^
    (if n then " skip nulls" else " keep nulls")
  and print_args =
    List.print ~first:"(" ~last:")" ~sep:", " (print with_types)
  in
  if max_depth <= 0 then
    Printf.fprintf oc "..."
  else (
    let p oc = print ~max_depth:(max_depth-1) with_types oc in
    (match e.text with
    | Const c ->
        T.print oc c
    | Tuple es ->
        List.print ~first:"(" ~last:")" ~sep:"; " p oc es
    | Record (star, sfs) ->
        Char.print oc '(' ;
        List.print ~first:"" ~last:"" ~sep:", "
          (fun oc sf ->
            Printf.fprintf oc "%a AZ %s DOC %S"
              p sf.expr
              (ramen_quote (RamenName.string_of_field sf.alias))
              sf.doc)
          oc sfs ;
        if star then String.print oc ", *" ;
        Char.print oc ')'
    | Vector es ->
        List.print ~first:"[" ~last:"]" ~sep:"; " p oc es ;
    | Variable name ->
        Printf.fprintf oc "%s" (RamenName.string_of_field name) ;
    | Binding s ->
        String.print oc s
    | Case (alts, else_) ->
        let print_alt oc alt =
          Printf.fprintf oc "WHEN %a THEN %a"
            p alt.case_cond
            p alt.case_cons
        in
        Printf.fprintf oc "CASE %a "
         (List.print ~first:"" ~last:"" ~sep:" " print_alt) alts ;
        Option.may (fun else_ ->
          Printf.fprintf oc "ELSE %a "
            p else_) else_ ;
        Printf.fprintf oc "END"
    | Stateless (SL1s (Coalesce, es)) ->
        Printf.fprintf oc "COALESCE %a" print_args es
    | Stateless (SL1 (Age, e)) ->
        Printf.fprintf oc "age (%a)" p e
    | Stateless (SL0 Now) ->
        Printf.fprintf oc "now"
    | Stateless (SL0 Random) ->
        Printf.fprintf oc "random"
    | Stateless (SL0 EventStart) ->
        Printf.fprintf oc "#start"
    | Stateless (SL0 EventStop) ->
        Printf.fprintf oc "#stop"
    | Stateless (SL1 (Cast typ, e)) ->
        Printf.fprintf oc "cast(%a, %a)"
          T.print_typ typ p e
    | Stateless (SL1 (Length, e)) ->
        Printf.fprintf oc "length (%a)" p e
    | Stateless (SL1 (Lower, e)) ->
        Printf.fprintf oc "lower (%a)" p e
    | Stateless (SL1 (Upper, e)) ->
        Printf.fprintf oc "upper (%a)" p e
    | Stateless (SL1 (Not, e)) ->
        Printf.fprintf oc "NOT (%a)" p e
    | Stateless (SL1 (Abs, e)) ->
        Printf.fprintf oc "ABS (%a)" p e
    | Stateless (SL1 (Minus, e)) ->
        Printf.fprintf oc "-(%a)" p e
    | Stateless (SL1 (Defined, e)) ->
        Printf.fprintf oc "(%a) IS NOT NULL" p e
    | Stateless (SL2 (Add, e1, e2)) ->
        Printf.fprintf oc "(%a) + (%a)" p e1 p e2
    | Stateless (SL2 (Sub, e1, e2)) ->
        Printf.fprintf oc "(%a) - (%a)" p e1 p e2
    | Stateless (SL2 (Mul, e1, e2)) ->
        Printf.fprintf oc "(%a) * (%a)" p e1 p e2
    | Stateless (SL2 (Div, e1, e2)) ->
        Printf.fprintf oc "(%a) / (%a)" p e1 p e2
    | Stateless (SL2 (Reldiff, e1, e2)) ->
        Printf.fprintf oc "reldiff((%a), (%a))" p e1 p e2
    | Stateless (SL2 (IDiv, e1, e2)) ->
        Printf.fprintf oc "(%a) // (%a)" p e1 p e2
    | Stateless (SL2 (Mod, e1, e2)) ->
        Printf.fprintf oc "(%a) %% (%a)" p e1 p e2
    | Stateless (SL2 (Pow, e1, e2)) ->
        Printf.fprintf oc "(%a) ^ (%a)" p e1 p e2
    | Stateless (SL1 (Exp, e)) ->
        Printf.fprintf oc "exp (%a)" p e
    | Stateless (SL1 (Log, e)) ->
        Printf.fprintf oc "log (%a)" p e
    | Stateless (SL1 (Log10, e)) ->
        Printf.fprintf oc "log10 (%a)" p e
    | Stateless (SL1 (Sqrt, e)) ->
        Printf.fprintf oc "sqrt (%a)" p e
    | Stateless (SL1 (Ceil, e)) ->
        Printf.fprintf oc "ceil (%a)" p e
    | Stateless (SL1 (Floor, e)) ->
        Printf.fprintf oc "floor (%a)" p e
    | Stateless (SL1 (Round, e)) ->
        Printf.fprintf oc "round (%a)" p e
    | Stateless (SL1 (Hash, e)) ->
        Printf.fprintf oc "hash (%a)" p e
    | Stateless (SL1 (Sparkline, e)) ->
        Printf.fprintf oc "sparkline (%a)" p e
    | Stateless (SL2 (Trunc, e1, e2)) ->
        Printf.fprintf oc "truncate (%a, %a)" p e1 p e2
    | Stateless (SL2 (In, e1, e2)) ->
        Printf.fprintf oc "(%a) IN (%a)" p e1 p e2
    | Stateless (SL1 ((BeginOfRange|EndOfRange as op), e)) ->
        Printf.fprintf oc "%s of (%a)"
          (if op = BeginOfRange then "begin" else "end")
          p e ;
    | Stateless (SL1 (Strptime, e)) ->
        Printf.fprintf oc "parse_time (%a)" p e
    | Stateless (SL1 (Variant, e)) ->
        Printf.fprintf oc "variant (%a)" p e
    | Stateless (SL2 (And, e1, e2)) ->
        Printf.fprintf oc "(%a) AND (%a)" p e1 p e2
    | Stateless (SL2 (Or, e1, e2)) ->
        Printf.fprintf oc "(%a) OR (%a)" p e1 p e2
    | Stateless (SL2 (Ge, e1, e2)) ->
        Printf.fprintf oc "(%a) >= (%a)" p e1 p e2
    | Stateless (SL2 (Gt, e1, e2)) ->
        Printf.fprintf oc "(%a) > (%a)" p e1 p e2
    | Stateless (SL2 (Eq, e1, e2)) ->
        Printf.fprintf oc "(%a) = (%a)" p e1 p e2
    | Stateless (SL2 (Concat, e1, e2)) ->
        Printf.fprintf oc "(%a) || (%a)" p e1 p e2
    | Stateless (SL2 (StartsWith, e1, e2)) ->
        Printf.fprintf oc "(%a) STARTS WITH (%a)" p e1 p e2
    | Stateless (SL2 (EndsWith, e1, e2)) ->
        Printf.fprintf oc "(%a) ENDS WITH (%a)" p e1 p e2
    | Stateless (SL2 (Strftime, e1, e2)) ->
        Printf.fprintf oc "format_time (%a, %a)" p e1 p e2
    | Stateless (SL2 (BitAnd, e1, e2)) ->
        Printf.fprintf oc "(%a) & (%a)" p e1 p e2
    | Stateless (SL2 (BitOr, e1, e2)) ->
        Printf.fprintf oc "(%a) | (%a)" p e1 p e2
    | Stateless (SL2 (BitXor, e1, e2)) ->
        Printf.fprintf oc "(%a) ^ (%a)" p e1 p e2
    | Stateless (SL2 (BitShift, e1, e2)) ->
        Printf.fprintf oc "(%a) << (%a)" p e1 p e2
    | Stateless (SL2 (Get, e1, e2)) ->
        Printf.fprintf oc "get(%a, %a)" p e1 p e2
    | Stateless (SL2 (Percentile, e1, e2)) ->
        Printf.fprintf oc "%ath percentile(%a)" p e1 p e2
    | Stateless (SL1 (Like pat, e)) ->
        Printf.fprintf oc "(%a) LIKE %S" p e pat
    | Stateless (SL1s (Max, es)) ->
        Printf.fprintf oc "GREATEST %a" print_args es
    | Stateless (SL1s (Min, es)) ->
        Printf.fprintf oc "LEAST %a" print_args es
    | Stateless (SL1s (Print, es)) ->
        Printf.fprintf oc "PRINT %a" print_args es
    | Stateful (g, n, SF1 (AggrMin, e)) ->
        Printf.fprintf oc "min%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrMax, e)) ->
        Printf.fprintf oc "max%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrSum, e)) ->
        Printf.fprintf oc "sum%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrAvg, e)) ->
        Printf.fprintf oc "avg%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrAnd, e)) ->
        Printf.fprintf oc "and%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrOr, e)) ->
        Printf.fprintf oc "or%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrFirst, e)) ->
        Printf.fprintf oc "first%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrLast, e)) ->
        Printf.fprintf oc "last%s(%a)" (st g n) p e
    | Stateful (g, n, SF1 (AggrHistogram (min, max, num_buckets), e)) ->
        Printf.fprintf oc "histogram%s(%a, %g, %g, %d)" (st g n)
          p e min max num_buckets
    | Stateful (g, n, SF2 (Lag, e1, e2)) ->
        Printf.fprintf oc "lag%s(%a, %a)" (st g n) p e1 p e2
    | Stateful (g, n, SF3 (MovingAvg, e1, e2, e3)) ->
        Printf.fprintf oc "season_moveavg%s(%a, %a, %a)"
          (st g n) p e1 p e2 p e3
    | Stateful (g, n, SF3 (LinReg, e1, e2, e3)) ->
        Printf.fprintf oc "season_fit%s(%a, %a, %a)"
          (st g n) p e1 p e2 p e3
    | Stateful (g, n, SF4s (MultiLinReg, e1, e2, e3, e4s)) ->
        Printf.fprintf oc "season_fit_multi%s(%a, %a, %a, %a)"
          (st g n) p e1 p e2 p e3 print_args e4s
    | Stateful (g, n, SF4s (Remember, fpr, tim, dur, es)) ->
        Printf.fprintf oc "remember%s(%a, %a, %a, %a)"
          (st g n) p fpr p tim p dur print_args es
    | Stateful (g, n, Distinct es) ->
        Printf.fprintf oc "distinct%s(%a)" (st g n) print_args es
    | Stateful (g, n, SF2 (ExpSmooth, e1, e2)) ->
        Printf.fprintf oc "smooth%s(%a, %a)" (st g n) p e1 p e2
    | Stateful (g, n, SF3 (Hysteresis, meas, accept, max)) ->
        Printf.fprintf oc "hysteresis%s(%a, %a, %a)"
          (st g n) p meas p accept p max
    | Stateful (g, n, Top { want_rank ; c ; max_size ; what ; by ; time ;
                            duration }) ->
        Printf.fprintf oc "%s %a in top %a %a%s by %a in the last %a at time %a"
          (if want_rank then "rank of" else "is")
          (List.print ~first:"" ~last:"" ~sep:", " p) what
          (fun oc -> function
           | None -> Unit.print oc ()
           | Some e -> Printf.fprintf oc " over %a" p e) max_size
          p c (st g n) p by p duration p time
    | Stateful (g, n, Last (c, e, es)) ->
        let print_by oc es =
          if es <> [] then
            Printf.fprintf oc " BY %a"
              (List.print ~first:"" ~last:"" ~sep:", " p) es in
        Printf.fprintf oc "LAST %a%s %a%a"
          p c (st g n) p e print_by es
    | Stateful (g, n, SF2 (Sample, c, e)) ->
      Printf.fprintf oc "SAMPLE%s(%a, %a)" (st g n) p c p e
    | Stateful (g, n, Past { what ; time ; max_age ; sample_size }) ->
        (match sample_size with
        | None -> ()
        | Some sz ->
            Printf.fprintf oc "SAMPLE OF SIZE %a OF THE " p sz) ;
        Printf.fprintf oc "LAST %a%s OF %a AT TIME %a"
          p max_age (st g n) p what p time
    | Stateful (g, n, SF1 (Group, e)) ->
      Printf.fprintf oc "GROUP%s %a" (st g n) p e

    | Generator (Split (e1, e2)) ->
      Printf.fprintf oc "split(%a, %a)" p e1 p e2
    ) ;
    if with_types then Printf.fprintf oc " [%a]" T.print_typ e.typ
  )

let is_nullable e = e.typ.T.nullable

let is_const e =
  match e.text with
  | Const _ -> true | _ -> false

let is_a_string e =
  e.typ.T.structure = TString

(* Tells if [e] (that must be typed) is a list or a vector, ie anything
 * which is represented with an OCaml array. *)
let is_a_list e =
  match e.typ.T.structure with
  | TList _ | TVec _ -> true
  | _ -> false

(* TODO: Should not be used but to populate the environments before folding
 * over an operation: *)
type tuple_prefix =
  | TupleIn
  | TupleGroup
  | TupleOutPrevious
  | TupleOut
  (* Tuple usable in sort expressions *)
  (* FIXME: unused, sadly *)
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
  (* For when a field is from an opened record being build.
   * The type of a variable bound to this record is the type of the record. *)
  | TupleRecord of t
  (* TODO: TupleOthers? *)
  [@@ppp PPP_OCaml]

let string_of_prefix = function
  | TupleIn -> "in"
  | TupleGroup -> "group"
  | TupleOutPrevious -> "out.previous"
  | TupleOut -> "out"
  | TupleSortFirst -> "sort.first"
  | TupleSortSmallest -> "sort.smallest"
  | TupleSortGreatest -> "sort.greatest"
  | TupleMergeGreatest -> "merge.greatest"
  | TupleParam -> "param"
  | TupleEnv -> "env"
  | TupleRecord _ -> "record"

let tuple_prefix_print oc p =
  Printf.fprintf oc "%s" (string_of_prefix p)

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

let tuple_need_state = function
  | TupleGroup -> true
  | _ -> false

let rec map f what env e =
  (* Shorthands : *)
  let m = map f what env
  and h = f what env in
  let mm = List.map m
  and om = Option.map m in
  match e.text with
  | Const _ | Variable _ | Binding _ | Stateless (SL0 _) -> h e

  | Case (alts, else_) ->
      h { e with text = Case (
        List.map (fun a ->
          { case_cond = m a.case_cond ; case_cons = m a.case_cons }
        ) alts, om else_) }

  | Tuple es -> h { e with text = Tuple (mm es) }

  | Record (star, sfs) ->
      let sfs' =
        (* We have to enrich the env as usual: *)
        List.fold_left (fun (sfs, env) sf ->
          { sf with expr = map f what env sf.expr } :: sfs,
          (* Notice we point to the record expression before the map, but
           * that's ok because we are interested in the types mostly *)
          (sf.alias, TupleRecord e) :: env
        ) ([], env) sfs |> fst |> List.rev in
      h { e with text = Record (star, sfs') }

  | Vector es -> h { e with text = Vector (mm es) }

  | Stateless (SL1 (o, e1)) ->
      h { e with text = Stateless (SL1 (o, m e1)) }
  | Stateless (SL1s (o, es)) ->
      h { e with text = Stateless (SL1s (o, mm es)) }
  | Stateless (SL2 (o, e1, e2)) ->
      h { e with text = Stateless (SL2 (o, m e1, m e2)) }

  | Stateful (g, n, SF1 (o, e1)) ->
      h { e with text = Stateful (g, n, SF1 (o, m e1)) }
  | Stateful (g, n, SF2 (o, e1, e2)) ->
      h { e with text = Stateful (g, n, SF2 (o, m e1, m e2)) }
  | Stateful (g, n, SF3 (o, e1, e2, e3)) ->
      h { e with text = Stateful (g, n, SF3 (o, m e1, m e2, m e3)) }
  | Stateful (g, n, SF4s (o, e1, e2, e3, e4s)) ->
      h { e with text = Stateful (g, n, SF4s (o, m e1, m e2, m e3, mm e4s)) }
  | Stateful (g, n, Top ({ c ; by ; time ; duration ; what ; max_size } as a)) ->
      h { e with text = Stateful (g, n, Top { a with
        c = m c ; by = m by ; time = m time ; duration = m duration ;
        what = mm what ; max_size = om max_size }) }
  | Stateful (g, n, Past { what ; time ; max_age ; sample_size }) ->
      h { e with text = Stateful (g, n, Past {
        what = m what ; time = m time ; max_age = m max_age ;
        sample_size = om sample_size }) }
  | Stateful (g, n, Last (c, e, es)) ->
      h { e with text = Stateful (g, n, Last (m c, m e, mm es)) }
  | Stateful (g, n, Distinct es) ->
      h { e with text = Stateful (g, n, Distinct (mm es)) }

  | Generator (Split (e1, e2)) ->
      h { e with text = Generator (Split (m e1, m e2)) }

(* Propagate values up the tree only, depth first. *)
let fold_subexpressions f i env e =
  let g i = f i env in
  let fl = List.fold_left g in
  let om = Option.map_default (g i)
  in
  match e.text with
  | Const _ | Variable _ | Binding _ | Stateless (SL0 _) -> i

  | Case (alts, else_) ->
      let i =
        List.fold_left (fun i a ->
          g (g i a.case_cond) a.case_cons
        ) i alts in
      om i else_

  | Tuple es | Vector es -> fl i es

  | Record (_, sfs) ->
      (* Environment is augmented with the new fields, one by one: *)
      List.fold_left (fun (i, env) sf ->
        f i env sf.expr,
        (sf.alias, TupleRecord e) :: env
      ) (i, env) sfs |> fst

  | Stateless (SL1 (_, e1)) | Stateful (_, _, SF1 (_, e1)) -> g i e1

  | Stateless (SL1s (_, e1s)) -> fl i e1s

  | Stateless (SL2 (_, e1, e2))
  | Stateful (_, _, SF2 (_, e1, e2)) -> g (g i e1) e2

  | Stateful (_, _, SF3 (_, e1, e2, e3)) -> g (g (g i e1) e2) e3
  | Stateful (_, _, SF4s (_, e1, e2, e3, e4s)) ->
      fl (g (g (g i e1) e2) e3) e4s

  | Stateful (_, _, Top { c ; by ; time ; duration ; what ; max_size }) ->
      om (fl i (c :: by :: time :: duration :: what)) max_size

  | Stateful (_, _, Past { what ; time ; max_age ; sample_size }) ->
      om (g (g (g i what) time) max_age) sample_size
  | Stateful (_, _, Last (e1, e2, e3s)) -> fl (g (g i e1) e2) e3s
  | Stateful (_, _, Distinct es) -> fl i es

  | Generator (Split (e1, e2)) -> g (g i e1) e2

(* Fold depth first, calling [f] bottom up: *)
let rec fold_up f i e =
  let i = fold_subexpressions (fun i _env e -> fold_up f i e) i [] e in
  f i e

let iter f =
  fold_up (fun () e -> f e) ()

let unpure_iter f e =
  fold_up (fun () e -> match e.text with
    | Stateful _ -> f e
    | _ -> ()
  ) () e |> ignore

let unpure_fold u f e =
  fold_up (fun u e -> match e.text with
    | Stateful _ -> f u e
    | _ -> u
  ) u e

(* Any expression that uses a generator is a generator: *)
let is_generator e =
  try
    iter (fun e ->
      match e.text with
      | Generator _ -> raise Exit
      | _ -> ()) e ;
    false
  with Exit -> true

let rec map_type f e =
  map (fun _what _env e ->
    { e with typ = f e.typ }
  ) "map_type" [] e

(* We can share default values: *)
let default_start = make (Stateless (SL0 EventStart))
let default_zero = zero ()
let default_one = one ()
let default_1hour = one_hour ()

module Parser =
struct
  type expr = t
  let const_of_string = of_string
  (*$< Parser *)
  open RamenParsing

  (* Single things *)
  let const m =
    let m = "constant" :: m in
    (
      (
        T.Parser.scalar ~min_int_width:32 >>:
        fun c ->
          (* We'd like to consider all constants as dimensionless, but that'd
             be a pain (for instance, COALESCE(x, 0) would be invalid if x had
             a unit, while by leaving the const unit unspecified it has the
             unit of x.
          let units =
            if T.(is_a_num (structure_of c)) then
              Some RamenUnits.dimensionless
            else None in*)
          make (Const c)
      ) ||| (
        duration >>: fun x ->
          make ~units:RamenUnits.seconds (Const (VFloat x))
      )
    ) m

  (*$= const & ~printer:(test_printer (print false))
    (Ok (Const (typ, VBool true), (4, [])))\
      (test_p const "true" |> replace_typ_in_expr)

    (Ok (Const (typ, VI8 (Stdint.Int8.of_int 15)), (4, []))) \
      (test_p const "15i8" |> replace_typ_in_expr)
  *)

  let null m =
    (
      T.Parser.null >>:
      fun v ->
        make (Const v) (* Type of "NULL" is yet unknown *)
    ) m

  let variable m =
    let m = "variable" :: m in
    (
      non_keyword >>:
      fun (n) ->
        make (Variable (RamenName.field_of_string n))
    ) m

  (*$= variable & ~printer:(test_printer (print false))
    (Ok (\
      Variable (typ, RamenName.field_of_string "bytes"),\
      (5, [])))\
      (test_p variable "bytes" |> replace_typ_in_expr)

    (Ok (\
      Variable (typ, RamenName.field_of_string "bytes"),\
      (8, [])))\
      (test_p variable "in.bytes" |> replace_typ_in_expr)

    (Ok (\
      Variable (typ, RamenName.field_of_string "bytes"),\
      (9, [])))\
      (test_p variable "out.bytes" |> replace_typ_in_expr)

    (Bad (\
      NoSolution (\
        Some { where = ParsersMisc.Item ((1,8), '.');\
               what=["eof"]})))\
      (test_p variable "pasglop.bytes" |> replace_typ_in_expr)
  *)

  let rec default_alias e =
    let force_public field =
      if String.length field = 0 || field.[0] <> '_' then field
      else String.lchop field in
    match e.text with
    | Variable name
        when not (RamenName.is_virtual name) ->
        force_public (RamenName.string_of_field name)
    (* Provide some default name for common aggregate functions: *)
    | Stateful (_, _, SF1 (AggrMin, e)) -> "min_"^ default_alias e
    | Stateful (_, _, SF1 (AggrMax, e)) -> "max_"^ default_alias e
    | Stateful (_, _, SF1 (AggrSum, e)) -> "sum_"^ default_alias e
    | Stateful (_, _, SF1 (AggrAvg, e)) -> "avg_"^ default_alias e
    | Stateful (_, _, SF1 (AggrAnd, e)) -> "and_"^ default_alias e
    | Stateful (_, _, SF1 (AggrOr, e)) -> "or_"^ default_alias e
    | Stateful (_, _, SF1 (AggrFirst, e)) -> "first_"^ default_alias e
    | Stateful (_, _, SF1 (AggrLast, e)) -> "last_"^ default_alias e
    | Stateful (_, _, SF1 (AggrHistogram _, e)) ->
        default_alias e ^"_histogram"
    | Stateless (SL2 (Percentile, { text = Const p ; _ }, e))
      when T.is_round_integer p ->
        Printf.sprintf2 "%s_%ath" (default_alias e) T.print p
    (* Some functions better leave no traces: *)
    | Stateless (SL1s (Print, e::_)) -> default_alias e
    | Stateless (SL1 (Cast _, e)) -> default_alias e
    | Stateful (_, _, SF1 (Group, e)) -> default_alias e
    | _ -> raise (Reject "must set alias")

  let state_lifespan m =
    let m = "state lifespan" :: m in
    (
      (strinG "globally" >>: fun () -> GlobalState) |||
      (strinG "locally" >>: fun () -> LocalState)
    ) m

  let skip_nulls m =
    let m = "skip nulls" :: m in
    (
      ((strinG "skip" >>: fun () -> true) |||
       (strinG "keep" >>: fun () -> false)) +-
      blanks +- strinGs "null"
    ) m

  let state_and_nulls ?(def_state=GlobalState)
                      ?(def_skipnulls=true) m =
    (
      optional ~def:def_state (blanks -+ state_lifespan) ++
      optional ~def:def_skipnulls (blanks -+ skip_nulls)
    ) m

  (* operators with lowest precedence *)
  let rec lowestest_prec_left_assoc m =
    let m = "logical OR operator" :: m in
    let op = strinG "or"
    and reduce e1 _op e2 = make (Stateless (SL2 (Or, e1, e2))) in
    (* FIXME: we do not need a blanks if we had parentheses ("(x)OR(y)" is OK) *)
    binary_ops_reducer ~op ~term:lowest_prec_left_assoc ~sep:blanks ~reduce m

  and lowest_prec_left_assoc m =
    let m = "logical AND operator" :: m in
    let op = strinG "and"
    and reduce e1 _op e2 = make (Stateless (SL2 (And, e1, e2))) in
    binary_ops_reducer ~op ~term:conditional ~sep:blanks ~reduce m

  and conditional m =
    let m = "conditional expression" :: m in
    (
      case ||| if_ ||| low_prec_left_assoc
    ) m

  and low_prec_left_assoc m =
    let m = "comparison operator" :: m in
    let op =
      that_string ">" ||| that_string ">=" ||| that_string "<" ||| that_string "<=" |||
      that_string "=" ||| that_string "<>" ||| that_string "!=" |||
      that_string "in" ||| that_string "like" |||
      ((that_string "starts" ||| that_string "ends") +- blanks +- strinG "with")
    and reduce e1 op e2 = match op with
      | ">" -> make (Stateless (SL2 (Gt, e1, e2)))
      | "<" -> make (Stateless (SL2 (Gt, e2, e1)))
      | ">=" -> make (Stateless (SL2 (Ge, e1, e2)))
      | "<=" -> make (Stateless (SL2 (Ge, e2, e1)))
      | "=" -> make (Stateless (SL2 (Eq, e1, e2)))
      | "!=" | "<>" ->
          make (Stateless (SL1 (Not, make (Stateless (SL2 (Eq, e1, e2))))))
      | "in" -> make (Stateless (SL2 (In, e1, e2)))
      | "like" ->
          (match string_of_const e2 with
          | None -> raise (Reject "LIKE pattern must be a string constant")
          | Some p -> make (Stateless (SL1 (Like p, e1))))
      | "starts" -> make (Stateless (SL2 (StartsWith, e1, e2)))
      | "ends" -> make (Stateless (SL2 (EndsWith, e1, e2)))
      | _ -> assert false in
    binary_ops_reducer ~op ~term:mid_prec_left_assoc ~sep:opt_blanks ~reduce m

  and mid_prec_left_assoc m =
    let m = "arithmetic operator" :: m in
    let op = that_string "+" ||| that_string "-" ||| that_string "||" |||
             that_string "|?"
    and reduce e1 op e2 = match op with
      | "+" -> make (Stateless (SL2 (Add, e1, e2)))
      | "-" -> make (Stateless (SL2 (Sub, e1, e2)))
      | "||" -> make (Stateless (SL2 (Concat, e1, e2)))
      | "|?" -> make (Stateless (SL1s (Coalesce, [ e1 ; e2 ])))
      | _ -> assert false in
    binary_ops_reducer ~op ~term:high_prec_left_assoc ~sep:opt_blanks ~reduce m

  and high_prec_left_assoc m =
    let m = "arithmetic operator" :: m in
    let op = that_string "*" ||| that_string "//" ||| that_string "/" |||
             that_string "%"
    and reduce e1 op e2 = match op with
      | "*" -> make (Stateless (SL2 (Mul, e1, e2)))
      (* Note: We want the default division to output floats by default *)
      (* Note: We reject IP/INT because that's a CIDR *)
      | "//" -> make (Stateless (SL2 (IDiv, e1, e2)))
      | "%" -> make (Stateless (SL2 (Mod, e1, e2)))
      | "/" ->
          (* "1.2.3.4/1" can be parsed both as a CIDR or a dubious division of
           * an IP by a number. Reject that one: *)
          (match e1.text, e2.text with
          | Const c1, Const c2 when
              T.(structure_of c1 |> is_an_ip) &&
              T.(structure_of c2 |> is_an_int) ->
              raise (Reject "That's a CIDR")
          | _ ->
              make (Stateless (SL2 (Div, e1, e2))))
      | _ -> assert false
    in
    binary_ops_reducer ~op ~term:higher_prec_left_assoc ~sep:opt_blanks ~reduce m

  and higher_prec_left_assoc m =
    let m = "bitwise logical operator" :: m in
    let op = that_string "&" ||| that_string "|" ||| that_string "#" |||
             that_string "<<" ||| that_string ">>"
    and reduce e1 op e2 = match op with
      | "&" -> make (Stateless (SL2 (BitAnd, e1, e2)))
      | "|" -> make (Stateless (SL2 (BitOr, e1, e2)))
      | "#" -> make (Stateless (SL2 (BitXor, e1, e2)))
      | "<<" -> make (Stateless (SL2 (BitShift, e1, e2)))
      | ">>" ->
          let e2 = make (Stateless (SL1 (Minus, e2))) in
          make (Stateless (SL2 (BitShift, e1, e2)))
      | _ -> assert false in
    binary_ops_reducer ~op ~term:higher_prec_right_assoc ~sep:opt_blanks ~reduce m

  and higher_prec_right_assoc m =
    let m = "arithmetic operator" :: m in
    let op = char '^'
    and reduce e1 _ e2 = make (Stateless (SL2 (Pow, e1, e2))) in
    binary_ops_reducer ~op ~right_associative:true
                       ~term:highest_prec_left_assoc ~sep:opt_blanks ~reduce m

  and highest_prec_left_assoc m =
    (
      (afun1 "not" >>: fun e ->
        make (Stateless (SL1 (Not, e)))) |||
      (strinG "-" -- opt_blanks --
        check (nay decimal_digit) -+ highestest_prec >>: fun e ->
          make (Stateless (SL1 (Minus, e)))) |||
      (highestest_prec ++
        optional ~def:None (
          blanks -- strinG "is" -- blanks -+
          optional ~def:(Some false)
                   (strinG "not" -- blanks >>: fun () -> Some true) +-
          strinG "null") >>: function
            | e, None -> e
            | e, Some false ->
                make (Stateless (SL1 (Not,
                  make (Stateless (SL1 (Defined, e))))))
            | e, Some true ->
                make (Stateless (SL1 (Defined, e)))) |||
      (strinG "begin" -- blanks -- strinG "of" -- blanks -+ highestest_prec >>:
        fun e -> make (Stateless (SL1 (BeginOfRange, e)))) |||
      (strinG "end" -- blanks -- strinG "of" -- blanks -+ highestest_prec >>:
        fun e -> make (Stateless (SL1 (EndOfRange, e)))) |||
      (highestest_prec +- char '.' ++ non_keyword >>:
        fun (e, s) ->
          let s = make (Const (VString s)) in
          make (Stateless (SL2 (Get, s, e))))
    ) m

  (* "sf" stands for "stateful" *)
  and afunv_sf ?def_state a n m =
    let sep = list_sep in
    let m = n :: m in
    (strinG n -+
     state_and_nulls ?def_state +-
     opt_blanks +- char '(' +- opt_blanks ++
     (if a > 0 then
       repeat ~what:"mandatory arguments" ~min:a ~max:a ~sep p ++
       optional ~def:[] (sep -+ repeat ~what:"variadic arguments" ~sep p)
      else
       return [] ++
       repeat ~what:"variadic arguments" ~sep p) +-
     opt_blanks +- char ')') m

  and afun_sf ?def_state a n =
    afunv_sf ?def_state a n >>: fun (g, (a, r)) ->
      if r = [] then g, a else
      raise (Reject "too many arguments")

  and afun1_sf ?def_state n =
    let sep = check (char '(') ||| blanks in
    (strinG n -+ state_and_nulls ?def_state +-
     sep ++ highestest_prec)

  and afun2_sf ?def_state n =
    afun_sf ?def_state 2 n >>: function (g, [a;b]) -> g, a, b | _ -> assert false

  and afun0v_sf ?def_state n =
    (* afunv_sf takes parentheses but it's nicer to also accept non
     * parenthesized highestest_prec, but then there would be 2 ways to
     * parse "distinct (x)" as highestest_prec also accept parenthesized
     * lower precedence expressions. Thus the "highestest_prec_no_parenthesis": *)
    (strinG n -+ state_and_nulls ?def_state +-
     blanks ++ highestest_prec_no_parenthesis >>: fun (f, e) -> f, [e]) |||
    (afunv_sf ?def_state 0 n >>:
     function (g, ([], r)) -> g, r | _ -> assert false)

  and afun2v_sf ?def_state n =
    afunv_sf ?def_state 2 n >>: function (g, ([a;b], r)) -> g, a, b, r | _ -> assert false

  and afun3_sf ?def_state n =
    afun_sf ?def_state 3 n >>: function (g, [a;b;c]) -> g, a, b, c | _ -> assert false

  and afun3v_sf ?def_state n =
    afunv_sf ?def_state 3 n >>: function (g, ([a;b;c], r)) -> g, a, b, c, r | _ -> assert false

  and afun4_sf ?def_state n =
    afun_sf ?def_state 4 n >>: function (g, [a;b;c;d]) -> g, a, b, c, d | _ -> assert false

  and afunv a n m =
    let m = n :: m in
    let sep = list_sep in
    (strinG n -- opt_blanks -- char '(' -- opt_blanks -+
     (if a > 0 then
       repeat ~what:"mandatory arguments" ~min:a ~max:a ~sep p ++
       optional ~def:[] (sep -+ repeat ~what:"variadic arguments" ~sep p)
      else
       return [] ++
       repeat ~what:"variadic arguments" ~sep p) +-
     opt_blanks +- char ')') m

  and afun a n =
    afunv a n >>: fun (a, r) ->
      if r = [] then a else
      raise (Reject "too many arguments")

  and afun1 n =
    let sep = check (char '(') ||| blanks in
    strinG n -- sep -+ highestest_prec

  and afun2 n =
    afun 2 n >>: function [a;b] -> a, b | _ -> assert false

  and afun3 n =
    afun 3 n >>: function [a;b;c] -> a, b, c | _ -> assert false

  and afun4 n =
    afun 4 n >>: function [a;b;c;d] -> a, b, c, d | _ -> assert false

  and afun5 n =
    afun 5 n >>: function [a;b;c;d;e] -> a, b, c, d, e | _ -> assert false

  and afun0v n =
    afunv 0 n >>: function ([], r) -> r | _ -> assert false

  and afun1v n =
    afunv 1 n >>: function ([a], r) -> a, r | _ -> assert false

  and afun2v n =
    afunv 2 n >>: function ([a;b], r) -> a, b, r | _ -> assert false

  and afun3v n =
    afunv 3 n >>: function ([a;b;c], r) -> a, b, c, r | _ -> assert false

  and func m =
    let m = "function" :: m in
    (* Note: min and max of nothing are NULL but sum of nothing is 0, etc *)
    (
      (afun1 "age" >>: fun e -> make (Stateless (SL1 (Age, e)))) |||
      (afun1 "abs" >>: fun e -> make (Stateless (SL1 (Abs, e)))) |||
      (afun1 "length" >>: fun e -> make (Stateless (SL1 (Length, e)))) |||
      (afun1 "lower" >>: fun e -> make (Stateless (SL1 (Lower, e)))) |||
      (afun1 "upper" >>: fun e -> make (Stateless (SL1 (Upper, e)))) |||
      (strinG "now" >>: fun () -> make (Stateless (SL0 Now))) |||
      (strinG "random" >>: fun () -> make (Stateless (SL0 Random))) |||
      (strinG "#start" >>: fun () -> make (Stateless (SL0 EventStart))) |||
      (strinG "#stop" >>: fun () -> make (Stateless (SL0 EventStop))) |||
      (afun1 "exp" >>: fun e -> make (Stateless (SL1 (Exp, e)))) |||
      (afun1 "log" >>: fun e -> make (Stateless (SL1 (Log, e)))) |||
      (afun1 "log10" >>: fun e -> make (Stateless (SL1 (Log10, e)))) |||
      (afun1 "sqrt" >>: fun e -> make (Stateless (SL1 (Sqrt, e)))) |||
      (afun1 "ceil" >>: fun e -> make (Stateless (SL1 (Ceil, e)))) |||
      (afun1 "floor" >>: fun e -> make (Stateless (SL1 (Floor, e)))) |||
      (afun1 "round" >>: fun e -> make (Stateless (SL1 (Round, e)))) |||
      (afun1 "truncate" >>: fun e ->
         make (Stateless (SL2 (Trunc, e, of_float 1.)))) |||
      (afun2 "truncate" >>: fun (e1, e2) ->
         make (Stateless (SL2 (Trunc, e1, e2)))) |||
      (afun1 "hash" >>: fun e -> make (Stateless (SL1 (Hash, e)))) |||
      (afun1 "sparkline" >>: fun e -> make (Stateless (SL1 (Sparkline, e)))) |||
      (afun1_sf ~def_state:LocalState "min" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrMin, e)))) |||
      (afun1_sf ~def_state:LocalState "max" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrMax, e)))) |||
      (afun1_sf ~def_state:LocalState "sum" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrSum, e)))) |||
      (afun1_sf ~def_state:LocalState "avg" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrAvg, e)))) |||
      (afun1_sf ~def_state:LocalState "and" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrAnd, e)))) |||
      (afun1_sf ~def_state:LocalState "or" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrOr, e)))) |||
      (afun1_sf ~def_state:LocalState "first" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrFirst, e)))) |||
      (afun1_sf ~def_state:LocalState "last" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (AggrLast, e)))) |||
      (afun1_sf ~def_state:LocalState "group" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (Group, e)))) |||
      (afun1_sf ~def_state:GlobalState "all" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF1 (Group, e)))) |||
      (
        (const ||| variable) +-
        (optional ~def:() (strinG "th")) +- blanks ++
        afun1 "percentile" >>:
        fun (p, e) ->
          make (Stateless (SL2 (Percentile, p, e)))
      ) |||
      (afun2_sf "lag" >>: fun ((g, n), e1, e2) ->
         make (Stateful (g, n, SF2 (Lag, e1, e2)))) |||
      (afun1_sf "lag" >>: fun ((g, n), e) ->
         make (Stateful (g, n, SF2 (Lag, one (), e)))) |||

      (* avg perform a division thus the float type *)
      (afun3_sf "season_moveavg" >>: fun ((g, n), e1, e2, e3) ->
         make (Stateful (g, n, SF3 (MovingAvg, e1, e2, e3)))) |||
      (afun2_sf "moveavg" >>: fun ((g, n), e1, e2) ->
         make (Stateful (g, n, SF3 (MovingAvg, one (), e1, e2)))) |||
      (afun3_sf "season_fit" >>: fun ((g, n), e1, e2, e3) ->
         make (Stateful (g, n, SF3 (LinReg, e1, e2, e3)))) |||
      (afun2_sf "fit" >>: fun ((g, n), e1, e2) ->
         make (Stateful (g, n, SF3 (LinReg, one (), e1, e2)))) |||
      (afun3v_sf "season_fit_multi" >>: fun ((g, n), e1, e2, e3, e4s) ->
         make (Stateful (g, n, SF4s (MultiLinReg, e1, e2, e3, e4s)))) |||
      (afun2v_sf "fit_multi" >>: fun ((g, n), e1, e2, e3s) ->
         make (Stateful (g, n, SF4s (MultiLinReg, one (), e1, e2, e3s)))) |||
      (afun2_sf "smooth" >>: fun ((g, n), e1, e2) ->
         make (Stateful (g, n, SF2 (ExpSmooth, e1, e2)))) |||
      (afun1_sf "smooth" >>: fun ((g, n), e) ->
         let alpha = of_float 0.5 in
         make (Stateful (g, n, SF2 (ExpSmooth, alpha, e)))) |||
      (afun3_sf "remember" >>: fun ((g, n), tim, dur, e) ->
         (* If we allowed a list of expressions here then it would be ambiguous
          * with the following "3+v" signature: *)
         let fpr = of_float 0.015 in
         make (Stateful (g, n, SF4s (Remember, fpr, tim, dur, [e])))) |||
      (afun3v_sf "remember" >>: fun ((g, n), fpr, tim, dur, es) ->
         make (Stateful (g, n, SF4s (Remember, fpr, tim, dur, es)))) |||
      (afun0v_sf ~def_state:LocalState "distinct" >>: fun ((g, n), es) ->
         make (Stateful (g, n, Distinct es))) |||
      (afun3_sf "hysteresis" >>: fun ((g, n), value, accept, max) ->
         make (Stateful (g, n, SF3 (Hysteresis, value, accept, max)))) |||
      (afun4_sf ~def_state:LocalState "histogram" >>:
       fun ((g, n), what, min, max, num_buckets) ->
         match float_of_const min,
               float_of_const max,
               int_of_const num_buckets with
         | Some min, Some max, Some num_buckets ->
             if num_buckets <= 0 then
               raise (Reject "Histogram size must be positive") ;
             make (Stateful (g, n, SF1 (
              AggrHistogram (min, max, num_buckets), what)))
         | _ -> raise (Reject "histogram dimensions must be constants")) |||
      (afun2 "split" >>: fun (e1, e2) ->
         make (Generator (Split (e1, e2)))) |||
      (afun2 "format_time" >>: fun (e1, e2) ->
         make (Stateless (SL2 (Strftime, e1, e2)))) |||
      (afun1 "parse_time" >>: fun e ->
         make (Stateless (SL1 (Strptime, e)))) |||
      (afun1 "variant" >>: fun e ->
         make (Stateless (SL1 (Variant, e)))) |||
      (* At least 2 args to distinguish from the aggregate functions: *)
      (afun2v "max" >>: fun (e1, e2, e3s) ->
         make (Stateless (SL1s (Max, e1 :: e2 :: e3s)))) |||
      (afun1v "greatest" >>: fun (e, es) ->
         make (Stateless (SL1s (Max, e :: es)))) |||
      (afun2v "min" >>: fun (e1, e2, e3s) ->
         make (Stateless (SL1s (Min, e1 :: e2 :: e3s)))) |||
      (afun1v "least" >>: fun (e, es) ->
         make (Stateless (SL1s (Min, e :: es)))) |||
      (afun1v "print" >>: fun (e, es) ->
         make (Stateless (SL1s (Print, e :: es)))) |||
      (afun2 "reldiff" >>: fun (e1, e2) ->
        make (Stateless (SL2 (Reldiff, e1, e2)))) |||
      (afun2_sf "sample" >>: fun ((g, n), c, e) ->
         make (Stateful (g, n, SF2 (Sample, c, e)))) |||
      k_moveavg ||| cast ||| top_expr ||| nth ||| last ||| past ||| get |||
      changed_field
    ) m

  and get m =
    let m = "get" :: m in
    (
      afun2 "get" >>: fun (n, v) ->
        (match n.text with
        | Const _ ->
            (match int_of_const n with
            | Some n ->
                if n < 0 then
                  raise (Reject "GET index must be positive")
            | None ->
                if string_of_const n = None then
                  raise (Reject "GET requires a numeric or string index"))
        | _ -> ()) ;
        make (Stateless (SL2 (Get, n, v)))
    ) m

  (* Syntactic sugar for `x <> previous.x` *)
  and changed_field m =
    let m = "changed" :: m in
    (
      afun1 "changed" >>:
      fun f ->
        match f.text with
        | Variable name ->
            (* If we figure out later that this variable is not an output
             * field then the error message will be about that field
             * not present in the output tuple. Not too bad. *)
            let prev_f =
              make (Stateless (SL2 (Get,
                const_of_string (RamenName.string_of_field name),
                make (Variable (RamenName.field_of_string "previous"))))) in
            make (Stateless (SL1 (Not,
              make (Stateless (SL2 (Eq, f, prev_f))))))
        | _ ->
            raise (Reject "Changed operator is only valid for fields")
    ) m

  and cast m =
    let m = "cast" :: m in
    let sep = check (char '(') ||| blanks in
    (
      T.Parser.scalar_typ +- sep ++
      highestest_prec >>:
      fun (t, e) ->
        (* The nullability of [value] should propagate to [type(value)],
         * while [type?(value)] should be nullable no matter what. *)
        make (Stateless (SL1 (Cast t, e)))
    ) m

  and k_moveavg m =
    let m = "k-moving average" :: m in
    let sep = check (char '(') ||| blanks in
    (
      (unsigned_decimal_number >>: T.Parser.narrowest_int_scalar) +-
      (strinG "-moveavg" ||| strinG "-ma") ++
      state_and_nulls +-
      sep ++ highestest_prec >>:
      fun ((k, (g, n)), e) ->
        if k = VNull then raise (Reject "Cannot use NULL here") ;
        let k = make (Const k) in
        make (Stateful (g, n, SF3 (MovingAvg, one (), k, e)))
    ) m

  and top_expr m =
    let m = "top expression" :: m in
    (
      (
        (strinG "rank" -- blanks -- strinG "of" >>: fun () -> true) |||
        (strinG "is" >>: fun () -> false)
      ) +- blanks ++
      (* We can allow lowest precedence expressions here because of the
       * keywords that follow: *)
      several ~sep:list_sep p +- blanks +-
      strinG "in" +- blanks +- strinG "top" +- blanks ++ (const ||| variable) ++
      optional ~def:None (
        some (blanks -- strinG "over" -- blanks -+ p)) ++
      state_and_nulls ++
      optional ~def:default_one (
        blanks -- strinG "by" -- blanks -+ highestest_prec) ++
      optional ~def:None (
        blanks -- strinG "at" -- blanks -- strinG "time" -- blanks -+ some p) ++
      optional ~def:None (
        blanks -- strinG "for" --
        optional ~def:() (blanks -- strinG "the" -- blanks -- strinG "last") --
        blanks -+ some (const ||| variable)) >>:
      fun (((((((want_rank, what), c), max_size),
              (g, n)), by), time), duration) ->
        let time, duration =
          match time, duration with
          (* If we asked for no time decay, use neutral values: *)
          | None, None -> default_zero, default_1hour
          | Some t, None -> t, default_1hour
          | None, Some d -> default_start, d
          | Some t, Some d -> t, d
        in
        make (Stateful (g, n, Top {
          want_rank ; c ; max_size ; what ; by ; duration ; time }))
    ) m

  and last m =
    let m = "last expression" :: m in
    (
      (* The quantity N disambiguates from the "last" aggregate. *)
      strinG "last" -- blanks -+ p ++
      state_and_nulls +- opt_blanks ++ p ++
      optional ~def:[] (
        blanks -- strinG "by" -- blanks -+
        several ~sep:list_sep p) >>:
      fun (((c, (g, n)), e), es) ->
        (* The result is null when the number of input is less than c: *)
        make (Stateful (g, n, Last (c, e, es)))
    ) m

  and sample m =
    let m = "sample expression" :: m in
    (
      strinG "sample" -- blanks --
      optional ~def:() (strinG "of" -- blanks -- strinG "size" -- blanks) -+
      p +- optional ~def:() (blanks -- strinG "of" -- blanks -- strinG "the")
    ) m

  and past m =
    let m = "recent expression" :: m in
    (
      optional ~def:None (some sample +- blanks) +-
      strinG "past" +- blanks ++ p ++
      state_and_nulls +- opt_blanks +-
      strinG "of" +- blanks ++ p ++
      optional ~def:default_start
        (blanks -- strinG "at" -- blanks -- strinG "time" -- blanks -+ p) >>:
      fun ((((sample_size, max_age), (g, n)), what), time) ->
        make (Stateful (g, n, Past { what ; time ; max_age ; sample_size }))
    ) m

  and nth m =
    let m = "n-th" :: m in
    let q =
      pos_decimal_integer "nth" ++
      (that_string "th" ||| that_string "st" ||| that_string "nd") >>:
      fun (n, th) ->
        if n = 0 then raise (Reject "tuple indices start at 1") ;
        if ordinal_suffix n = th then n
        (* Pedantic but also helps disambiguating the syntax: *)
        else raise (Reject ("bad suffix "^ th ^" for "^ string_of_int n))
    and sep = check (char '(') ||| blanks in
    (
      q +- sep ++ highestest_prec >>:
      fun (n, es) ->
        let n = make (Const (T.scalar_of_int (n - 1))) in
        make (Stateless (SL2 (Get, n, es)))
    ) m

  and case m =
    let m = "case" :: m in
    let alt m =
      let m = "case alternative" :: m in
      (strinG "when" -- blanks -+ p +-
       blanks +- strinG "then" +- blanks ++ p >>:
       fun (cd, cs) -> { case_cond = cd ; case_cons = cs }) m
    in
    (
      strinG "case" -- blanks -+
      several ~sep:blanks alt +- blanks ++
      optional ~def:None (
        strinG "else" -- blanks -+ some p +- blanks) +-
      strinG "end" >>:
      fun (alts, else_) -> make (Case (alts, else_))
    ) m

  and if_ m =
    let m = "if" :: m in
    (
      (
        strinG "if" -- blanks -+ p +-
        blanks +- strinG "then" +- blanks ++ p ++
        optional ~def:None (
          blanks -- strinG "else" -- blanks -+
          some p) >>:
        fun ((case_cond, case_cons), else_) ->
          make (Case ([ { case_cond ; case_cons } ], else_))
      ) ||| (
        afun2 "if" >>:
        fun (case_cond, case_cons) ->
          make (Case ([ { case_cond ; case_cons } ], None))
      ) ||| (
        afun3 "if" >>:
        fun (case_cond, case_cons, else_) ->
          make (Case ([ { case_cond ; case_cons } ], Some else_))
      )
    ) m

  and coalesce m =
    let m = "coalesce" :: m in
    (
      afun0v "coalesce" >>: function
        | [] -> raise (Reject "empty COALESCE")
        | [_] -> raise (Reject "COALESCE must have at least 2 arguments")
        | r -> make (Stateless (SL1s (Coalesce, r)))
    ) m

  and accept_units q =
    q ++ optional ~def:None (opt_blanks -+ some RamenUnits.Parser.p) >>:
    function e, None -> e
           | e, units -> { e with typ = { e.typ with units } }

  and highestest_prec_no_parenthesis m =
    (
      accept_units (const ||| variable ||| null) ||| func ||| coalesce
    ) m

  and highestest_prec m =
    (
      highestest_prec_no_parenthesis |||
      accept_units (char '(' -- opt_blanks -+ p +- opt_blanks +- char ')') |||
      tuple ||| vector ||| record
    ) m

  (* Empty tuples and tuples of arity 1 are disallowed in order not to
   * conflict with parentheses used as grouping symbols. We could do the
   * same trick as in python though (TODO): *)
  and tuple m =
    let m = "tuple" :: m in
    (
      char '(' -- opt_blanks -+
      repeat ~min:2 ~sep:T.Parser.tup_sep p +-
      opt_blanks +- char ')' >>:
      fun es -> make (Tuple es)
    ) m

  and record_field m =
    let m = "record field" :: m in
    (
      p ++ optional ~def:(None, "") (
        T.Parser.kv_sep -+ some non_keyword ++
        optional ~def:"" (blanks -+ quoted_string)) ++
      optional ~def:None (
        blanks -+ some T.Parser.default_aggr) >>:
      fun ((expr, (alias, doc)), aggr) ->
        let alias =
          Option.default_delayed (fun () -> default_alias expr) alias in
        let alias = RamenName.field_of_string alias in
        { expr ; alias ; doc ; aggr }
    ) m

  and record m =
    let m = "record" :: m in
    (
      char '(' -- opt_blanks -+
      several ~sep:T.Parser.tup_sep (
        (star >>: fun _ -> None) |||
        some record_field) +-
      opt_blanks +- char ')' >>:
      fun lst ->
        let star, sfs =
          List.fold_left (fun (star, sfs) -> function
            | None ->
                if star then
                  !logger.warning "duplicate STAR selector has no effect" ;
                true, sfs
            | Some sf ->
                star, sf :: sfs
          ) (false, []) lst in
        make (Record (star, sfs))
    ) m

  (* Empty vectors are disallowed so we cannot ignore the element type: *)
  and vector m =
    let m = "vector" :: m in
    (
      char '[' -- opt_blanks -+
      several ~sep:T.Parser.tup_sep p +-
      opt_blanks +- char ']' >>:
      fun es ->
        let num_items = List.length es in
        assert (num_items >= 1) ;
        make (Vector es)
    ) m

  and p m = lowestest_prec_left_assoc m

  (*$= p & ~printer:(test_printer (print false))
    (Ok (Const (typ, VI32 (Stdint.Int32.of_int 13)), (13, []))) \
      (test_p p "13i32{secs^2}" |> replace_typ_in_expr)

    (Ok (Const (typ, VI32 (Stdint.Int32.of_int 13)), (16, []))) \
      (test_p p "13i32 {secs ^ 2}" |> replace_typ_in_expr)

    (Ok (\
      Const (typ, VBool true),\
      (4, [])))\
      (test_p p "true" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun1 (typ, Not, StatelessFun1 (typ, Defined, Variable (typ, RamenName.field_of_string "zone_src"))),\
      (16, [])))\
      (test_p p "zone_src IS NULL" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, And, \
        StatelessFun2 (typ, Or, \
          StatelessFun1 (typ, Not, \
            StatelessFun1 (typ, Defined, Variable (typ, RamenName.field_of_string "zone_src"))),\
          StatelessFun2 (typ, Eq, Variable (typ, RamenName.field_of_string "zone_src"),\
                                  Variable (typ, RamenName.field_of_string "z1"))), \
        StatelessFun2 (typ, Or, \
          StatelessFun1 (typ, Not, \
            StatelessFun1 (typ, Defined, Variable (typ, RamenName.field_of_string "zone_dst"))),\
          StatelessFun2 (typ, Eq, \
            Variable (typ, RamenName.field_of_string "zone_dst"), \
            Variable (typ, RamenName.field_of_string "z2")))),\
      (75, [])))\
      (test_p p "(zone_src IS NULL or zone_src = z1) and \\
                 (zone_dst IS NULL or zone_dst = z2)" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, Div, \
        StatefulFun (typ, LocalState, true, AggrSum (\
          Variable (typ, RamenName.field_of_string "bytes"))),\
        Variable (typ, RamenName.field_of_string "avg_window")),\
      (22, [])))\
      (test_p p "(sum bytes)/avg_window" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, IDiv, \
        Variable (typ, RamenName.field_of_string "start"),\
        StatelessFun2 (typ, Mul, \
          Const (typ, VU32 (Uint32.of_int 1_000_000)),\
          Variable (typ, RamenName.field_of_string "avg_window"))),\
      (33, [])))\
      (test_p p "start // (1_000_000 * avg_window)" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, Percentile, \
        Variable (typ, RamenName.field_of_string "p"),\
        Variable (typ, RamenName.field_of_string "bytes_per_sec")),\
      (26, [])))\
      (test_p p "p percentile bytes_per_sec" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, Gt, \
        StatefulFun (typ, LocalState, true, AggrMax (\
          Variable (typ, RamenName.field_of_string "start"))),\
        StatelessFun2 (typ, Add, \
          Variable (typ, ref .field_of_string "start"),\
          StatelessFun2 (typ, Mul, \
            StatelessFun2 (typ, Mul, \
              Variable (typ, RamenName.field_of_string "obs_window"),\
              Const (typ, VFloat 1.15)),\
            Const (typ, VU32 (Uint32.of_int 1_000_000))))),\
      (58, [])))\
      (test_p p "max in.start > \\
                 out.start + (obs_window * 1.15) * 1_000_000" |> replace_typ_in_expr)

    (Ok (\
      StatelessFun2 (typ, Mod, \
        Variable (typ, RamenName.field_of_string "x"),\
        Variable (typ, RamenName.field_of_string "y")),\
      (5, [])))\
      (test_p p "x % y" |> replace_typ_in_expr)

    (Ok ( \
      StatelessFun1 (typ, Abs, \
        StatelessFun2 (typ, Sub, \
          Variable (typ, RamenName.field_of_string "bps"), \
          StatefulFun (typ, GlobalState, true, Lag (\
            Const (typ, VU32 Uint32.one), \
            Variable (typ, RamenName.field_of_string "bps"))))), \
      (21, []))) \
      (test_p p "abs(bps - lag(1,bps))" |> replace_typ_in_expr)

    (Ok ( \
      StatefulFun (typ, GlobalState, true, Hysteresis (\
        Variable (typ, RamenName.field_of_string "value"),\
        Const (typ, VU32 (Uint32.of_int 900)),\
        Const (typ, VU32 (Uint32.of_int 1000)))),\
      (28, [])))\
      (test_p p "hysteresis(value, 900, 1000)" |> replace_typ_in_expr)

    (Ok ( \
      StatelessFun2 (typ, Mul, \
        StatelessFun2 (typ, BitAnd, \
          Const (typ, VU32 (Uint32.of_int 4)), \
          Const (typ, VU32 (Uint32.of_int 4))), \
        Const (typ, VU32 (Uint32.of_int 2))), \
      (9, []))) \
      (test_p p "4 & 4 * 2" |> replace_typ_in_expr)
  *)

  (*$>*)
end

(* Used only for tests but could be handy in a REPL: *)
let parse =
  let print = print false in
  RamenParsing.string_parser ~what:"expression" ~print Parser.p

(* Environment: some helper functions.
 * Here the environment is composed of a stack of pairs from
 * field name to tuple_prefix, giving us the origin of that
 * field name at this point in the AST. *)
module Env = struct
  type binding = RamenName.field * tuple_prefix

  let env_param = RamenName.field_of_string "param", TupleParam
  let env_env = RamenName.field_of_string "env", TupleEnv
  let env_in = RamenName.field_of_string "in", TupleIn
  let env_out = RamenName.field_of_string "out", TupleOut
  let env_group = RamenName.field_of_string "group", TupleGroup
  let env_previous = RamenName.field_of_string "previous", TupleOutPrevious
  let env_greatest = RamenName.field_of_string "greatest", TupleMergeGreatest
  let env_smallest = RamenName.field_of_string "smallest", TupleSortSmallest
  let env_first = RamenName.field_of_string "first", TupleSortFirst

  let print_binding oc (name, pref) =
    Printf.fprintf oc "%a.%a"
      tuple_prefix_print pref
      RamenName.field_print name

  let unbound_var_msg what env name =
    Printf.sprintf2 "%s: Unbound variable %a (environment is: %a)"
      what
      RamenName.field_print name
      (pretty_list_print print_binding) env

  let unbound_var what env name =
    unbound_var_msg what env name |> failwith

  let lookup what env name =
    try List.assoc name env
    with exn ->
      !logger.debug "%s" (unbound_var_msg what env name) ;
      raise exn

  let rec fold f i env e =
    let i = f i env e in
    fold_subexpressions (fold f) i env e

  let iter f env e =
    fold (fun () env e -> f env e) () env e

  (* Given an expression, return the same expression with lose variables
   * "grounded" to param or in: *)
  let ground_on params what env e =
    map (fun what env e ->
      match e.text with
      | Variable name ->
          let do_ground_on tup_pref =
            make (Stateless (SL2 (Get,
              of_string (RamenName.string_of_field name),
              make (Variable (RamenName.field_of_string tup_pref)))))
          in
          (match lookup what env name with
          | exception Not_found ->
              (* First, look at this name in the declared parameters: *)
              (match List.find (fun p ->
                       p.RamenTuple.ptyp.name = name
                     ) params with
              | exception Not_found ->
                  (* Assume input: *)
                  do_ground_on "in"
              | _ -> do_ground_on "param")
          | _ ->
              (* If we can find this variable in the environment (ie it's the
               * field name of some opened record) then there is no reason
               * to do anything. *)
              e)
      | _ -> e
    ) what env e
end

(* Function to check an expression after typing, to check that we do not
 * use any IO tuple for init, non constants, etc, when not allowed. *)
(* TODO: Also check that when we use a variable as the "constant" parameter
 * of a percentile it is indeed constant (ie comes from params or env).
 * TODO: same for the size and duration of a Top, *)
let check =
  let check_no_io what env =
    iter (fun e ->
      match e.text with
      | Variable name ->
          (match Env.lookup what env name with
          | exception Not_found -> Env.unbound_var what env name
          (* params, env and opened records are available from everywhere *)
          | TupleParam | TupleEnv | TupleRecord _ -> ()
          | tup_pref ->
              Printf.sprintf2 "%s is not allowed to access %s"
                what (string_of_prefix tup_pref) |>
              failwith)
      (* TODO: all other similar cases *)
      | _ -> ())
  in
  fun what ->
    Env.iter (fun env e ->
      match e.text with
      | Stateful (_, _, Past { max_age ; sample_size ; _ }) ->
          let what' = what ^": duration of function past" in
          check_no_io what' env max_age ;
          let what' = what ^": sample size of function past" in
          Option.may (check_no_io what' env) sample_size
      | _ -> ())

(* Return the expected units for a given expression.
 * Fail if the operation does not accept the arguments units.
 * Returns None if the unit is unknown or if the value cannot have a unit
 * (non-numeric).
 * This is best-effort:
 * - units are not propagated from one conditional consequent to another;
 * - units of a Get is not inferred but in the simplest cases;
 * - units of x**y is not inferred unless y is constant.
 *)
let units_of_expr params units_of_input units_of_output =
  let units_of_params name =
    match List.find (fun param ->
            param.RamenTuple.ptyp.name = name
          ) params with
    | exception Not_found ->
        Printf.sprintf2 "Unknown parameter %a while looking for units"
          RamenName.field_print name |>
        failwith
    | p -> p.RamenTuple.ptyp.units
  in
  let rec uoe ~indent ~env e =
    let char_of_indent = Char.chr (Char.code 'a' + indent) in
    let prefix = Printf.sprintf "%s%c. " (String.make (indent * 2) ' ')
                                         char_of_indent in
    !logger.debug "%sUnits of expression %a...?" prefix (print true) e ;
    let indent = indent + 1 in
    if e.typ.units <> None then e.typ.units else
    (match e.text with
    | Const v ->
        if T.(is_a_num (structure_of v)) then e.typ.units
        else None
    | Variable name ->
        let what = "Computing units" in
        (match Env.lookup what env name with
        | exception Not_found ->
            Env.unbound_var what env name
        | origin ->
            if tuple_has_type_input origin then
              units_of_input name
            else if tuple_has_type_output origin then
              units_of_output name
            else if origin = TupleParam then
              units_of_params name
            else None)
    | Case (cas, else_opt) ->
        (* We merely check that the units of the alternatives are either
         * the same of unknown. *)
        List.iter (fun ca -> check_no_units ~indent ~env ca.case_cond) cas ;
        let units_opt = Option.bind else_opt (uoe ~indent ~env) in
        List.map (fun ca -> ca.case_cons) cas |>
        same_units ~indent ~env "Conditional alternatives" units_opt
    | Stateless (SL1s (Coalesce, es)) ->
        same_units ~indent ~env "Coalesce alternatives" None es
    | Stateless (SL0 (Now|EventStart|EventStop)) ->
        Some RamenUnits.seconds_since_epoch
    | Stateless (SL1 (Age, e)) ->
        check ~indent ~env e RamenUnits.seconds_since_epoch ;
        Some RamenUnits.seconds
    | Stateless (SL1 ((Cast _|Abs|Minus|Ceil|Floor|Round), e))
    | Stateless (SL2 (Trunc, e, _)) ->
        uoe ~indent  ~env e
    | Stateless (SL1 (Length, e)) ->
        check_no_units ~indent ~env e ;
        Some RamenUnits.chars
    | Stateless (SL1 (Sqrt, e)) ->
        Option.map (fun e -> RamenUnits.pow e 0.5) (uoe ~indent ~env e)
    | Stateless (SL2 (Add, e1, e2)) ->
        option_map2 RamenUnits.add (uoe ~indent ~env e1) (uoe ~indent ~env e2)
    | Stateless (SL2 (Sub, e1, e2)) ->
        option_map2 RamenUnits.sub (uoe ~indent ~env e1) (uoe ~indent ~env e2)
    | Stateless (SL2 ((Mul|Mod), e1, e2)) ->
        option_map2 RamenUnits.mul (uoe ~indent ~env e1) (uoe ~indent ~env e2)
    | Stateless (SL2 ((Div|IDiv), e1, e2)) ->
        option_map2 RamenUnits.div (uoe ~indent ~env e1) (uoe ~indent ~env e2)
    | Stateless (SL2 (Pow, e1, e2)) ->
        (* Best effort in case the exponent is a constant, otherwise we
         * just don't know what the unit is. *)
        option_map2 RamenUnits.pow (uoe ~indent ~env e1) (float_of_const e2)
    (* Although shifts could be seen as mul/div, we'd rather consider
     * only dimensionless values receive this treatment, esp. since
     * it's not possible to distinguish between a mul and div. *)
    | Stateless (SL2 ((And|Or|Concat|StartsWith|EndsWith|
                       BitAnd|BitOr|BitXor|BitShift), e1, e2)) ->
        check_no_units ~indent ~env e1 ;
        check_no_units ~indent ~env e2 ;
        None
    | Stateless (SL2 (Get, e1, { text = Vector es ; _ })) ->
        Option.bind (int_of_const e1) (fun n ->
          List.at es n |> uoe ~indent ~env)
    | Stateless (SL2 (Get, n, { text = Tuple es ; _ })) ->
        (* Not super useful. FIXME: use the solver. *)
        let n = int_of_const n |>
                option_get "Get from tuple must have const index" in
        (try List.at es n |> uoe ~indent ~env
        with Invalid_argument _ -> None)
    | Stateless (SL2 (Get, s, ({ text = Record (_, sfs) ; _ } as rec_exp))) ->
        (* Not super useful neither and that's more annoying as records
         * are replacing operation fields.
         * FIXME: Compute and set the units after type-checking using the
         *        solver. *)
        let s = string_of_const s |>
                option_get "Get from record must have string index" in
        (* Units of field k of this record is the units of this field
         * values, evaluated with all the _previous_ fields in the env: *)
        let rec find_last env last = function
          | [] -> last
          | sf :: rest ->
              let last =
                (* found a later occurrence of that field name: *)
                if RamenName.string_of_field sf.alias = s then
                  Some (sf.expr, env)
                else last in
              find_last ((sf.alias, TupleRecord rec_exp) :: env) last rest in
        (match find_last env None sfs with
        | None -> None
        | Some (v, env) -> uoe ~indent ~env v)
    | Stateless (SL2 (Percentile, _,
                      { text = Stateful (_, _, Last ( _, e, _))
                             | Stateful (_, _, SF2 (Sample, _, e))
                             | Stateful (_, _, SF1 (Group, e)) ; _ })) ->
        uoe ~indent ~env e
    | Stateless (SL1 (Like _, e)) ->
        check_no_units ~indent ~env e ;
        None
    | Stateless (SL1s ((Max|Min), es)) ->
        same_units ~indent ~env "Min/Max alternatives" None es
    | Stateless (SL1s (Print, e::_)) ->
        uoe ~indent ~env e
    | Stateful (_, _, SF1 ((AggrMin|AggrMax|AggrAvg|AggrFirst|AggrLast), e))
    | Stateful (_, _, SF2 ((Lag|ExpSmooth), _, e))
    | Stateful (_, _, SF3 ((MovingAvg|LinReg), _, _, e)) ->
        uoe ~indent ~env e
    | Stateful ( _, _, SF1 (AggrSum, e)) ->
        let u = uoe ~indent ~env e in
        check_not_rel e u ;
        u
    | Generator (Split (e1, e2)) ->
        check_no_units ~indent ~env e1 ;
        check_no_units ~indent ~env e2 ;
        None
    | _ -> None) |>
    function
      | Some u as res ->
          !logger.debug "%s-> %a" prefix RamenUnits.print u ;
          res
      | None -> None

  and check ~indent ~env e u =
    match uoe ~indent ~env e with
    | None -> ()
    | Some u' ->
        if not (RamenUnits.eq u u') then
          Printf.sprintf2 "%a must have units %a not %a"
            (print false) e
            RamenUnits.print u
            RamenUnits.print u' |>
          failwith

  and check_no_units ~indent ~env e =
    match uoe ~indent ~env e with
    | None -> ()
    | Some u ->
        Printf.sprintf2 "%a must have no units but has unit %a"
          (print false) e
          RamenUnits.print u |>
        failwith

  and check_not_rel e u =
    Option.may (fun u ->
      if RamenUnits.is_relative u then
        Printf.sprintf2 "%a must not have relative unit but has unit %a"
          (print false) e
          RamenUnits.print u |>
        failwith
    ) u

  and same_units ~indent ~env what i es =
    List.enum es /@ (uoe ~indent ~env) |>
    RamenUnits.check_same_units ~what i

  in uoe ~indent:0 ~env:[]
