port module Main exposing (main)

import Cmd.Extra exposing (withCmd, withNoCmd)
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Lambda.Defs
import Lambda.Eval
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
    , environment : Dict String String
    , viewStyle : Lambda.ViewStyle
    }


type Msg
    = Input String
    | ReceivedDataFromJS E.Value


type alias Flags =
    ()


init : () -> ( Model, Cmd Msg )
init _ =
    { residualCommand = ""
    , fileContents = Nothing
    , environment = Dict.empty
    , viewStyle = Lambda.Pretty
    }
        |> withCmd (loadFileCmd "defs.txt")


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch [ get Input, receiveData ReceivedDataFromJS ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Input input ->
            case input of
                "" ->
                    model |> withCmd (put "")

                "\n" ->
                    model |> withCmd (put "")

                _ ->
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

                        environment =
                            Lambda.Defs.dictionary data
                    in
                    -- { model | fileContents = Just data } |> withCmd (put <| "Data read: " ++ String.fromInt (String.length input))
                    { model
                        | fileContents = Just data_

                        --  , definitions = definitions
                        , environment = environment
                    }
                        |> withCmd (put <| transformOutput model.viewStyle <| data)


transformOutput : Lambda.ViewStyle -> String -> String
transformOutput viewStyle str =
    case viewStyle of
        Lambda.Raw ->
            str

        Lambda.Pretty ->
            prettify str

        Lambda.Named ->
            prettify str


prettify : String -> String
prettify str =
    String.replace "\\" (String.fromChar 'λ') str


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
                    model |> withCmd (put "Error computing normal")

        Just ":let" ->
            case args of
                ":let" :: name :: "=" :: rest ->
                    if rest == [] then
                        model |> withCmd (put "Missing argument: :let foo = BAR")

                    else
                        let
                            data =
                                String.join " " rest |> String.trimRight
                        in
                        { model | environment = Dict.insert name data model.environment } |> withCmd (put <| "added " ++ name ++ " as " ++ transformOutput model.viewStyle data)

                _ ->
                    model |> withCmd (put "Bad args")

        Just ":beta" ->
            model |> withCmd (put (Lambda.Eval.equivalent model.environment (String.replace ":beta " "" cmdString)))

        Just ":raw" ->
            { model | viewStyle = Lambda.Raw } |> withCmd (put "")

        Just ":pretty" ->
            { model | viewStyle = Lambda.Pretty } |> withCmd (put "")

        Just ":named" ->
            { model | viewStyle = Lambda.Named } |> withCmd (put "")

        Just ":load" ->
            loadFile model arg

        Just ":reset" ->
            { model | environment = Dict.empty, fileContents = Nothing } |> withCmd (put "reset: done")

        Just ":parse" ->
            model |> withCmd (put (Debug.toString (parse (List.drop 1 args |> String.join " "))))

        Just ":show" ->
            model |> withCmd (put (model.fileContents |> Maybe.withDefault "no environment defined" |> transformOutput model.viewStyle))

        Just ":env" ->
            model |> withCmd (put (Lambda.Defs.show model.environment))

        _ ->
            -- return default output (beta reduce input)
            model |> withCmd (put (Lambda.Eval.eval model.viewStyle model.environment cmdString))


isNormal model str =
    let
        output =
            case Result.map Lambda.isNormal (parse str) of
                Ok True ->
                    "true"

                Ok False ->
                    "false"

                Err _ ->
                    "Error (normal)"
    in
    model |> withCmd (put <| output)



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


removeComments : String -> String
removeComments input =
    input
        |> String.lines
        |> List.filter (\line -> String.left 1 line /= "#")
        |> String.join "\n"
        |> String.trim
