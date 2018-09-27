open Debug_adapter_protocol
open Debug_protocol
open Debug_protocol_ex
open Signatures

module Make (Args : sig
    val rpc : Rpc.t
    val replace_agent : (module AGENT) -> unit
    val init_args : Initialize_command.Request.Arguments.t
    val caps : Capabilities.t
    val launch_args : Launch_command.Request.Arguments.t
    val proc : Agent_launched.launched_process
    val symbols : Symbols.t
    val conn : Debug_conn.t
    val pid : int
    val source_by_modname : (string, Source.t) Hashtbl.t
  end) = struct

  open Args

  module Ident_map = BatMap.Make (Ident)
  module Remote_value = Debug_conn.Remote_value

  type variable = {
    var_handle : int;
    var_name : string;
    var_value : string;
    var_vars : variable list Lwt.t Lazy.t option;
  }

  let stack = ref ([||] : (int * Instruct.debug_event) array)
  let site_id = ref 0
  let var_by_handle = (Hashtbl.create 0 : (int, variable) Hashtbl.t)
  let make_handle = 
    let next_handle = ref 1 in
    fun () ->
      let id = !next_handle in
      incr next_handle;
      id

  let walk_stack fn =
    let%lwt backup_stack_pos, _ = Debug_conn.get_frame conn in
    let wrap () =
      let%lwt stack_pos, pc = Debug_conn.initial_frame conn in
      if%lwt Lwt.return (stack_pos <> -1) then (
        let ev = Symbols.event_at_pc symbols pc in
        if%lwt fn (stack_pos, ev) then
          let rec walk_up (ev : Instruct.debug_event) =
            match%lwt Debug_conn.up_frame conn ev.ev_stacksize with
            | Some (stack_pos, pc) -> (
                match Symbols.event_at_pc symbols pc with
                | exception Not_found -> Lwt.return_unit
                | ev -> (
                    if%lwt fn (stack_pos, ev) then (
                      walk_up ev
                    )
                  )
              )
            | None -> Lwt.return_unit
          in walk_up ev
      )
    in
    (wrap ())[%finally Debug_conn.set_frame conn backup_stack_pos]

  let get_frames limit =
    let frames = ref [] in
    let count = ref 0 in
    walk_stack (fun (stack_pos, ev) ->
      incr count;
      frames := (stack_pos, ev) :: !frames;
      Lwt.return (
        match limit with
        | Some limit -> !count < limit
        | None -> true
      )
    );%lwt
    Lwt.return (!frames |> List.rev |> Array.of_list)

  let report ((rep : Debug_conn.report), guided) =
    let%lwt frames = get_frames None in
    stack := frames;
    incr site_id;
    if guided = `No_guide && rep.rep_type = Exited then (
      Rpc.emit_event rpc (module Terminated_event) { restart = `Assoc [] }
    ) else (
      let reason = match guided, rep.rep_type with
        | `Step, _ -> "step"
        | `No_guide, Event -> "step"
        | `No_guide, Trap_barrier -> "step"
        | `No_guide, Breakpoint -> "breakpoint"
        | `No_guide, Uncaught_exc -> "exception"
        | `No_guide, Exited -> assert false
      in
      Rpc.emit_event rpc (module Stopped_event) {
        reason;
        description = None;
        thread_id = Some 0;
        preserve_focus_hint = false;
        text = None;
        all_threads_stopped = true;
      }
    )

  let loaded_sources_command _ = 
    Lwt.return_ok Loaded_sources_command.Response.Body.{
      sources = BatHashtbl.values source_by_modname |> BatList.of_enum
    }

  let source_command _ = assert%lwt false

  let threads_command _ = 
    Lwt.return_ok Threads_command.Response.Body.{
      threads = [
        Thread.({
          id = 0;
          name = "main";
        })
      ]
    }

  let stack_trace_command _ = 
    let stack_frames =
      !stack
      |> Array.to_list
      |> List.mapi (fun i (_, ev) ->
        let line, column, end_line, end_column =
          if i = 0 then (
            let line, column = Symbols.line_column_of_event ev in
            line, column, None, None
          ) else (
            let (line, column) = Symbols.line_column_of_pos ev.ev_loc.loc_start in
            let (end_line, end_column) = Symbols.line_column_of_pos ev.ev_loc.loc_end in
            line, column, Some end_line, Some end_column
          )
        in
        Stack_frame.{
          id = i;
          name = "";
          source = Some (Hashtbl.find source_by_modname ev.ev_module);
          line; column; end_line; end_column;
          module_id = None;
          presentation_hint = None;
        }
      )
    in
    Lwt.return_ok Stack_trace_command.Response.Body.{
      stack_frames;
      total_frames = None;
    }

  let with_frame idx fn = 
    let cur_idx = ref 0 in
    let ret = ref None in
    walk_stack (fun (stack_pos, ev) -> 
      let at_frame = !cur_idx = idx in
      if%lwt Lwt.return at_frame then (
        let%lwt res = fn (stack_pos, ev) in
        ret := Some res;
        Lwt.return_unit
      );%lwt
      incr cur_idx;
      Lwt.return (not at_frame)
    );%lwt
    Lwt.return (BatOption.get !ret)


  let publish_var var = 
    Hashtbl.replace var_by_handle var.var_handle var

  let make_var name value get_vars =
    let handle, vars = match get_vars with
      | None -> 0, None
      | Some get_vars -> (
          let pin_site_id = !site_id in
          let handle = make_handle () in
          handle, Some (Lazy.from_fun (fun () ->
            if pin_site_id <> !site_id 
            then Lwt.return_nil
            else get_vars ()
          ))
        )
    in { 
      var_handle = handle;
      var_name = name;
      var_value = value;
      var_vars = vars;
    }

  let make_plain_var to_string name _ _ rv =
    let%lwt obj = Remote_value.obj conn rv in 
    Lwt.return (make_var name (to_string obj) None)

  let make_unit_var = make_plain_var (fun _ -> "()")
  let make_bool_var = make_plain_var string_of_bool
  let make_int_var = make_plain_var string_of_int
  let make_float_var = make_plain_var string_of_float
  let make_char_var = make_plain_var Char.escaped
  let make_int32_var = make_plain_var Int32.to_string
  let make_int64_var = make_plain_var Int64.to_string
  let make_nativeint_var = make_plain_var Nativeint.to_string
  let make_string_var = make_plain_var (fun s -> Printf.sprintf "%S" s)
  let make_exn_var = make_plain_var Printexc.to_string

  let make_bytes_var name _ _ rv = 
    Lwt.return (make_var name "<bytes>" (Some (fun () -> 
      let%lwt obj = Remote_value.obj conn rv in 
      let buf = (obj : bytes) in
      let vars = ref [] in
      Bytes.iteri (fun i c -> 
        vars := (make_var (string_of_int i) (Printf.sprintf "%0#x" (Char.code c)) None) :: !vars;
      ) buf;
      Lwt.return (List.rev !vars)
    )))

  let var_makers = 
    let moregeneral path env ty = 
      Ctype.moregeneral env false path ty
    in
    let same_path path _ (ty : Types.type_expr) = 
      match (Ctype.repr ty).desc with
      | Tconstr (path', [], _) -> Path.same path path'
      | _ -> false
    in
    [
      moregeneral Predef.type_int, make_int_var; 
      moregeneral Predef.type_float, make_float_var; 
      moregeneral Predef.type_char, make_char_var; 
      moregeneral Predef.type_int32, make_int32_var; 
      moregeneral Predef.type_nativeint, make_nativeint_var; 
      moregeneral Predef.type_int64, make_int64_var; 
      same_path Predef.path_unit, make_unit_var;
      same_path Predef.path_bool, make_bool_var;
      same_path Predef.path_string, make_string_var;
      same_path Predef.path_bytes, make_bytes_var;
      same_path Predef.path_exn, make_exn_var;
    ]

  let find_var_maker env ty =
    List.find_opt (fun (test, _) -> test env ty) var_makers |> BatOption.map snd

  let abstract_type =
    Ctype.newty (Tconstr (Pident (Ident.create "abstract"), [], ref Types.Mnil))

  let rec make_value_var name env ty rv =
    match find_var_maker env ty with
    | Some var_maker -> var_maker name env ty rv
    | None -> (
        match (Ctype.repr ty).desc with
        | Tsubst ty | Tpoly (ty, _) -> make_value_var name env ty rv
        | Tvar _ | Tunivar _ -> Lwt.return (make_var name "<poly>" None)
        | Tarrow _ -> Lwt.return (make_var name "<fun>" None)
        | Ttuple tys -> 
          let rec build_vars vars idx tys =
            match tys with
            | [] -> Lwt.return vars
            | ty :: tys -> 
              let%lwt rv = Remote_value.field conn rv idx in
              let%lwt var = make_value_var (string_of_int idx) env ty rv in
              build_vars (var :: vars) (idx + 1) tys
          in
          Lwt.return (make_var name "<tuple>" (Some (fun () -> 
            let%lwt vars = build_vars [] 0 tys in
            Lwt.return (List.rev vars)
          )))
        | Tconstr (path, [ty_arg1], _) when Path.same path Predef.path_list ->
          let rec build_vars vars idx rv =
            if Remote_value.is_block rv then (
              let%lwt hd = Remote_value.field conn rv 0 in
              let%lwt tl = Remote_value.field conn rv 1 in
              let%lwt var = make_value_var (string_of_int idx) env ty_arg1 hd in
              build_vars (var :: vars) (idx + 1) tl
            ) else Lwt.return vars
          in
          Lwt.return (make_var name "<list>" (Some (fun () -> 
            let%lwt vars = build_vars [] 0 rv in
            Lwt.return (List.rev vars)
          )))
        | Tconstr (path, [ty_arg1], _) when Path.same path Predef.path_array ->
          let%lwt length = Remote_value.size conn rv in
          let rec build_vars vars idx =
            if idx < length then (
              let%lwt fld_rv = Remote_value.field conn rv idx in
              let%lwt fld_var = make_value_var (string_of_int idx) env ty_arg1 fld_rv in
              build_vars (fld_var :: vars) (idx + 1)
            ) else Lwt.return vars
          in
          Lwt.return (make_var name "<array>" (Some (fun () -> 
            let%lwt vars = build_vars [] 0 in
            Lwt.return (List.rev vars)
          )))
        | Tconstr (path, [ty_arg1], _) when Path.same path Predef.path_lazy_t ->
          let%lwt tag = Remote_value.tag conn rv in
          if tag = Obj.lazy_tag then Lwt.return (make_var name "<lazy>" None)
          else (
            let%lwt forced_rv = 
              if tag = Obj.forward_tag 
              then Remote_value.field conn rv 0
              else Lwt.return rv
            in
            make_value_var name env ty_arg1 forced_rv
          )
        | Tconstr(path, ty_list, _) -> (
            try%lwt (
              let decl = Env.find_type path env in
              match decl with
              | {type_kind = Type_abstract; type_manifest = None; _} -> 
                Lwt.return (make_var name "<abstr>" None)
              | {type_kind = Type_abstract; type_manifest = Some body; _} -> (
                  let ty = 
                    try Ctype.apply env decl.type_params body ty_list
                    with Ctype.Cannot_apply -> abstract_type 
                  in
                  make_value_var name env ty rv
                )
              | {type_kind = Type_variant constr_list; type_unboxed; _} ->
                let unbx = type_unboxed.unboxed in
                let open Types in
                let%lwt tag = 
                  if unbx then Lwt.return Cstr_unboxed
                  else if Remote_value.is_block rv then 
                    let%lwt tag = Remote_value.tag conn rv in
                    Lwt.return (Cstr_block tag)
                  else
                    let%lwt obj = Remote_value.obj conn rv in
                    Lwt.return (Cstr_constant obj)
                in
                let {cd_id; cd_args; cd_res; _} = Datarepr.find_constr_by_tag tag constr_list in
                let type_params =
                  match cd_res with
                    Some t ->
                    begin match (Ctype.repr t).desc with
                        Tconstr (_,params,_) ->
                        params
                      | _ -> assert false end
                  | None -> decl.type_params
                in (
                  match cd_args with
                  | Cstr_tuple l -> (
                      let ty_args =
                        List.map (fun ty -> 
                          try Ctype.apply env type_params ty ty_list 
                          with Ctype.Cannot_apply -> abstract_type) l
                      in
                      if ty_args = [] then 
                        Lwt.return (make_var name (Ident.name cd_id) None) 
                      else if unbx then
                        Lwt.return (
                          make_var name (Ident.name cd_id) (Some (fun () -> 
                            let%lwt var = make_value_var "0" env (List.hd ty_args) rv in
                            Lwt.return [var]
                          ))
                        )
                      else 
                        let rec build_vars vars idx tys =
                          match tys with
                          | [] -> Lwt.return vars
                          | ty :: tys -> 
                            let%lwt rv = Remote_value.field conn rv idx in
                            let%lwt var = make_value_var (string_of_int idx) env ty rv in
                            build_vars (var :: vars) (idx + 1) tys
                        in
                        Lwt.return (make_var name (Ident.name cd_id) (Some (fun () -> 
                          let%lwt vars = build_vars [] 0 ty_args in
                          Lwt.return (List.rev vars)
                        )))
                    )
                  | _ -> Lwt.return (make_var name "…" None)
                )
              | {type_kind = Type_record(lbl_list, rep); _} ->
                let type_params = decl.type_params in
                let unbx =
                  match rep with 
                  | Record_unboxed _ -> true 
                  | _ -> false
                in
                if unbx then 
                  Lwt.return (make_var name "<record>" (Some (fun () -> 
                    let lbl = List.hd lbl_list in
                    let ty_arg =
                      try
                        Ctype.apply env type_params lbl.ld_type
                          ty_list
                      with
                        Ctype.Cannot_apply -> abstract_type 
                    in
                    let%lwt fld = make_value_var (Ident.name lbl.ld_id) env ty_arg rv in
                    Lwt.return [fld]
                  )))
                else
                  let rec build_vars vars pos lbl_list  =
                    match lbl_list with
                    | {Types.ld_id; ld_type; _} :: lbl_list -> (
                        let ty_arg =
                          try
                            Ctype.apply env type_params ld_type
                              ty_list
                          with
                            Ctype.Cannot_apply -> abstract_type 
                        in
                        let%lwt tag = Remote_value.tag conn rv in
                        let%lwt rv = 
                          if tag = Obj.double_array_tag then
                            let%lwt fld = Remote_value.double_field conn rv pos in
                            Lwt.return (Remote_value.repr fld)
                          else
                            Remote_value.field conn rv pos
                        in
                        let%lwt var = make_value_var (Ident.name ld_id) env ty_arg rv in
                        build_vars (var :: vars) (pos + 1) lbl_list
                      )
                    | [] -> Lwt.return vars
                  in
                  let pos =
                    match rep with
                    | Record_extension -> 1
                    | _ -> 0
                  in
                  Lwt.return (make_var name "<record>" (Some (fun () -> 
                    let%lwt vars = build_vars [] pos lbl_list in
                    Lwt.return (List.rev vars)
                  )))
              | _ -> Lwt.return (make_var name "…" None)
            ) with 
            | Not_found -> 
              Lwt.return (make_var name "<abstr>" None)
            | Datarepr.Constr_not_found -> 
              Lwt.return (make_var name "<unknown constructor>" None)
          )
        | _ -> Lwt.return (make_var name "…" None)
      )

  let make_scope_var frame_idx kind =
    let name = match kind with
      | `Stack -> "stack"
      | `Heap -> "heap"
    in
    make_var name "" (Some (fun () -> 
      with_frame frame_idx (fun (_, ev) -> 
        let env = Envaux.env_from_summary ev.ev_typenv ev.ev_typsubst in
        let tbl = match kind with `Stack -> ev.ev_compenv.ce_stack | `Heap -> ev.ev_compenv.ce_heap in
        let get_remote_value pos =
          match kind with
          | `Stack -> Remote_value.local conn (ev.ev_stacksize - pos)
          | `Heap -> Remote_value.from_environment conn pos
        in
        Ident.fold_name Ident_map.add tbl Ident_map.empty
        |> Ident_map.bindings
        |> Lwt_list.filter_map_s (fun (ident, _) ->
          let name = ident.Ident.name in
          match Env.lookup_value (Longident.Lident name) env with
          | exception Not_found -> Lwt.return_none
          | (_, valdesc) ->
            let ty = Ctype.correct_levels valdesc.Types.val_type in
            let pos = Ident.find_same ident tbl in
            let%lwt rv = get_remote_value pos in
            let%lwt var = make_value_var name env ty rv in
            Lwt.return_some var
        )
      )
    ))

  let scopes_command (args : Scopes_command.Request.Arguments.t) = 
    let make_scope_by_var var =  Scope.(
      make ~name:var.var_name ~variables_reference:var.var_handle ~expensive:true ()
    ) in
    let scope_vars = [
      make_scope_var args.frame_id `Stack;
      make_scope_var args.frame_id `Heap;
    ] in
    List.iter publish_var scope_vars;
    Lwt.return_ok Scopes_command.Response.Body.({
      scopes = List.map make_scope_by_var scope_vars
    })

  let variables_command (args : Variables_command.Request.Arguments.t) = 
    let var = Hashtbl.find var_by_handle args.variables_reference in
    let%lwt vars = Lazy.force (BatOption.get var.var_vars) in
    List.iter publish_var vars;
    let variables = vars |> List.map (fun var -> Variable.(
      make ~name:var.var_name ~value:var.var_value ~variables_reference:var.var_handle ()
    )) in
    Lwt.return_ok Variables_command.Response.Body.{ variables }

  let set_variable_command _ = Lwt.return_error ("Not supported", None)
  let set_expression_command _ = Lwt.return_error ("Not supported", None)
  let completions_command _ = Lwt.return_error ("Not supported", None)
end
