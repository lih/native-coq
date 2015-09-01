open Errors
open Term
open Environ
open Reduction
open Univ
open Declarations
open Names
open Inductive
open Util
open Unix
open Nativecode
open Inductiveops
open Closure
open Nativevalues

let decompose_prod env t =
  let (name,dom,codom as res) = destProd (whd_betadeltaiota env t) in
  if name = Anonymous then (Name (id_of_string "x"),dom,codom)
  else res

let app_type env c =
  let t = whd_betadeltaiota env c in
  try destApp t with _ -> (t,[||])

 
let find_rectype_a env c =
  let (t, l) = app_type env c in
  match kind_of_term t with
  | Ind ind -> (ind, l)
  | _ -> raise Not_found

(* Instantiate inductives and parameters in constructor type *)

let type_constructor mind mib typ params = 
  let s = ind_subst mind mib in
  let ctyp = substl s typ in
  let nparams = Array.length params in
  if nparams = 0 then ctyp
  else
    let _,ctyp = decompose_prod_n nparams ctyp in   
    substl (List.rev (Array.to_list params)) ctyp

let construct_of_constr_notnative const env tag (mind, _ as ind) allargs =
  let mib,mip = lookup_mind_specif env ind in
  let nparams = mib.mind_nparams in
  let i = Cbytecodes.invert_tag const tag mip.mind_reloc_tbl in
  let params = Array.sub allargs 0 nparams in
  let ctyp = type_constructor mind mib (mip.mind_nf_lc.(i-1)) params in
  (mkApp(mkConstruct(ind,i), params), ctyp)
 

let construct_of_constr const env tag typ =
  let t, l = app_type env typ in
  match kind_of_term t with
  | Ind ind -> 
      construct_of_constr_notnative const env tag ind l
  | _ ->
      assert (t = Typeops.type_of_int env);
      (mkInt (Uint63.of_int tag), t)

let construct_of_constr_const env tag typ = 
  fst (construct_of_constr true env tag typ)

let construct_of_constr_block = construct_of_constr false

let build_branches_type env (mind,_ as _ind) mib mip params dep p =
  let rtbl = mip.mind_reloc_tbl in
  (* [build_one_branch i cty] construit le type de la ieme branche (commence
     a 0) et les lambda correspondant aux realargs *)
  let build_one_branch i cty =
    let typi = type_constructor mind mib cty params in
    let decl,indapp = Term.decompose_prod typi in
    let ind,cargs = find_rectype_a env indapp in
    let nparams = Array.length params in
    let carity = snd (rtbl.(i)) in
    let crealargs = Array.sub cargs nparams (Array.length cargs - nparams) in
    let codom = 
      let papp = mkApp(lift (List.length decl) p,crealargs) in
      if dep then
	let cstr = ith_constructor_of_inductive ind (i+1) in
        let relargs = Array.init carity (fun i -> mkRel (carity-i)) in
	let dep_cstr = mkApp(mkApp(mkConstruct cstr,params),relargs) in
	mkApp(papp,[|dep_cstr|])
      else papp
    in 
    decl, codom
  in Array.mapi build_one_branch mip.mind_nf_lc

let build_case_type dep p realargs c = 
  if dep then mkApp(mkApp(p, realargs), [|c|])
  else mkApp(p, realargs)

(* TODO move this function *)
let type_of_rel env n = 
  let (_,_,ty) = lookup_rel n env in
  lift n ty

let type_of_prop = mkSort type1_sort

let type_of_sort s = 
  match s with
  | Prop _ -> type_of_prop
  | Type u -> mkType (Univ.super u)

let type_of_var env id = 
  try let (_,_,ty) = lookup_named id env in ty
  with Not_found ->
    anomaly ("type_of_var: variable "^(string_of_id id)^" unbound")

let sort_of_product env domsort rangsort =
  match (domsort, rangsort) with
    (* Product rule (s,Prop,Prop) *)
    | (_,       Prop Null)  -> rangsort
    (* Product rule (Prop/Set,Set,Set) *)
    | (Prop _,  Prop Pos) -> rangsort
    (* Product rule (Type,Set,?) *)
    | (Type u1, Prop Pos) ->
        if engagement env = Some ImpredicativeSet then
          (* Rule is (Type,Set,Set) in the Set-impredicative calculus *)
          rangsort
        else
          (* Rule is (Type_i,Set,Type_i) in the Set-predicative calculus *)
          Type (sup u1 type0_univ)
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Prop Pos,  Type u2)  -> Type (sup type0_univ u2)
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Prop Null, Type _)  -> rangsort
    (* Product rule (Type_i,Type_i,Type_i) *)
    | (Type u1, Type u2) -> Type (sup u1 u2)

(* normalisation of values *)

let branch_of_switch lvl ans bs = 
  let tbl = ans.asw_reloc in
  let branch i = 
    let tag,arity = tbl.(i) in
    let ci = 
      if arity = 0 then mk_const tag
      else mk_block tag (mk_rels_accu lvl arity) in
    bs ci in
  Array.init (Array.length tbl) branch

let rec nf_val env v typ =
  match kind_of_value v with
  | Vaccu accu -> nf_accu env accu
  | Vfun f -> 
      let lvl = nb_rel env in
      let name,dom,codom = 
	try decompose_prod env typ
	with _ -> (* TODO: is this the right exception to raise? *)
	  raise (Type_errors.TypeError(env,Type_errors.ReferenceVariables typ))
      in
      let env = push_rel (name,None,dom) env in
      let body = nf_val env (f (mk_rel_accu lvl)) codom in
      mkLambda(name,dom,body)
  | Vconst n -> construct_of_constr_const env n typ
  | Vblock b ->
      let capp,ctyp = construct_of_constr_block env (block_tag b) typ in
      let args = nf_bargs env b ctyp in
      mkApp(capp,args)
  | Vint i -> mkInt i
  | Varray p -> nf_array env p typ

and nf_type env v =
  match kind_of_value v with
  | Vaccu accu -> nf_accu env accu
  | _ -> assert false

and nf_type_sort env v =
  match kind_of_value v with
  | Vaccu accu -> 
      let t,s = nf_accu_type env accu in
      let s = try destSort s with _ -> assert false in
      t, s
  | _ -> assert false

and nf_accu env accu =
  let atom = atom_of_accu accu in
  if accu_nargs accu = 0 then nf_atom env atom
  else
    let a,typ = nf_atom_type env atom in
    let _, args = nf_args env accu typ in
    mkApp(a,Array.of_list args)

and nf_accu_type env accu =
  let atom = atom_of_accu accu in
  if accu_nargs accu = 0 then nf_atom_type env atom
  else
    let a,typ = nf_atom_type env atom in
    let t, args = nf_args env accu typ in
    mkApp(a,Array.of_list args), t

and nf_args env accu t =
  let aux arg (t,l) = 
	let _,dom,codom = try decompose_prod env t with _ -> exit 123 in
	let c = nf_val env arg dom in
	(subst1 c codom, c::l)
  in
  let t,l = List.fold_right aux (args_of_accu accu) (t,[]) in
  t, List.rev l

and nf_bargs env b t =
  let t = ref t in
  let len = block_size b in
  Array.init len
    (fun i ->
      let _,dom,codom = try decompose_prod env !t with _ -> exit 124 in
      let c = nf_val env (block_field b i) dom in
      t := subst1 c codom; c)

and nf_atom env atom =
  match atom with
  | Arel i -> mkRel (nb_rel env - i)
  | Aconstant cst -> mkConst cst
  | Aind ind -> mkInd ind
  | Asort s -> mkSort s
  | Avar id -> mkVar id
  | Aprod(n,dom,codom) ->
      let dom = nf_type env dom in
      let vn = mk_rel_accu (nb_rel env) in
      let env = push_rel (n,None,dom) env in
      let codom = nf_type env (codom vn) in
      mkProd(n,dom,codom)
  | _ -> fst (nf_atom_type env atom)

and nf_atom_type env atom = 
  match atom with
  | Arel i ->
      let n = (nb_rel env - i) in
      mkRel n, type_of_rel env n
  | Aconstant cst ->
      mkConst cst, Typeops.type_of_constant env cst
  | Aind ind ->
      mkInd ind, Inductiveops.type_of_inductive env ind 
  | Asort s ->
      mkSort s, type_of_sort s
  | Avar id ->
      mkVar id, type_of_var env id
  | Acase(ans,accu,p,bs) ->
      let a,ta = nf_accu_type env accu in
      let (mind,_ as ind),allargs = find_rectype_a env ta in
      let (mib,mip) = Inductive.lookup_mind_specif env ind in
      let nparams = mib.mind_nparams in
      let params,realargs = Util.array_chop nparams allargs in
      let pT = 
	hnf_prod_applist env 
	  (Inductiveops.type_of_inductive env ind) (Array.to_list params) in
      let pT = whd_betadeltaiota env pT in
      let dep, p = nf_predicate env ind mip params p pT in
      (* Calcul du type des branches *)
      let btypes = build_branches_type env ind mib mip params dep p in
      (* calcul des branches *)
      let bsw = branch_of_switch (nb_rel env) ans bs in
      let mkbranch i v =
	let decl,codom = btypes.(i) in
	let env = 
	  List.fold_right 
	    (fun (name,t) env -> push_rel (name,None,t) env) decl env in
	let b = nf_val env v codom in
	compose_lam decl b 
      in 
      let branchs = Array.mapi mkbranch bsw in
      let tcase = build_case_type dep p realargs a in
      let ci = ans.asw_ci in
      mkCase(ci, p, a, branchs), tcase 
  | Afix(tt,ft,rp,s) ->
      let tt = Array.map (nf_type env) tt in
      let name = Array.map (fun _ -> (Name (id_of_string "Ffix"))) tt in
      let lvl = nb_rel env in
      let fargs = mk_rels_accu lvl (Array.length ft) in
      let env = push_rec_types (name,tt,[||]) env in
      let ft = Array.mapi (fun i v -> nf_val env (napply v fargs) tt.(i)) ft in
      mkFix((rp,s),(name,tt,ft)), tt.(s)
  | Acofix(tt,ft,s,_) | Acofixe(tt,ft,s,_) ->
      let tt = Array.map (nf_type env) tt in
      let name = Array.map (fun _ -> (Name (id_of_string "Fcofix"))) tt in
      let lvl = nb_rel env in
      let fargs = mk_rels_accu lvl (Array.length ft) in
      let env = push_rec_types (name,tt,[||]) env in
      let ft = Array.mapi (fun i v -> nf_val env (napply v fargs) tt.(i)) ft in
      mkCoFix(s,(name,tt,ft)), tt.(s)
  | Aprod(n,dom,codom) ->
      let dom,s1 = nf_type_sort env dom in
      let vn = mk_rel_accu (nb_rel env) in
      let env = push_rel (n,None,dom) env in
      let codom,s2 = nf_type_sort env (codom vn) in
      mkProd(n,dom,codom), mkSort (sort_of_product env s1 s2)

and nf_array env p typ =
  let t, allargs = app_type env typ in 
  assert (Typeops.type_of_array env = t);
  let typ_elem = allargs.(0) in
  let l = Uint63.to_int (Parray.length p) in
      (* FIXME: use a combinator from PArray *)
  let p = 
    Array.init (l + 1)
      (fun i -> 
	nf_val env (Parray.get p (Uint63.of_int i)) typ_elem) in
  mkArray(typ_elem, p)

  
and  nf_predicate env ind mip params v pT =
  match kind_of_value v, kind_of_term pT with
  | Vfun f, Prod _ ->
      let k = nb_rel env in
      let vb = f (mk_rel_accu k) in
      let name,dom,codom = try decompose_prod env pT with _ -> exit 121 in
      let dep,body = 
	nf_predicate (push_rel (name,None,dom) env) ind mip params vb codom in
      dep, mkLambda(name,dom,body)
  | Vfun f, _ -> 
      let k = nb_rel env in
      let vb = f (mk_rel_accu k) in
      let name = Name (id_of_string "c") in
      let n = mip.mind_nrealargs in
      let rargs = Array.init n (fun i -> mkRel (n-i)) in
      let params = if n=0 then params else Array.map (lift n) params in
      let dom = mkApp(mkInd ind,Array.append params rargs) in
      let body = nf_type (push_rel (name,None,dom) env) vb in
      true, mkLambda(name,dom,body)
  | _, _ -> false, nf_type env v

let native_norm env c ty =  
  if !Flags.no_native_compiler then
    error "Native_compute reduction has been disabled"
  else
  let penv = Environ.pre_env env in 
  (*
  Format.eprintf "Numbers of free variables (named): %i\n" (List.length vl1);
  Format.eprintf "Numbers of free variables (rel): %i\n" (List.length vl2);
  *)
  let ml_filename, prefix = Nativelib.get_ml_filename () in
  let code, upd = mk_norm_code penv prefix c in
  match Nativelib.compile ml_filename code with
    | true,fn ->
        print_endline "Running norm ...";
	let t0 = Sys.time () in
	Nativelib.call_linker prefix fn (Some upd);
	let t1 = Sys.time () in
	Format.eprintf "Evaluation done in %.5f@." (t1 -. t0);
	nf_val env !Nativelib.rt1 ty
    | _ -> anomaly "Compilation failure" 
