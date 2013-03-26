(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id: lambda.ml 12070 2012-01-23 14:49:39Z lefessan $ *)

open Misc
open Path
open Asttypes

type primitive =
    Pidentity
  | Pignore
  | Prevapply of Location.t
  | Pdirapply of Location.t
    (* Globals *)
  | Pgetglobal of Ident.t
  | Psetglobal of Ident.t
  (* Operations on heap blocks *)
  | Pmakeblock of int * mutable_flag
  | Pfield of int
  | Psetfield of int * bool
  | Pfloatfield of int
  | Psetfloatfield of int
  | Pduprecord of Types.record_representation * int
  (* Force lazy values *)
  | Plazyforce
  (* External call *)
  | Pccall of Primitive.description
  (* Exceptions *)
  | Praise
  (* Boolean operations *)
  | Psequand | Psequor | Pnot
  (* Integer operations *)
  | Pnegint | Paddint | Psubint | Pmulint | Pdivint | Pmodint
  | Pandint | Porint | Pxorint
  | Plslint | Plsrint | Pasrint
  | Pintcomp of comparison
  | Poffsetint of int
  | Poffsetref of int
  (* Float operations *)
  | Pintoffloat | Pfloatofint
  | Pnegfloat | Pabsfloat
  | Paddfloat | Psubfloat | Pmulfloat | Pdivfloat
  | Pfloatcomp of comparison
  (* String operations *)
  | Pstringlength | Pstringrefu | Pstringsetu | Pstringrefs | Pstringsets
  (* Array operations *)
  | Pmakearray of array_kind
  | Parraylength of array_kind
  | Parrayrefu of array_kind
  | Parraysetu of array_kind
  | Parrayrefs of array_kind
  | Parraysets of array_kind
  (* Test if the argument is a block or an immediate integer *)
  | Pisint
  (* Test if the (integer) argument is outside an interval *)
  | Pisout
  (* Bitvect operations *)
  | Pbittest
  (* Operations on boxed integers (Nativeint.t, Int32.t, Int64.t) *)
  | Pbintofint of boxed_integer
  | Pintofbint of boxed_integer
  | Pcvtbint of boxed_integer (*source*) * boxed_integer (*destination*)
  | Pnegbint of boxed_integer
  | Paddbint of boxed_integer
  | Psubbint of boxed_integer
  | Pmulbint of boxed_integer
  | Pdivbint of boxed_integer
  | Pmodbint of boxed_integer
  | Pandbint of boxed_integer
  | Porbint of boxed_integer
  | Pxorbint of boxed_integer
  | Plslbint of boxed_integer
  | Plsrbint of boxed_integer
  | Pasrbint of boxed_integer
  | Pbintcomp of boxed_integer * comparison
  (* Operations on big arrays: (unsafe, #dimensions, kind, layout) *)
  | Pbigarrayref of bool * int * bigarray_kind * bigarray_layout
  | Pbigarrayset of bool * int * bigarray_kind * bigarray_layout

and comparison =
    Ceq | Cneq | Clt | Cgt | Cle | Cge

and array_kind =
    Pgenarray | Paddrarray | Pintarray | Pfloatarray

and boxed_integer =
    Pnativeint | Pint32 | Pint64

and bigarray_kind =
    Pbigarray_unknown
  | Pbigarray_float32 | Pbigarray_float64
  | Pbigarray_sint8 | Pbigarray_uint8
  | Pbigarray_sint16 | Pbigarray_uint16
  | Pbigarray_int32 | Pbigarray_int64
  | Pbigarray_caml_int | Pbigarray_native_int
  | Pbigarray_complex32 | Pbigarray_complex64

and bigarray_layout =
    Pbigarray_unknown_layout
  | Pbigarray_c_layout
  | Pbigarray_fortran_layout

type structured_constant =
    Const_base of constant
  | Const_pointer of int
  | Const_block of int * structured_constant list
  | Const_float_array of string list
  | Const_immstring of string

type function_kind = Curried | Tupled

type let_kind = Strict | Alias | StrictOpt | Variable

type meth_kind = Self | Public | Cached

type shared_code = (int * int) list

type lambda_type = 
  | Lt_top | Lt_bot
  | Lt_arrow of lambda_type * lambda_type
  | Lt_value of lambda_val_type
  | Lt_var of Ident.t
  | Lt_mu of Ident.t * lambda_type

and lambda_val_type = {
  blocks : (int * lambda_type list) list;
  const : [`Any | `Some of int list ];
}

type lambda_type_env = lambda_type Ident.tbl

type lambda =
    Lvar of Ident.t
  | Lconst of structured_constant
  | Lapply of lambda * lambda list * Location.t
  | Lfunction of function_kind * (Ident.t * lambda_type) list * lambda
  | Llet of let_kind * Ident.t * lambda * lambda
  | Lletrec of (Ident.t * lambda) list * lambda
  | Lprim of primitive * lambda list
  | Lswitch of lambda * lambda_switch
  | Lstaticraise of int * lambda list
  | Lstaticcatch of lambda * (int * Ident.t list) * lambda
  | Ltrywith of lambda * Ident.t * lambda
  | Lifthenelse of lambda * lambda * lambda
  | Lsequence of lambda * lambda
  | Lwhile of lambda * lambda
  | Lfor of Ident.t * lambda * lambda * direction_flag * lambda
  | Lassign of Ident.t * lambda
  | Lsend of meth_kind * lambda * lambda * lambda list * Location.t
  | Levent of lambda * lambda_event
  | Lifused of Ident.t * lambda

and lambda_switch =
  { sw_numconsts: int;
    sw_consts: (int * lambda) list;
    sw_numblocks: int;
    sw_blocks: (int * lambda) list;
    sw_failaction : lambda option}

and lambda_event =
  { lev_loc: Location.t;
    lev_kind: lambda_event_kind;
    lev_repr: int ref option;
    lev_env: Env.summary }

and lambda_event_kind =
    Lev_before
  | Lev_after of Types.type_expr
  | Lev_function

let const_unit = Const_pointer 0

let lambda_unit = Lconst const_unit

let rec same l1 l2 =
  match (l1, l2) with
  | Lvar v1, Lvar v2 ->
      Ident.same v1 v2
  | Lconst c1, Lconst c2 ->
      c1 = c2
  | Lapply(a1, bl1, _), Lapply(a2, bl2, _) ->
      same a1 a2 && samelist same bl1 bl2
  | Lfunction(k1, idl1, a1), Lfunction(k2, idl2, a2) ->
      k1 = k2 && samelist (fun (i1,t1) (i2,t2) -> Ident.same i1 i2) idl1 idl2 && same a1 a2
  | Llet(k1, id1, a1, b1), Llet(k2, id2, a2, b2) ->
      k1 = k2 && Ident.same id1 id2 && same a1 a2 && same b1 b2
  | Lletrec (bl1, a1), Lletrec (bl2, a2) ->
      samelist samebinding bl1 bl2 && same a1 a2
  | Lprim(p1, al1), Lprim(p2, al2) ->
      p1 = p2 && samelist same al1 al2
  | Lswitch(a1, s1), Lswitch(a2, s2) ->
      same a1 a2 && sameswitch s1 s2
  | Lstaticraise(n1, al1), Lstaticraise(n2, al2) ->
      n1 = n2 && samelist same al1 al2
  | Lstaticcatch(a1, (n1, idl1), b1), Lstaticcatch(a2, (n2, idl2), b2) ->
      same a1 a2 && n1 = n2 && samelist Ident.same idl1 idl2 && same b1 b2
  | Ltrywith(a1, id1, b1), Ltrywith(a2, id2, b2) ->
      same a1 a2 && Ident.same id1 id2 && same b1 b2
  | Lifthenelse(a1, b1, c1), Lifthenelse(a2, b2, c2) ->
      same a1 a2 && same b1 b2 && same c1 c2
  | Lsequence(a1, b1), Lsequence(a2, b2) ->
      same a1 a2 && same b1 b2
  | Lwhile(a1, b1), Lwhile(a2, b2) ->
      same a1 a2 && same b1 b2
  | Lfor(id1, a1, b1, df1, c1), Lfor(id2, a2, b2, df2, c2) ->
      Ident.same id1 id2 &&  same a1 a2 &&
      same b1 b2 && df1 = df2 && same c1 c2
  | Lassign(id1, a1), Lassign(id2, a2) ->
      Ident.same id1 id2 && same a1 a2
  | Lsend(k1, a1, b1, cl1, _), Lsend(k2, a2, b2, cl2, _) ->
      k1 = k2 && same a1 a2 && same b1 b2 && samelist same cl1 cl2
  | Levent(a1, ev1), Levent(a2, ev2) ->
      same a1 a2 && ev1.lev_loc = ev2.lev_loc
  | Lifused(id1, a1), Lifused(id2, a2) ->
      Ident.same id1 id2 && same a1 a2
  | _, _ ->
      false

and samebinding (id1, c1) (id2, c2) =
  Ident.same id1 id2 && same c1 c2

and sameswitch sw1 sw2 =
  let samecase (n1, a1) (n2, a2) = n1 = n2 && same a1 a2 in
  sw1.sw_numconsts = sw2.sw_numconsts &&
  sw1.sw_numblocks = sw2.sw_numblocks &&
  samelist samecase sw1.sw_consts sw2.sw_consts &&
  samelist samecase sw1.sw_blocks sw2.sw_blocks &&
  (match (sw1.sw_failaction, sw2.sw_failaction) with
    | (None, None) -> true
    | (Some a1, Some a2) -> same a1 a2
    | _ -> false)

let name_lambda arg fn =
  match arg with
    Lvar id -> fn id
  | _ -> let id = Ident.create "let" in Llet(Strict, id, arg, fn id)

(* FIXME: Lt_bot? *)
let name_lambda_list args fn =
  let rec name_list names = function
    [] -> fn (List.rev names)
  | (Lvar id as arg) :: rem ->
      name_list (arg :: names) rem
  | arg :: rem ->
      let id = Ident.create "let" in
      Llet(Strict, id, arg, name_list (Lvar id :: names) rem) in
  name_list [] args

let rec iter f = function
    Lvar _
  | Lconst _ -> ()
  | Lapply(fn, args, _) ->
      f fn; List.iter f args
  | Lfunction(kind, params, body) ->
      f body
  | Llet(str, id, arg, body) ->
      f arg; f body
  | Lletrec(decl, body) ->
      f body;
      List.iter (fun (id, exp) -> f exp) decl
  | Lprim(p, args) ->
      List.iter f args
  | Lswitch(arg, sw) ->
      f arg;
      List.iter (fun (key, case) -> f case) sw.sw_consts;
      List.iter (fun (key, case) -> f case) sw.sw_blocks;
      begin match sw.sw_failaction with
      | None -> ()
      | Some l -> f l
      end
  | Lstaticraise (_,args) ->
      List.iter f args
  | Lstaticcatch(e1, (_,vars), e2) ->
      f e1; f e2
  | Ltrywith(e1, exn, e2) ->
      f e1; f e2
  | Lifthenelse(e1, e2, e3) ->
      f e1; f e2; f e3
  | Lsequence(e1, e2) ->
      f e1; f e2
  | Lwhile(e1, e2) ->
      f e1; f e2
  | Lfor(v, e1, e2, dir, e3) ->
      f e1; f e2; f e3
  | Lassign(id, e) ->
      f e
  | Lsend (k, met, obj, args, _) ->
      List.iter f (met::obj::args)
  | Levent (lam, evt) ->
      f lam
  | Lifused (v, e) ->
      f e

module IdentSet =
  Set.Make(struct
    type t = Ident.t
    let compare = compare
  end)

let free_ids get l =
  let fv = ref IdentSet.empty in
  let rec free l =
    iter free l;
    fv := List.fold_right IdentSet.add (get l) !fv;
    match l with
      Lfunction(kind, params, body) ->
        List.iter (fun (id,ty) -> fv := IdentSet.remove id !fv) params
    | Llet(str, id, arg, body) ->
        fv := IdentSet.remove id !fv
    | Lletrec(decl, body) ->
        List.iter (fun (id, exp) -> fv := IdentSet.remove id !fv) decl
    | Lstaticcatch(e1, (_,vars), e2) ->
        List.iter (fun id -> fv := IdentSet.remove id !fv) vars
    | Ltrywith(e1, exn, e2) ->
        fv := IdentSet.remove exn !fv
    | Lfor(v, e1, e2, dir, e3) ->
        fv := IdentSet.remove v !fv
    | Lassign(id, e) ->
        fv := IdentSet.add id !fv
    | Lvar _ | Lconst _ | Lapply _
    | Lprim _ | Lswitch _ | Lstaticraise _
    | Lifthenelse _ | Lsequence _ | Lwhile _
    | Lsend _ | Levent _ | Lifused _ -> ()
  in free l; !fv

let free_variables l =
  free_ids (function Lvar id -> [id] | _ -> []) l

let free_methods l =
  free_ids (function Lsend(Self, Lvar meth, obj, _, _) -> [meth] | _ -> []) l

(* Check if an action has a "when" guard *)
let raise_count = ref 0

let next_raise_count () =
  incr raise_count ;
  !raise_count

(* Anticipated staticraise, for guards *)
let staticfail = Lstaticraise (0,[])

let rec is_guarded = function
  | Lifthenelse( cond, body, Lstaticraise (0,[])) -> true
  | Llet(str, id, lam, body) -> is_guarded body
  | Levent(lam, ev) -> is_guarded lam
  | _ -> false

let rec patch_guarded patch = function
  | Lifthenelse (cond, body, Lstaticraise (0,[])) ->
      Lifthenelse (cond, body, patch)
  | Llet(str, id, lam, body) ->
      Llet (str, id, lam, patch_guarded patch body)
  | Levent(lam, ev) ->
      Levent (patch_guarded patch lam, ev)
  | _ -> fatal_error "Lambda.patch_guarded"

(* Translate an access path *)

(** FIXME: Lift typing information *)
let rec transl_path = function
    Pident id ->
      if Ident.global id then Lprim(Pgetglobal id, []) else Lvar id
  | Pdot(p, s, pos) ->
      Lprim(Pfield pos, [transl_path p])
  | Papply(p1, p2) ->
      fatal_error "Lambda.transl_path"

(* Compile a sequence of expressions *)

let rec make_sequence fn = function
    [] -> lambda_unit
  | [x] -> fn x
  | x::rem ->
      let lam = fn x in Lsequence(lam, make_sequence fn rem)

(* Apply a substitution to a lambda-term.
   Assumes that the bound variables of the lambda-term do not
   belong to the domain of the substitution.
   Assumes that the image of the substitution is out of reach
   of the bound variables of the lambda-term (no capture). *)

let subst_lambda s lam =
  let rec subst = function
    Lvar id as l ->
      begin try Ident.find_same id s with Not_found -> l end
  | Lconst sc as l -> l
  | Lapply(fn, args, loc) -> Lapply(subst fn, List.map subst args, loc)
  | Lfunction(kind, params, body) -> Lfunction(kind, params, subst body)
  | Llet(str, id, arg, body) -> Llet(str, id, subst arg, subst body)
  | Lletrec(decl, body) -> Lletrec(List.map subst_decl decl, subst body)
  | Lprim(p, args) -> Lprim(p, List.map subst args)
  | Lswitch(arg, sw) ->
      Lswitch(subst arg,
              {sw with sw_consts = List.map subst_case sw.sw_consts;
                       sw_blocks = List.map subst_case sw.sw_blocks;
                       sw_failaction =
                         match sw.sw_failaction with
                         | None -> None
                         | Some l -> Some (subst l)})

  | Lstaticraise (i,args) ->  Lstaticraise (i, List.map subst args)
  | Lstaticcatch(e1, io, e2) -> Lstaticcatch(subst e1, io, subst e2)
  | Ltrywith(e1, exn, e2) -> Ltrywith(subst e1, exn, subst e2)
  | Lifthenelse(e1, e2, e3) -> Lifthenelse(subst e1, subst e2, subst e3)
  | Lsequence(e1, e2) -> Lsequence(subst e1, subst e2)
  | Lwhile(e1, e2) -> Lwhile(subst e1, subst e2)
  | Lfor(v, e1, e2, dir, e3) -> Lfor(v, subst e1, subst e2, dir, subst e3)
  | Lassign(id, e) -> Lassign(id, subst e)
  | Lsend (k, met, obj, args, loc) ->
      Lsend (k, subst met, subst obj, List.map subst args, loc)
  | Levent (lam, evt) -> Levent (subst lam, evt)
  | Lifused (v, e) -> Lifused (v, subst e)
  and subst_decl (id, exp) = (id, subst exp)
  and subst_case (key, case) = (key, subst case)
  in subst lam


(* To let-bind expressions to variables *)

let bind str var exp body =
  match exp with
    Lvar var' when Ident.same var var' -> body
  | _ -> Llet(str, var, exp, body)

and commute_comparison = function
| Ceq -> Ceq| Cneq -> Cneq
| Clt -> Cgt | Cle -> Cge
| Cgt -> Clt | Cge -> Cle

and negate_comparison = function
| Ceq -> Cneq| Cneq -> Ceq
| Clt -> Cge | Cle -> Cgt
| Cgt -> Cle | Cge -> Clt

(* Type-check lambda expression *)

type error =
  | Not_subtype of lambda_type * lambda_type
  | Cant_apply of lambda_type * lambda_type
  | Unbound_var of Ident.t
  | Unbound_tvar of Ident.t

exception Error of error
let error err = raise (Error err)

  (*| Lt_bot
  | Lt_arrow of lambda_type * lambda_type
  | Lt_block of int list * (int * lambda_type list) list
  | Lt_var of Ident.t
  | Lt_mu of Ident.t * lambda_type*)

module AssumSet = Set.Make(struct type t = Ident.t * lambda_type let compare = compare end)
type assumptions = AssumSet.t * AssumSet.t

type env = {
  vars : lambda_type_env;
  types : lambda_type_env;
  assum : assumptions;
}

let find_var id env =
  try Ident.find_same id env
  with Not_found -> error (Unbound_var id)

let assuming_l id t assum = AssumSet.mem (id,t) (fst assum)
let assuming_r t id assum = AssumSet.mem (id,t) (snd assum)

let assum_empty = AssumSet.empty, AssumSet.empty
let assum_l id t assum = (AssumSet.add (id,t) (fst assum), snd assum)
let assum_r t id assum = (fst assum, AssumSet.add (id,t) (snd assum))

let rec assert_subtype assum tenv t1 t2 = match t1,t2 with
  | _, Lt_top -> ()
  | Lt_bot, _ -> ()

  | Lt_var id, t when assuming_l id t assum -> ()
  | t, Lt_var id when assuming_r t id assum -> ()
  | Lt_var id, t2 ->
    begin match 
      try Some (Ident.find_same id tenv)
      with Not_found -> None
    with
      | None -> error (Unbound_tvar id)
      | Some t1 -> assert_subtype (assum_l id t2 assum) tenv t1 t2
    end
  | t1, Lt_var id ->
    begin match 
      try Some (Ident.find_same id tenv)
      with Not_found -> None
    with
      | None -> error (Unbound_tvar id)
      | Some t2 -> assert_subtype (assum_r t1 id assum) tenv t1 t2
    end

  | t1, Lt_mu (id,t2) -> 
    let tenv = Ident.add id t2 tenv in
    assert_subtype assum tenv t1 t2
  | Lt_mu (id,t1), t2 -> 
    let tenv = Ident.add id t1 tenv in
    assert_subtype assum tenv t1 t2

  | Lt_arrow (a1,a2), Lt_arrow (b1,b2) ->
      assert_subtype assum tenv b1 a1;
      assert_subtype assum tenv a2 b2
  | Lt_value v1, Lt_value v2 ->
      assert_subvalue assum tenv t1 v1 t2 v2
  | Lt_top, _ | _, Lt_bot | (Lt_value _ | Lt_arrow _), (Lt_value _ | Lt_arrow _) ->
      error (Not_subtype (t1,t2))

and assert_subvalue assum tenv t1 v1 t2 v2 =
  let subconst c1 c2 = match c1,c2 with
    | _, `Any -> true
    | `Some l1, `Some l2 ->
        List.for_all (fun tag -> List.exists ((=) tag) l2) l1
    | _ -> false
  in
  let subblock b1 b2 =
    List.iter (fun (tag,values) ->
      let tag',values' = List.find (fun (tag',_) -> tag = tag') b2 in
      List.iter2 (assert_subtype assum tenv) values values'
    ) b1
  in
  try
    if not (subconst v1.const v2.const) then raise Not_found;
    subblock v1.blocks v2.blocks
  with Not_found | Invalid_argument "List.iter2" ->
    error (Not_subtype (t1,t2))

let lt_app tenv tfn targ = match tfn with
  | Lt_arrow (arg,result) -> assert_subtype assum_empty tenv targ arg; result
  | _ -> error (Cant_apply (tfn,targ))

let rec lt_check ~tenv ~env = function
  | Lvar id ->
      (try Ident.find_same id env
       with Not_found -> error (Unbound_var id))
  | Lconst const -> Lt_bot
  | Lapply (fn,args,loc) ->
      let targs = List.map (lt_check ~tenv ~env) args in
      let tfn = lt_check ~tenv ~env fn in
      List.fold_left (lt_app tenv) tfn targs

  | Lfunction (kind(*TODO*),args,body) -> 
      let env = List.fold_left
        (fun env (id,ty) -> Ident.add id ty env)
        env
        args
      in
      let tresult = lt_check ~tenv ~env body in
      List.fold_right
        (fun (id,targ) tres -> Lt_arrow (targ,tres))
        args
        tresult

  | Llet (kind(*TODO*),id,expr,body) ->
      let texpr = lt_check ~tenv ~env expr in
      let env = Ident.add id texpr env in
      lt_check ~tenv ~env body

  | Lprim (prim,args) -> failwith "lol"

  | _ -> failwith "TODO"

  (*
  | Lletrec (bindings,body) -> 
  | Lswitch (expr,switch) -> 
  | Lstaticraise _ -> failwith "TODO"
  | Lstaticcatch _ -> failwith "TODO"
  | Ltrywith (body,id,handler) -> 
  | Lifthenelse (cond,bt,bf) ->
  | Lsequence (l1,l2) -> 
  | Lwhile (pred,body) -> 
  | Lfor (id,l1,l2,d,body) -> 
  | Lassign (id,lam) ->
  | Lsend (k,l1,l2,args,loc) -> failwith "TODO"
  | Levent (lam,lev) -> failwith "TODO"
  | Lifused (id,lam) -> failwith "TODO"
  *)