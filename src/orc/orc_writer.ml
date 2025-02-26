(* Small program to test the ORC writing facility:
 * Requires the string representation of a ramen type as a command line
 * argument, then writes and compiles an ORC writer for that format, then
 * reads from stdin string representation of ramen values and write them,
 * until EOF when it exits (C++ OrcHandler being deleted and therefore the
 * ORC file flushed). *)
open Batteries
open RamenHelpers
open RamenLog
module T = RamenTypes
module N = RamenName
module C = RamenConf
module Orc = RamenOrc
module Files = RamenFiles

let main =
  init_logger Debug ;
  let exec_file = N.path (Sys.argv.(1)) in
  let ramen_type = Sys.argv.(2) in
  let orc_write_func = "orc_write"
  and orc_read_func = "orc_read" in
  let rtyp = PPP.of_string_exc T.t_ppp_ocaml ramen_type in
  RamenOCamlCompiler.use_external_compiler := false ;
  let bundle_dir =
    N.path (Sys.getenv_opt "RAMEN_LIBS" |? "./bundle") in
  let site = N.site "test" in
  let conf = C.make_conf ~debug:true ~bundle_dir ~site (N.path "") in
  let cc_dst, schema =
    RamenCompiler.orc_codec conf orc_write_func orc_read_func
                            (N.path "orc_writer_") rtyp in
  (*
   * Now the ML side:
   *)
  let ml_obj_name =
    N.path (Filename.temp_file "orc_writer_" ".cmx") |>
    RamenOCamlCompiler.make_valid_for_module in
  let keep_temp_files = true in
  let reuse_prev_files = false in
  let ml_src_file =
    RamenOCamlCompiler.with_code_file_for ml_obj_name reuse_prev_files (fun oc ->
      let p fmt = Printf.fprintf oc (fmt^^"\n") in
      p "open Batteries" ;
      p "open Stdint" ;
      p "open RamenHelpers" ;
      p "open RamenNullable" ;
      p "open RamenLog" ;
      p "" ;
      p "let value_of_string str =" ;
      p "  check_parse_all str (" ;
      let emit_is_null fins str_var offs_var oc =
        Printf.fprintf oc
          "if looks_like_null ~offs:%s %s &&
            string_is_term %a %s (%s + 4) then \
         true, %s + 4 else false, %s"
        offs_var str_var
        (List.print char_print_quoted) fins str_var offs_var
        offs_var offs_var in
      CodeGen_OCaml.emit_value_of_string 2 rtyp "str" "0" emit_is_null [] true oc ;
      p "  )" ;
      p "" ;
      p "let string_of_value v =" ;
      CodeGen_OCaml.emit_string_of_value 1 rtyp "v" oc ;
      p "" ;
      p "(* A handler to be passed to the function generated by" ;
      p "   emit_write_value: *)" ;
      p "type handler" ;
      p "" ;
      p "external orc_write : handler -> %a -> float -> float -> unit = %S"
        CodeGen_OCaml.otype_of_type rtyp
        orc_write_func ;
      p "external orc_read : string -> int -> (%a -> unit) -> (int * int) = %S"
        CodeGen_OCaml.otype_of_type rtyp
        orc_read_func ;
      (* Destructor do not seems to be called when the OCaml program exits: *)
      p "external orc_close : handler -> unit = \"orc_handler_close\"" ;
      p "" ;
      p "(* Parameters: schema * path * index * row per batch * batches per file * archive *)" ;
      p "external orc_make_handler : string -> string -> bool -> int -> int -> bool -> handler =" ;
      p "  \"orc_handler_create_bytecode_lol\" \"orc_handler_create\"" ;
      p "" ;
      p "let main =" ;
      p "  let syntax () =" ;
      p "    !logger.error \"%%s [read|write] file.orc\" Sys.argv.(0) ;" ;
      p "    exit 1 in" ;
      p "  let batch_size = 1000 and num_batches = 100 in" ;
      p "  if Array.length Sys.argv <> 3 then syntax () ;" ;
      p "  let orc_fname = Sys.argv.(2) in" ;
      p "  match String.lowercase_ascii Sys.argv.(1) with" ;
      p "  | \"read\" | \"r\" ->" ;
      p "      let cb x =" ;
      p "        Printf.printf \"%%s\\n\" (string_of_value x) in" ;
      p "      let lines, errs = orc_read orc_fname batch_size cb in" ;
      p "      (if errs > 0 then !logger.error else !logger.debug)" ;
      p "        \"Read %%d lines (%%d errors)\" lines errs" ;
      p "  | \"write\" | \"w\" ->" ;
      p "      let handler =" ;
      p "        orc_make_handler %S orc_fname false batch_size num_batches false in"
        schema ;
      p "      (try forever (fun () ->" ;
      p "            let tuple = read_line () |> value_of_string in" ;
      p "            orc_write handler tuple 0. 0." ;
      p "          ) ()" ;
      p "      with End_of_file ->" ;
      p "        !logger.info \"Exiting...\" ;" ;
      p "        orc_close handler)" ;
      p "  | _ -> syntax ()" ;
  ) in
  !logger.info "Generated OCaml support module in %a"
    N.path_print ml_src_file ;
  (*
   * Link!
   *)
  let obj_files = [ cc_dst ] in
  RamenOCamlCompiler.link conf ~keep_temp_files ~what:"ORC writer"
                          ~obj_files ~src_file:ml_src_file ~exec_file
