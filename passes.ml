
(*
The MIT License (MIT)

Copyright (c) 2014 Leonardo Laguna Ruiz, Carl Jönsson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*)

(** Transformations and optimizations of the syntax tree *)

open Types
open CCList
open TypesUtil


(** Generic type of transformations *)
type ('data,'value) transformation = 'data -> 'value -> 'data * 'value

(** Generic type of expanders *)
type ('data,'value) expander = 'data -> 'value -> 'data * 'value list

(** Generic type of folders *)
type ('data,'value) folder = 'data -> 'value -> 'data


(** Makes a chain of transformations. E.g. foo |-> bar will apply first foo then bar. *)
let (|->) : ('data,'value) transformation -> ('data,'value) transformation -> ('data,'value) transformation =
   fun a b ->
   fun state exp ->
      let new_state,new_exp = a state exp in
      b new_state new_exp

(** Pipes a pair (state,value) into transformation functions *)
let (|+>) : ('state * 'value) -> ('state, 'value) transformation -> ('state * 'value) =
   fun (state,value) transformation ->
      transformation state value

(** Default inline weight *)
let default_inline_weight = 10

(** Traversing state one *)
type state_t1 =
   {
      functions       : parse_exp NamedIdMap.t;
      function_weight : int NamedIdMap.t;
      counter         : int;
      inline_weight   : int;
   }
(* ======================= *)

let returnBindsAndDecl ((decls:val_bind list),(binds: parse_exp list)) (bind:val_bind) =
   match bind with
   | ValBind(name,init,exp) ->
      let loc = TypesUtil.getNamedIdLocation name in
      ValNoBind(name,init)::decls, StmtBind(PId(name),exp,loc)::binds
   | ValNoBind(name,init) -> ValNoBind(name,init)::decls,binds

(** Transforms mem x=0; -> mem x; x=0; *)
let separateBindAndDeclaration : ('data,parse_exp) expander =
   fun state stmt ->
      match stmt with
      | StmtMem(vlist,loc) ->
         let new_vlist,binds = List.fold_left returnBindsAndDecl ([],[]) vlist in
         let stmts = StmtMem(List.rev new_vlist,loc)::binds  in
         state,stmts
      | StmtVal(vlist,loc) ->
         let new_vlist,binds = List.fold_left returnBindsAndDecl ([],[]) vlist in
         let stmts = StmtVal(List.rev new_vlist,loc)::binds  in
         state,stmts
      | _ -> state,[stmt]

(* ======================= *)

(** Transforms val x,y; -> val x; val y; *)
let makeSingleDeclaration : ('data,parse_exp) expander =
   fun state stmt ->
      match stmt with
      | StmtVal(vlist,loc) ->
         let stmts = List.map (fun a -> StmtVal([a],loc)) vlist in
         state,stmts
      | StmtMem(vlist,loc) ->
         let stmts = List.map (fun a -> StmtMem([a],loc)) vlist in
         state,stmts
      | _ -> state,[stmt]

(* ======================= *)

(** Adds a default name to all function calls. e.g. foo(x) ->  _inst_0:foo(x) *)
let nameFunctionCalls : ('data,parse_exp) transformation =
   fun state exp ->
      match exp with
      | PCall(SimpleId(name,loc),args,floc,attr) ->
         let inst = "_inst"^(string_of_int state.counter) in
         let new_state = {state with counter = state.counter+1} in
         new_state,PCall(NamedId(inst,name,loc,loc),args,floc,attr)
      | _ -> state,exp

(* ======================= *)

(** Transforms all operators into function calls *)
let operatorsToFunctionCalls : ('data,parse_exp) transformation =
   fun state exp ->
      match exp with
      | PUnOp(op,e,loc) ->
         state,PCall(NamedId("_",op,loc,loc),[e],loc,[])
      | PBinOp(op,e1,e2,loc) ->
         state,PCall(NamedId("_",op,loc,loc),[e1;e2],loc,[])
      | _ -> state,exp

(* ======================= *)
let simplifyTupleAssign : ('data,parse_exp) expander =
   fun state exp ->
      match exp with
      | StmtBind(PTuple(lhs,loc1),PTuple(rhs,loc2),loc) ->
         let lhs_id = TypesUtil.getIdsInExpList lhs in
         let rhs_id = TypesUtil.getIdsInExpList rhs in
         let common = Set.inter ~eq:TypesUtil.compareName lhs_id rhs_id in
         begin
            match common with
            | [] -> state,List.map2 (fun a b -> StmtBind(a,b,loc)) lhs rhs
            | _  ->
               let init = state.counter in
               let tmp_vars  = List.mapi (fun i _ -> SimpleId("_tpl"^(string_of_int (i+init)),default_loc)) lhs in
               let tmp_e     = List.map (fun a -> PId(a)) tmp_vars in
               let to_tmp    = List.map2 (fun a b -> StmtBind(a,b,loc)) tmp_e rhs in
               let from_tmp  = List.map2 (fun a b -> StmtBind(a,b,loc)) lhs tmp_e in
               let decl = List.map (fun a -> StmtVal([ValNoBind(a,None)],loc)) tmp_vars in
               let new_state = { state with counter = init+(List.length lhs)} in
               new_state,decl@to_tmp@from_tmp
         end
      | _ -> state,[exp]


(* ======================= *)

(** True if the attributes contains SimpleBinding *)
let isSimpleBinding attr = List.exists (fun a->a=SimpleBinding) attr

(** Creates bindings for all function calls in an expression *)
let bindFunctionCallsInExp : (int * parse_exp list,parse_exp) transformation =
   fun data exp ->
      match exp with
      | PCall(name,args,loc,attr) when not (isSimpleBinding attr) ->
         let count,stmts = data in
         let tmp_var = SimpleId("_tmp"^(string_of_int count),default_loc) in
         let decl = StmtVal([ValNoBind(tmp_var,None)],loc) in
         let bind_stmt = StmtBind(PId(tmp_var),PCall(name,args,loc,SimpleBinding::attr),loc) in
         (count+1,[bind_stmt;decl]@stmts),PId(tmp_var)
      | _ -> data,exp

(** Binds all function calls to a variable. e.g. foo(bar(x)) -> tmp1 = bar(x); tmp2 = foo(tmp1); tmp2; *)
let bindFunctionCalls : ('data,parse_exp) expander  =
   fun state stmt ->
      match stmt with
      | StmtBind(lhs,PCall(name,args,loc1,attr),loc) ->
         let (count,stmts),new_args = TypesUtil.traverseBottomExpList bindFunctionCallsInExp (state.counter,[]) args in
         {state with counter = count},(List.rev (StmtBind(lhs,PCall(name,new_args,loc,attr),loc)::stmts))
      | StmtBind(lhs,rhs,loc) ->
         let (count,stmts),new_rhs = TypesUtil.traverseBottomExp bindFunctionCallsInExp (state.counter,[]) rhs in
         {state with counter = count},(List.rev (StmtBind(lhs,new_rhs,loc)::stmts))
      | StmtReturn(e,loc) ->
         let (count,stmts),new_e = TypesUtil.traverseBottomExp bindFunctionCallsInExp (state.counter,[]) e in
         {state with counter = count},(List.rev (StmtReturn(new_e,loc)::stmts))
      | StmtIf(cond,then_stmts,else_stmts,loc) ->
         let (count,stmts),new_cond = TypesUtil.traverseBottomExp bindFunctionCallsInExp (state.counter,[]) cond in
         {state with counter = count},(List.rev (StmtIf(new_cond,then_stmts,else_stmts,loc)::stmts))

      | _ -> state,[stmt]

(* ======================= *)

(** Wraps the values of an if expression into return statements *)
let wrapIfExpValues : ('data,parse_exp) transformation =
   fun state exp ->
      match exp with
      | PIf(cond,then_exp,else_exp,loc) ->
         state,PIf(cond,StmtReturn(then_exp,loc),StmtReturn(else_exp,loc),loc)
      | _ -> state,exp


(* ======================= *)

(** Adds all function definitions to a map in the state and also the weight of the function *)
let collectFunctionDefinitions : ('data,parse_exp) folder =
   fun state exp ->
      match exp with
      | StmtFun(name,args,stmts,loc) ->
         let simple_name = removeNamedIdType name in
         let weight = getExpListWeight stmts in
         (*let _ = Printf.printf "*** Adding function '%s' with weight %i\n" (namedIdStr simple_name) weight in*)
         { state with
           functions = NamedIdMap.add simple_name exp state.functions;
           function_weight = NamedIdMap.add simple_name weight state.function_weight }
      | _ -> state

(* ======================= *)

(** Changes appends the given prefix to all named_ids *)
let prefixAllNamedIds : ('data,parse_exp) transformation =
   fun prefix exp ->
      match exp with
      | PId(name) -> prefix,PId(prefixNamedId prefix name)
      | _ -> prefix,exp

let inlineFunctionCall (state:'data) (name:named_id) (args:parse_exp list) loc : parse_exp list =
   let call_name,ftype = getFunctionTypeAndName name in
   let fname = SimpleId(ftype,default_loc) in
   let function_def = NamedIdMap.find fname state.functions in
   match function_def with
   | StmtFun(_,fargs,fbody,_) ->
      let prefix = call_name^"_" in
      let fargs_prefixed = List.map (prefixNamedId prefix) fargs in
      let _,fbody_prefixed = TypesUtil.traverseBottomExpList prefixAllNamedIds prefix fbody in
      let new_decl = List.map (fun a-> StmtVal([ValNoBind(a,None)],loc)) fargs_prefixed in
      let new_assignments = List.map2 (fun a b -> StmtBind(PId(a),b,loc)) fargs_prefixed args in
      new_decl@new_assignments@fbody_prefixed
   | _ -> failwith "inlineFunctionCall: Invalid function declaration"

let inlineStmts : ('data,parse_exp) expander =
   fun state exp ->
      match exp with
      | PCall(fname_full,args,loc,_) ->
         let name,ftype = getFunctionTypeAndName fname_full in
         let fname = SimpleId(ftype,default_loc) in
         if name = "_" || not (NamedIdMap.mem fname state.functions)  then
            state,[exp]
         else
            let weight = NamedIdMap.find fname state.function_weight in
            if weight > state.inline_weight then
               state,[exp]
            else begin
               let new_stmts = inlineFunctionCall state fname_full args loc in
               state,new_stmts
            end
      | _ -> state,[exp]

(* ======================= *)

(** Returns Some(e,stmts) if the sequence has a single return in the form 'stmts; return e;' *)
let rec hasSingleReturnAtEnd (acc:parse_exp list) (stmts:parse_exp list) : (parse_exp * parse_exp list) option =
   match stmts with
   | [] -> None
   | [StmtReturn(e,_)] -> Some(e,List.rev acc)
   | StmtReturn(_,_)::_ -> None
   | h::t -> hasSingleReturnAtEnd (h::acc) t

(** Transforms x = {return y;}; -> x = y;  and _ = { stmts; } -> stmts *)
let simplifySequenceBindings : ('data,parse_exp) expander =
   fun state exp ->
      match exp with
      | StmtBind(lhs,StmtSequence(stmts,_),loc) ->
         begin
            match hasSingleReturnAtEnd [] stmts with
            | Some(e,rem_stmts) -> state,rem_stmts@[StmtBind(lhs,e,loc)]
            | None -> state,[exp]
         end
      | StmtSequence(stmts,_) ->
         let contains_return = List.exists (fun a -> match a with StmtReturn(_,_) -> true | _ -> false) stmts in
         if contains_return then
            state,[exp]
         else
            state,stmts
      | _ -> state,[exp]

(* ======================= *)

(** Takes a lis of statements and removes the duplicated mem declarations *)
let rec removeDuplicateMem (declared:bool NamedIdMap.t) (acc:parse_exp list) (stmts:parse_exp list) : parse_exp list =
   match stmts with
   | [] -> List.rev acc
   | StmtMem([ValNoBind(name,init)],_)::t when NamedIdMap.mem name declared ->
      removeDuplicateMem declared acc t
   | (StmtMem([ValNoBind(name,init)],_) as h)::t ->
      removeDuplicateMem (NamedIdMap.add name true declared) (h::acc) t
   | h::t -> removeDuplicateMem declared (h::acc) t

(** Removes duplicated mem declarations  from StmtSequence *)
let removeDuplicateMemStmts : ('data,parse_exp) traverser =
   fun state exp ->
      match exp with
      | StmtSequence(stmts,loc) ->
         let new_stmts = removeDuplicateMem NamedIdMap.empty [] stmts in
         state,StmtSequence(new_stmts,loc)
      | _ -> state,exp
(* ======================= *)

(** Takes a fold function and wrap it as it was a transformation so it can be chained with |+> *)
let foldAsTransformation (f:('data,parse_exp) folder) (state:'date) (exp_list:parse_exp list) : 'data * parse_exp list =
   let new_state = TypesUtil.foldTopExpList f state exp_list in
   new_state,exp_list

(** Takes a list of statements and puts them into a StmtSequence *)
let makeStmtSequence (state:'data) (stmts:parse_exp list) : 'data * parse_exp list =
   match stmts with
   | []  -> state,[]
   | [_] -> state,stmts
   | _   -> state,[StmtSequence(stmts,default_loc)]

let inlineFunctionBodies (state:'data) (exp_list:parse_exp list) : 'data * parse_exp list =
   let inlineFunctionBody name fun_decl table =
      match fun_decl with
      | StmtFun(fname,fargs,fbody,loc) ->
         let _,new_fbody = TypesUtil.expandStmtList inlineStmts state fbody in
         NamedIdMap.add name (StmtFun(fname,fargs,new_fbody,loc)) table
      | _ -> table
   in
   let new_functions = NamedIdMap.fold inlineFunctionBody state.functions NamedIdMap.empty in
   { state with functions = new_functions },exp_list

let applyTransformations (results:parser_results) =
   let initial_state =
      {
         counter = 0;
         functions = NamedIdMap.empty;
         function_weight = NamedIdMap.empty;
         inline_weight = default_inline_weight;
      }
   in
   let passes stmts =
      (initial_state,[StmtSequence(stmts,default_loc)])
      |+> TypesUtil.traverseTopExpList (nameFunctionCalls|->operatorsToFunctionCalls|->wrapIfExpValues)
      |+> TypesUtil.expandStmtList separateBindAndDeclaration
      |+> TypesUtil.expandStmtList makeSingleDeclaration
      |+> TypesUtil.expandStmtList bindFunctionCalls
      |+> TypesUtil.expandStmtList simplifyTupleAssign
      |+> foldAsTransformation collectFunctionDefinitions
      |+> inlineFunctionBodies
      |+> foldAsTransformation collectFunctionDefinitions
      |+> TypesUtil.expandStmtList inlineStmts
      |+> makeStmtSequence
      |+> TypesUtil.expandStmtList simplifySequenceBindings
      |+> makeStmtSequence
      |+> TypesUtil.traverseTopExpList removeDuplicateMemStmts
      |> snd
   in
   let new_stmts = CCError.map passes results.presult in
   { results with presult = new_stmts }


