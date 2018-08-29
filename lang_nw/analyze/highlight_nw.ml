(* Yoann Padioleau
 *
 * Copyright (C) 2010 Facebook
 * Copyright (C) 2015, 2018 Yoann Padioleau
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

module Ast = Ast_nw
module T = Lexer_nw
module TH = Token_helpers_nw

open Highlight_code

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* todo: now that we have a fuzzy AST for noweb, we could use that
 * instead of some of those span_xxx functions.
 *)
let span_close_brace xs = xs +> Common2.split_when (function 
  | T.TCBrace _ -> true | _ -> false)

let span_newline xs = xs +> Common2.split_when (function 
  | T.TCommentNewline _ -> true | _ -> false)


let tag_all_tok_with ~tag categ xs = 
  xs +> List.iter (fun tok ->
    let info = TH.info_of_tok tok in
    tag info categ
  )

(*****************************************************************************)
(* Code highlighter *)
(*****************************************************************************)

(* The idea of the code below is to visit the program either through its
 * AST or its list of tokens. The tokens are easier for tagging keywords,
 * number and basic entities. The AST is better for other things.
 *)
let visit_program ~tag_hook _prefs (_program, toks) =
  let already_tagged = Hashtbl.create 101 in
  let tag = (fun ii categ ->
    tag_hook ii categ;
    Hashtbl.replace already_tagged ii true
  )
  in

  (* -------------------------------------------------------------------- *)
  (* toks phase 1 (sequence of tokens) *)
  (* -------------------------------------------------------------------- *)

  let rec aux_toks xs = 
    match xs with
    | [] -> ()

    (* pad-specific: *)
    |   T.TComment(ii)
      ::T.TCommentNewline (_ii2)
      ::T.TComment(ii3)
      ::T.TCommentNewline (_ii4)
      ::T.TComment(ii5)
      ::xs ->
        let s = Parse_info.str_of_info ii in
        let s5 =  Parse_info.str_of_info ii5 in
        (match () with
        | _ when s =~ ".*\\*\\*\\*\\*" && s5 =~ ".*\\*\\*\\*\\*" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection0
        | _ when s =~ ".*------" && s5 =~ ".*------" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection1
        | _ when s =~ ".*####" && s5 =~ ".*####" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection2
        | _ ->
            ()
        );
        aux_toks xs

    | T.TCommand(s,_):: T.TOBrace _:: xs ->
       let (before, _, _) = span_close_brace xs in
       let categ_opt =
         match s with
         | ("chapter" | "chapter*") -> Some CommentSection0
         | "section" -> Some CommentSection1
         | "subsection" -> Some CommentSection2
         | "subsubsection" -> Some CommentSection3

         | "label" -> Some (Label Def)
         | "ref" -> Some (Label Use)
         | "cite" -> Some (Label Use)

         | "begin" | "end" -> Some KeywordExn (* TODO *)
         | "input" | "usepackage" -> Some IncludeFilePath
         | "url" | "furl" -> Some EmbededUrl

         | _ -> Some (Parameter Use)
       in
       categ_opt |> Common.do_option (fun categ -> 
         tag_all_tok_with ~tag categ  before;
       );
       (* repass on tokens, in case there are nested TeX commands *)
       aux_toks xs


    (* syncweb-specific: *)
    | T.TSymbol("#", _ii)::T.TWord("include", ii2)::xs ->
        tag ii2 Include;
        aux_toks xs

    (* specific to texinfo *)
    | T.TSymbol("@", _)::T.TWord(s, ii)::xs ->
           let categ_opt = 
             (match s with
             | "title" -> Some CommentSection0
             | "chapter" -> Some CommentSection0
             | "section" -> Some CommentSection1
             | "subsection" -> Some CommentSection2
             | "subsubsection" -> Some CommentSection3
             | "c" -> Some Comment
             (* don't want to polluate my view with indexing "aspect" *)
             | "cindex" -> 
                 tag ii Comment;
                 Some Comment
             | _ -> None
             )
           in
           (match categ_opt with
           | None -> 
               tag ii Keyword;
               aux_toks xs
           | Some categ ->
               let (before, _, _) = span_newline xs in
               tag_all_tok_with ~tag categ before;
               (* repass on tokens, in case there are nested tex commands *)
               aux_toks xs
           )

    (* specific to web TeX source: ex: @* \[24] Getting the next token. *)
    |    T.TSymbol("@*", _)
      :: T.TCommentSpace _
      :: T.TSymbol("\\", _)
      :: T.TSymbol("[", ii1)
      :: T.TNumber(_, iinum)
      :: T.TSymbol("]", ii2)
      :: T.TCommentSpace _
      :: xs 
      ->
       let (before, _, _) = span_newline xs in
       [ii1;iinum;ii2] +> List.iter (fun ii -> tag ii CommentSection0);
       tag_all_tok_with ~tag CommentSection0 before;
       (* repass on tokens, in case there are nested tex commands *)
       aux_toks xs

    | _x::xs ->
        aux_toks xs
  in
  let toks' = toks +> Common.exclude (function
    (* needed ? *)
    (* | T.TCommentSpace _ -> true *)
    | _ -> false
  )
  in
  aux_toks toks';

  (* -------------------------------------------------------------------- *)
  (* AST phase 1 *) 
  (* -------------------------------------------------------------------- *)

  (* -------------------------------------------------------------------- *)
  (* toks phase 2 (individual tokens) *)
  (* -------------------------------------------------------------------- *)

  toks +> List.iter (fun tok -> 
    match tok with
    | T.TComment ii ->
        if not (Hashtbl.mem already_tagged ii)
        then 
         let s = Parse_info.str_of_info ii in
         (match s with
         | _ when s =~ "^%todo:" -> tag ii BadSmell
         | _ -> tag ii CommentImportance0
         )
    | T.TCommentSpace _ii -> ()
    | T.TCommentNewline _ii -> ()

    | T.TCommand (s, ii) -> 
        let categ = 
          (match s with
          | s when s =~ "^if" -> KeywordConditional
          | s when s =~ ".*true$" -> Boolean
          | s when s =~ ".*false$" -> Boolean

          | "fi" -> KeywordConditional
          | "input" | "usepackage" -> Include
          | "appendix" -> CommentSection0

          | _ -> Keyword
          )
        in
        tag ii categ
      
    | T.TWord (s, ii) ->
        (match s with
        | "TODO" -> tag ii BadSmell
        | _ -> ()
        )

    (* noweb-specific: (obviously) *)
    | T.TBeginNowebChunk ii
    | T.TEndNowebChunk ii
      ->
        tag ii KeywordExn (* TODO *)

    | T.TNowebChunkStr (_, ii) ->
        tag ii EmbededCode
    | T.TNowebCode (_, ii) ->
        tag ii EmbededCode
    | T.TNowebCodeLink (_, ii) ->
        tag ii (StructName Use) (* TODO *)

    | T.TNowebChunkName (_, ii) ->
        tag ii KeywordObject (* TODO *)

    | T.TBeginVerbatim ii | T.TEndVerbatim ii -> tag ii Keyword

    | T.TVerbatimLine (_, ii) ->
        tag ii Verbatim
    (* syncweb-specific: *)
    | T.TFootnote (c, ii) ->
        (match c with
        | 't' -> tag ii BadSmell
        | 'n' -> tag ii Comment
        | 'l' -> tag ii CommentImportance1
        | _ -> failwith (spf "syncweb \\x special macro not recognized:%c" c)
        )

    | T.TNumber (_, ii) | T.TUnit (_, ii) -> 
        if not (Hashtbl.mem already_tagged ii)
        then tag ii Number

    | T.TSymbol (s, ii) -> 
      (match s with
      | "&" | "\\" ->
        tag ii Punctuation
      | _ -> ()
      )

    | T.TOBrace ii | T.TCBrace ii ->  tag ii Punctuation

    | T.TUnknown ii -> tag ii Error
    | T.EOF _ii-> ()

  );

  (* -------------------------------------------------------------------- *)
  (* AST phase 2 *)  

  ()
