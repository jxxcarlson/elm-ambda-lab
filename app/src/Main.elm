port module Main exposing (main)

import Cmd.Extra exposing (withCmd, withCmds, withNoCmd)
import Json.Decode as D
import Json.Encode as E
import Lambda.Defs as Defs
import Lambda.Expression as Lambda
import Lambda.Parser exposing (parse)
import List.Extra
import Platform exposing (Program)
import Text


port get : (String -> msg) -> Sub msg


port put : String -> Cmd msg


port sendFileName : E.Value -> Cmd msg


port receiveData : (E.Value -> msg) -> Sub msg


main : Program Flags Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


type alias Model =
    { residualCommand : String
    , fileContents : Maybe String
    , substitutions : List ( String, String )
    , viewStyle : ViewStyle
    }


type ViewStyle
    = Raw
    | Pretty


type Msg
    = Input String
    | ReceivedDataFromJS E.Value


type alias Flags =
    ()


init : () -> ( Model, Cmd Msg )
init _ =
    { residualCommand = ""
    , fileContents = Nothing
    , substitutions = []
    , viewStyle = Pretty
    }
        |> withNoCmd


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch [ get Input, receiveData ReceivedDataFromJS ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Input input ->
            case input == "" of
                True ->
                    model |> withNoCmd

                False ->
                    -- process user input
                    processCommand { model | residualCommand = getResidualCmd input } input

        ReceivedDataFromJS value ->
            case decodeFileContents value of
                Nothing ->
                    model |> withCmd (put "Couldn't load file")

                Just data_ ->
                    let
                        data =
                            -- If there is a residual command, prepend it to the
                            -- input before sending the input to the black box.
                            case model.residualCommand == "" of
                                True ->
                                    removeComments data_

                                False ->
                                    ":" ++ model.residualCommand ++ " " ++ removeComments data_

                        substitutions =
                            Defs.install data []
                    in
                    -- { model | fileContents = Just data } |> withCmd (put <| "Data read: " ++ String.fromInt (String.length input))
                    { model | fileContents = Just data_, substitutions = substitutions } |> withCmd (put <| transformOutput model.viewStyle <| data)


transformOutput : ViewStyle -> String -> String
transformOutput viewStyle str =
    case viewStyle of
        Raw ->
            str

        Pretty ->
            prettify str


prettify : String -> String
prettify str =
    String.replace "\\" (String.fromChar 'λ') str


prettifyPair : ( String, String ) -> String
prettifyPair ( a, b ) =
    "(" ++ a ++ ", " ++ prettify b ++ ")"


prettifyPairList : List ( String, String ) -> String
prettifyPairList pairs =
    List.foldl (\p acc -> acc ++ prettifyPair p ++ "\n") "" pairs


processCommand : Model -> String -> ( Model, Cmd Msg )
processCommand model cmdString =
    let
        args =
            String.split " " cmdString
                |> List.map String.trim
                |> List.filter (\item -> item /= "")

        cmd =
            List.head args

        arg =
            List.Extra.getAt 1 args
                |> Maybe.withDefault ""
    in
    case cmd of
        Just ":help" ->
            model |> withCmd (put Text.help)

        Just ":examples" ->
            model |> withCmd (put Text.examples)

        Just ":normal" ->
            case args of
                ":normal" :: [] ->
                    model |> withCmd (put "Need one more argument")

                ":normal" :: rest ->
                    isNormal model (String.join " " rest)

                _ ->
                    model |> withCmd (put "Error")

        Just ":let" ->
            case args of
                ":let" :: name :: rest ->
                    if rest == [] then
                        model |> withCmd (put "Missing argument: :let foo bar")

                    else
                        let
                            _ =
                                Debug.log "NAME" name

                            data =
                                String.join " " rest |> String.trimRight |> Debug.log "DATA"
                        in
                        { model | substitutions = ( name, data ) :: model.substitutions } |> withCmd (put <| "added " ++ name ++ " as " ++ transformOutput model.viewStyle data)

                _ ->
                    model |> withCmd (put "Bad args")

        Just ":raw" ->
            { model | viewStyle = Raw } |> withCmd (put "view style = raw")

        Just ":pretty" ->
            { model | viewStyle = Pretty } |> withCmd (put "view style = pretty")

        Just ":load" ->
            loadFile model arg

        Just ":reset" ->
            { model | substitutions = [] } |> withCmd (put "reset: done")

        Just ":parse" ->
            model |> withCmd (put (Debug.toString (Debug.log "INPUT" <| parse (List.drop 1 args |> String.join " "))))

        Just ":show" ->
            model |> withCmd (put (model.fileContents |> Maybe.withDefault "no file loaded" |> transformOutput model.viewStyle))

        Just ":defs" ->
            model |> withCmd (put (prettifyPairList model.substitutions))

        _ ->
            -- return default output
            betaReduce model cmdString


betaReduce model str =
    model |> withCmd (put <| transformOutput model.viewStyle <| transform (applySubstitutions model.substitutions str))


isNormal model str =
    let
        output =
            case Result.map Lambda.isNormal (parse str) of
                Ok True ->
                    "true"

                Ok False ->
                    "false"

                Err _ ->
                    "Error"
    in
    model |> withCmd (put <| output)


applySubstitutions : List ( String, String ) -> String -> String
applySubstitutions substitutions str =
    List.foldl (\( a, b ) s -> String.replace a b s) str substitutions



-- FILE HANDLING


loadFile model fileName =
    ( model, loadFileCmd fileName )


loadFileCmd : String -> Cmd msg
loadFileCmd filePath =
    sendFileName (E.string <| filePath)


decodeFileContents : E.Value -> Maybe String
decodeFileContents value =
    case D.decodeValue D.string value of
        Ok str ->
            Just str

        Err _ ->
            Nothing



-- HELPERS


{-| This is used in the context

:get FILENAME xxx yyy zzz

in which xxx yyy zzzz is the command to be
applied to the contents of FILENAME once
it is received.

-}
getResidualCmd : String -> String
getResidualCmd input =
    let
        args =
            input
                |> String.split " "
                |> List.filter (\s -> s /= "")
    in
    args
        |> List.drop 2
        |> String.join " "



-- FILE/CONTENT OPERATIONS


transform : String -> String
transform str =
    case str |> parse |> Result.map (Lambda.beta >> Lambda.toString) of
        Ok output ->
            output

        Err _ ->
            "Error"


removeComments : String -> String
removeComments input =
    input
        |> String.lines
        |> List.filter (\line -> String.left 1 line /= "#")
        |> String.join "\n"
        |> String.trim


listToPair : List a -> Maybe ( a, a )
listToPair list =
    case list of
        x :: y :: [] ->
            Just ( x, y )

        _ ->
            Nothing
