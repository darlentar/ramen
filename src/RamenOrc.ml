(* ORC types and mapping with Ramen types.
 *
 * No comprehensive doc for ORC but see:
 * http://hadooptutorial.info/hive-data-types-examples/
 *
 * Note: in all this private fields are not taken into account.
 * This is because it is easier to deal with them in the ocaml code than the
 * C++ code (especially reading them back as `any cheap value`). This must
 * therefore be wrapped in an OCaml generated code that remove/add them.
 *)
open Batteries
open RamenHelpers
module T = RamenTypes
module N = RamenName

let debug = false

(*$inject
   module T = RamenTypes
*)

type t =
  | Boolean
  | TinyInt (* 8 bits, signed *)
  | SmallInt (* 16 bits, signed *)
  | Int (* 32 bits, signed *)
  | BigInt (*64 bits, signed *)
  | Float
  | Double
  | TimeStamp
  | Date
  | String
  | Binary
  (* It seems that precision is the number of digits and scale the number of
   * those after the fractional dot: *)
  | Decimal of { precision : int ; scale : int }
  | VarChar of int (* max length *)
  | Char of int (* also max length *)
  (* Compound types: *)
  | Array of t
  | UnionType of t array
  | Struct of (string * t) array
  | Map of (t * t)

(* Orc types string format use colon as a separator, and liborc accepts only
 * alphanums and underscores, then optionally a dot followed by some
 * alphabetic (no nums). Otherwise it will throw:
 * std::logic_error: Unrecognized character.
 * Better replace everything that's not alphanum by an underscore: *)
let print_label oc str =
  String.map (fun c -> if is_alphanum c then c else '_') str |>
  String.print oc

(* Output the schema of the type.
 * Similar to https://github.com/apache/orc/blob/529bfcedc10402c58d9269c2c95919cba6c4b93f/c%2B%2B/src/TypeImpl.cc#L157
 * in a more civilised language. *)
let rec print oc = function
  | Boolean -> String.print oc "boolean"
  | TinyInt -> String.print oc "tinyint"
  | SmallInt -> String.print oc "smallint"
  | Int -> String.print oc "int"
  | BigInt -> String.print oc "bigint"
  | Double -> String.print oc "double"
  | Float -> String.print oc "float"
  | TimeStamp -> String.print oc "timestamp"
  | Date -> String.print oc "date"
  | String -> String.print oc "string"
  | Binary -> String.print oc "binary"
  | Decimal { precision ; scale } ->
      Printf.fprintf oc "decimal(%d,%d)" precision scale
  | VarChar len ->
      Printf.fprintf oc "varchar(%d)" len
  | Char len ->
      Printf.fprintf oc "char(%d)" len
  | Array t ->
      Printf.fprintf oc "array<%a>" print t
  | UnionType ts ->
      Printf.fprintf oc "uniontype<%a>"
        (Array.print ~first:"" ~last:"" ~sep:"," print) ts
  | Struct kts ->
      Printf.fprintf oc "struct<%a>"
        (Array.print ~first:"" ~last:"" ~sep:","
          (Tuple2.print ~first:"" ~last:"" ~sep:":" print_label print)) kts
  | Map (k, v) ->
      Printf.fprintf oc "map<%a,%a>" print k print v

(*$= print & ~printer:BatPervasives.identity
  "double" (BatIO.to_string print Double)
  "struct<a_map:map<smallint,char(5)>,a_list:array<decimal(3,1)>>" \
    (BatIO.to_string print \
      (Struct [| "a_map", Map (SmallInt, Char 5); \
                 "a_list", Array (Decimal { precision=3; scale=1 }) |]))
 *)

(* Generate the ORC type corresponding to a Ramen type. Note that for ORC
 * every value can be NULL so there is no nullability in the type.
 * In the other way around that is not a conversion but a cast.
 * ORC has no unsigned integer types. We could upgrade all unsigned types
 * to the next bigger signed type, but that would not be very efficient for
 * storing values. Also, we could not do this for uint128 as the largest
 * Decimal supported must fit an int128.
 * Therefore, we encode unsigned as signed. This is no problem when Ramen
 * read them back, as it always know the exact type, but could cause some
 * issues when importing the files in Hive etc. *)
let rec of_structure = function
  | T.TEmpty | T.TAny -> assert false
  (* We use TNum to denotes a normal OCaml integer. We use some to encode
   * Cidr masks for instance. *)
  | T.TNum -> Int
  | T.TChar -> TinyInt
  | T.TFloat -> Double
  | T.TString -> String
  | T.TBool -> Boolean
  | T.TI8 | T.TU8 -> TinyInt
  | T.TI16 | T.TU16 -> SmallInt
  | T.TI32 | T.TU32 -> Int
  | T.TI64 | T.TU64 -> BigInt
  (* 128 bits would be 39 digits, but liborc would fail on 39.
   * It will happily store 128 bits inside its 128 bits value though.
   * Not all other ORC readers might perform that well unfortunately. *)
  | T.TI128 | T.TU128 -> Decimal { precision = 38 ; scale = 0 }
  | T.TEth -> BigInt
  (* We store IPv4/6 in the smallest numeric type that fits.
   * For TIp, we use a union. *)
  | T.TIpv4 -> Int
  | T.TIpv6 -> Decimal { precision = 38 ; scale = 0 }
  | T.TIp ->
      UnionType [| of_structure T.TIpv4 ; of_structure T.TIpv6 |]
  (* For CIDR we use a structure of an IP and a mask: *)
  | T.TCidrv4 ->
      Struct [| "ip", of_structure T.TIpv4 ; "mask", TinyInt |]
  | T.TCidrv6 ->
      Struct [| "ip", of_structure T.TIpv6 ; "mask", TinyInt |]
  | T.TCidr ->
      UnionType [| of_structure T.TCidrv4 ; of_structure T.TCidrv6 |]
  | T.TTuple ts ->
      (* There are no tuple in ORC so we use a Struct: *)
      Struct (
        Array.mapi (fun i t ->
          string_of_int i, of_structure t.T.structure) ts)
  | T.TVec (_, t) | T.TList t ->
      Array (of_structure t.T.structure)
  | T.TRecord kts ->
      (* Keep the order of definition but ignore private fields
       * that are going to be skipped over when serializing.
       * (TODO: also ignore shadowed fields): *)
      Struct (
        Array.filter_map (fun (k, t) ->
          if N.(is_private (field k)) then None else
          Some (k, of_structure t.T.structure)
        ) kts)

(*$= of_structure & ~printer:BatPervasives.identity
  "struct<ip:int,mask:tinyint>" \
    (BatIO.to_string print (of_structure T.TCidrv4))
  "struct<pas_glop:int>" \
    (BatIO.to_string print (of_structure \
      (T.TRecord [| "pas:glop", T.make T.TI32 |])))
*)

(* Until we have a single output value, mimic outputting a record: *)
let of_tuple typ =
  Struct (
    List.enum typ /@
    (fun ft ->
      (ft.RamenTuple.name :> string),
      of_structure ft.typ.T.structure) |>
   Array.of_enum)

(* Map ORC types into the C++ class used to batch this type: *)
let batch_type_of = function
  | Boolean | TinyInt | SmallInt | Int | BigInt | Date -> "LongVectorBatch"
  | Float | Double -> "DoubleVectorBatch"
  | TimeStamp -> "TimestampVectorBatch"
  | String | Binary | VarChar _ | Char _ -> "StringVectorBatch"
  | Decimal { precision ; _ } ->
      if precision <= 18 then "Decimal64VectorBatch"
      else "Decimal128VectorBatch"
  | Struct _ -> "StructVectorBatch"
  | Array _ -> "ListVectorBatch"
  | UnionType _ -> "UnionVectorBatch"
  | Map _ -> "MapVectorBatch"

let batch_type_of_structure = batch_type_of % of_structure

let gensym =
  let seq = ref 0 in
  fun pref ->
    incr seq ;
    pref ^"_"^ string_of_int !seq

(*
 * Writing ORC files
 *)

(* Convert from OCaml value to a corresponding C++ value suitable for ORC: *)
let emit_conv_of_ocaml st val_var oc =
  let p fmt = Printf.fprintf oc fmt in
  let scaled_int s =
    (* Signed small integers are shifted all the way to the left: *)
    p "(((intnat)Long_val(%s)) >> \
        (CHAR_BIT * sizeof(intnat) - %d - 1))"
      val_var s in
  match st with
  | T.TEmpty | T.TAny ->
      assert false
  | T.TBool ->
      p "Bool_val(%s)" val_var
  | T.TChar ->
      p "Long_val(%s)" val_var
  | T.TNum | T.TU8 | T.TU16 ->
      p "Long_val(%s)" val_var
  | T.TU32 | T.TIpv4 ->
      (* Assuming the custom val is suitably aligned: *)
      p "(*(uint32_t*)Data_custom_val(%s))" val_var
  | T.TU64 | T.TEth ->
      p "(*(uint64_t*)Data_custom_val(%s))" val_var
  | T.TU128 | T.TIpv6 ->
      p "(*(uint128_t*)Data_custom_val(%s))" val_var
  | T.TI8 ->
      scaled_int 8
  | T.TI16 ->
      scaled_int 16
  | T.TI32 ->
      p "(*(int32_t*)Data_custom_val(%s))" val_var
  | T.TI64 ->
      p "(*(int64_t*)Data_custom_val(%s))" val_var
  | T.TI128 ->
      p "(*(int128_t*)Data_custom_val(%s))" val_var
  | T.TFloat ->
      p "Double_val(%s)" val_var
  | T.TString ->
      (* String_val return a pointer to the string, that the StringVectorBatch
       * will store. Obviously, we want it to store a non-relocatable copy and
       * then free it... FIXME *)
      (* Note: we pass the OCaml string length. the string might be actually
       * nul terminated before that, but that's not supposed to happen and
       * would not cause problems other than the string appear shorter. *)
      p "handler->keep_string(String_val(%s), caml_string_length(%s))"
        val_var val_var
  | T.TIp | T.TCidrv4 | T.TCidrv6 | T.TCidr
  | T.TTuple _ | T.TVec _ | T.TList _ | T.TRecord _ ->
      (* Compound types have no values of their own *)
      ()

(* Convert from OCaml value to a corresponding C++ value suitable for ORC
 * and write it in the vector buffer: *)
let rec emit_store_data indent vb_var i_var st val_var oc =
  let p fmt = emit oc indent fmt in
  let fld n = Printf.sprintf "Field(%s, %d)" val_var n in
  match st with
  | T.TEmpty | T.TAny
  (* Never called on recursive types (dealt with iter_scalars): *)
  | T.TTuple _ | T.TVec _ | T.TList _ | T.TRecord _ ->
      assert false
  | T.TEth | T.TIpv4 | T.TBool | T.TNum | T.TFloat
  | T.TChar | T.TI8 | T.TU8 | T.TI16 | T.TU16
  | T.TI32 | T.TU32 | T.TI64 | T.TU64 ->
      (* Most of the time we just store a single value in an array: *)
      p "%s->data[%s] = %t;" vb_var i_var (emit_conv_of_ocaml st val_var)
  | T.TI128 ->
      (* ORC Int128 is a custom thing which constructor will accept only a
       * int16_t for the low bits, or two int64_t for high and low bits.
       * Initializing from an int128_t will /silently/ cast it to a single
       * int64_t and initialize the Int128 with garbage. *)
      let tmp_var = gensym "i128" in
      p "int128_t const %s = %t;" tmp_var (emit_conv_of_ocaml st val_var) ;
      p "%s->values[%s] = Int128((int64_t)(%s >> 64), (int64_t)%s);"
        vb_var i_var tmp_var tmp_var
  | T.TU128 | T.TIpv6 ->
      let tmp_var = gensym "u128" in
      p "uint128_t const %s = %t;" tmp_var (emit_conv_of_ocaml st val_var) ;
      p "%s->values[%s] = Int128((int64_t)(%s >> 64U), (int64_t)%s);"
        vb_var i_var tmp_var tmp_var
  | T.TString ->
      p "assert(String_tag == Tag_val(%s));" val_var ;
      p "%s->data[%s] = %t;" vb_var i_var (emit_conv_of_ocaml st val_var) ;
      p "%s->length[%s] = caml_string_length(%s);" vb_var i_var val_var
  | T.TIp ->
      (* Unions: we have 2 children (0 for v4 and 1 for v6) and we have
       * to fill them independently. Then in the Union itself the [tags]
       * array that we must fill with the tag for that row, as well as
       * the [offsets] array where to put the offset in the children of
       * the current row because liborc is a bit lazy.
       * First, are we v4 or v6? *)
      let vb4 = batch_type_of_structure T.TIpv4
      and vb6 = batch_type_of_structure T.TIpv6 in
      p "if (Tag_val(%s) == 0) { /* IPv4 */" val_var ;
      let vbs = gensym "ips" in
      p "  %s *%s = dynamic_cast<%s *>(%s->children[0]);" vb4 vbs vb4 vb_var ;
      p "  %s->tags[%s] = 0;" vb_var i_var ;
      p "  %s->offsets[%s] = %s->numElements;" vb_var i_var vbs ;
      emit_store_data
        (indent + 1) vbs (vbs ^"->numElements") T.TIpv4 (fld 0) oc ;
      p "  %s->numElements++;" vbs ;
      p "} else { /* IPv6 */" ;
      p "  %s *%s = dynamic_cast<%s *>(%s->children[1]);" vb6 vbs vb6 vb_var ;
      p "  %s->tags[%s] = 1;" vb_var i_var ;
      p "  %s->offsets[%s] = %s->numElements;" vb_var i_var vbs ;
      emit_store_data
        (indent + 1) vbs (vbs ^"->numElements") T.TIpv6 (fld 0) oc ;
      p "  %s->numElements++;" vbs ;
      p "}"
  | T.TCidrv4 ->
      (* A structure of IPv4 and mask. Write each field recursively. *)
      let ip_vb = batch_type_of_structure T.TIpv4 in
      let ips = gensym "ips" and msks = gensym "msks" in
      p "%s *%s = dynamic_cast<%s *>(%s->fields[0]);" ip_vb ips ip_vb vb_var ;
      emit_store_data indent ips i_var T.TIpv4 (fld 0) oc ;
      let msk_vb = batch_type_of_structure T.TNum in
      p "%s *%s = dynamic_cast<%s *>(%s->fields[1]);" msk_vb msks msk_vb vb_var ;
      emit_store_data indent msks i_var T.TNum (fld 1) oc
  | T.TCidrv6 ->
      (* A structure of IPv6 and mask. Write each field recursively. *)
      let ip_vb = batch_type_of_structure T.TIpv6 in
      let ips = gensym "ips" and msks = gensym "msks" in
      p "%s *%s = dynamic_cast<%s *>(%s->fields[0]);" ip_vb ips ip_vb vb_var ;
      emit_store_data indent ips i_var T.TIpv6 (fld 0) oc ;
      let msk_vb = batch_type_of_structure T.TNum in
      p "%s *%s = dynamic_cast<%s *>(%s->fields[1]);" msk_vb msks msk_vb vb_var ;
      emit_store_data indent msks i_var T.TNum (fld 1) oc
  | T.TCidr ->
      (* Another union with tag 0 for v4 and tag 1 for v6: *)
      let vb4 = batch_type_of_structure T.TCidrv4
      and vb6 = batch_type_of_structure T.TCidrv6
      and vbs = gensym "vbs"
      (* Whatever the tag (v4 or v6), the values to write are the first and
       * second fields of the first field of the Cidr: *)
      and ip_var = Printf.sprintf "Field(%s, 0)" (fld 0)
      and msk_var = Printf.sprintf "Field(%s, 1)" (fld 0) in
      p "if (Tag_val(%s) == 0) { /* CIDRv4 */" val_var ;
      p "  %s *%s = dynamic_cast<%s *>(%s->children[0]);" vb4 vbs vb4 vb_var ;
      p "  %s->tags[%s] = 0;" vb_var i_var ;
      p "  %s->offsets[%s] = %s->numElements;" vb_var i_var vbs ;
      let ip_vb = batch_type_of_structure T.TIpv4 in
      let ips = gensym "ips" in
      p "  %s *%s = dynamic_cast<%s *>(%s->fields[0]);" ip_vb ips ip_vb vbs ;
      let msk_vb = batch_type_of_structure T.TNum in
      let msks = gensym "msks" in
      p "  %s *%s = dynamic_cast<%s *>(%s->fields[1]);" msk_vb msks msk_vb vbs ;
      emit_store_data
        (indent + 1) ips (vbs ^"->numElements") T.TIpv4 ip_var oc ;
      emit_store_data
        (indent + 1) msks (vbs ^"->numElements") T.TNum msk_var oc ;
      p "  %s->numElements++;" vbs ;
      p "} else { /* CIDRv6 */" ;
      p "  %s *%s = dynamic_cast<%s *>(%s->children[1]);" vb6 vbs vb6 vb_var ;
      p "  %s->tags[%s] = 1;" vb_var i_var ;
      p "  %s->offsets[%s] = %s->numElements;" vb_var i_var vbs ;
      let ip_vb = batch_type_of_structure T.TIpv6 in
      p "  %s *%s = dynamic_cast<%s *>(%s->fields[0]);" ip_vb ips ip_vb vbs ;
      let msk_vb = batch_type_of_structure T.TNum in
      p "  %s *%s = dynamic_cast<%s *>(%s->fields[1]);" msk_vb msks msk_vb vbs ;
      emit_store_data
        (indent + 1) ips (vbs ^"->numElements") T.TIpv6 ip_var oc ;
      emit_store_data
        (indent + 1) msks (vbs ^"->numElements") T.TNum msk_var oc ;
      p "  %s->numElements++;" vbs ;
      p "}"

(* From the writers we need only two functions:
 *
 * The first one to "register interest" in a ORC files writer for a given
 * ORC type. That one only need to return a handle with all appropriate
 * information but must not perform any file opening or anything, as we
 * do not know yet if anything will actually be ever written.
 *
 * And the second function required by the worker is one to write a single
 * message. That one must create the file when required, flush a batch when
 * required, close the file etc, in addition to actually converting the
 * ocaml representation of the output tuple into an ORC value and write it
 * in the many involved vector batches. *)

(* Cast [batch_var] into a vector for the given type, named vb: *)
let emit_get_vb indent vb_var rtyp batch_var oc =
  let p fmt = emit oc indent fmt in
  let btyp = batch_type_of_structure rtyp.T.structure in
  p "%s *%s = dynamic_cast<%s *>(%s);" btyp vb_var btyp batch_var

(* Write a single OCaml value [val_var] of the given RamenType into the
 * ColumnVectorBatch [batch_var]: *)
let rec emit_add_value_to_batch
          indent depth val_var batch_var i_var rtyp field_name oc =
  let p fmt = Printf.fprintf oc ("%s"^^fmt^^"\n") (indent_of indent) in
  let add_to_batch indent rtyp val_var =
    let p fmt = Printf.fprintf oc ("%s"^^fmt^^"\n") (indent_of indent) in
    let iter_struct tuple_with_1_element kts =
      Enum.fold (fun (oi, xi) (k, t) ->
        (* Skip over private fields.
         * TODO: also skip over shadowed fields! *)
        if N.(is_private (field k)) then
          oi, xi + 1
        else (
          p "{ /* Structure/Tuple item %s */" k ;
          let btyp = batch_type_of_structure t.T.structure in
          let arr_item = gensym "arr_item" in
          p "  %s *%s = dynamic_cast<%s *>(%s->fields[%d]);"
            btyp arr_item btyp batch_var oi ;
          let val_var =
            Option.map (fun v ->
              (* OCaml has no such tuples. Value is then unboxed. *)
              if tuple_with_1_element then v
              else Printf.sprintf "Field(%s, %d)" v xi
            ) val_var
          and field_name =
            if field_name = "" then k else field_name ^"."^ k
          and i_var =
            Printf.sprintf "%s->numElements" arr_item in
          emit_add_value_to_batch
            (indent + 1) (depth + 1) val_var arr_item i_var t field_name oc ;
          p "}" ;
          oi + 1, xi + 1
        )
      ) (0, 0) kts |> ignore
    in
    match rtyp.T.structure with
    | T.TEmpty | T.TAny ->
        assert false
    | T.TBool
    | T.TChar
    | T.TU8 | T.TU16 | T.TU32 | T.TU64
    | T.TI8 | T.TI16 | T.TI32 | T.TI64
    | T.TU128 | T.TI128
    | T.TIpv4 | T.TIpv6 | T.TIp
    | T.TCidrv4 | T.TCidrv6 | T.TCidr
    | T.TNum | T.TEth | T.TFloat | T.TString ->
        Option.may (fun v ->
          p "/* Write the value for %s (of type %a) */"
            (if field_name <> "" then field_name else "root value")
            T.print_typ rtyp ;
          emit_store_data
            indent batch_var i_var rtyp.T.structure v oc
        ) val_var

    | T.TTuple ts ->
        Array.enum ts |>
        Enum.mapi (fun i t -> string_of_int i, t) |>
        iter_struct (Array.length ts = 1)
    | T.TRecord kts ->
        Array.enum kts |>
        iter_struct (Array.length kts = 1)
    | T.TList t | T.TVec (_, t) ->
        (* Regardless of [t], we treat a list as a "scalar" because
         * that's how it looks like for ORC: each new list value is
         * added to the [offsets] vector, while the list items are on
         * the side pushed to the global [elements] vector-batch. *)
        Option.may (fun v ->
          p "/* Write the values for %s (of type %a) */"
            (if field_name <> "" then field_name else "root value")
            T.print_typ t ;
          let vb = gensym "vb" in
          emit_get_vb
            indent vb t (batch_var ^"->elements.get()") oc ;
          let bi_lst = gensym "bi_lst" in
          p "uint64_t const %s = %s->numElements;" bi_lst vb ;
          (* FIXME: handle arrays of unboxed values *)
          let idx_var = gensym "idx" in
          p "unsigned %s;" idx_var ;
          p "for (%s = 0; %s < Wosize_val(%s); %s++) {"
            idx_var idx_var v idx_var ;
          let v_lst = gensym "v_lst" in
          p "  value %s = Field(%s, %s);" v_lst v idx_var ;
          emit_add_value_to_batch
            (indent + 1) 0 (Some v_lst) vb (bi_lst ^"+"^ idx_var) t
            (field_name ^".elmt") oc ;
          p "}"
        ) val_var ;

        (* Regardless of the value being NULL or not, when we have a
         * list we must initialize the offsets value. *)
        let nb_vals =
          match val_var with
          | None -> "0"
          | Some v -> Printf.sprintf "Wosize_val(%s)" v in
        p "%s->offsets[%s + 1] = %s->offsets[%s] + %s;"
          batch_var i_var batch_var i_var nb_vals ;
        if debug then (
          p "cerr << \"%s.offsets[\" << %s << \"+1]=\"" field_name i_var ;
          p "     << %s->offsets[%s + 1] << \"\\n\";" batch_var i_var)
  in
  (match val_var with
  | Some v when rtyp.T.nullable ->
      (* Only generate that code in the "not null" branches: *)
      p "if (Is_block(%s)) { /* Not null */" v ;
      (* The first non const constructor is "NotNull of ...": *)
      let non_null = gensym "non_null" in
      p "  value %s = Field(%s, 0);" non_null v ;
      let rtyp' = { rtyp with nullable = false } in
      add_to_batch (indent + 1) rtyp' (Some non_null) ;
      p "} else { /* Null */" ;
      (* liborc initializes hasNulls to false and notNull to all ones: *)
      if debug then
        p "  cerr << \"%s[\" << %s << \"] is null\\n\";"
          field_name i_var ;
      p "  %s->hasNulls = true;" batch_var ;
      p "  %s->notNull[%s] = 0;" batch_var i_var ;
      add_to_batch (indent + 1) rtyp None ;
      p "}"
  | _ ->
      if val_var = None then (
        (* A field above us was null. We have to set all subfields to null. *)
        if debug then
          p "cerr << \"%s[\" << %s << \"] is null\\n\";"
            field_name i_var ;
        p "%s->hasNulls = true;" batch_var ;
        p "%s->notNull[%s] = 0;" batch_var i_var
      ) ;
      add_to_batch indent rtyp val_var
  ) ;
  (* Also increase numElements: *)
  p "%s->numElements++;" batch_var ;
  if debug then
    p "cerr << \"%s->numElements=\" << %s->numElements << \"\\n\";"
      field_name batch_var

(* Generate an OCaml callable function named [func_name] that receives a
 * "handler" and an OCaml value of a given type [rtyp] and batch it.
 * Notice that we want the handler created with the fname and type, but
 * without creating a file nor a batch before values are actually added. *)
let emit_write_value func_name rtyp oc =
  let p fmt = emit oc 0 fmt in
  p "extern \"C\" CAMLprim value %s(" func_name ;
  p "    value hder_, value v_, value start_, value stop_)" ;
  p "{" ;
  p "  CAMLparam4(hder_, v_, start_, stop_);" ;
  p "  OrcHandler *handler = Handler_val(hder_);" ;
  p "  if (! handler->writer) handler->start_write();" ;
  emit_get_vb 1 "root" rtyp "handler->batch.get()" oc ;
  emit_add_value_to_batch
    1 0 (Some "v_") "root" "root->numElements" rtyp "" oc ;
  p "  if (root->numElements >= root->capacity) {" ;
  p "    handler->flush_batch(true);" ; (* might destroy the writer... *)
  p "    root->numElements = 0;" ;  (* ... but not the batch! *)
  p "  }" ;
  p "  // Since we survived, update this file timestamps:" ;
  p "  double start = Double_val(start_);" ;
  p "  double stop = Double_val(stop_);" ;
  p "  if (start < handler->start) handler->start = start;" ;
  p "  if (stop > handler->stop) handler->stop = stop;" ;
  p "  CAMLreturn(Val_unit);" ;
  p "}"

(* ...where flush_batch check for handle->num_batches and close the file and
 * reset handler->ri when the limit is reached.  *)

(*
 * Reading ORC files
 *)

(* Emits the code to read row [row_var] (an uint64_t) from [batch_var] (a
 * pointer to a ColumnVectorBatch), that's of RamenTypes.t [rtyp].
 * The result must be set in the (uninitialized) value [res_var].
 * [depth] is the recursion depth (ie. indent + const) that gives us the
 * name of the OCaml temp value we can use. *)
let rec emit_read_value_from_batch
    indent depth orig_batch_var row_var res_var rtyp oc =
  let p fmt = emit oc indent fmt in
  let tmp_var = "tmp" ^ string_of_int depth in
  (* Start with casting the batch to the proper type corresponding to [rtyp]
   * structure: *)
  let batch_var = gensym "batch" in
  emit_get_vb indent batch_var rtyp orig_batch_var oc ;
  let emit_read_nonnull indent =
    let p fmt = emit oc indent fmt in
    let emit_read_array t len_var =
      p "%s = caml_alloc(%s, 0);" res_var len_var ;
      let idx_var = gensym "idx" in
      p "for (uint64_t %s = 0; %s < %s; %s++) {"
        idx_var idx_var len_var idx_var ;
      let elmts_var = batch_var ^"->elements.get()" in
      let elmt_idx_var = gensym "row" in
      p "  uint64_t %s = %s->offsets[%s] + %s;"
        elmt_idx_var batch_var row_var idx_var ;
      emit_read_value_from_batch
        (indent + 1) (depth + 1) elmts_var elmt_idx_var tmp_var t oc ;
      p "  caml_modify(&Field(%s, %s), %s);" res_var idx_var tmp_var ;
      p "}"
    and emit_read_boxed ops custom_sz =
      (* See READ_BOXED in ringbuf/wrapper.c *)
      p "%s = caml_alloc_custom(&%s, %d, 0, 1);" res_var ops custom_sz ;
      p "memcpy(Data_custom_val(%s), &%s->data[%s], %d);"
        res_var batch_var row_var custom_sz
    and emit_read_unboxed_signed shift =
      (* See READ_UNBOXED_INT in ringbuf/wrapper.c, remembering than i8 and
       * i16 are normal ints shifted all the way to the left. *)
      p "%s = Val_long((intnat)%s->data[%s] << \
                       (CHAR_BIT * sizeof(intnat) - %d - 1));"
        res_var batch_var row_var shift
    and emit_read_unboxed_unsigned typ_name =
      (* Same as above, but we have to take care that liborc extended the sign
       * of our unsigned value: *)
      p "%s = Val_long((%s)%s->data[%s]);" res_var typ_name batch_var row_var
    and emit_read_struct tuple_with_1_element kts =
      (* For structs, we build an OCaml tuple in the same order
       * as that of the ORC fields; unless that's a tuple with onle 1
       * element, in which case we return directly the unboxed var. *)
      if not tuple_with_1_element then
        p "%s = caml_alloc_tuple(%s->fields.size());" res_var batch_var ;
      Enum.iteri (fun i (k, t) ->
        p "/* Field %s */" k ;
        if debug then p "cerr << \"Field %s\" << endl;" k ;
        (* Use our tmp var to store the result of reading the i-th field: *)
        let field_var = gensym "field" in
        let field_batch_var =
          Printf.sprintf "%s->fields[%d]" batch_var i in
        emit_get_vb indent field_var t field_batch_var oc ;
        emit_read_value_from_batch
          indent (depth + 1) field_var row_var tmp_var t oc ;
        if tuple_with_1_element then
          p "%s = %s; // Single element tuple is unboxed" res_var tmp_var
        else
          p "Store_field(%s, %d, %s);" res_var i tmp_var
      ) kts
    and emit_read_cidr ip_st =
      (* Cf. emit_store_data for a description of the encoding *)
      (* Result is a tuple with ip and mask: *)
      p "%s = caml_alloc(2, 0);" res_var ;
      let ips_var = Printf.sprintf "%s->fields[0]" batch_var in
      let iptyp = T.make ~nullable:false ip_st in
      (* Fetch the IP in tmp_var (when you do not understand why we cannot
       * fetch directly into Field(res, 0) address, it's better if you stay
       * away from this code) *)
      emit_read_value_from_batch
        indent (depth + 1) ips_var row_var tmp_var iptyp oc ;
      p "Store_field(%s, 0, %s);" res_var tmp_var ;
      (* Same for the mask. Notice that we declare it as TinyInt, so we have
       * to deal with liborc having sign-extended it already (same as U8 and
       * U16): *)
      let msks_var = Printf.sprintf "%s->fields[1]" batch_var in
      let msktyp = T.make ~nullable:false T.TNum in
      emit_read_value_from_batch
        indent (depth + 1) msks_var row_var tmp_var msktyp oc ;
      p "Store_field(%s, 1, Val_long((uint8_t)Long_val(%s)));" res_var tmp_var
    and emit_case tag st =
      let iptyp = T.make ~nullable:false st in
      p "  case %d: /* %a */" tag T.print_structure st ;
      p "    {" ;
      let ips_var = gensym "ips" in
      let chld_var = Printf.sprintf "%s->children[%d]" batch_var tag in
      emit_get_vb (indent + 3) ips_var iptyp chld_var oc ;
      let offs_var = Printf.sprintf "%s->offsets[%s]" batch_var row_var in
      emit_read_value_from_batch
        (indent + 3) (depth + 1) ips_var offs_var tmp_var iptyp oc ;
      p "      %s = caml_alloc_small(1, %d);" res_var tag ;
      p "      Field(%s, 0) = %s;" res_var tmp_var ;
      p "      break;" ;
      p "    }"
    and emit_default typ_name =
      p "  default: /* Invalid */" ;
      p "    {" ;
      p "      cerr << \"Invalid tag for %s: \" << %s->tags[%s] << \"\\n\";"
        typ_name batch_var row_var ;
      p "      assert(false);" ;  (* TODO: raise an OCaml exception *)
      p "      break;" ;
      p "    }"
    and emit_read_i128 signed =
      p "%s = caml_alloc_custom(&%s, 16, 0, 1);"
        res_var (if signed then "int128_ops" else "uint128_ops") ;
      let i128_var = gensym "i128" and i_var = gensym "i128" in
      p "Int128 *%s = &%s->values[%s];" i128_var batch_var row_var ;
      let std_typ = if signed then "int128_t" else "uint128_t" in
      p "%s const %s =" std_typ i_var ;
      p "  ((%s)%s->getHighBits() << 64%s) | (%s->getLowBits());"
        std_typ i128_var (if signed then "U" else "") i128_var ;
      p "memcpy(Data_custom_val(%s), &%s, 16);" res_var i_var
    in
    match rtyp.T.structure with
    | T.TEmpty | T.TAny -> assert false
    | T.TNum ->
        p "%s = Val_long(%s->data[%s]);" res_var batch_var row_var
    | T.TI8 -> emit_read_unboxed_signed 8
    | T.TI16 -> emit_read_unboxed_signed 16
    | T.TI32 -> emit_read_boxed "caml_int32_ops" 4
    | T.TI64 -> emit_read_boxed "caml_int64_ops" 8
    | T.TU8 -> emit_read_unboxed_unsigned "uint8_t"
    | T.TU16 -> emit_read_unboxed_unsigned "uint16_t"
    | T.TU32 | T.TIpv4 -> emit_read_boxed "uint32_ops" 4
    | T.TU64 | T.TEth -> emit_read_boxed "uint64_ops" 8
    | T.TI128 -> emit_read_i128 true
    | T.TU128 | T.TIpv6 -> emit_read_i128 false
    | T.TBool ->
        p "%s = Val_bool(%s->data[%s]);" res_var batch_var row_var
    | T.TChar -> emit_read_unboxed_unsigned "uint8_t"
    | T.TFloat ->
        p "%s = caml_copy_double(%s->data[%s]);" res_var batch_var row_var
    | T.TString ->
        p "%s = caml_alloc_initialized_string(%s->length[%s], %s->data[%s]);"
          res_var batch_var row_var batch_var row_var
    | T.TIp ->
        (* Cf. emit_store_data for a description of the encoding *)
        p "switch (%s->tags[%s]) {" batch_var row_var ;
        emit_case 0 T.TIpv4 ;
        emit_case 1 T.TIpv6 ;
        emit_default "TIp" ;
        p "}"
    | T.TCidrv4 ->
        emit_read_cidr T.TIpv4
    | T.TCidrv6 ->
        emit_read_cidr T.TIpv6
    | T.TCidr ->
        (* Cf. emit_store_data for a description of the encoding *)
        p "switch (%s->tags[%s]) {" batch_var row_var ;
        emit_case 0 T.TCidrv4 ;
        emit_case 1 T.TCidrv6 ;
        emit_default "TCidr" ;
        p "}"
    | T.TList t ->
        (* The [elements] field will have all list items concatenated and
         * the [offsets] data buffer at row [row_var] will have the row
         * number of the starting element.
         * We can therefore get the size of that list, alloc an array for
         * [res_var] and then read each of the value into it (recursing). *)
        let len_var = gensym "len" in
        (* It seems that the offsets of the last+1 element is set to the
         * end of the elements, so this works also for the last element: *)
        p "int64_t %s =" len_var ;
        p "  %s->offsets[%s + 1] - %s->offsets[%s];"
          batch_var row_var batch_var row_var ;
        p "if (%s < 0) {" len_var ;
        p "  cerr << \"Invalid list of \" << %s << \" entries at row \" << %s"
          len_var row_var ;
        p "       << \"(offsets are \" << %s->offsets[%s]"
          batch_var row_var ;
        p "       << \" and then \" << %s->offsets[%s + 1] << \")\\n\";"
          batch_var row_var ;
        (* TODO: raise an OCaml exception instead *)
        p "  assert(false);" ;
        p "}" ;
        emit_read_array t ("((uint64_t)"^ len_var ^")") ;
    | T.TVec (d, t) ->
        emit_read_array t (string_of_int d)
    | T.TTuple ts ->
        Array.enum ts |>
        Enum.mapi (fun i t -> string_of_int i, t) |>
        emit_read_struct (Array.length ts = 1)
    | T.TRecord kts ->
        Array.enum kts //
        (fun (k, _) -> not N.(is_private (field k))) |>
        emit_read_struct (Array.length kts = 1)
  in
  (* If the type is nullable, check the null column (we can do this even
   * before getting the proper column vector. Convention: if we have no
   * notNull buffer then that means we have no nulls (it is assumed that
   * NULLs are rare in the wild): *)
  if rtyp.T.nullable then (
    p "if (%s->hasNulls && !%s->notNull[%s]) {"
      orig_batch_var orig_batch_var row_var ;
    p "  %s = Val_long(0); /* RamenNullable.Null */" res_var ;
    p "} else {" ;
    emit_read_nonnull (indent + 1) ;
    (* We must wrap res into a NotNull block (tag 0). Since we are back
     * from emit_read_nonnull we are free to reuse our tmp value: *)
    p "  %s = caml_alloc_small(1, 0);" tmp_var ;
    p "  Field(%s, 0) = %s;" tmp_var res_var ;
    p "  %s = %s;" res_var tmp_var ;
    p "}"
  ) else (
    (* Value is not nullable *)
    emit_read_nonnull indent
  )

(* Generate an OCaml callable function named [func_name] that receive a
 * file name, a batch size and an OCaml callback and read that file, calling
 * back OCaml code with each row as an OCaml value: *)
let emit_read_values func_name rtyp oc =
  let p fmt = emit oc 0 fmt in
  let max_depth = 7 (* TODO *) in
  p "extern \"C\" value %s(value path_, value batch_sz_, value cb_)" func_name ;
  p "{" ;
  p "  CAMLparam3(path_, batch_sz_, cb_);" ;
  p "  CAMLlocal1(res);" ;
  let rec localN n =
    if n < max_depth then
      let c = min 5 (max_depth - n) in
      p "  CAMLlocal%d(%a);" c
        (Enum.print ~sep:", " (fun oc n -> Printf.fprintf oc "tmp%d" n))
          (Enum.range n ~until:(n + c - 1)) ;
      localN (n + c) in
  localN 0 ;
  p "  char const *path = String_val(path_);" ;
  p "  unsigned batch_sz = Long_val(batch_sz_);" ;
  p "  unique_ptr<InputStream> in_file = readLocalFile(path);" ;
  p "  ReaderOptions options;" ;
  p "  unique_ptr<Reader> reader = createReader(move(in_file), options);" ;
  p "  RowReaderOptions row_options;" ;
  p "  unique_ptr<RowReader> row_reader =" ;
  p "    reader->createRowReader(row_options);" ;
  p "  unique_ptr<ColumnVectorBatch> batch =" ;
  p "    row_reader->createRowBatch(batch_sz);" ;
  p "  unsigned num_lines = 0;" ;
  p "  unsigned num_errors = 0;" ;
  p "  while (row_reader->next(*batch)) {" ;
  p "    for (uint64_t row = 0; row < batch->numElements; row++) {" ;
  emit_read_value_from_batch 3 0 "batch.get()" "row" "res" rtyp oc ;
  p "      res = caml_callback_exn(cb_, res);" ;
  p "      if (Is_exception_result(res)) {" ;
  p "        res = Extract_exception(res);" ;
  p "        // Print only the first 10 such exceptions:" ;
  p "        if (num_errors++ < 10) {" ;
  p "          cerr << \"Exception while reading ORC file \" << path" ;
  p "               << \": to_be_printed\\n\";" ;
  p "        }" ;
  p "      }" ;
  p "      num_lines++;" ;
  p "    }" ;
  p "  }" ;
  p "  // Return the number of lines and errors:" ;
  p "  res = caml_alloc(2, 0);" ;
  p "  Store_field(res, 0, Val_long(num_lines));" ;
  p "  Store_field(res, 1, Val_long(num_errors));" ;
  p "  CAMLreturn(res);" ;
  p "}"

let emit_intro oc =
  let p fmt = emit oc 0 fmt in
  p "/* This code is automatically generated. Edition is futile. */" ;
  p "#include <cassert>" ;
  p "#include <orc/OrcFile.hh>" ;
  p "extern \"C\" {" ;
  p "#  include <limits.h> /* CHAR_BIT */" ;
  p "#  include <caml/mlvalues.h>" ;
  p "#  include <caml/memory.h>" ;
  p "#  include <caml/alloc.h>" ;
  p "#  include <caml/custom.h>" ;
  p "#  include <caml/callback.h>" ;
  p "extern struct custom_operations uint128_ops;" ;
  p "extern struct custom_operations uint64_ops;" ;
  p "extern struct custom_operations uint32_ops;" ;
  p "extern struct custom_operations int128_ops;" ;
  p "extern struct custom_operations caml_int64_ops;" ;
  p "extern struct custom_operations caml_int32_ops;" ;
  p "}" ;
  p "typedef __int128_t int128_t;" ;
  p "typedef __uint128_t uint128_t;" ;
  p "using namespace std;" ;
  p "using namespace orc;" ;
  p "" ;
  p "class OrcHandler {" ;
  p "    unique_ptr<Type> type;" ;
  p "    string fname;" ;
  p "    bool const with_index;" ;
  p "    unsigned const batch_size;" ;
  p "    unsigned const max_batches;" ;
  p "    unsigned num_batches;" ;
  p "    bool archive;" ;
  p "    std::vector<char> strs;" ;
  p "  public:" ;
  p "    OrcHandler(string schema, string fn, bool with_index, unsigned bsz, unsigned mb, bool arc);" ;
  p "    ~OrcHandler();" ;
  p "    void start_write();" ;
  p "    void flush_batch(bool);" ;
  p "    char *keep_string(char const *, size_t);" ;
  p "    unique_ptr<OutputStream> outStream;" ;
  p "    unique_ptr<Writer> writer;" ;
  p "    unique_ptr<ColumnVectorBatch> batch;" ;
  p "    double start, stop;" ;
  p "};" ;
  p "" ;
  p "#define Handler_val(v) (*((class OrcHandler **)Data_custom_val(v)))" ;
  p ""

let emit_outro oc =
  ignore oc
