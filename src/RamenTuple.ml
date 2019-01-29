(* This module keeps types and functions related to tuples.
 *
 * Tuples are what operations consume and produce.
 * Notice that we have a type to describe the type of a tuple (the type
 * and names of its fields) but no type to describe an actual tuple value.
 * That's because all tuple values appear only in generated code.
 *)
open Batteries
open RamenHelpers

type field_typ =
  { mutable name : RamenName.field ;
    mutable typ : RamenTypes.t ;
    mutable units : RamenUnits.t option ;
    mutable doc : string ;
    mutable aggr : string option ;
    (* Also disp name, etc... *) }
  [@@ppp PPP_OCaml]

(* Some "well known" type that we might need on the fly: *)
let seq_typ =
  { name = RamenName.field_of_string "Seq" ;
    typ = RamenTypes.{ structure = TU64 ; nullable = false ;
                       units = None ; doc = "" ; aggr = None } ;
    units = Some RamenUnits.dimensionless ;
    doc = "Sequence number" ;
    aggr = None }

let start_typ =
  { name = RamenName.field_of_string "Event start" ;
    typ = RamenTypes.{ structure = TFloat ; nullable = true ;
                       units = None ; doc = "" ; aggr = None } ;
    units = Some RamenUnits.seconds_since_epoch ;
    doc = "Event start" ;
    aggr = Some "min" }

let stop_typ =
  { name = RamenName.field_of_string "Event stop" ;
    typ = RamenTypes.{ structure = TFloat ; nullable = true ;
                       units = None ; doc = "" ; aggr = None } ;
    units = Some RamenUnits.seconds_since_epoch ;
    doc = "Event stop" ;
    aggr = Some "max" }

(* TODO: have an array instead? *)
type typ = field_typ list [@@ppp PPP_OCaml]

let print_field_typ oc field =
  Printf.fprintf oc "%a %a"
    RamenName.field_print field.name
    RamenTypes.print_typ field.typ ;
  Option.may (RamenUnits.print oc) field.units

let print_typ oc =
  (List.print ~first:"(" ~last:")" ~sep:", "
    (fun oc t -> print_field_typ oc t)) oc

let print_typ_names oc =
  pretty_list_print (fun oc t ->
    String.print_quoted oc (RamenName.string_of_field t.name)) oc

(* Params form a special tuple with fixed values: *)

type param =
  { ptyp : field_typ ; value : RamenTypes.value }
  [@@ppp PPP_OCaml]

type params = param list [@@ppp PPP_OCaml]

let print_param oc p =
  Printf.fprintf oc "%a=%a"
    RamenName.field_print p.ptyp.name
    RamenTypes.print p.value

let print_params oc =
  List.print (fun oc p -> print_param oc p) oc

let params_sort params =
  let param_compare p1 p2 =
    RamenName.compare p1.ptyp.name p2.ptyp.name in
  List.fast_sort param_compare params

let params_find n = List.find (fun p -> p.ptyp.name = n)
let params_mem n = List.exists (fun p -> p.ptyp.name = n)

let print_params_names oc =
  print_typ_names oc % List.map (fun p -> p.ptyp) % params_sort

(* Same signature for different instances of the same program but changes
 * whenever the type of parameters change: *)

let type_signature =
  List.fold_left (fun s ft ->
    if RamenName.is_private ft.name then s
    else
      (if s = "" then "" else s ^ "_") ^
      RamenName.string_of_field ft.name ^ ":" ^
      RamenTypes.string_of_typ ft.typ
  ) ""

let params_type_signature =
  type_signature % List.map (fun p -> p.ptyp) % params_sort

(* Override ps1 with values from ps2, ignoring the values of ps2 that are
 * not in ps1. Enlarge the values of ps2 as necessary: *)
let overwrite_params ps1 ps2 =
  List.map (fun p1 ->
    match Hashtbl.find ps2 p1.ptyp.name with
    | exception Not_found -> p1
    | p2_val ->
        let open RamenTypes in
        if p2_val = VNull then
          if not p1.ptyp.typ.nullable then
            Printf.sprintf2 "Parameter %a is not nullable so cannot \
                             be set to NULL"
              RamenName.field_print p1.ptyp.name |>
            failwith
          else
            { p1 with value = VNull }
        else match enlarge_value p1.ptyp.typ.structure p2_val with
          | exception Invalid_argument _ ->
              Printf.sprintf2 "Parameter %a of type %a can not be \
                               promoted into a %a"
                RamenName.field_print p1.ptyp.name
                print_structure (structure_of p2_val)
                print_typ p1.ptyp.typ |>
              failwith
          | value -> { p1 with value }
  ) ps1

module Parser =
struct
  open RamenParsing

  let field m =
    let m = "field declaration" :: m in
    (
      non_keyword +- blanks ++ RamenTypes.Parser.typ ++
      optional ~def:None (opt_blanks -+ some RamenUnits.Parser.p) ++
      optional ~def:"" (opt_blanks -+ quoted_string) ++
      optional ~def:None (
        opt_blanks -+ some RamenTypes.Parser.default_aggr) >>:
      fun ((((name, typ), units), doc), aggr) ->
        let name = RamenName.field_of_string name in
        { name ; typ ; units ; doc ; aggr }
    ) m
end
