(* Global configuration for rigatoni daemon *)
open Batteries
open Log

type temp_tup_typ =
  { mutable complete : bool ;
    (* Not sure we need the rank for anything, actually *)
    fields : (string, int option ref * Lang.Expr.typ) Hashtbl.t }

let print_temp_tup_typ fmt t =
  Printf.fprintf fmt "%a (%s)"
    (Hashtbl.print ~first:"{" ~last:"}" ~sep:", " ~kvsep:":"
                   String.print
                   (fun fmt (rank, expr_typ) ->
                     Printf.fprintf fmt "[%s] %a"
                      (match !rank with
                      | Some r -> string_of_int r
                      | None -> "??")
                      Lang.Expr.print_typ expr_typ)) t.fields
    (if t.complete then "complete" else "incomplete")

let temp_tup_typ_complete t =
  if not t.complete &&
     Hashtbl.fold (fun _ (_rank, typ) complete ->
       complete && Lang.Expr.typ_is_complete typ) t.fields true
  then
    t.complete <- true

let make_temp_tup_typ () =
  { complete = false ;
    fields = Hashtbl.create 7 }

let temp_tup_typ_of_tup_typ complete tup_typ =
  let t = make_temp_tup_typ () in
  t.complete <- complete ;
  List.iteri (fun i f ->
      let expr_typ =
        Lang.Expr.make_typ ~nullable:f.Lang.Tuple.nullable
                           ~typ:f.Lang.Tuple.typ f.Lang.Tuple.name in
      Hashtbl.add t.fields f.Lang.Tuple.name (ref (Some i), expr_typ)
    ) tup_typ ;
  t

let list_of_temp_tup_type ttt =
  Hashtbl.values ttt.fields |>
  List.of_enum |>
  List.fast_sort (fun (r1, _) (r2, _) -> compare r1 r2) |>
  List.map (fun (r, f) -> !r, f)

let tup_typ_of_temp_tup_type ttt =
  let open Lang in
  assert ttt.complete ;
  list_of_temp_tup_type ttt |>
  List.map (fun (_, typ) ->
    { Tuple.name = typ.Expr.name ;
      Tuple.nullable = Option.get typ.Expr.nullable ;
      Tuple.typ = Option.get typ.Expr.typ })

type node =
  { name : string ;
    operation : Lang.Operation.t ;
    mutable parents : node list ;
    mutable children : node list ;
    mutable in_type : temp_tup_typ ;
    mutable out_type : temp_tup_typ ;
    mutable command : string option ;
    mutable pid : int option }

type graph =
  { nodes : (string, node) Hashtbl.t }

type conf =
  { building_graph : graph ;
    save_file : string }

let make_node name operation =
  !logger.debug "Creating node %s" name ;
  { name ; operation ; parents = [] ; children = [] ;
    (* Set once the all graph is known: *)
    in_type = make_temp_tup_typ () ; out_type = make_temp_tup_typ () ;
    command = None ; pid = None }

let compile_node node =
  assert node.in_type.complete ;
  assert node.out_type.complete ;
  let in_typ = tup_typ_of_temp_tup_type node.in_type
  and out_typ = tup_typ_of_temp_tup_type node.out_type in
  node.command <- Some (
    CodeGen_OCaml.gen_operation node.name in_typ out_typ node.operation)

let make_new_graph () =
  { nodes = Hashtbl.create 17 }

let make_graph save_file =
  try
    File.with_file_in save_file (fun ic -> Marshal.input ic)
  with
    | Sys_error err ->
      !logger.debug "Cannot read state from file %S: %s. Starting anew" save_file err ;
      make_new_graph ()
    | BatInnerIO.No_more_input ->
      !logger.debug "Cannot read state from file %S: not enough input. Starting anew" save_file ;
      make_new_graph ()

let save_graph conf graph =
  !logger.debug "Saving graph in %S" conf.save_file ;
  File.with_file_out ~mode:[`create; `trunc] conf.save_file (fun oc ->
    Marshal.output oc graph)

let has_node _conf graph id =
  Hashtbl.mem graph.nodes id

let find_node _conf graph id =
  Hashtbl.find graph.nodes id

let add_node conf graph id node =
  Hashtbl.add graph.nodes id node ;
  save_graph conf graph

let remove_node conf graph id =
  let node = Hashtbl.find graph.nodes id in
  List.iter (fun p ->
      p.children <- List.filter ((!=) node) p.children
    ) node.parents ;
  List.iter (fun p ->
      p.parents <- List.filter ((!=) node) p.parents
    ) node.children ;
  Hashtbl.remove_all graph.nodes id ;
  save_graph conf graph

let has_link _conf src dst =
  List.exists ((==) dst) src.children

let make_link conf graph src dst =
  !logger.debug "Create link between nodes %s and %s" src.name dst.name ;
  src.children <- dst :: src.children ;
  dst.parents <- src :: dst.parents ;
  save_graph conf graph

let remove_link conf graph src dst =
  !logger.debug "Delete link between nodes %s and %s" src.name dst.name ;
  src.children <- List.filter ((!=) dst) src.children ;
  dst.parents <- List.filter ((!=) src) dst.parents ;
  save_graph conf graph

let make_conf debug save_file =
  logger := Log.make_logger debug ;
  { building_graph = make_graph save_file ; save_file }

(*
 * Compilation of a graph
 *
 * We must first check all input/output tuple types.  For this we have two
 * temp_tuple_typ per node, one for input tuple and one for output tuple.  Each
 * check operation takes those as input and returns true if they completed any
 * of those.  Beware that those lists are completed bit by bit, since one
 * iteration of the loop might reveal only some info of some field.
 *
 * Once the fixed point is reached we check if we have all the fields we should
 * have.
 *
 * Types propagate to parents output to node input, then from operations to
 * node output, via the expected_type of each expression.
 *)

exception CompilationError of string

let can_cast ~from_scalar_type ~to_scalar_type =
  let open Lang.Scalar in
  let compatible_types =
    match from_scalar_type with
    | TU8 -> [ TU8 ; TU16 ; TU32 ; TU64 ; TU128 ; TI16 ; TI32 ; TI64 ; TI128 ; TFloat ]
    | TU16 -> [ TU16 ; TU32 ; TU64 ; TU128 ; TI32 ; TI64 ; TI128 ; TFloat ]
    | TU32 -> [ TU32 ; TU64 ; TU128 ; TI64 ; TI128 ; TFloat ]
    | TU64 -> [ TU64 ; TU128 ; TI128 ; TFloat ]
    | TU128 -> [ TU128 ; TFloat ]
    | TI8 -> [ TI8 ; TI16 ; TI32 ; TI64 ; TI128 ; TU16 ; TU32 ; TU64 ; TU128 ; TFloat ]
    | TI16 -> [ TI16 ; TI32 ; TI64 ; TI128 ; TU32 ; TU64 ; TU128 ; TFloat ]
    | TI32 -> [ TI32 ; TI64 ; TI128 ; TU64 ; TU128 ; TFloat ]
    | TI64 -> [ TI64 ; TI128 ; TU128 ; TFloat ]
    | TI128 -> [ TI128 ; TFloat ]
    | x -> [ x ] in
  List.mem to_scalar_type compatible_types

(* Improve to rank with from *)
let check_rank ~from ~to_ =
  match !to_, !from with
  | None, Some _ ->
    to_ := !from ;
    true
  (* Contrary to type, once to_ is set it is better than from.
   * Example: "select 42, *" -> the star will add all fields from input into
   * output with a larger rank than on input. Then checking the rank again
   * would complain. *)
  | _ -> false

(* Improve to_ while checking compatibility with from.
 * Numerical types of to_ can be enlarged to match those of from. *)
let check_expr_type ~from ~to_ =
  let open Lang in
  let changed =
    match to_.Expr.typ, from.Expr.typ with
    | None, Some _ ->
      to_.Expr.typ <- from.Expr.typ ;
      true
    | Some to_typ, Some from_typ when to_typ <> from_typ ->
      if can_cast ~from_scalar_type:to_typ ~to_scalar_type:from_typ then (
        to_.Expr.typ <- from.Expr.typ ;
        true
      ) else (
        let m = Printf.sprintf "%s must have type %s but got %s of type %s"
                    to_.Expr.name (IO.to_string Scalar.print_typ to_typ)
                    from.Expr.name (IO.to_string Scalar.print_typ from_typ) in
        raise (CompilationError m)
      )
    | _ -> false in
  let changed =
    match to_.Expr.nullable, from.Expr.nullable with
    | None, Some _ ->
      to_.Expr.nullable <- from.Expr.nullable ;
      true
    | Some to_null, Some from_null when to_null <> from_null ->
      let m = Printf.sprintf "%s must%s be nullable but %s is%s"
                to_.Expr.name (if to_null then "" else " not")
                from.Expr.name (if from_null then "" else " not") in
      raise (CompilationError m)
    | _ -> changed in
  changed

(* Check that this expression fulfill the type expected by the caller (exp_type).
 * Also, improve exp_type (set typ and nullable, enlarge numerical types ...).
 * When we recurse from an operator to its operand we set the exp_type to the one
 * in the operator so we improve typing of the AST along the way. *)
let rec check_expr ~in_type ~out_type ~exp_type =
  let open Lang in
  let check_operand op_typ sub_typ ?exp_sub_typ ?exp_sub_nullable sub_expr=
    (* Start by recursing into the sub-expression to know its real type: *)
    let changed = check_expr ~in_type ~out_type ~exp_type:sub_typ sub_expr in
    (* Now we check this comply with the operator expectations about its operand : *)
    (match sub_typ.Expr.typ, exp_sub_typ with
    | Some actual_typ, Some exp_sub_typ ->
      if not (can_cast ~from_scalar_type:actual_typ ~to_scalar_type:exp_sub_typ) then
        let m = Printf.sprintf "Operand of %s is supposed to have type compatible with %s, not %s"
          op_typ.Expr.name
          (IO.to_string Scalar.print_typ exp_sub_typ)
          (IO.to_string Scalar.print_typ actual_typ) in
        raise (CompilationError m)
    | _ -> ()) ;
    (match exp_sub_nullable, sub_typ.Expr.nullable with
    | Some n1, Some n2 when n1 <> n2 ->
      let m = Printf.sprintf "Operand of %s is%s supposed to be NULLable"
        op_typ.Expr.name (if n1 then "" else " not") in
      raise (CompilationError m)
    | _ -> ()) ;
    changed
  in
  (* Check that actual_typ is a better version of op_typ and improve op_typ,
   * then check that the resulting op_type fulfill exp_type. *)
  let check_operator op_typ actual_typ nullable =
    let from = Expr.make_typ ~typ:actual_typ ?nullable op_typ.Lang.Expr.name in
    let changed = check_expr_type ~from ~to_:op_typ in
    check_expr_type ~from:op_typ ~to_:exp_type || changed
  in
  let check_unary_op op_typ make_op_typ ?(propagate_null=true) ?exp_sub_typ ?exp_sub_nullable sub_expr =
    (* First we check the operand: does it comply with the expected type
     * (enlarging it if necessary)? *)
    let sub_typ = Expr.typ_of sub_expr in
    let changed = check_operand op_typ sub_typ ?exp_sub_typ ?exp_sub_nullable sub_expr in
    (* So far so good. So, given the type of the operand, what is the type of the operator? *)
    match sub_typ.Expr.typ with
    | Some sub_typ_typ ->
      let actual_typ = make_op_typ sub_typ_typ in
      (* We propagate nullability automatically for most operator *)
      let nullable =
        if propagate_null then sub_typ.Expr.nullable else None in
      (* Now check that this is OK with this operator type, enlarging it if required: *)
      check_operator op_typ actual_typ nullable || changed
    | None -> changed (* try again later *)
  in
  let check_binary_op op_typ make_op_typ ?(propagate_null=true)
                      ?exp_sub_typ1 ?exp_sub_nullable1 sub_expr1
                      ?exp_sub_typ2 ?exp_sub_nullable2 sub_expr2 =
    let sub_typ1 = Expr.typ_of sub_expr1 in
    let changed =
        check_operand op_typ sub_typ1 ?exp_sub_typ:exp_sub_typ1 ?exp_sub_nullable:exp_sub_nullable1 sub_expr1 in
    let sub_typ2 = Expr.typ_of sub_expr2 in
    let changed =
        check_operand op_typ sub_typ2 ?exp_sub_typ:exp_sub_typ2 ?exp_sub_nullable:exp_sub_nullable2 sub_expr2 || changed in
    match sub_typ1.Expr.typ, sub_typ2.Expr.typ with
    | Some sub_typ1_typ, Some sub_typ2_typ ->
      let actual_typ = make_op_typ (sub_typ1_typ, sub_typ2_typ) in
      let nullable = if propagate_null then
          match sub_typ1.Expr.nullable, sub_typ2.Expr.nullable with
          | Some true, _ | _, Some true -> Some true
          | Some false, Some false -> Some false
          | _ -> None
        else None in
      check_operator op_typ actual_typ nullable || changed
    | _ -> changed
  in
  (* Useful helpers for make_op_typ above: *)
  let larger_type (t1, t2) =
    if Scalar.compare_typ t1 t2 >= 0 then t1 else t2
  and return_bool _ = Scalar.TBool
  in
  function
  | Expr.Const (op_typ, _) ->
    (* op_typ is already optimal. But is it compatible with exp_type? *)
    check_expr_type ~from:op_typ ~to_:exp_type
  | Expr.Field (op_typ, tuple, field) ->
    if same_tuple_as_in tuple then (
      (* Check that this field is, or could be, in in_type *)
      match Hashtbl.find in_type.fields field with
      | exception Not_found ->
        if in_type.complete then (
          let m = Printf.sprintf "field %s not in %S tuple" field tuple in
          raise (CompilationError m)) ;
        false
      | _, from ->
        if in_type.complete then ( (* Save the type *)
          op_typ.Expr.nullable <- from.Expr.nullable ;
          op_typ.Expr.typ <- from.Expr.typ
        ) ;
        check_expr_type ~from ~to_:exp_type
    ) else if tuple = "out" then (
      (* If we already have this field in out then check it's compatible (or
       * enlarge out or exp). If we don't have it then add it. *)
      match Hashtbl.find out_type.fields field with
      | exception Not_found ->
        if out_type.complete then (
          let m = Printf.sprintf "field %s not in %S tuple" field tuple in
          raise (CompilationError m)) ;
        Hashtbl.add out_type.fields field (ref None, exp_type) ;
        true
      | _, out ->
        if out_type.complete then ( (* Save the type *)
          op_typ.Expr.nullable <- out.Expr.nullable ;
          op_typ.Expr.typ <- out.Expr.typ
        ) ;
        check_expr_type ~from:out ~to_:exp_type
    ) else (
      let m = Printf.sprintf "unknown tuple %S" tuple in
      raise (CompilationError m)
    )
  | Expr.Param (_op_typ, _pname) ->
    (* TODO: one day we will know the type or value of params *)
    false
  | Expr.AggrMin (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.AggrMax (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.AggrSum (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.AggrAnd (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.AggrOr (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.AggrPercentile (op_typ, e1, e2) ->
    check_binary_op op_typ snd ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Age (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.Not (op_typ, e) ->
    check_unary_op op_typ identity ~exp_sub_typ:Scalar.TFloat e
  | Expr.Defined (op_typ, e) ->
    check_unary_op op_typ return_bool ~exp_sub_nullable:true ~propagate_null:false e
  | Expr.Add (op_typ, e1, e2) ->
    check_binary_op op_typ larger_type ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Sub (op_typ, e1, e2) ->
    check_binary_op op_typ larger_type ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Mul (op_typ, e1, e2) ->
    check_binary_op op_typ larger_type ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Div (op_typ, e1, e2) ->
    check_binary_op op_typ larger_type ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Exp (op_typ, e1, e2) ->
    check_binary_op op_typ larger_type ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.And (op_typ, e1, e2) ->
    check_binary_op op_typ return_bool ~exp_sub_typ1:Scalar.TBool e1 ~exp_sub_typ2:Scalar.TBool e2
  | Expr.Or (op_typ, e1, e2) ->
    check_binary_op op_typ return_bool ~exp_sub_typ1:Scalar.TBool e1 ~exp_sub_typ2:Scalar.TBool e2
  | Expr.Ge (op_typ, e1, e2) ->
    check_binary_op op_typ return_bool ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Gt (op_typ, e1, e2) ->
    check_binary_op op_typ return_bool ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2
  | Expr.Eq (op_typ, e1, e2) ->
    check_binary_op op_typ return_bool ~exp_sub_typ1:Scalar.TFloat e1 ~exp_sub_typ2:Scalar.TFloat e2

(* Given two tuple types, transfer all fields from the parent to the child,
 * while checking those already in the child are compatible.
 * If autorank is true, do not try to reuse from rank but add them instead.
 * This is meant to be used when transfering input to output due to "select *"
 *)
let check_inherit_tuple ~including_complete ~is_subset ~from_tuple ~to_tuple ~autorank =
  assert (not to_tuple.complete) ;
  let max_rank fields =
    Hashtbl.fold (fun _ (rank, _) max_rank ->
      match !rank with
      | None -> max_rank
      | Some r -> max max_rank r) fields 0
  in
  (* Check that to_tuple is included in from_tuple (is is_subset) and if so
   * that they are compatible. Improve child type using parent type. *)
  let changed =
    Hashtbl.fold (fun n (child_rank, child_field) changed ->
        match Hashtbl.find from_tuple.fields n with
        | exception Not_found ->
          if is_subset && from_tuple.complete then (
            let m = Printf.sprintf "Unknown field %s" n in
            raise (CompilationError m)) ;
          changed (* no-op *)
        | parent_rank, parent_field ->
          let c1 = check_expr_type ~from:parent_field ~to_:child_field
          and c2 = check_rank ~from:parent_rank ~to_:child_rank in
          c1 || c2 || changed
      ) to_tuple.fields false in
  (* Add new fields into children. *)
  let changed =
    Hashtbl.fold (fun n (parent_rank, parent_field) changed ->
        match Hashtbl.find to_tuple.fields n with
        | exception Not_found ->
          let copy = Lang.Expr.copy_typ parent_field in
          let rank =
            if autorank then ref (Some (max_rank to_tuple.fields + 1))
            else ref !parent_rank in
          Hashtbl.add to_tuple.fields n (rank, copy) ;
          true
        | _ ->
          changed (* We already checked those types above. All is good. *)
      ) from_tuple.fields changed in
  (* If from_tuple is complete then so is to_tuple *)
  let changed =
    if including_complete && from_tuple.complete then (
      to_tuple.complete <- true ;
      true
    ) else changed in
  changed

let check_select ~in_type ~out_type fields and_all_others where =
  let open Lang in
  (* Check the expression, improving out_type and checking against in_type: *)
  let changed =
    let exp_type =
      (* That where expressions cannot be null seems a nice improvement
       * over SQL. *)
      Expr.make_bool_typ ~nullable:false "where clause" in
    check_expr ~in_type ~out_type ~exp_type where in
  (* Also check other expression and make use of them to improve out_type.
   * Everything that's selected must be (added) in out_type. *)
  let changed =
    List.fold_lefti (fun changed i selfield ->
        let name = List.hd selfield.Operation.alias in
        let exp_type =
          match Hashtbl.find out_type.fields name with
          | exception Not_found ->
            let expr_typ = Expr.make_typ name in
            !logger.debug "Adding out field %s" name ;
            Hashtbl.add out_type.fields name (ref (Some i), expr_typ) ;
            expr_typ
          | _rank, exp_typ -> exp_typ in
        check_expr ~in_type ~out_type ~exp_type selfield.Operation.expr || changed
      ) changed fields in
  (* Then if all other fields are selected, add them *)
  let changed =
    if and_all_others then (
      check_inherit_tuple ~including_complete:false ~is_subset:false ~from_tuple:in_type ~to_tuple:out_type ~autorank:true || changed
    ) else changed in
  changed

let check_aggregate ~in_type ~out_type fields and_all_others
                    where key commit_when =
  let open Lang in
  (* Improve out_type using all expressions. Check we satisfy in_type. *)
  let changed =
    List.fold_left (fun changed k ->
        (* The key can be anything *)
        let exp_type = Expr.typ_of k in
        check_expr ~in_type ~out_type ~exp_type k || changed
      ) false key in
  let changed =
    let exp_type = Expr.make_bool_typ ~nullable:false "commit-when clause" in
    check_expr ~in_type ~out_type ~exp_type commit_when || changed in
  check_select ~in_type ~out_type fields and_all_others where || changed

(*
 * Improve out_type using in_type and this node operation.
 * in_type is a given, don't modify it!
 *)
let check_operation ~in_type ~out_type =
  let open Lang in
  function
  | Operation.Select { fields ; and_all_others ; where } ->
    check_select ~in_type ~out_type fields and_all_others where
  | Operation.Aggregate { fields ; and_all_others ; where ;
                          key ; commit_when } ->
    check_aggregate ~in_type ~out_type fields and_all_others where
                    key commit_when
  | Operation.OnChange expr ->
    (* Start by transmitting the field so that the expression can
     * sooner use out tuple: *)
    let changed =
      check_inherit_tuple ~including_complete:true ~is_subset:true ~from_tuple:in_type ~to_tuple:out_type ~autorank:false in
    (* Then check the expression: *)
    let exp_type =
      Expr.make_bool_typ ~nullable:false "on-change clause" in
    check_expr ~in_type ~out_type ~exp_type expr || changed
  | Operation.Alert _ ->
    check_inherit_tuple ~including_complete:true ~is_subset:true ~from_tuple:in_type ~to_tuple:out_type ~autorank:false
  | Operation.ReadCSVFile { fields ; _ } ->
    let from_tuple = temp_tup_typ_of_tup_typ true fields in
    check_inherit_tuple ~including_complete:true ~is_subset:true ~from_tuple ~to_tuple:out_type ~autorank:false

(*
 * Type inference for the graph
 *)

let check_node_types node =
  try ( (* Prepend the node name to any CompilationError *)
    (* Try to improve the in_type using the out_type of parents: *)
    let changed =
      if node.in_type.complete then false
      else if node.parents = [] then (
        node.in_type.complete <- true ; true
      ) else List.fold_left (fun changed par ->
            check_inherit_tuple ~including_complete:true ~is_subset:true ~from_tuple:par.out_type ~to_tuple:node.in_type ~autorank:false || changed
          ) false node.parents in
    (* Now try to improve out_type using the in_type and the operation: *)
    let changed =
      if node.out_type.complete then changed else (
        check_operation ~in_type:node.in_type ~out_type:node.out_type node.operation ||
        changed
      ) in
    changed
  ) with CompilationError e ->
    !logger.debug "Compilation error: %s at %s"
      e (Printexc.get_backtrace ()) ;
    let e' = Printf.sprintf "node %S: %s" node.name e in
    raise (CompilationError e')

let node_is_complete node =
  node.in_type.complete && node.out_type.complete

let set_all_types graph =
  let rec loop pass =
    if pass < 0 then (
      let bad_nodes =
        Hashtbl.values graph.nodes //
        (fun n -> not (node_is_complete n)) in
      let print_bad_node fmt node =
        Printf.fprintf fmt "%s: %a"
          node.name
          (List.print ~sep:" and " ~first:"" ~last:"" String.print)
            ((if node.in_type.complete then [] else ["cannot type input"]) @
            (if node.out_type.complete then [] else ["cannot type output"])) in
      let msg = IO.to_string (Enum.print ~sep:", " print_bad_node) bad_nodes in
      raise (CompilationError msg)) ;
    if Hashtbl.fold (fun _ node changed ->
          check_node_types node || changed
        ) graph.nodes false
    then loop (pass - 1)
  in
  let max_pass = 50 (* TODO: max number of field for a node times number of nodes? *) in
  loop max_pass
  (* TODO:
   * - check that input type empty <=> no parents
   * - check that output type empty <=> no children
   *)

(* If we have all info set the typing to complete. We must wait until the end
 * of type propagation because types can still be enlarged otherwise. *)
let node_complete_typing node =
  temp_tup_typ_complete node.in_type ;
  temp_tup_typ_complete node.out_type

let compile conf graph =
  set_all_types graph ;
  let complete =
    Hashtbl.fold (fun _ node complete ->
        node_complete_typing node ;
        !logger.debug "node %S:\n\tinput type: %a\n\toutput type: %a\n\n"
          node.name
          print_temp_tup_typ node.in_type
          print_temp_tup_typ node.out_type ;
        complete && node_is_complete node
      ) graph.nodes true in
  (* TODO: better reporting *)
  if not complete then raise (CompilationError "Cannot complete typing") ;
  Hashtbl.iter (fun _ node ->
      try compile_node node
      with Failure m ->
        raise (Failure ("While compiling "^ node.name ^": "^ m))
    ) graph.nodes ;
  save_graph conf graph

let graph_is_compiled graph =
  Hashtbl.fold (fun _ node compiled ->
      compiled && node.command <> None
    ) graph.nodes true

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
  match fork () with
  | 0 -> execve cmd args env
  | pid -> pid

let run conf graph =
  if not (graph_is_compiled graph) then
    raise (CompilationError "Cannot run if not compiled") ;
  (* For now each node creates its own output ringbuf itself but we still have
   * to set the names so that we can pass it to its children. *)
  Hashtbl.iter (fun _ node ->
      let command = Option.get node.command in
      let rb_out_name_of node = "/tmp/ringbuf_"^ node.name ^"_out"
      in
      let rb_in =
        match node.parents with
        | par::_ -> [ "input_ringbuf="^ rb_out_name_of par ]
        | [] -> []
      and rb_out =
        match node.children with
        | _::_ -> [ "output_ringbuf="^ rb_out_name_of node ]
        | [] -> [] in
      let env = rb_in @ rb_out |> Array.of_list in
      node.pid <- Some (run_background command [||] env) ;
      save_graph conf graph
    ) graph.nodes
