(* Yoann Padioleau
 *
 * Copyright (C) 2010 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

open Common

module Ast = Ast_cpp

module Db = Database_code

module HC = Highlight_code

module T = Parser_cpp

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let mk_entity ~root ~hcomplete_name_of_info info categ =

  let s = Ast.str_of_info info in
  (*pr2 (spf "mk_entity %s" s);*)

  let l = Ast.line_of_info info in
  let c = Ast.col_of_info info in
  
  let name = s in
  let fullname = 
    try Hashtbl.find hcomplete_name_of_info info +> snd
    with Not_found -> ""
  in
              
  { Database_code.
    e_name = name;
    e_fullname = 
      if fullname <> name then fullname else "";
    e_file = 
      Ast.file_of_info info +> 
        Common.filename_without_leading_path root;
    e_pos = { Common.l = l; Common.c = c };
    e_kind = Database_code.entity_kind_of_highlight_category categ;

    (* filled in step 2 *)
    e_number_external_users = 0;
    (* TODO *)
    e_good_examples_of_use = [];
  }


(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let compute_database ?(verbose=false) files_or_dirs = 


  (* when we want to merge this database with the db of another language
   * like PHP, the other database may use realpath for the path of the files
   * so we want to behave the same.
   *)
  let files_or_dirs = files_or_dirs +> List.map Common.realpath in
  let root = Common.common_prefix_of_files_or_dirs files_or_dirs in
  pr2 (spf "generating C/C++ db_light with root = %s" root);

  let files = Lib_parsing_cpp.find_cpp_files_of_dir_or_files files_or_dirs in
  let dirs = files +> List.map Filename.dirname +> Common.uniq_eff in

  (* step1: collecting definitions *)
  let (hdefs: (string, Db.entity) Hashtbl.t) = Hashtbl.create 1001 in

  let (hdefs_pos: (Ast.info, bool) Hashtbl.t) = Hashtbl.create 1001 in

  files +> List.iter (fun file ->
    if verbose then pr2 (spf "PHASE 1: %s" file);

    let (ast2, _stat) = Parse_cpp.parse file in

    let hcomplete_name_of_info = 
      (*Class_js.extract_complete_name_of_info ast *)
      Hashtbl.create 101
    in

    ast2 +> List.iter (fun (ast, (_str, toks)) ->
      let prefs = Highlight_code.default_highlighter_preferences in

      Highlight_cpp.visit_toplevel 
        ~tag_hook:(fun info categ -> 
          match categ with
          | HC.Function (HC.Def2 _) 
          | HC.Global (HC.Def2 _)
          | HC.Class (HC.Def2 _) 
          | HC.Method (HC.Def2 _) 
          | HC.Field (HC.Def2 _) 
          | HC.MacroVar (HC.Def2 _) 
          | HC.Macro (HC.Def2 _) 
            ->
              Hashtbl.add hdefs_pos info true;
              let e = mk_entity ~root ~hcomplete_name_of_info 
                info categ 
              in
              Hashtbl.add hdefs e.Db.e_name e;
          | _ -> ()
        )
        prefs
        (ast, toks)
      ;
    );
  );

  (* step2: collecting uses *)
  files +> List.iter (fun file ->
    if verbose 
    then pr2 (spf "PHASE 2: %s" file);

    let (ast2, _stat) = Parse_cpp.parse file in

    ast2 +> List.iter (fun (ast, (_str, toks)) ->
      let prefs = Highlight_code.default_highlighter_preferences in

      Highlight_cpp.visit_toplevel 
        ~tag_hook:(fun info categ -> 
          match categ with
          | HC.Function (HC.Use2 _) 
          | HC.StructName (HC.Use)

          | HC.Field (HC.Use2 _)
          | HC.Macro (HC.Use2 _)
          | HC.MacroVar (HC.Use2 _)
            ->
              let s = Ast.str_of_info info in
              Hashtbl.find_all hdefs s +> List.iter (fun entity ->
                let file_entity = entity.Db.e_file in
                (* todo: check corresponding entity_kind ? *)
                if file_entity <> file
                then begin
                  entity.Db.e_number_external_users <-
                    entity.Db.e_number_external_users + 1;
                end
              );

          | _ -> ()
        )
        prefs
        (ast, toks)
      ;
    );
    ()
  );

  (* step3: adding cross reference information *)
  let entities_arr = 
    Common.hash_to_list hdefs +> List.map snd +> Array.of_list
  in
  Db.adjust_method_or_field_external_users entities_arr;

  let dirs = dirs +> List.map (fun s -> 
    Common.filename_without_leading_path root s) in
  let dirs = Db.alldirs_and_parent_dirs_of_relative_dirs dirs in

  { Db.
    root = root;

    dirs = dirs +> List.map (fun d -> 
      d
      , 0); (* TODO *)
    files = files +> List.map (fun f -> 
      Common.filename_without_leading_path root f
      , 0); (* TODO *)

    entities = entities_arr;
  }
