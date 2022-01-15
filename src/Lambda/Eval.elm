module Lambda.Eval exposing (eval)

{-| There is a single exposed function,

    eval : Dict String String -> String -> String

The first argument is a dictionary which defined rewrite
rules, e.g.,

    Dict.fromList
        [
          ("true", "\\x.\\y.x")
          "false",  "\\x.\\y.y")
          "and", "\\p.\\q.p q p")
          "or", "\\p.\\q.p p q"
          "not", "\\p.p (\\x.\\y.y) (\\x.\\y.x)"
        ]

Strings on the left are to be rewritten as strings on the right.
Those on the right should be lambda tersm.

The eval function parses the given string, rewrites it as needed,
applies beta reduction, and then turns this final expression
back into a string.

@docs eval

-}

import Dict exposing (Dict)
import Lambda.Expression exposing (Expr(..))
import Lambda.Parser


{-| -}
eval : Dict String String -> String -> String
eval dict str =
    case Lambda.Parser.parse str of
        Err err ->
            "Parse error: " ++ Debug.toString err

        Ok expr ->
            rewrite dict expr
                |> Lambda.Expression.beta
                |> Lambda.Expression.reduceSubscripts
                -- |> Lambda.Expression.compressNameSpace
                |> Lambda.Expression.toString


rewrite : Dict String String -> Expr -> Expr
rewrite definitions expr =
    case expr of
        Var s ->
            case Dict.get s definitions of
                Just t ->
                    -- Var (parenthesize t)
                    case Lambda.Parser.parse t of
                        Ok u ->
                            u

                        Err _ ->
                            Var "ERROR"

                Nothing ->
                    Var s

        Lambda binder body ->
            Lambda binder (rewrite definitions body)

        Apply e1 e2 ->
            Apply (rewrite definitions e1) (rewrite definitions e2)
