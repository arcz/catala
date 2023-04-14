(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020-2022 Inria,
   contributor: Alain Delaët-Tixeuil <alain.delaet--tixeuil@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
module D = Dcalc.Ast
module A = Ast

(** The main idea around this pass is to compile Dcalc to Lcalc without using
    [raise EmptyError] nor [try _ with EmptyError -> _]. To do so, we use the
    same technique as in rust or erlang to handle this kind of exceptions. Each
    [raise EmptyError] will be translated as [None] and each
    [try e1 with EmtpyError -> e2] as
    [match e1 with | None -> e2 | Some x -> x].

    When doing this naively, this requires to add matches and Some constructor
    everywhere. We apply here an other technique where we generate what we call
    `hoists`. Hoists are expression whom could minimally [raise EmptyError]. For
    instance in [let x = <e1, e2, ..., en| e_just :- e_cons> * 3 in x + 1], the
    sub-expression [<e1, e2, ..., en| e_just :- e_cons>] can produce an empty
    error. So we make a hoist with a new variable [y] linked to the Dcalc
    expression [<e1, e2, ..., en| e_just :- e_cons>], and we return as the
    translated expression [let x = y * 3 in x + 1].

    The compilation process is handled by the [trans_expr] function. *)

open Shared_ast

(** Default-monad utilities. *)

module Monad : sig
  val monad_return :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr

  val monad_empty : mark:'m mark -> (([< all ] as 'a), 'm mark) boxed_gexpr

  val monad_bind_var :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) gexpr Var.t ->
    ('a, 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr

  val monad_bind :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr

  val monad_bind_cont :
    mark:'m mark ->
    ((([< all ] as 'a), 'm mark) gexpr Var.t -> ('a, 'm mark) boxed_gexpr) ->
    ('a, 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr

  val monad_mbind_mvar :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) gexpr Var.t list ->
    ('a, 'm mark) boxed_gexpr list ->
    ('a, 'm mark) boxed_gexpr

  val monad_mbind :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr list ->
    ('a, 'm mark) boxed_gexpr

  val monad_mbind_cont :
    mark:'m mark ->
    ((([< all ] as 'a), 'm mark) gexpr Var.t list -> ('a, 'm mark) boxed_gexpr) ->
    ('a, 'm mark) boxed_gexpr list ->
    ('a, 'm mark) boxed_gexpr

  val monad_eoe :
    mark:'a mark ->
    ?toplevel:bool ->
    (([< all > `Exceptions ] as 'b), 'a mark) boxed_gexpr ->
    ('b, 'a mark) boxed_gexpr

  val monad_map :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr

  val monad_mmap_mvar :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) gexpr Var.t list ->
    ('a, 'm mark) boxed_gexpr list ->
    ('a, 'm mark) boxed_gexpr

  val monad_mmap :
    mark:'m mark ->
    (([< all ] as 'a), 'm mark) boxed_gexpr ->
    ('a, 'm mark) boxed_gexpr list ->
    ('a, 'm mark) boxed_gexpr
end = struct
  let monad_return ~(mark : 'a mark) e =
    Expr.einj e Ast.some_constr Ast.option_enum mark

  let monad_empty ~(mark : 'a mark) =
    Expr.einj (Expr.elit LUnit mark) Ast.none_constr Ast.option_enum mark

  let monad_bind_var ~(mark : 'a mark) f x arg =
    let cases =
      EnumConstructor.Map.of_seq
        (List.to_seq
           [
             ( Ast.none_constr,
               let x = Var.make "_" in
               Expr.eabs
                 (Expr.bind [| x |]
                    (Expr.einj (Expr.evar x mark) Ast.none_constr
                       Ast.option_enum mark))
                 [TLit TUnit, Expr.mark_pos mark]
                 mark );
             (* | None x -> None x *)
             ( Ast.some_constr,
               Expr.eabs (Expr.bind [| x |] f) [TAny, Expr.mark_pos mark] mark )
             (*| Some x -> f (where f contains x as a free variable) *);
           ])
    in
    Expr.ematch arg Ast.option_enum cases mark

  let monad_bind ~(mark : 'a mark) f arg =
    let x = Var.make "x" in
    (* todo modify*)
    monad_bind_var f x arg ~mark

  let monad_bind_cont ~(mark : 'a mark) f arg =
    let x = Var.make "x" in
    monad_bind_var (f x) x arg ~mark

  let monad_mbind_mvar ~(mark : 'a mark) f xs args =
    (* match e1, ..., en with | Some e1', ..., Some en' -> f (e1, ..., en) | _
       -> None *)
    ListLabels.fold_left2 xs args ~f:(monad_bind_var ~mark)
      ~init:(Expr.eapp f (List.map (fun v -> Expr.evar v mark) xs) mark)

  let monad_mbind ~(mark : 'a mark) f args =
    (* match e1, ..., en with | Some e1', ..., Some en' -> f (e1, ..., en) | _
       -> None *)
    let vars =
      ListLabels.mapi args ~f:(fun i _ -> Var.make (Format.sprintf "e_%i" i))
    in
    monad_mbind_mvar f vars args ~mark

  let monad_mbind_cont ~(mark : 'a mark) f args =
    let vars =
      ListLabels.mapi args ~f:(fun i _ -> Var.make (Format.sprintf "e_%i" i))
    in
    ListLabels.fold_left2 vars args ~f:(monad_bind_var ~mark) ~init:(f vars)
  (* monad_mbind_mvar (f vars) vars args ~mark *)

  let monad_mmap_mvar ~(mark : 'a mark) f xs args =
    (* match e1, ..., en with | Some e1', ..., Some en' -> f (e1, ..., en) | _
       -> None *)
    ListLabels.fold_left2 xs args ~f:(monad_bind_var ~mark)
      ~init:
        (Expr.einj
           (Expr.eapp f (List.map (fun v -> Expr.evar v mark) xs) mark)
           Ast.some_constr Ast.option_enum mark)

  let monad_map_var ~(mark : 'a mark) f x arg =
    monad_mmap_mvar f [x] [arg] ~mark

  let monad_map ~(mark : 'a mark) f arg =
    let x = Var.make "x" in
    monad_map_var f x arg ~mark

  let monad_mmap ~(mark : 'a mark) f args =
    let vars =
      ListLabels.mapi args ~f:(fun i _ -> Var.make (Format.sprintf "e_%i" i))
    in
    monad_mmap_mvar f vars args ~mark

  let monad_eoe ~(mark : 'a mark) ?(toplevel = false) arg =
    let cases =
      EnumConstructor.Map.of_seq
        (List.to_seq
           [
             ( Ast.none_constr,
               let x = Var.make "x" in
               Expr.eabs
                 (Expr.bind [| x |] (Expr.eraise NoValueProvided mark))
                 [TAny, Expr.mark_pos mark]
                 mark );
             (* | None x -> raise NoValueProvided *)
             Ast.some_constr, Expr.eid mark (* | Some x -> x*);
           ])
    in
    if toplevel then Expr.ematch arg Ast.option_enum cases mark
    else monad_return ~mark (Expr.ematch arg Ast.option_enum cases mark)
end

open Monad

(** Start of the translation *)

(** Type translating functions.

    Since positions where there is thunked expressions is exactly where we will
    put option expressions. Hence, the transformation simply reduce [unit -> 'a]
    into ['a option] recursivly. There is no polymorphism inside catala. *)

(** In the general case, we use the [trans_typ_to_any] function to put [TAny]
    and then ask the typing algorithm to reinfer all the types. However, this is
    not sufficient as the typing inference need at least input and output types.
    Those a generated using the [trans_typ_keep] function, that build TOptions
    where needed. *)
let trans_typ_to_any (tau : typ) : typ = Marked.same_mark_as TAny tau

let rec trans_typ_keep (tau : typ) : typ =
  let m = Marked.get_mark tau in
  (Fun.flip Marked.same_mark_as)
    tau
    begin
      match Marked.unmark tau with
      | TLit l -> TLit l
      | TTuple ts -> TTuple (List.map trans_typ_keep ts)
      | TStruct s -> TStruct s
      | TEnum en -> TEnum en
      | TOption _ ->
        Errors.raise_internal_error
          "The type option should not appear before the dcalc -> lcalc \
           translation step."
      | TAny -> TAny
      | TArray ts ->
        TArray (TOption (trans_typ_keep ts), m) (* catala is not polymorphic *)
      | TArrow ([(TLit TUnit, _)], t2) -> Marked.unmark (trans_typ_keep t2)
      | TArrow (t1, t2) ->
        TArrow (List.map trans_typ_keep t1, (TOption (trans_typ_keep t2), m))
    end

let trans_typ_keep (tau : typ) : typ =
  Marked.same_mark_as (TOption (trans_typ_keep tau)) tau

let trans_op : dcalc Op.t -> lcalc Op.t = Operator.translate

type 'a info_pure = {
  info_pure : bool;
  is_scope : bool;
  var : 'a Ast.expr Var.t;
}

let trans_var ctx (x : 'm D.expr Var.t) : 'm Ast.expr Var.t =
  (Var.Map.find x ctx).var

(** The function [e' = trans ctx e] actually do the translation between dexpr
    and lexpr. The context link every free variables of the [e] expression to a
    new lcalc variable [var], and some information [info_pure] on whenever the
    variable can be an EmptyError while evaluating and hence should be matched.
    We also keep [is_scope] to indicate if a variable come from a top-level
    scope definition. This is used when applying functions as described below.
    Finally, the following invariant it kept by the application of the function
    if [e] is of type [a], then the result should be of type [trans_typ_keep a].
    For literals, this mean that a expression of type [money] will be of type
    [money option]. We rely on later optimization to shorten the size of the
    generated code. *)

let rec trans ctx (e : 'm D.expr) : (lcalc, 'm mark) boxed_gexpr =
  let m = Marked.get_mark e in
  let mark = m in
  let pos = Expr.pos e in
  (* Cli.debug_format "%a" (Print.expr_debug ~debug:true) e; *)
  match Marked.unmark e with
  | EVar x ->
    if (Var.Map.find x ctx).info_pure then
      monad_return (Expr.evar (trans_var ctx x) m) ~mark
    else Expr.evar (trans_var ctx x) m
  | EApp { f = EVar v, _; args = [(ELit LUnit, _)] } ->
    (* As users cannot write thunks, it is obligatory added by the compiler.
       Hence we can safely remove those. *)
    assert (not (Var.Map.find v ctx).info_pure);
    Expr.evar (trans_var ctx v) m
  | EAbs { binder; tys = [(TLit TUnit, _)] } ->
    (* this is to be used with monad_bind. *)
    let _, body = Bindlib.unmbind binder in
    trans ctx body
  | EAbs { binder; tys } ->
    (* Every functions of type [a -> b] are translated to a function of type [a
       -> option b] *)
    let vars, body = Bindlib.unmbind binder in
    let ctx' =
      ArrayLabels.fold_right vars ~init:ctx ~f:(fun v ->
          Var.Map.add v
            { info_pure = true; is_scope = false; var = Var.translate v })
    in

    let body' = trans ctx' body in
    let binder' = Expr.bind (Array.map Var.translate vars) body' in
    monad_return ~mark (Expr.eabs binder' tys m)
  | EDefault { excepts; just; cons } ->
    let excepts' = List.map (trans ctx) excepts in
    let just' = trans ctx just in
    let cons' = trans ctx cons in

    (* If the default term has the following type [<es: a list | just: bool |-
       cons: a>] then resulting term will have type [handledefaultOpt (es': a
       option list) (just': bool option) (cons': a option)] *)
    let m' = match m with Typed m -> Typed { m with ty = TAny, pos } in
    Expr.make_app
      (Expr.eop Op.HandleDefaultOpt [TAny, pos; TAny, pos; TAny, pos] m')
      [Expr.earray excepts' m; Expr.thunk_term just' m; Expr.thunk_term cons' m]
      pos
  | ELit l -> monad_return ~mark (Expr.elit l m)
  | EEmptyError -> monad_empty ~mark
  | EErrorOnEmpty arg ->
    let arg' = trans ctx arg in
    monad_eoe arg' ~mark ~toplevel:false
  | EApp { f = EVar scope, _; args = [(EStruct { fields; name }, _)] }
    when (Var.Map.find scope ctx).is_scope ->
    (* Scopes are encoded as functions that can take option arguments, and
       always return (or raise panic exceptions like AssertionFailed,
       NoValueProvided or Conflict) an structure that can contain optionnal
       elements. Hence, to call a scope, we don't need to use the monad bind. *)
    monad_return ~mark
      (Expr.eapp
         (Expr.evar (trans_var ctx scope) mark)
         [
           Expr.estruct name
             (StructField.MapLabels.map fields ~f:(trans ctx))
             mark;
         ]
         mark)
  | EApp { f = (EVar ff, _) as f; args } when not (Var.Map.find ff ctx).is_scope
    ->
    (* INVARIANT: functions are always encoded using this function.

       As every functions of type [a -> b] but top-level scopes are built using
       this function, returning a function of type [a -> b option], hence, we
       should use [monad_mbind]. *)
    let f_var = Var.make "fff" in
    monad_bind_var ~mark
      (monad_mbind (Expr.evar f_var mark) (List.map (trans ctx) args) ~mark)
      f_var (trans ctx f)
  | EApp { f = (EStructAccess _, _) as f; args } ->
    (* This occurs when calling a subscope function. The same encoding as the
       one for [EApp (Var _) _] if the variable is not a scope works. *)
    let f_var = Var.make "fff" in
    monad_bind_var ~mark
      (monad_mbind (Expr.evar f_var mark) (List.map (trans ctx) args) ~mark)
      f_var (trans ctx f)
  | EApp { f = EAbs { binder; _ }, _; args } ->
    (* INVARIANTS: every let have only one argument. (checked by
       invariant_let) *)
    let var, body = Bindlib.unmbind binder in
    let[@warning "-8"] [| var |] = var in
    let var' = Var.translate var in
    let[@warning "-8"] [arg] = args in
    let ctx' =
      Var.Map.add var { info_pure = true; is_scope = false; var = var' } ctx
    in
    monad_bind_var (trans ctx' body) var' (trans ctx arg) ~mark
  | EApp { f = EApp { f = EOp { op = Op.Log _; _ }, _; args = _ }, _; _ } ->
    Errors.raise_internal_error
      "Parameter trace is incompatible with parameter avoid_exceptions: some \
       tracing logs were added while they are not supported."
  (* Encoding of Fold, Filter, Map and Reduce is non trivial because we don't
     define new monadic operator for every one of those. *)
  | EApp { f = EOp { op = Op.Fold; tys }, opmark; args = [f; init; l] } ->
    (* The function f should have type b -> a -> a. Hence, its translation has
       type [b] -> [a] -> option [a]. But we need a function of type option [b]
       -> option [a] -> option [a] for the type checking of fold. Hence, we
       "iota-expand" the function as follows: [λ x y. bindm x y. [f] x y] *)
    let x1 = Var.make "f" in
    let x2 = Var.make "init" in
    let f' =
      monad_bind_cont ~mark
        (fun f ->
          monad_return ~mark
            (Expr.eabs
               (Expr.bind [| x1; x2 |]
                  (monad_mbind_cont ~mark
                     (fun vars ->
                       Expr.eapp (Expr.evar f m)
                         (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
                         m)
                     [Expr.evar x1 m; Expr.evar x2 m]))
               [TAny, pos; TAny, pos]
               m))
        (trans ctx f)
    in
    monad_mbind
      (Expr.eop (trans_op Op.Fold) tys opmark)
      [f'; monad_return ~mark (trans ctx init); trans ctx l]
      ~mark
  | EApp { f = EOp { op = Op.Reduce; tys }, opmark; args = [f; init; l] } ->
    let x1 = Var.make "x1" in
    let x2 = Var.make "x2" in
    let f' =
      monad_bind_cont ~mark
        (fun f ->
          monad_return ~mark
            (Expr.eabs
               (Expr.bind [| x1; x2 |]
                  (monad_mbind_cont ~mark
                     (fun vars ->
                       Expr.eapp (Expr.evar f m)
                         (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
                         m)
                     [Expr.evar x1 m; Expr.evar x2 m]))
               [TAny, pos; TAny, pos]
               m))
        (trans ctx f)
    in
    monad_mbind
      (Expr.eop (trans_op Op.Reduce) tys opmark)
      [f'; monad_return ~mark (trans ctx init); trans ctx l]
      ~mark
  | EApp { f = EOp { op = Op.Map; tys }, opmark; args = [f; l] } ->
    (* The funtion $f$ has type $a -> option b$, but Map needs a function of
       type $a -> b$, hence we need to transform $f$ into a function of type $a
       option -> option b$. *)
    let x1 = Var.make "f" in
    let f' =
      monad_bind_cont ~mark
        (fun f ->
          monad_return ~mark
            (Expr.eabs
               (Expr.bind [| x1 |]
                  (monad_mbind_cont ~mark
                     (fun vars ->
                       Expr.eapp (Expr.evar f m)
                         (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
                         m)
                     [Expr.evar x1 m]))
               [TAny, pos]
               m))
        (trans ctx f)
    in
    monad_mbind_cont
      (fun vars ->
        monad_return ~mark
          (Expr.eapp
             (Expr.eop (trans_op Op.Map) tys opmark)
             (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
             mark))
      [f'; trans ctx l]
      ~mark
  | EApp { f = EOp { op = Op.Filter; tys }, opmark; args = [f; l] } ->
    (* The function $f$ has type $a -> bool option$ while the filter operator
       requires an function of type $a option -> bool$. Hence we need to modify
       $f$ by first matching the input, and second using the error_on_empty on
       the result.*)
    let x1 = Var.make "p" in
    let f' =
      monad_bind_cont ~mark
        (fun f ->
          monad_return ~mark
            (Expr.eabs
               (Expr.bind [| x1 |]
                  (monad_eoe ~toplevel:true ~mark
                     (monad_mbind_cont ~mark
                        (fun vars ->
                          Expr.eapp (Expr.evar f m)
                            (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
                            m)
                        [Expr.evar x1 m])))
               [TAny, pos]
               m))
        (trans ctx f)
    in
    monad_mbind_cont
      (fun vars ->
        monad_return ~mark
          (Expr.eapp
             (Expr.eop (trans_op Op.Filter) tys opmark)
             (ListLabels.map vars ~f:(fun v -> Expr.evar v m))
             mark))
      [f'; trans ctx l]
      ~mark
  | EApp { f = EOp { op = Op.Filter as op; _ }, _; _ }
  | EApp { f = EOp { op = Op.Map as op; _ }, _; _ }
  | EApp { f = EOp { op = Op.Fold as op; _ }, _; _ }
  | EApp { f = EOp { op = Op.Reduce as op; _ }, _; _ } ->
    (* Cannot happend: list operator must be fully determined *)
    Errors.raise_internal_error
      "List operator %a was not fully determined: some partial evaluation was \
       found while compiling."
      Print.operator op
  | EApp { f = EOp { op; tys }, opmark; args } ->
    let res =
      monad_mmap
        (Expr.eop (trans_op op) tys opmark)
        (List.map (trans ctx) args)
        ~mark
    in
    res
  | EMatch { name; e; cases } ->
    let cases =
      EnumConstructor.MapLabels.map cases ~f:(fun case ->
          match Marked.unmark case with
          | EAbs { binder; tys } ->
            let vars, body = Bindlib.unmbind binder in
            let ctx' =
              ArrayLabels.fold_right vars ~init:ctx ~f:(fun var ->
                  Var.Map.add var
                    {
                      info_pure = true;
                      is_scope = false;
                      var = Var.translate var;
                    })
            in
            let binder =
              Expr.bind (Array.map Var.translate vars) (trans ctx' body)
            in
            Expr.eabs binder tys m
          | _ -> assert false)
    in
    monad_bind_cont
      (fun e -> Expr.ematch (Expr.evar e m) name cases m)
      (trans ctx e) ~mark
  | EArray args ->
    monad_mbind_cont ~mark
      (fun vars ->
        monad_return ~mark
          (Expr.earray
             (List.map (fun v -> monad_return ~mark (Expr.evar v m)) vars)
             mark))
      (List.map (trans ctx) args)
  | EStruct { name; fields } ->
    let fields_name, fields = List.split (StructField.Map.bindings fields) in
    monad_mbind_cont
      (fun xs ->
        let fields =
          ListLabels.fold_right2 fields_name
            (List.map (fun x -> monad_return ~mark (Expr.evar x mark)) xs)
            ~f:StructField.Map.add ~init:StructField.Map.empty
        in
        monad_return ~mark (Expr.estruct name fields mark))
      (List.map (trans ctx) fields)
      ~mark
  | EIfThenElse { cond; etrue; efalse } ->
    (* There is two different encoding of the if then else. The first one is to
       consider it as if it is an operator. Hence, if one of the branches is an
       EmptyError, then it propagate to the final result of the expression. The
       second one is [<<|cond |- a >, <|not cond |- b>| false :- empty>]. The
       second semantics is redondant with exising default terms, but is the one
       decided by the compiler. *)
    monad_bind_cont ~mark
      (fun cond ->
        Expr.eifthenelse (Expr.evar cond mark) (trans ctx etrue)
          (trans ctx efalse) mark)
      (trans ctx cond)
  | EInj { name; cons; e } ->
    monad_bind_cont
      (fun e ->
        monad_return ~mark (Expr.einj (Expr.evar e mark) cons name mark))
      (trans ctx e) ~mark
  | EStructAccess { name; e; field } ->
    monad_bind_cont
      (fun e -> Expr.estructaccess (Expr.evar e mark) field name mark)
      (trans ctx e) ~mark
  | ETuple args ->
    monad_mbind_cont
      (fun xs ->
        monad_return ~mark
          (Expr.etuple (List.map (fun x -> Expr.evar x mark) xs) mark))
      (List.map (trans ctx) args)
      ~mark
  | ETupleAccess { e; index; size } ->
    monad_bind_cont
      (fun e -> Expr.etupleaccess (Expr.evar e mark) index size mark)
      (trans ctx e) ~mark
  | EAssert e ->
    monad_bind_cont
      (fun e -> monad_return ~mark (Expr.eassert (Expr.evar e mark) mark))
      (trans ctx e) ~mark
  | EApp _ ->
    Errors.raise_spanned_error (Expr.pos e)
      "Internal Error: found an EApp that does not satisfy the invariants when \
       translating Dcalc to Lcalc without exceptions."
  (* invalid invariant *)
  | EOp _ ->
    Errors.raise_spanned_error (Expr.pos e)
      "Internal Error: found an EOp that does not satisfy the invariants when \
       translating Dcalc to Lcalc without exceptions."
  | ELocation _ -> .

(** Now we have translated expression, we still need to translate the statements
    (scope_let_list) and then scopes. This is pretty much straightforward. *)
let rec trans_scope_let ctx s =
  match s with
  | {
   scope_let_kind = SubScopeVarDefinition;
   scope_let_typ = (TArrow ([(TLit TUnit, _)], _), _) as scope_let_typ;
   scope_let_expr = EAbs { binder; _ }, _;
   scope_let_next;
   scope_let_pos;
  } ->
    (* special case : the subscope variable is thunked (context i/o). We remove
       this thunking. *)
    let _, scope_let_expr = Bindlib.unmbind binder in
    let next_var, next_body = Bindlib.unbind scope_let_next in

    let next_var' = Var.translate next_var in
    let ctx' =
      Var.Map.add next_var
        { info_pure = false; is_scope = false; var = next_var' }
        ctx
    in

    let next_var = next_var' in
    let next_body = trans_scope_body_expr ctx' next_body in

    let scope_let_next = Bindlib.bind_var next_var next_body in

    let scope_let_expr = Expr.Box.lift @@ trans ctx scope_let_expr in

    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        {
          scope_let_kind = SubScopeVarDefinition;
          scope_let_typ = trans_typ_to_any scope_let_typ;
          scope_let_expr;
          scope_let_next;
          scope_let_pos;
        })
      scope_let_expr scope_let_next
  | {
   scope_let_kind = SubScopeVarDefinition;
   scope_let_typ;
   scope_let_expr = (EAbs _, _) as scope_let_expr;
   scope_let_next;
   scope_let_pos;
  } ->
    (* special case : the subscope variable is thunked (context i/o). We remove
       this thunking. *)
    let next_var, next_body = Bindlib.unbind scope_let_next in
    let next_var' = Var.translate next_var in
    let ctx' =
      Var.Map.add next_var
        { info_pure = false; is_scope = false; var = next_var' }
        ctx
    in
    let next_var = next_var' in
    let next_body = trans_scope_body_expr ctx' next_body in

    let scope_let_next = Bindlib.bind_var next_var next_body in

    let scope_let_expr = Expr.Box.lift @@ trans ctx scope_let_expr in

    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        {
          scope_let_kind = SubScopeVarDefinition;
          scope_let_typ = trans_typ_to_any scope_let_typ;
          scope_let_expr;
          scope_let_next;
          scope_let_pos;
        })
      scope_let_expr scope_let_next
  | {
   scope_let_kind = SubScopeVarDefinition;
   scope_let_typ;
   scope_let_expr = EErrorOnEmpty e, mark;
   scope_let_next;
   scope_let_pos;
  } ->
    (* special case: regular input to the subscope *)
    let next_var, next_body = Bindlib.unbind scope_let_next in

    let next_var' = Var.translate next_var in
    let ctx' =
      Var.Map.add next_var
        { info_pure = true; is_scope = false; var = next_var' }
        ctx
    in

    let next_var = next_var' in
    let next_body = trans_scope_body_expr ctx' next_body in

    let scope_let_next = Bindlib.bind_var next_var next_body in

    let scope_let_expr =
      Expr.Box.lift @@ monad_eoe ~mark ~toplevel:true (trans ctx e)
    in

    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        {
          scope_let_kind = SubScopeVarDefinition;
          scope_let_typ = trans_typ_to_any scope_let_typ;
          scope_let_expr;
          scope_let_next;
          scope_let_pos;
        })
      scope_let_expr scope_let_next
  | { scope_let_kind = SubScopeVarDefinition; scope_let_pos = pos; _ } ->
    Errors.raise_spanned_error pos
      "Internal Error: found an SubScopeVarDefinition that does not satisfy \
       the invariants when translating Dcalc to Lcalc without exceptions."
  | {
   scope_let_kind;
   scope_let_typ;
   scope_let_expr;
   scope_let_next;
   scope_let_pos;
  } ->
    (* base case *)
    let next_var, next_body = Bindlib.unbind scope_let_next in

    let next_var' = Var.translate next_var in
    let ctx' =
      Var.Map.add next_var
        (match scope_let_kind with
        | DestructuringInputStruct -> (
          (* note for future: we keep this useless match for distinguishing
             further optimization while building the terms. *)
          match Marked.unmark scope_let_typ with
          | TArrow ([(TLit TUnit, _)], _) ->
            { info_pure = false; is_scope = false; var = next_var' }
          | _ -> { info_pure = false; is_scope = false; var = next_var' })
        | ScopeVarDefinition | SubScopeVarDefinition | CallingSubScope
        | DestructuringSubScopeResults | Assertion ->
          { info_pure = false; is_scope = false; var = next_var' })
        ctx
    in

    let next_var = next_var' in
    let next_body = trans_scope_body_expr ctx' next_body in

    let scope_let_next = Bindlib.bind_var next_var next_body in

    let scope_let_expr = Expr.Box.lift @@ trans ctx scope_let_expr in

    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        {
          scope_let_kind;
          scope_let_typ = trans_typ_to_any scope_let_typ;
          scope_let_expr;
          scope_let_next;
          scope_let_pos;
        })
      scope_let_expr scope_let_next

and trans_scope_body_expr ctx s :
    (lcalc, typed mark) gexpr scope_body_expr Bindlib.box =
  match s with
  | Result e -> begin
    (* invariant : result is always in the form of a record. *)
    match Marked.unmark e with
    | EStruct { name; fields } ->
      Bindlib.box_apply
        (fun e -> Result e)
        (Expr.Box.lift
        @@ Expr.estruct name
             (StructField.Map.map (trans ctx) fields)
             (Marked.get_mark e))
    | _ -> assert false
  end
  | ScopeLet s ->
    Bindlib.box_apply (fun s -> ScopeLet s) (trans_scope_let ctx s)

let trans_scope_body
    ctx
    { scope_body_input_struct; scope_body_output_struct; scope_body_expr } =
  let var, body = Bindlib.unbind scope_body_expr in
  let body =
    trans_scope_body_expr
      (Var.Map.add var
         { info_pure = true; is_scope = false; var = Var.translate var }
         ctx)
      body
  in
  let binder = Bindlib.bind_var (Var.translate var) body in
  Bindlib.box_apply
    (fun scope_body_expr ->
      { scope_body_input_struct; scope_body_output_struct; scope_body_expr })
    binder

let rec trans_code_items ctx c :
    (lcalc, typed mark) gexpr code_item_list Bindlib.box =
  match c with
  | Nil -> Bindlib.box Nil
  | Cons (c, next) -> (
    let var, next = Bindlib.unbind next in
    match c with
    | Topdef (name, typ, e) ->
      let next =
        Bindlib.bind_var (Var.translate var)
          (trans_code_items
             (Var.Map.add var
                { info_pure = false; is_scope = false; var = Var.translate var }
                ctx)
             next)
      in
      let e = Expr.Box.lift @@ trans ctx e in
      (* Invariant: We suppose there is no default in toplevel def, hence we
         don't need to add an error_on_empty *)
      Bindlib.box_apply2
        (fun next e -> Cons (Topdef (name, trans_typ_to_any typ, e), next))
        next e
    | ScopeDef (name, body) ->
      let next =
        Bindlib.bind_var (Var.translate var)
          (trans_code_items
             (Var.Map.add var
                { info_pure = true; is_scope = true; var = Var.translate var }
                ctx)
             next)
      in
      let body = trans_scope_body ctx body in
      Bindlib.box_apply2
        (fun next body -> Cons (ScopeDef (name, body), next))
        next body)

let translate_program (prgm : typed D.program) : untyped A.program =
  let decl_ctx =
    {
      prgm.decl_ctx with
      ctx_enums =
        prgm.decl_ctx.ctx_enums
        |> EnumName.Map.add A.option_enum A.option_enum_config;
    }
  in
  let decl_ctx =
    {
      decl_ctx with
      ctx_structs =
        prgm.decl_ctx.ctx_structs
        |> StructName.Map.mapi (fun _n str ->
               StructField.Map.map trans_typ_keep str);
    }
  in

  let code_items = trans_code_items Var.Map.empty prgm.code_items in

  Bindlib_ext.assert_closed code_items;

  (* program is closed here. *)
  let code_items = Bindlib.unbox code_items in

  Program.untype { decl_ctx; code_items }
