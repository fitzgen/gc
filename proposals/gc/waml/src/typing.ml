open Source
open Syntax

module T = Type


(* Error handling *)

exception Error of Source.region * string

let error at fmt = Printf.ksprintf (fun s -> raise (Error (at, s))) fmt


(* Environments *)

type env = (Type.poly, Type.con, Type.sig_, Type.sig_) Env.env

module E =
struct
  include Env
  let extend_typ env y c =
    match find_opt_typ y env with
    | None -> Env.extend_typ env y c
    | Some c' ->
      error y.at "type binding for `%s` shadows previous binding at %s"
        y.it (Source.string_of_region c'.at)

  let extend_mod env x s =
    match find_opt_mod x env with
    | None -> Env.extend_mod env x s
    | Some s' ->
      error x.at "module binding for `%s` shadows previous binding at %s"
        x.it (Source.string_of_region s'.at)

  let extend_val_mono env x t = extend_val env x (T.Forall ([], t))
  let extend_typ_gnd env y t = extend_typ env y (T.Lambda ([], t))
  let extend_typ_var env y = extend_typ_gnd env y (T.var y.it)
  let extend_typs_var env ys = List.fold_left extend_typ_var env ys

  let adjoin env1 env2 =
    env1
    |> fold_vals (fun x t env -> extend_val env (x @@ t.at) t.it) env2
    |> fold_typs (fun y c env -> extend_typ env (y @@ c.at) c.it) env2
    |> fold_mods (fun x s env -> extend_mod env (x @@ s.at) s.it) env2
    |> fold_sigs (fun y s env -> extend_sig env (y @@ s.at) s.it) env2
end

type pass = FullPass | RecPrePass | RecPass


(* Paths *)

let check_val_var env x : T.poly =
  match E.find_opt_val x env with
  | Some t -> t.it
  | None -> error x.at "unknown value identifier `%s`" x.it

let check_typ_con env y : T.con =
  match E.find_opt_typ y env with
  | Some c -> c.it
  | None -> error y.at "unknown type identifier `%s`" y.it

let check_mod_var env x : T.sig_ =
  match E.find_opt_mod x env with
  | Some s -> s.it
  | None -> error x.at "unknown module identifier `%s`" x.it

let check_sig_con env y : T.sig_ =
  match E.find_opt_sig y env with
  | Some s -> s.it
  | None -> error y.at "unknown signature identifier `%s`" y.it


let rec check_str_path env q : T.str =
  match check_mod_path env q with
  | T.Str (bs, str) -> assert (bs = []); str
  | _ -> error q.at "structure expected"

and check_val_path env q : T.poly =
  match q.it with
  | PlainP x -> check_val_var env x
  | QualP (q1, x) ->
    match E.find_opt_val x (check_str_path env q1) with
    | Some t -> t.it
    | None -> error x.at "unknown value component `%s`" x.it

and check_typ_path env q : T.con =
  match q.it with
  | PlainP y -> check_typ_con env y
  | QualP (q1, y) ->
    match E.find_opt_typ y (check_str_path env q1) with
    | Some c -> c.it
    | None -> error y.at "unknown type component `%s`" y.it

and check_mod_path env q : T.sig_ =
  match q.it with
  | PlainP x -> check_mod_var env x
  | QualP (q1, x) ->
    match E.find_opt_mod x (check_str_path env q1) with
    | Some s -> s.it
    | None -> error x.at "unknown module component `%s`" x.it

and check_sig_path env q : T.sig_ =
  match q.it with
  | PlainP y -> check_sig_con env y
  | QualP (q1, y) ->
    match E.find_opt_sig y (check_str_path env q1) with
    | Some s -> s.it
    | None -> error y.at "unknown signature component `%s`" y.it


(* Types *)

let rec check_typ env t : T.typ =
  let t' = check_typ' env t in
  assert (t.et = None || T.eq t' (Option.get t.et));
  t.et <- Some t';
  t'

and check_typ' (env : env) t : T.typ =
  match t.it with
  | VarT y ->
    let T.Lambda (bs, t') = check_typ_con env y in
    assert (bs = []);
    t'
  | ConT (q, ts) ->
    let T.Lambda (bs, t') = check_typ_path env q in
    if List.length ts <> List.length bs then
      error t.at "wrong number of type arguments at type use";
    T.subst (T.typ_subst bs (List.map (check_typ env) ts)) t'
  | BoolT -> T.Bool
  | ByteT -> T.Byte
  | IntT -> T.Int
  | FloatT -> T.Float
  | TextT -> T.Text
  | RefT t1 -> T.Ref (check_typ env t1)
  | TupT ts -> T.Tup (List.map (check_typ env) ts)
  | FunT (t1, t2) -> T.Fun (check_typ env t1, check_typ env t2)


(* Patterns *)

let unify t1 t2 at =
  try T.unify t1 t2 with T.Unify (t1', t2') ->
    if t1 = t1' && t2 = t2' then
      error at "type mismatch: cannot unify types %s and %s"
        (T.string_of_typ t1) (T.string_of_typ t2)
    else
      error at "type mismatch: cannot unify types %s and %s, because %s and %s are incompatible"
        (T.string_of_typ t1) (T.string_of_typ t2)
        (T.string_of_typ t1') (T.string_of_typ t2')


let check_lit _env lit : T.typ =
  match lit with
  | IntL _ -> T.Int
  | FloatL _ -> T.Float
  | TextL _ -> T.Text

let rec check_pat env p : T.typ * env =
  let t, env' = check_pat' env p in
  p.et <- Some t;
  t, env'

and check_pat' env p : T.typ * env =
  match p.it with
  | WildP ->
    T.(infer Any), E.empty

  | VarP x ->
    let t = T.(infer Any) in
    t, E.singleton_val x (T.Forall ([], t))

  | LitP l ->
    let t = check_lit env l in
    t, E.empty

  | ConP (q, ps) ->
    let pt = check_val_path env q in
    let ts, env' = check_pats env ps in
    let t = T.(infer Any) in
    let t1' = List.fold_right (fun tI t -> T.Fun (tI, t)) ts t in
    unify (T.inst pt) t1' q.at;
    t, env'

  | RefP p1 ->
    let t1, env' = check_pat env p1 in
    T.Ref t1, env'

  | TupP ps ->
    let ts, env' = check_pats env ps in
    T.Tup ts, env'

  | AnnotP (p1, t) ->
    let t1, env' = check_pat env p1 in
    let t2 = check_typ env t in
    unify t1 t2 p1.at;
    t2, env'

and check_pats env = function
  | [] -> [], E.empty
  | p::ps ->
    let t, env1 = check_pat env p in
    let ts, env2 = check_pats env ps in
    try t::ts, E.disjoint_union env1 env2 with E.Clash x ->
      error p.at "duplicate variable `%s` in pattern" x


(* Expressions *)

let rec check_exp env e : T.typ =
  assert (e.et = None);
  let t = check_exp' env e in
  e.et <- Some t;
  t

and check_exp' env e : T.typ =
  match e.it with
  | VarE q ->
    T.inst (check_val_path env q)

  | LitE l ->
    check_lit env l

  | ConE q ->
    T.inst (check_val_path env q)

  | UnE (op, e1) ->
    let t1 = check_exp env e1 in
    (match op with
    | PosOp | NegOp -> unify t1 T.(infer Num) e.at
    | InvOp -> unify t1 T.Int e.at
    | NotOp -> unify t1 T.Bool e.at
    );
    t1

  | BinE (e1, op, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    unify t1 t2 e.at;
    (match op with
    | AddOp | SubOp | MulOp | DivOp -> unify t1 T.(infer Num) e.at
    | ModOp | AndOp | OrOp | XorOp | ShlOp | ShrOp -> unify t1 T.Int e.at
    | CatOp -> unify t1 T.Text e.at
    );
    t1

  | RelE (e1, op, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    unify t1 t2 e.at;
    (match op with
    | EqOp | NeOp -> unify t1 T.(infer Eq) e.at
    | LtOp | GtOp | LeOp | GeOp -> unify t1 T.(infer Ord) e.at
    );
    T.Bool

  | LogE (e1, op, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    unify t1 T.Bool e1.at;
    unify t2 T.Bool e2.at;
    T.Bool

  | RefE e1 ->
    let t1 = check_exp env e1 in
    T.Ref t1

  | DerefE e1 ->
    let t1 = check_exp env e1 in
    let t = T.(infer Any) in
    unify t1 (T.Ref t) e1.at;
    t

  | AssignE (e1, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    unify t1 (T.Ref t2) e1.at;
    T.Tup []

  | TupE es ->
    let ts = List.map (check_exp env) es in
    T.Tup ts

  | FunE (p1, e2) ->
    let t1, env' = check_pat env p1 in
    let t2 = check_exp (E.adjoin env env') e2 in
    T.Fun (t1, t2)

  | AppE (e1, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    let t = T.(infer Any) in
    unify t1 (T.Fun (t2, t)) e1.at;
    t

  | AnnotE (e1, t) ->
    let t1 = check_exp env e1 in
    let t2 = check_typ env t in
    unify t1 t2 e1.at;
    t2

  | IfE (e1, e2, e3) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    let t3 = check_exp env e3 in
    unify t1 T.Bool e1.at;
    unify t2 t3 e.at;
    t2

  | CaseE (e1, pes) ->
    let t1 = check_exp env e1 in
    let t = T.(infer Any) in
    List.iter (fun (pI, eI) ->
      let tI1, envI' = check_pat env pI in
      unify t1 tI1 pI.at;
      let tI2 = check_exp (E.adjoin env envI') eI in
      unify t tI2 eI.at;
    ) pes;
    t

  | LetE (ds, e1) ->
    let bs, env' = check_scope env ds in
    let t = check_exp (E.adjoin env env') e1 in
    let escape = E.Set.inter (T.free t) (E.Set.of_list bs) in
    Option.iter (fun b ->
      error e.at "type `%s` escapes scope of its definition in type %s"
        b (T.string_of_typ t)
    ) (E.Set.min_elt_opt escape);
    t


(* Declarations *)

and is_pure e =
  match e.it with
  | VarE _ | LitE _ | ConE _ | FunE _ -> true
  | UnE _ | BinE _ | RelE _ | LogE _ -> true
  | RefE _ | DerefE _ | AssignE _ -> false
  | TupE es -> List.for_all is_pure es
  | AppE (e1, e2) -> is_pure_con e1 && is_pure e2
  | AnnotE (e1, _) -> is_pure e1
  | IfE (e1, e2, e3) -> is_pure e1 && is_pure e2 && is_pure e3
  | CaseE (e1, pes) -> is_pure e1 && List.for_all (fun (_, eI) -> is_pure eI) pes
  | LetE _ -> false

and is_pure_con e =
  match e.it with
  | ConE _ -> true
  | AppE (e1, e2) -> is_pure_con e1 && is_pure e2
  | _ -> false


and check_dec pass env d : T.typ * T.var list * env =
  assert (d.et = None);
  let t, bs, env' = check_dec' pass env d in
  if pass = FullPass then d.et <- Some (t, env');
  t, bs, env'

and check_dec' pass env d : T.typ * T.var list * env =
  match d.it with
  | ExpD e ->
    let t = check_exp env e in
    t, [], E.empty

  | AssertD e ->
    let t = check_exp env e in
    unify t T.Bool e.at;
    T.Tup [], [], E.empty

  | ValD (p, e) when pass = RecPrePass ->
    let _, env' = check_pat env p in
    T.Tup [], [], env'

  | ValD (p, e) when pass = RecPass ->
    let t1, env' = check_pat env p in
    let t2 = check_exp env e in
    unify t1 t2 d.at;
    E.iter_vals (fun x t ->
      T.unify (T.inst t.it) (T.inst (E.find_val (x @@ t.at) env).it)
    ) env';
    T.Tup [], [], env'

  | ValD (p, e) ->
    let t1, env' = check_pat env p in
    let t2 = check_exp env e in
    unify t1 t2 d.at;
    let env'' =
      if not (is_pure e) then env' else
      E.map_vals (T.generalize (T.free_str env)) env'
    in
    T.Tup [], [], env''

  | TypD (y, ys, t) ->
    let t' = check_typ (E.extend_typs_var env ys) t in
    T.Tup [], [], E.singleton_typ y (T.Lambda (List.map it ys, t'))

  | DatD (y, ys, xtss) ->
    let b = y.it in
    let bs = List.map it ys in
    let t = T.Var (b, List.map T.var bs) in
    let env1 =
      if pass = RecPass then E.empty else
      E.singleton_typ y (T.Lambda (bs, t))
    in
    let env' = E.extend_typs_var (E.adjoin env env1) ys in
    let env2 =
      if pass = RecPrePass then E.empty else
      List.fold_left (fun env2 (x, ts) ->
        let ts' = List.map (check_typ env') ts in
        let t' = List.fold_right (fun tI t' -> T.Fun (tI, t')) ts' t in
        E.extend_val env2 x (T.Forall (bs, t'))
      ) E.empty xtss
    in
    T.Tup [], [b], E.adjoin env1 env2

  | ModD (x, m) ->
    let bs, s = T.unpack x.it (check_mod env m) in
    T.Tup [], bs, E.singleton_mod x s

  | SigD (y, s) ->
    let s' = check_sig env s in
    T.Tup [], [], E.singleton_sig y s'

  | RecD ds ->
    let _, bs, env' = check_decs RecPrePass env ds (T.Tup []) in
    let _, _, env'' = check_decs RecPass (E.adjoin env env') ds (T.Tup []) in
    let env''' =
      if E.is_empty_vals env'' then env'' else
      let _, t = E.choose_val env'' in
      let T.Forall (bs, t') = T.generalize (T.free_str env) t.it in
      if bs = [] then env'' else
      E.map_vals (fun (T.Forall (bs', t)) -> T.Forall (bs, t)) env''
    in
    T.Tup [], bs, env'''

  | InclD m ->
    let s = check_mod env m in
    match s with
    | T.Str (bs, env') -> T.Tup [], bs, env'
    | _ -> error m.at "structure expected, but got %s" (T.string_of_sig s)

and check_decs pass env ds t : T.typ * T.var list * env =
  match ds with
  | [] -> t, [], E.empty
  | d::ds' ->
    let t', bs1, env1 = check_dec pass env d in
    let t'', bs2, env2 = check_decs pass (E.adjoin env env1) ds' t' in
    try t'', bs1 @ bs2, E.disjoint_union env1 env2 with E.Clash x ->
      error d.at "duplicate definition for `%s`" x

and check_scope env ds : T.var list * env =
  let _t, bs, env' = check_decs FullPass env ds (T.Tup []) in
  bs, env'


(* Signatures *)

and check_spec pass env s : T.var list * env =
  assert (s.et = None);
  let bs, env' = check_spec' pass env s in
  if pass = FullPass then s.et <- Some env';
  bs, env'

and check_spec' pass env s : T.var list * env =
  match s.it with
  | ValS (x, ys, t) ->
    let t' = check_typ (E.extend_typs_var env ys) t in
    [], E.singleton_val x (T.Forall (List.map it ys, t'))

  | TypS (y, ys, Some t) ->
    let t' = check_typ (E.extend_typs_var env ys) t in
    [], E.singleton_typ y (T.Lambda (List.map it ys, t'))

  | TypS (y, ys, None) ->
    let b = y.it in
    let bs = List.map it ys in
    [b], E.singleton_typ y (T.Lambda (bs, T.Var (b, List.map T.var bs)))

  | DatS (y, ys, xtss) ->
    let b = y.it in
    let bs = List.map it ys in
    let t = T.Var (b, List.map T.var bs) in
    let env1 = E.singleton_typ y (T.Lambda (bs, t)) in
    let env' = E.extend_typs_var (E.adjoin env env1) ys in
    let env2 =
      if pass = RecPrePass then E.empty else
      List.fold_left (fun env2 (x, ts) ->
        let ts' = List.map (check_typ env') ts in
        let t' = List.fold_right (fun tI t' -> T.Fun (tI, t')) ts' t in
        E.extend_val env2 x (T.Forall (bs, t'))
      ) E.empty xtss
    in
    [b], E.adjoin env1 env2

  | ModS (x, s) ->
    let bs, s' = T.unpack x.it (check_sig env s) in
    bs, E.singleton_mod x s'

  | SigS (y, s) ->
    let s' = check_sig env s in
    [], E.singleton_sig y s'

  | RecS ss ->
    let bs, env' = check_specs RecPrePass env ss in
    let _, env'' = check_specs RecPass (E.adjoin env env') ss in
    bs, env''

  | InclS s ->
    let s' = check_sig env s in
    match s' with
    | T.Str (bs, env') -> bs, env'
    | _ ->
      error s.at "structure signature expected, but got %s" (T.string_of_sig s')

and check_specs pass env ss : T.var list * env =
  match ss with
  | [] -> [], E.empty
  | s::ss' ->
    let bs1, env1 = check_spec pass env s in
    let bs2, env2 = check_specs pass (E.adjoin env env1) ss' in
    try bs1 @ bs2, E.disjoint_union env1 env2 with E.Clash x ->
      error s.at "duplicate specification for `%s`" x


and check_sig env s : T.sig_ =
  assert (s.et = None);
  let s' = check_sig' env s in
  s.et <- Some s';
  s'

and check_sig' env s : T.sig_ =
  match s.it with
  | ConS q ->
    check_sig_path env q

  | StrS ss ->
    let bs, env' = check_specs FullPass env ss in
    T.Str (bs, env')

  | FunS (x, s1, s2) ->
    let bs1, s1' = T.unpack x.it (check_sig env s1) in
    let s2 = check_sig (E.extend_mod env x s1') s2 in
    T.Fct (bs1, s1', s2)

  | WithS (s1, q, ys, t) ->
    let s1' = check_sig env s1 in
    let t' = check_typ (E.extend_typs_var env ys) t in
    match s1' with
    | T.Str (bs1, str1) ->
      (match check_typ_path str1 q with
      | T.Lambda (bs2, T.Var (b, ts2))
        when List.mem b bs1 && ts2 = List.map T.var bs2 ->
        if List.length ys <> List.length bs2 then
          error q.at "refinement type has incompatible arity";
        let c = T.Lambda (List.map it ys, t') in
        T.Str (List.filter ((<>) b) bs1, T.subst_str (T.con_subst [b] [c]) str1)
      | _ -> error q.at "refined type is not abstract in signature"
      )
    | _ ->
      error s1.at "structure signature expected, but got %s"
        (T.string_of_sig s1')


(* Modules *)

and check_mod env m : T.sig_ =
  assert (m.et = None);
  let s = check_mod' env m in
  m.et <- Some s;
  s

and check_mod' env m : T.sig_ =
  match m.it with
  | VarM q ->
    check_mod_path env q

  | StrM ds ->
    let bs, env' = check_scope env ds in
    T.Str (bs, env')

  | FunM (x, s, m) ->
    let bs, s1 = T.unpack x.it (check_sig env s) in
    let s2 = check_mod (E.extend_mod env x s1) m in
    T.Fct (bs, s1, s2)

  | AppM (m1, m2) ->
    let s1 = check_mod env m1 in
    let s2 = check_mod env m2 in
    (match s1 with
    | T.Fct (bs, s2', s) ->
      let su = try T.sub s2 (T.pack bs s2') with T.Mismatch s ->
        error m.at "module does not match functor parameter signature, %s" s
      in
      T.subst_sig su s  (* TODO: fresh names *)
    | _ -> error m1.at "functor expected but got %s" (T.string_of_sig s1)
    )

  | AnnotM (m1, s) ->
    let s1 = check_mod env m1 in
    let s2 = check_sig env s in
    (try ignore (T.sub s1 s2) with T.Mismatch s ->
      error m.at "module does not match annotation, %s" s
    );
    s2  (* TODO: fresh names *)

  | LetM (ds, m) ->
    let bs, env' = check_scope env ds in
    let s = check_mod (E.adjoin env env') m in
    let escape = E.Set.inter (T.free_sig s) (E.Set.of_list bs) in
    Option.iter (fun b ->
      error m.at "type `%s` escapes scope of its definition in signature %s"
        b (T.string_of_sig s)
    ) (E.Set.min_elt_opt escape);
    s


(* Programs *)

let get_env = ref (fun _at _url -> failwith "get_sig")

let check_imp env (bs', env') d : T.var list * env =
  let ImpD (x, url) = d.it in
  let bs, str = !get_env d.at url in
  d.et <- Some str;
  let bs', s = T.unpack ("\"" ^ url ^ "\"") (T.Str (bs, str)) in
  bs' @ bs, E.extend_mod env' x s

let env0 =
  let at = Prelude.region in
  E.empty
  |> List.fold_right (fun (y, t) env ->
      E.extend_typ_gnd env (y @@ at) (check_typ env (t @@ at))
    ) Prelude.typs
  |> List.fold_right (fun (x, l) env ->
      E.extend_val_mono env (x @@ at) (check_lit env l)
    ) Prelude.vals
  |> List.fold_right (fun (x, t) env ->
      E.extend_val_mono env (x @@ at) (check_typ env (t @@ at))
    ) Prelude.cons

let check_prog env p : T.typ * T.var list * env =
  assert (p.et = None);
  let Prog (is, ds) = p.it in
  let env' = E.adjoin env0 env in
  let bs1, env1 = List.fold_left (check_imp env') ([], E.empty) is in
  let t, bs2, env2 = check_decs FullPass (E.adjoin env' env1) ds (T.Tup []) in
  let env'' = E.adjoin env1 env2 in
  T.default_str env2;
  p.et <- Some (t, env'');
  t, bs2, env''