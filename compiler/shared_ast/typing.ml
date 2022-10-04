(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Typing for the default calculus. Because of the error terms, we perform type
    inference using the classical W algorithm with union-find unification. *)

open Utils
module A = Definitions

module Any =
  Utils.Uid.Make
    (struct
      type info = unit

      let to_string _ = "any"
      let format_info fmt () = Format.fprintf fmt "any"
      let equal _ _ = true
      let compare _ _ = 0
    end)
    ()

type unionfind_typ = naked_typ Marked.pos UnionFind.elem
(** We do not reuse {!type: Shared_ast.typ} because we have to include a new
    [TAny] variant. Indeed, error terms can have any type and this has to be
    captured by the type sytem. *)

and naked_typ =
  | TLit of A.typ_lit
  | TArrow of unionfind_typ * unionfind_typ
  | TTuple of unionfind_typ list
  | TStruct of A.StructName.t
  | TEnum of A.EnumName.t
  | TOption of unionfind_typ
  | TArray of unionfind_typ
  | TAny of Any.t

let rec typ_to_ast (ty : unionfind_typ) : A.typ =
  let ty, pos = UnionFind.get (UnionFind.find ty) in
  match ty with
  | TLit l -> A.TLit l, pos
  | TTuple ts -> A.TTuple (List.map typ_to_ast ts), pos
  | TStruct s -> A.TStruct s, pos
  | TEnum e -> A.TEnum e, pos
  | TOption t -> A.TOption (typ_to_ast t), pos
  | TArrow (t1, t2) -> A.TArrow (typ_to_ast t1, typ_to_ast t2), pos
  | TAny _ -> A.TAny, pos
  | TArray t1 -> A.TArray (typ_to_ast t1), pos

let rec ast_to_typ (ty : A.typ) : unionfind_typ =
  let ty' =
    match Marked.unmark ty with
    | A.TLit l -> TLit l
    | A.TArrow (t1, t2) -> TArrow (ast_to_typ t1, ast_to_typ t2)
    | A.TTuple ts -> TTuple (List.map ast_to_typ ts)
    | A.TStruct s -> TStruct s
    | A.TEnum e -> TEnum e
    | A.TOption t -> TOption (ast_to_typ t)
    | A.TArray t -> TArray (ast_to_typ t)
    | A.TAny -> TAny (Any.fresh ())
  in
  UnionFind.make (Marked.same_mark_as ty' ty)

(** {1 Types and unification} *)

let typ_needs_parens (t : unionfind_typ) : bool =
  let t = UnionFind.get (UnionFind.find t) in
  match Marked.unmark t with TArrow _ | TArray _ -> true | _ -> false

let rec format_typ
    (ctx : A.decl_ctx)
    (fmt : Format.formatter)
    (naked_typ : unionfind_typ) : unit =
  let format_typ = format_typ ctx in
  let format_typ_with_parens (fmt : Format.formatter) (t : unionfind_typ) =
    if typ_needs_parens t then Format.fprintf fmt "(%a)" format_typ t
    else Format.fprintf fmt "%a" format_typ t
  in
  let naked_typ = UnionFind.get (UnionFind.find naked_typ) in
  match Marked.unmark naked_typ with
  | TLit l -> Format.fprintf fmt "%a" Print.tlit l
  | TTuple ts ->
    Format.fprintf fmt "@[<hov 2>(%a)]"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ *@ ")
         (fun fmt t -> Format.fprintf fmt "%a" format_typ t))
      ts
  | TStruct s -> Format.fprintf fmt "%a" A.StructName.format_t s
  | TEnum e -> Format.fprintf fmt "%a" A.EnumName.format_t e
  | TOption t ->
    Format.fprintf fmt "@[<hov 2>%a@ %s@]" format_typ_with_parens t "eoption"
  | TArrow (t1, t2) ->
    Format.fprintf fmt "@[<hov 2>%a →@ %a@]" format_typ_with_parens t1
      format_typ t2
  | TArray t1 -> (
    match Marked.unmark (UnionFind.get (UnionFind.find t1)) with
    | TAny _ -> Format.pp_print_string fmt "collection"
    | _ -> Format.fprintf fmt "@[collection@ %a@]" format_typ t1)
  | TAny _ -> Format.pp_print_string fmt "<any>"

exception Type_error of A.any_expr * unionfind_typ * unionfind_typ

type mark = { pos : Pos.t; uf : unionfind_typ }

(** Raises an error if unification cannot be performed. The position annotation
    of the second [unionfind_typ] argument is propagated (unless it is [TAny]). *)
let rec unify
    (ctx : A.decl_ctx)
    (e : ('a, 'm A.mark) A.gexpr) (* used for error context *)
    (t1 : unionfind_typ)
    (t2 : unionfind_typ) : unit =
  let unify = unify ctx in
  (* Cli.debug_format "Unifying %a and %a" (format_typ ctx) t1 (format_typ ctx)
     t2; *)
  let t1_repr = UnionFind.get (UnionFind.find t1) in
  let t2_repr = UnionFind.get (UnionFind.find t2) in
  let raise_type_error () = raise (Type_error (A.AnyExpr e, t1, t2)) in
  let () =
    match Marked.unmark t1_repr, Marked.unmark t2_repr with
    | TLit tl1, TLit tl2 -> if tl1 <> tl2 then raise_type_error ()
    | TArrow (t11, t12), TArrow (t21, t22) ->
      unify e t12 t22;
      unify e t11 t21
    | TTuple ts1, TTuple ts2 ->
      if List.length ts1 = List.length ts2 then List.iter2 (unify e) ts1 ts2
      else raise_type_error ()
    | TStruct s1, TStruct s2 ->
      if not (A.StructName.equal s1 s2) then raise_type_error ()
    | TEnum e1, TEnum e2 ->
      if not (A.EnumName.equal e1 e2) then raise_type_error ()
    | TOption t1, TOption t2 -> unify e t1 t2
    | TArray t1', TArray t2' -> unify e t1' t2'
    | TAny _, _ | _, TAny _ -> ()
    | ( ( TLit _ | TArrow _ | TTuple _ | TStruct _ | TEnum _ | TOption _
        | TArray _ ),
        _ ) ->
      raise_type_error ()
  in
  ignore
  @@ UnionFind.merge
       (fun t1 t2 -> match Marked.unmark t2 with TAny _ -> t1 | _ -> t2)
       t1 t2

let handle_type_error ctx e t1 t2 =
  (* TODO: if we get weird error messages, then it means that we should use the
     persistent version of the union-find data structure. *)
  let pos =
    match e with
    | A.AnyExpr e -> (
      match Marked.get_mark e with Untyped { pos } | Typed { pos; _ } -> pos)
  in
  let t1_repr = UnionFind.get (UnionFind.find t1) in
  let t2_repr = UnionFind.get (UnionFind.find t2) in
  let t1_pos = Marked.get_mark t1_repr in
  let t2_pos = Marked.get_mark t2_repr in
  let unformat_typ typ =
    let buf = Buffer.create 59 in
    let ppf = Format.formatter_of_buffer buf in
    (* set infinite width to disable line cuts *)
    Format.pp_set_margin ppf max_int;
    format_typ ctx ppf typ;
    Format.pp_print_flush ppf ();
    Buffer.contents buf
  in
  let t1_s fmt () =
    Cli.format_with_style [ANSITerminal.yellow] fmt (unformat_typ t1)
  in
  let t2_s fmt () =
    Cli.format_with_style [ANSITerminal.yellow] fmt (unformat_typ t2)
  in
  Errors.raise_multispanned_error
    [
      ( Some
          (Format.asprintf
             "Error coming from typechecking the following expression:"),
        pos );
      Some (Format.asprintf "Type %a coming from expression:" t1_s ()), t1_pos;
      Some (Format.asprintf "Type %a coming from expression:" t2_s ()), t2_pos;
    ]
    "Error during typechecking, incompatible types:\n%a %a\n%a %a"
    (Cli.format_with_style [ANSITerminal.blue; ANSITerminal.Bold])
    "-->" t1_s ()
    (Cli.format_with_style [ANSITerminal.blue; ANSITerminal.Bold])
    "-->" t2_s ()

let lit_type (type a) (lit : a A.glit) : naked_typ =
  match lit with
  | LBool _ -> TLit TBool
  | LInt _ -> TLit TInt
  | LRat _ -> TLit TRat
  | LMoney _ -> TLit TMoney
  | LDate _ -> TLit TDate
  | LDuration _ -> TLit TDuration
  | LUnit -> TLit TUnit
  | LEmptyError -> TAny (Any.fresh ())

(** Operators have a single type, instead of being polymorphic with constraints.
    This allows us to have a simpler type system, while we argue the syntactic
    burden of operator annotations helps the programmer visualize the type flow
    in the code. *)
let op_type (op : A.operator Marked.pos) : unionfind_typ =
  let pos = Marked.get_mark op in
  let bt = UnionFind.make (TLit TBool, pos) in
  let it = UnionFind.make (TLit TInt, pos) in
  let rt = UnionFind.make (TLit TRat, pos) in
  let mt = UnionFind.make (TLit TMoney, pos) in
  let dut = UnionFind.make (TLit TDuration, pos) in
  let dat = UnionFind.make (TLit TDate, pos) in
  let any = UnionFind.make (TAny (Any.fresh ()), pos) in
  let array_any = UnionFind.make (TArray any, pos) in
  let any2 = UnionFind.make (TAny (Any.fresh ()), pos) in
  let array_any2 = UnionFind.make (TArray any2, pos) in
  let arr x y = UnionFind.make (TArrow (x, y), pos) in
  match Marked.unmark op with
  | A.Ternop A.Fold ->
    arr (arr any2 (arr any any2)) (arr any2 (arr array_any any2))
  | A.Binop (A.And | A.Or | A.Xor) -> arr bt (arr bt bt)
  | A.Binop (A.Add KInt | A.Sub KInt | A.Mult KInt | A.Div KInt) ->
    arr it (arr it it)
  | A.Binop (A.Add KRat | A.Sub KRat | A.Mult KRat | A.Div KRat) ->
    arr rt (arr rt rt)
  | A.Binop (A.Add KMoney | A.Sub KMoney) -> arr mt (arr mt mt)
  | A.Binop (A.Add KDuration | A.Sub KDuration) -> arr dut (arr dut dut)
  | A.Binop (A.Sub KDate) -> arr dat (arr dat dut)
  | A.Binop (A.Add KDate) -> arr dat (arr dut dat)
  | A.Binop (A.Mult KDuration) -> arr dut (arr it dut)
  | A.Binop (A.Div KMoney) -> arr mt (arr mt rt)
  | A.Binop (A.Mult KMoney) -> arr mt (arr rt mt)
  | A.Binop (A.Lt KInt | A.Lte KInt | A.Gt KInt | A.Gte KInt) ->
    arr it (arr it bt)
  | A.Binop (A.Lt KRat | A.Lte KRat | A.Gt KRat | A.Gte KRat) ->
    arr rt (arr rt bt)
  | A.Binop (A.Lt KMoney | A.Lte KMoney | A.Gt KMoney | A.Gte KMoney) ->
    arr mt (arr mt bt)
  | A.Binop (A.Lt KDate | A.Lte KDate | A.Gt KDate | A.Gte KDate) ->
    arr dat (arr dat bt)
  | A.Binop (A.Lt KDuration | A.Lte KDuration | A.Gt KDuration | A.Gte KDuration)
    ->
    arr dut (arr dut bt)
  | A.Binop (A.Eq | A.Neq) -> arr any (arr any bt)
  | A.Binop A.Map -> arr (arr any any2) (arr array_any array_any2)
  | A.Binop A.Filter -> arr (arr any bt) (arr array_any array_any)
  | A.Binop A.Concat -> arr array_any (arr array_any array_any)
  | A.Unop (A.Minus KInt) -> arr it it
  | A.Unop (A.Minus KRat) -> arr rt rt
  | A.Unop (A.Minus KMoney) -> arr mt mt
  | A.Unop (A.Minus KDuration) -> arr dut dut
  | A.Unop A.Not -> arr bt bt
  | A.Unop (A.Log (A.PosRecordIfTrueBool, _)) -> arr bt bt
  | A.Unop (A.Log _) -> arr any any
  | A.Unop A.Length -> arr array_any it
  | A.Unop A.GetDay -> arr dat it
  | A.Unop A.GetMonth -> arr dat it
  | A.Unop A.GetYear -> arr dat it
  | A.Unop A.FirstDayOfMonth -> arr dat dat
  | A.Unop A.LastDayOfMonth -> arr dat dat
  | A.Unop A.RoundMoney -> arr mt mt
  | A.Unop A.RoundDecimal -> arr rt rt
  | A.Unop A.IntToRat -> arr it rt
  | A.Unop A.MoneyToRat -> arr mt rt
  | A.Unop A.RatToMoney -> arr rt mt
  | Binop (Mult KDate) | Binop (Div (KDate | KDuration)) | Unop (Minus KDate) ->
    Errors.raise_spanned_error pos "This operator is not available!"

(** {1 Double-directed typing} *)

module Env = struct
  type 'e t = {
    vars : ('e, unionfind_typ) Var.Map.t;
    scope_vars : A.typ A.ScopeVarMap.t;
    scopes : A.typ A.ScopeVarMap.t A.ScopeMap.t;
  }

  let empty =
    {
      vars = Var.Map.empty;
      scope_vars = A.ScopeVarMap.empty;
      scopes = A.ScopeMap.empty;
    }

  let get t v = Var.Map.find_opt v t.vars
  let get_scope_var t sv = A.ScopeVarMap.find_opt sv t.scope_vars

  let get_subscope_var t scope var =
    Option.bind (A.ScopeMap.find_opt scope t.scopes) (fun vmap ->
        A.ScopeVarMap.find_opt var vmap)

  let add v tau t = { t with vars = Var.Map.add v tau t.vars }
  let add_var v typ t = add v (ast_to_typ typ) t

  let add_scope_var v typ t =
    { t with scope_vars = A.ScopeVarMap.add v typ t.scope_vars }

  let add_scope scope_name vmap t =
    { t with scopes = A.ScopeMap.add scope_name vmap t.scopes }
end

let add_pos e ty = Marked.mark (Expr.pos e) ty
let ty (_, { uf; _ }) = uf
let ( let+ ) x f = Bindlib.box_apply f x
let ( and+ ) x1 x2 = Bindlib.box_pair x1 x2

(* Maps a boxing function on a list, returning a boxed list *)
let bmap (f : 'a -> 'b Bindlib.box) (es : 'a list) : 'b list Bindlib.box =
  List.fold_right
    (fun e acc ->
      let+ e' = f e and+ acc in
      e' :: acc)
    es (Bindlib.box [])

(* Likewise, but with a function of two arguments on two lists of identical
   lengths *)
let bmap2 (f : 'a -> 'b -> 'c Bindlib.box) (es : 'a list) (xs : 'b list) :
    'c list Bindlib.box =
  List.fold_right2
    (fun e x acc ->
      let+ e' = f e x and+ acc in
      e' :: acc)
    es xs (Bindlib.box [])

let box_ty e = Bindlib.unbox (Bindlib.box_apply ty e)

(** Infers the most permissive type from an expression *)
let rec typecheck_expr_bottom_up :
    type a m.
    A.decl_ctx ->
    (a, m A.mark) A.gexpr Env.t ->
    (a, m A.mark) A.gexpr ->
    (a, mark) A.gexpr A.box =
 fun ctx env e ->
  (* Cli.debug_format "Looking for type of %a" (Expr.format ~debug:true ctx)
     e; *)
  let pos_e = Expr.pos e in
  let mark e1 uf =
    let () =
      (* If the expression already has a type annotation, validate it before
         rewrite *)
      match Marked.get_mark e with
      | A.Untyped _ | A.Typed { A.ty = A.TAny, _; _ } -> ()
      | A.Typed { A.ty; _ } -> unify ctx e uf (ast_to_typ ty)
    in
    Marked.mark { uf; pos = pos_e } e1
  in
  let unionfind_make ?(pos = e) t = UnionFind.make (add_pos pos t) in
  let mark_with_uf e1 ?pos ty = mark e1 (unionfind_make ?pos ty) in
  match Marked.unmark e with
  | A.ELocation loc as e1 -> (
    let ty =
      match loc with
      | DesugaredScopeVar (v, _) | ScopelangScopeVar v ->
        Env.get_scope_var env (Marked.unmark v)
      | SubScopeVar (scope_name, _, v) ->
        Env.get_subscope_var env scope_name (Marked.unmark v)
    in
    match ty with
    | Some ty -> Bindlib.box (mark e1 (ast_to_typ ty))
    | None ->
      Errors.raise_spanned_error pos_e "Reference to %a not found"
        (Expr.format ctx) e)
  | A.EStruct (s_name, fmap) ->
    let+ fmap' =
      (* This assumes that the fields in fmap and the struct type are already
         ensured to be the same *)
      List.fold_left
        (fun fmap' (f_name, f_ty) ->
          let f_e = A.StructFieldMap.find f_name fmap in
          let+ fmap'
          and+ f_e' = typecheck_expr_top_down ctx env (ast_to_typ f_ty) f_e in
          A.StructFieldMap.add f_name f_e' fmap')
        (Bindlib.box A.StructFieldMap.empty)
        (A.StructMap.find s_name ctx.A.ctx_structs)
    in
    mark_with_uf (A.EStruct (s_name, fmap')) (TStruct s_name)
  | A.EStructAccess (e_struct, f_name, s_name) ->
    let f_ty =
      ast_to_typ (List.assoc f_name (A.StructMap.find s_name ctx.A.ctx_structs))
    in
    let+ e_struct' =
      typecheck_expr_top_down ctx env (unionfind_make (TStruct s_name)) e_struct
    in
    mark (A.EStructAccess (e_struct', f_name, s_name)) f_ty
  | A.EEnumInj (e_enum, c_name, e_name) ->
    let c_ty =
      ast_to_typ (List.assoc c_name (A.EnumMap.find e_name ctx.A.ctx_enums))
    in
    let+ e_enum' = typecheck_expr_top_down ctx env c_ty e_enum in
    mark (A.EEnumInj (e_enum', c_name, e_name)) (unionfind_make (TEnum e_name))
  | A.EMatchS (e1, e_name, cases) ->
    let cases_ty = A.EnumMap.find e_name ctx.A.ctx_enums in
    let t_ret = unionfind_make ~pos:e1 (TAny (Any.fresh ())) in
    let+ e1' =
      typecheck_expr_top_down ctx env (unionfind_make (TEnum e_name)) e1
    and+ cases' =
      A.EnumConstructorMap.fold
        (fun c_name e cases' ->
          let c_ty = List.assoc c_name cases_ty in
          let e_ty = unionfind_make ~pos:e (TArrow (ast_to_typ c_ty, t_ret)) in
          let+ cases' and+ e' = typecheck_expr_top_down ctx env e_ty e in
          A.EnumConstructorMap.add c_name e' cases')
        cases
        (Bindlib.box A.EnumConstructorMap.empty)
    in
    mark (A.EMatchS (e1', e_name, cases')) t_ret
  | A.ERaise ex ->
    Bindlib.box (mark_with_uf (A.ERaise ex) (TAny (Any.fresh ())))
  | A.ECatch (e1, ex, e2) ->
    let+ e1' = typecheck_expr_bottom_up ctx env e1
    and+ e2' = typecheck_expr_bottom_up ctx env e2 in
    let e_ty = ty e1' in
    unify ctx e e_ty (ty e2');
    mark (A.ECatch (e1', ex, e2')) e_ty
  | A.EVar v -> begin
    match Env.get env v with
    | Some t ->
      let+ v' = Bindlib.box_var (Var.translate v) in
      mark v' t
    | None ->
      Errors.raise_spanned_error (Expr.pos e)
        "Variable %s not found in the current context." (Bindlib.name_of v)
  end
  | A.ELit lit as e1 -> Bindlib.box @@ mark_with_uf e1 (lit_type lit)
  | A.ETuple (es, None) ->
    let+ es = bmap (typecheck_expr_bottom_up ctx env) es in
    mark_with_uf (A.ETuple (es, None)) (TTuple (List.map ty es))
  | A.ETuple (es, Some s_name) ->
    let tys =
      List.map
        (fun (_, ty) -> ast_to_typ ty)
        (A.StructMap.find s_name ctx.A.ctx_structs)
    in
    let+ es = bmap2 (typecheck_expr_top_down ctx env) tys es in
    mark_with_uf (A.ETuple (es, Some s_name)) (TStruct s_name)
  | A.ETupleAccess (e1, n, s, typs) -> begin
    let utyps = List.map ast_to_typ typs in
    let tuple_ty = match s with None -> TTuple utyps | Some s -> TStruct s in
    let+ e1 = typecheck_expr_top_down ctx env (unionfind_make tuple_ty) e1 in
    match List.nth_opt utyps n with
    | Some t' -> mark (A.ETupleAccess (e1, n, s, typs)) t'
    | None ->
      Errors.raise_spanned_error (Marked.get_mark e1).pos
        "Expression should have a tuple type with at least %d elements but \
         only has %d"
        n (List.length typs)
  end
  | A.EInj (e1, n, e_name, ts) ->
    let ts' = List.map ast_to_typ ts in
    let ts_n =
      match List.nth_opt ts' n with
      | Some ts_n -> ts_n
      | None ->
        Errors.raise_spanned_error (Expr.pos e)
          "Expression should have a sum type with at least %d cases but only \
           has %d"
          n (List.length ts')
    in
    let+ e1' = typecheck_expr_top_down ctx env ts_n e1 in
    mark_with_uf (A.EInj (e1', n, e_name, ts)) (TEnum e_name)
  | A.EMatch (e1, es, e_name) ->
    let enum_cases =
      List.map (fun e' -> unionfind_make ~pos:e' (TAny (Any.fresh ()))) es
    in
    let t_e1 = UnionFind.make (add_pos e1 (TEnum e_name)) in
    let t_ret = unionfind_make ~pos:e (TAny (Any.fresh ())) in
    let+ e1' = typecheck_expr_top_down ctx env t_e1 e1
    and+ es' =
      bmap2
        (fun es' enum_t ->
          typecheck_expr_top_down ctx env
            (unionfind_make ~pos:es' (TArrow (enum_t, t_ret)))
            es')
        es enum_cases
    in
    mark (A.EMatch (e1', es', e_name)) t_ret
  | A.EAbs (binder, taus) ->
    if Bindlib.mbinder_arity binder <> List.length taus then
      Errors.raise_spanned_error (Expr.pos e)
        "function has %d variables but was supplied %d types"
        (Bindlib.mbinder_arity binder)
        (List.length taus)
    else
      let xs, body = Bindlib.unmbind binder in
      let xs' = Array.map Var.translate xs in
      let xstaus = List.mapi (fun i tau -> xs.(i), ast_to_typ tau) taus in
      let env =
        List.fold_left (fun env (x, tau) -> Env.add x tau env) env xstaus
      in
      let body' = typecheck_expr_bottom_up ctx env body in
      let t_func =
        List.fold_right
          (fun (_, t_arg) acc -> unionfind_make (TArrow (t_arg, acc)))
          xstaus (box_ty body')
      in
      let+ binder' = Bindlib.bind_mvar xs' body' in
      mark (A.EAbs (binder', taus)) t_func
  | A.EApp (e1, args) ->
    let args' = bmap (typecheck_expr_bottom_up ctx env) args in
    let t_ret = unionfind_make (TAny (Any.fresh ())) in
    let t_func =
      List.fold_right
        (fun ty_arg acc -> unionfind_make (TArrow (ty_arg, acc)))
        (Bindlib.unbox (Bindlib.box_apply (List.map ty) args'))
        t_ret
    in
    let+ e1' = typecheck_expr_bottom_up ctx env e1 and+ args' in
    unify ctx e (ty e1') t_func;
    mark (A.EApp (e1', args')) t_ret
  | A.EOp op as e1 -> Bindlib.box @@ mark e1 (op_type (Marked.mark pos_e op))
  | A.EDefault (excepts, just, cons) ->
    let just' =
      typecheck_expr_top_down ctx env
        (unionfind_make ~pos:just (TLit TBool))
        just
    in
    let cons' = typecheck_expr_bottom_up ctx env cons in
    let tau = box_ty cons' in
    let+ just'
    and+ cons'
    and+ excepts' =
      bmap (fun except -> typecheck_expr_top_down ctx env tau except) excepts
    in
    mark (A.EDefault (excepts', just', cons')) tau
  | A.EIfThenElse (cond, et, ef) ->
    let cond' =
      typecheck_expr_top_down ctx env
        (unionfind_make ~pos:cond (TLit TBool))
        cond
    in
    let et' = typecheck_expr_bottom_up ctx env et in
    let tau = box_ty et' in
    let+ cond' and+ et' and+ ef' = typecheck_expr_top_down ctx env tau ef in
    mark (A.EIfThenElse (cond', et', ef')) tau
  | A.EAssert e1 ->
    let+ e1' =
      typecheck_expr_top_down ctx env (unionfind_make ~pos:e1 (TLit TBool)) e1
    in
    mark_with_uf (A.EAssert e1') (TLit TUnit)
  | A.ErrorOnEmpty e1 ->
    let+ e1' = typecheck_expr_bottom_up ctx env e1 in
    mark (A.ErrorOnEmpty e1') (ty e1')
  | A.EArray es ->
    let cell_type = unionfind_make (TAny (Any.fresh ())) in
    let+ es' =
      bmap
        (fun e1 ->
          let e1' = typecheck_expr_bottom_up ctx env e1 in
          unify ctx e1 cell_type (box_ty e1');
          e1')
        es
    in
    mark_with_uf (A.EArray es') (TArray cell_type)

(** Checks whether the expression can be typed with the provided type *)
and typecheck_expr_top_down :
    type a m.
    A.decl_ctx ->
    (a, m A.mark) A.gexpr Env.t ->
    unionfind_typ ->
    (a, m A.mark) A.gexpr ->
    (a, mark) A.gexpr Bindlib.box =
 fun ctx env tau e ->
  (* Cli.debug_format "Propagating type %a for naked_expr %a" (format_typ ctx)
     tau (Expr.format ctx) e; *)
  let pos_e = Expr.pos e in
  let () =
    (* If there already is a type annotation on the given expr, ensure it
       matches *)
    match Marked.get_mark e with
    | A.Untyped _ | A.Typed { A.ty = A.TAny, _; _ } -> ()
    | A.Typed { A.ty; _ } -> unify ctx e tau (ast_to_typ ty)
  in
  let mark e = Marked.mark { uf = tau; pos = pos_e } e in
  let unify_and_mark tau' f_e =
    unify ctx e tau' tau;
    Bindlib.box_apply (Marked.mark { uf = tau; pos = pos_e }) (f_e ())
  in
  let unionfind_make ?(pos = e) t = UnionFind.make (add_pos pos t) in
  match Marked.unmark e with
  | A.ELocation loc as e1 -> (
    let ty =
      match loc with
      | DesugaredScopeVar (v, _) | ScopelangScopeVar v ->
        Env.get_scope_var env (Marked.unmark v)
      | SubScopeVar (scope, _, v) ->
        Env.get_subscope_var env scope (Marked.unmark v)
    in
    match ty with
    | Some ty -> unify_and_mark (ast_to_typ ty) (fun () -> Bindlib.box e1)
    | None ->
      Errors.raise_spanned_error pos_e "Reference to %a not found"
        (Expr.format ctx) e)
  | A.EStruct (s_name, fmap) ->
    unify_and_mark (unionfind_make (TStruct s_name))
    @@ fun () ->
    let+ fmap' =
      (* This assumes that the fields in fmap and the struct type are already
         ensured to be the same *)
      List.fold_left
        (fun fmap' (f_name, f_ty) ->
          let f_e = A.StructFieldMap.find f_name fmap in
          let+ fmap'
          and+ f_e' = typecheck_expr_top_down ctx env (ast_to_typ f_ty) f_e in
          A.StructFieldMap.add f_name f_e' fmap')
        (Bindlib.box A.StructFieldMap.empty)
        (A.StructMap.find s_name ctx.A.ctx_structs)
    in
    A.EStruct (s_name, fmap')
  | A.EStructAccess (e_struct, f_name, s_name) ->
    unify_and_mark
      (ast_to_typ
         (List.assoc f_name (A.StructMap.find s_name ctx.A.ctx_structs)))
    @@ fun () ->
    let+ e_struct' =
      typecheck_expr_top_down ctx env (unionfind_make (TStruct s_name)) e_struct
    in
    A.EStructAccess (e_struct', f_name, s_name)
  | A.EEnumInj (e_enum, c_name, e_name) ->
    unify_and_mark (unionfind_make (TEnum e_name))
    @@ fun () ->
    let+ e_enum' =
      typecheck_expr_top_down ctx env
        (ast_to_typ (List.assoc c_name (A.EnumMap.find e_name ctx.A.ctx_enums)))
        e_enum
    in
    A.EEnumInj (e_enum', c_name, e_name)
  | A.EMatchS (e1, e_name, cases) ->
    let cases_ty = A.EnumMap.find e_name ctx.A.ctx_enums in
    let t_ret = unionfind_make ~pos:e1 (TAny (Any.fresh ())) in
    unify_and_mark t_ret
    @@ fun () ->
    let+ e1' =
      typecheck_expr_top_down ctx env (unionfind_make (TEnum e_name)) e1
    and+ cases' =
      A.EnumConstructorMap.fold
        (fun c_name e cases' ->
          let c_ty = List.assoc c_name cases_ty in
          let e_ty = unionfind_make ~pos:e (TArrow (ast_to_typ c_ty, t_ret)) in
          let+ cases' and+ e' = typecheck_expr_top_down ctx env e_ty e in
          A.EnumConstructorMap.add c_name e' cases')
        cases
        (Bindlib.box A.EnumConstructorMap.empty)
    in
    A.EMatchS (e1', e_name, cases')
  | A.ERaise _ as e1 -> Bindlib.box (mark e1)
  | A.ECatch (e1, ex, e2) ->
    let+ e1' = typecheck_expr_top_down ctx env tau e1
    and+ e2' = typecheck_expr_top_down ctx env tau e2 in
    mark (A.ECatch (e1', ex, e2'))
  | A.EVar v ->
    let tau' =
      match Env.get env v with
      | Some t -> t
      | None ->
        Errors.raise_spanned_error pos_e
          "Variable %s not found in the current context" (Bindlib.name_of v)
    in
    unify_and_mark tau' @@ fun () -> Bindlib.box_var (Var.translate v)
  | A.ELit lit as e1 ->
    unify_and_mark (unionfind_make (lit_type lit))
    @@ fun () -> Bindlib.box @@ e1
  | A.ETuple (es, None) ->
    let tys = List.map (fun _ -> unionfind_make (TAny (Any.fresh ()))) es in
    unify_and_mark (unionfind_make (TTuple tys))
    @@ fun () ->
    let+ es' = bmap2 (typecheck_expr_top_down ctx env) tys es in
    A.ETuple (es', None)
  | A.ETuple (es, Some s_name) ->
    let tys =
      List.map
        (fun (_, ty) -> ast_to_typ ty)
        (A.StructMap.find s_name ctx.A.ctx_structs)
    in
    unify_and_mark (unionfind_make (TStruct s_name))
    @@ fun () ->
    let+ es' = bmap2 (typecheck_expr_top_down ctx env) tys es in
    A.ETuple (es', Some s_name)
  | A.ETupleAccess (e1, n, s, typs) ->
    let typs' = List.map ast_to_typ typs in
    let tuple_ty = match s with None -> TTuple typs' | Some s -> TStruct s in
    let t1n =
      try List.nth typs' n
      with Not_found ->
        Errors.raise_spanned_error (Expr.pos e1)
          "Expression should have a tuple type with at least %d elements but \
           only has %d"
          n (List.length typs)
    in
    unify_and_mark t1n
    @@ fun () ->
    let+ e1' = typecheck_expr_top_down ctx env (unionfind_make tuple_ty) e1 in
    A.ETupleAccess (e1', n, s, typs)
  | A.EInj (e1, n, e_name, ts) ->
    let ts' = List.map ast_to_typ ts in
    let ts_n =
      try List.nth ts' n
      with Not_found ->
        Errors.raise_spanned_error (Expr.pos e)
          "Expression should have a sum type with at least %d cases but only \
           has %d"
          n (List.length ts)
    in
    unify_and_mark (unionfind_make (TEnum e_name))
    @@ fun () ->
    let+ e1' = typecheck_expr_top_down ctx env ts_n e1 in
    A.EInj (e1', n, e_name, ts)
  | A.EMatch (e1, es, e_name) ->
    let+ es' =
      bmap2
        (fun es' (_, c_ty) ->
          typecheck_expr_top_down ctx env
            (unionfind_make ~pos:es' (TArrow (ast_to_typ c_ty, tau)))
            es')
        es
        (A.EnumMap.find e_name ctx.ctx_enums)
    and+ e1' =
      typecheck_expr_top_down ctx env (unionfind_make ~pos:e1 (TEnum e_name)) e1
    in
    mark (A.EMatch (e1', es', e_name))
  | A.EAbs (binder, t_args) ->
    if Bindlib.mbinder_arity binder <> List.length t_args then
      Errors.raise_spanned_error (Expr.pos e)
        "function has %d variables but was supplied %d types"
        (Bindlib.mbinder_arity binder)
        (List.length t_args)
    else
      let tau_args = List.map ast_to_typ t_args in
      let t_ret = unionfind_make (TAny (Any.fresh ())) in
      let t_func =
        List.fold_right
          (fun t_arg acc -> unionfind_make (TArrow (t_arg, acc)))
          tau_args t_ret
      in
      unify_and_mark t_func
      @@ fun () ->
      let xs, body = Bindlib.unmbind binder in
      let xs' = Array.map Var.translate xs in
      let env =
        List.fold_left2
          (fun env x tau_arg -> Env.add x tau_arg env)
          env (Array.to_list xs) tau_args
      in
      let body' = typecheck_expr_top_down ctx env t_ret body in
      let+ binder' = Bindlib.bind_mvar xs' body' in
      A.EAbs (binder', t_args)
  | A.EApp (e1, args) ->
    let t_args =
      List.map (fun _ -> unionfind_make (TAny (Any.fresh ()))) args
    in
    let t_func =
      List.fold_right
        (fun t_arg acc -> unionfind_make (TArrow (t_arg, acc)))
        t_args tau
    in
    let+ e1' = typecheck_expr_top_down ctx env t_func e1
    and+ args' = bmap2 (typecheck_expr_top_down ctx env) t_args args in
    mark (A.EApp (e1', args'))
  | A.EOp op as e1 ->
    unify_and_mark (op_type (add_pos e op)) @@ fun () -> Bindlib.box e1
  | A.EDefault (excepts, just, cons) ->
    let+ cons' = typecheck_expr_top_down ctx env tau cons
    and+ just' =
      typecheck_expr_top_down ctx env
        (unionfind_make ~pos:just (TLit TBool))
        just
    and+ excepts' = bmap (typecheck_expr_top_down ctx env tau) excepts in
    mark (A.EDefault (excepts', just', cons'))
  | A.EIfThenElse (cond, et, ef) ->
    let+ et' = typecheck_expr_top_down ctx env tau et
    and+ ef' = typecheck_expr_top_down ctx env tau ef
    and+ cond' =
      typecheck_expr_top_down ctx env
        (unionfind_make ~pos:cond (TLit TBool))
        cond
    in
    mark (A.EIfThenElse (cond', et', ef'))
  | A.EAssert e1 ->
    unify_and_mark (unionfind_make (TLit TUnit))
    @@ fun () ->
    let+ e1' =
      typecheck_expr_top_down ctx env (unionfind_make ~pos:e1 (TLit TBool)) e1
    in
    A.EAssert e1'
  | A.ErrorOnEmpty e1 ->
    let+ e1' = typecheck_expr_top_down ctx env tau e1 in
    mark (A.ErrorOnEmpty e1')
  | A.EArray es ->
    let cell_type = unionfind_make (TAny (Any.fresh ())) in
    unify_and_mark (unionfind_make (TArray cell_type))
    @@ fun () ->
    let+ es' = bmap (typecheck_expr_top_down ctx env cell_type) es in
    A.EArray es'

let wrap ctx f e =
  try
    Bindlib.unbox (f e)
    (* We need to unbox here, because the typing may otherwise be stored in
       Bindlib closures and not yet applied, and would escape the `try..with` *)
  with Type_error (e, ty1, ty2) -> (
    let bt = Printexc.get_raw_backtrace () in
    try handle_type_error ctx e ty1 ty2
    with e -> Printexc.raise_with_backtrace e bt)

(** {1 API} *)

let get_ty_mark { uf; pos } = A.Typed { ty = typ_to_ast uf; pos }

(* Infer the type of an expression *)
let expr
    (type a)
    (ctx : A.decl_ctx)
    ?(env = Env.empty)
    ?(typ : A.typ option)
    (e : (a, 'm) A.gexpr) : (a, A.typed A.mark) A.gexpr A.box =
  let fty =
    match typ with
    | None -> typecheck_expr_bottom_up ctx env
    | Some typ -> typecheck_expr_top_down ctx env (ast_to_typ typ)
  in
  Expr.map_marks ~f:get_ty_mark (wrap ctx fty e)

let rec scope_body_expr ctx env ty_out body_expr =
  match body_expr with
  | A.Result e ->
    let e' = wrap ctx (typecheck_expr_top_down ctx env ty_out) e in
    let e' = Expr.map_marks ~f:get_ty_mark e' in
    Bindlib.box_apply (fun e -> A.Result e) e'
  | A.ScopeLet
      {
        scope_let_kind;
        scope_let_typ;
        scope_let_expr = e0;
        scope_let_next;
        scope_let_pos;
      } ->
    let ty_e = ast_to_typ scope_let_typ in
    let e = wrap ctx (typecheck_expr_bottom_up ctx env) e0 in
    wrap ctx (fun t -> Bindlib.box (unify ctx e0 (ty e) t)) ty_e;
    (* We could use [typecheck_expr_top_down] rather than this manual
       unification, but we get better messages with this order of the [unify]
       parameters, which keeps location of the type as defined instead of as
       inferred. *)
    let var, next = Bindlib.unbind scope_let_next in
    let env = Env.add var ty_e env in
    let next = scope_body_expr ctx env ty_out next in
    let scope_let_next = Bindlib.bind_var (Var.translate var) next in
    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        A.ScopeLet
          {
            scope_let_kind;
            scope_let_typ;
            scope_let_expr;
            scope_let_next;
            scope_let_pos;
          })
      (Expr.map_marks ~f:get_ty_mark e)
      scope_let_next

let scope_body ctx env body =
  let get_pos struct_name =
    Marked.get_mark (A.StructName.get_info struct_name)
  in
  let struct_ty struct_name =
    UnionFind.make (Marked.mark (get_pos struct_name) (TStruct struct_name))
  in
  let ty_in = struct_ty body.A.scope_body_input_struct in
  let ty_out = struct_ty body.A.scope_body_output_struct in
  let var, e = Bindlib.unbind body.A.scope_body_expr in
  let env = Env.add var ty_in env in
  let e' = scope_body_expr ctx env ty_out e in
  ( Bindlib.bind_var (Var.translate var) e',
    UnionFind.make
      (Marked.mark
         (get_pos body.A.scope_body_output_struct)
         (TArrow (ty_in, ty_out))) )

let rec scopes ctx env = function
  | A.Nil -> Bindlib.box A.Nil
  | A.ScopeDef def ->
    let body_e, ty_scope = scope_body ctx env def.scope_body in
    let scope_next =
      let scope_var, next = Bindlib.unbind def.scope_next in
      let env = Env.add scope_var ty_scope env in
      let next' = scopes ctx env next in
      Bindlib.bind_var (Var.translate scope_var) next'
    in
    Bindlib.box_apply2
      (fun scope_body_expr scope_next ->
        A.ScopeDef
          {
            def with
            scope_body = { def.scope_body with scope_body_expr };
            scope_next;
          })
      body_e scope_next

let program prg =
  let scopes = Bindlib.unbox (scopes prg.A.decl_ctx Env.empty prg.A.scopes) in
  { prg with scopes }
