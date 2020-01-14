module Spa exposing (create, Program)

{-|


## Let's build some single page applications!

`Spa.create` replaces [Browser.application](https://package.elm-lang.org/packages/elm/browser/latest/Browser#application)
as the entrypoint to your app.

    import Global
    import Pages
    import Routes exposing (routes)
    import Spa
    import Transitions
    import Utils.Spa

    main : Utils.Spa.Program Pages.Model Pages.Msg
    main =
        Spa.create
            { routing =
                { routes = Routes.parsers
                , toPath = Routes.toPath
                , notFound = routes.notFound
                , afterNavigate = Nothing
                }
            , transitions = Transitions.transitions
            , global =
                { init = Global.init
                , update = Global.update
                , subscriptions = Global.subscriptions
                }
            , page = Pages.page
            }

@docs create, Program

-}

import Browser
import Browser.Navigation as Nav
import Dict exposing (Dict)
import Internals.Page as Page
import Internals.Path as Path exposing (Path)
import Internals.Transition as Transition exposing (Transition)
import Internals.Utils as Utils
import Url exposing (Url)
import Url.Parser as Parser exposing (Parser)



-- APPLICATION


{-| An alias for `Platform.Program` to make annotations a little more clear.
-}
type alias Program flags globalModel globalMsg layoutModel layoutMsg =
    Platform.Program flags (Model flags globalModel layoutModel) (Msg globalMsg layoutMsg)


{-| Creates a new `Program` given some one-time configuration:

  - `routing` - What are the app's routes?
  - `transitions` - How should we transition between routes?
  - `global` - How do we share state between pages?
  - `page` - What page should we render?

-}
create :
    { global :
        { init :
            { navigate : route -> Cmd (Msg globalMsg layoutMsg)
            }
            -> flags
            -> ( globalModel, Cmd globalMsg, Cmd (Msg globalMsg layoutMsg) )
        , update :
            { navigate : route -> Cmd (Msg globalMsg layoutMsg)
            }
            -> globalMsg
            -> globalModel
            -> ( globalModel, Cmd globalMsg, Cmd (Msg globalMsg layoutMsg) )
        , subscriptions : globalModel -> Sub globalMsg
        }
    , page : Page.Page route route layoutModel layoutMsg layoutModel layoutMsg globalModel globalMsg (Msg globalMsg layoutMsg)
    , routing :
        { routes : List (Parser (route -> route) route)
        , toPath : route -> String
        , notFound : route
        , afterNavigate : Maybe ({ old : route, new : route } -> globalMsg)
        }
    , transitions :
        { layout : Transition (Msg globalMsg layoutMsg)
        , page : Transition (Msg globalMsg layoutMsg)
        , pages :
            List
                { path : Path
                , transition : Transition (Msg globalMsg layoutMsg)
                }
        }
    }
    -> Program flags globalModel globalMsg layoutModel layoutMsg
create config =
    let
        page =
            Page.upgrade
                { toModel = identity
                , toMsg = identity
                , page = config.page
                }
    in
    Browser.application
        { init =
            init
                { init =
                    { global = config.global.init
                    , pages = page.init
                    }
                , routing =
                    { fromUrl = fromUrl config.routing
                    , toPath = config.routing.toPath
                    , transition = config.transitions.layout
                    }
                }
        , update =
            update
                { routing =
                    { fromUrl = fromUrl config.routing
                    , toPath = config.routing.toPath
                    , routes = config.routing.routes
                    , afterNavigate = config.routing.afterNavigate
                    , transitions = pageTransitions config.transitions
                    }
                , init = page.init
                , update =
                    { global = config.global.update
                    , pages = page.update
                    }
                }
        , subscriptions =
            subscriptions
                { bundle = page.bundle
                , global = config.global.subscriptions
                , transition = config.transitions.layout
                , fromUrl = fromUrl config.routing
                }
        , view =
            view
                { bundle = page.bundle
                , transitions = config.transitions
                , fromUrl = fromUrl config.routing
                }
        , onUrlChange = ChangedUrl
        , onUrlRequest = ClickedLink
        }



-- ROUTING


type alias Routes route a =
    List (Parser (route -> a) a)


fromUrl : { a | routes : Routes route route, notFound : route } -> Url -> route
fromUrl config =
    Parser.parse (Parser.oneOf config.routes)
        >> Maybe.withDefault config.notFound



-- INIT


type alias Model flags globalModel model =
    { url : Url
    , flags : flags
    , key : Nav.Key
    , global : globalModel
    , page : model
    , path : Path
    , visibilities :
        { layout : Transition.Visibility
        , page : Transition.Visibility
        }
    }


init :
    { routing :
        { fromUrl : Url -> route
        , toPath : route -> String
        , transition : Transition ui_msg
        }
    , init :
        { global :
            { navigate : route -> Cmd (Msg globalMsg layoutMsg) }
            -> flags
            -> ( globalModel, Cmd globalMsg, Cmd (Msg globalMsg layoutMsg) )
        , pages : route -> Page.Init route layoutModel layoutMsg globalModel globalMsg
        }
    }
    -> flags
    -> Url
    -> Nav.Key
    -> ( Model flags globalModel layoutModel, Cmd (Msg globalMsg layoutMsg) )
init config flags url key =
    url
        |> config.routing.fromUrl
        |> (\route ->
                let
                    ( globalModel, globalCmd, cmd ) =
                        config.init.global
                            { navigate = navigate config.routing.toPath url
                            }
                            flags

                    ( pageModel, pageCmd, pageGlobalCmd ) =
                        config.init.pages route
                            { global = globalModel
                            , queryParameters = queryParameters url
                            , route = route
                            }
                in
                ( { flags = flags
                  , url = url
                  , key = key
                  , global = globalModel
                  , page = pageModel
                  , path = []
                  , visibilities =
                        { layout = Transition.invisible
                        , page = Transition.visible
                        }
                  }
                , Cmd.batch
                    [ Cmd.map Page pageCmd
                    , Cmd.map Global pageGlobalCmd
                    , Cmd.map Global globalCmd
                    , Utils.delay (Transition.duration config.routing.transition) FadeInLayout
                    , cmd
                    ]
                )
           )



-- UPDATE


type Msg globalMsg msg
    = ChangedUrl Url
    | ClickedLink Browser.UrlRequest
    | Global globalMsg
    | Page msg
    | FadeInLayout
    | FadeInPage Url


update :
    { routing :
        { fromUrl : Url -> route
        , toPath : route -> String
        , routes : Routes route a
        , afterNavigate : Maybe ({ old : route, new : route } -> globalMsg)
        , transitions :
            List
                { path : Path
                , transition : Transition ui_msg
                }
        }
    , init : route -> Page.Init route layoutModel layoutMsg globalModel globalMsg
    , update :
        { global :
            { navigate : route -> Cmd (Msg globalMsg layoutMsg) }
            -> globalMsg
            -> globalModel
            -> ( globalModel, Cmd globalMsg, Cmd (Msg globalMsg layoutMsg) )
        , pages :
            layoutMsg
            -> layoutModel
            -> Page.Update route layoutModel layoutMsg globalModel globalMsg
        }
    }
    -> Msg globalMsg layoutMsg
    -> Model flags globalModel layoutModel
    -> ( Model flags globalModel layoutModel, Cmd (Msg globalMsg layoutMsg) )
update config msg model =
    case msg of
        FadeInLayout ->
            ( { model
                | visibilities =
                    { layout = Transition.visible
                    , page = model.visibilities.page
                    }
              }
            , Cmd.none
            )

        FadeInPage url ->
            url
                |> config.routing.fromUrl
                |> (\route ->
                        config.init route
                            { global = model.global
                            , queryParameters = queryParameters model.url
                            , route = route
                            }
                   )
                |> (\( pageModel, pageCmd, globalCmd ) ->
                        ( { model
                            | visibilities = { layout = Transition.visible, page = Transition.visible }
                            , page = pageModel
                          }
                        , Cmd.batch
                            [ Cmd.map Page pageCmd
                            , Cmd.map Global globalCmd
                            ]
                        )
                   )

        ClickedLink (Browser.Internal url) ->
            if url == model.url then
                ( model, Cmd.none )

            else
                ( model
                , Nav.pushUrl model.key (Url.toString url)
                )

        ClickedLink (Browser.External url) ->
            ( model
            , Nav.load url
            )

        ChangedUrl url ->
            let
                ( path, duration ) =
                    chooseFrom
                        { transitions = config.routing.transitions
                        , from = model.url
                        , to = url
                        }
                        |> Just
                        |> Maybe.withDefault (List.head config.routing.transitions)
                        |> Maybe.map (\item -> ( item.path, Transition.duration item.transition ))
                        |> Maybe.withDefault ( [], 0 )
            in
            ( { model
                | url = url
                , visibilities =
                    { layout = Transition.visible
                    , page = Transition.invisible
                    }
                , path = path
              }
            , Cmd.batch
                [ Utils.delay
                    duration
                    (FadeInPage url)
                , case config.routing.afterNavigate of
                    Just toMsg ->
                        (Utils.send >> Cmd.map Global)
                            (toMsg
                                { old = config.routing.fromUrl model.url
                                , new = config.routing.fromUrl url
                                }
                            )

                    Nothing ->
                        Cmd.none
                ]
            )

        Global globalMsg ->
            config.update.global
                { navigate = navigate config.routing.toPath model.url
                }
                globalMsg
                model.global
                |> (\( global, globalCmd, cmd ) ->
                        ( { model | global = global }
                        , Cmd.batch
                            [ Cmd.map Global globalCmd
                            , cmd
                            ]
                        )
                   )

        Page pageMsg ->
            config.update.pages pageMsg
                model.page
                { global = model.global
                , queryParameters = queryParameters model.url
                , route = config.routing.fromUrl model.url
                }
                |> (\( page, pageCmd, globalCmd ) ->
                        ( { model | page = page }
                        , Cmd.batch
                            [ Cmd.map Page pageCmd
                            , Cmd.map Global globalCmd
                            ]
                        )
                   )


navigate :
    (route -> String)
    -> Url
    -> route
    -> Cmd (Msg globalMsg layoutMsg)
navigate toPath url route =
    Utils.send <|
        ClickedLink (Browser.Internal { url | path = toPath route })



-- SUBSCRIPTIONS


subscriptions :
    { bundle :
        layoutModel
        -> Page.Bundle route layoutMsg globalModel globalMsg (Msg globalMsg layoutMsg)
    , global : globalModel -> Sub globalMsg
    , transition : Transition (Msg globalMsg layoutMsg)
    , fromUrl : Url -> route
    }
    -> Model flags globalModel layoutModel
    -> Sub (Msg globalMsg layoutMsg)
subscriptions config model =
    Sub.batch
        [ (config.bundle
            model.page
            { fromGlobalMsg = Global
            , fromPageMsg = Page
            , path = model.path
            , transitions = []
            , visibility = model.visibilities.page
            }
            { global = model.global
            , route = config.fromUrl model.url
            , queryParameters = queryParameters model.url
            }
          ).subscriptions
        , Sub.map Global (config.global model.global)
        ]



-- VIEW


type alias Transitions msg =
    { layout : Transition msg
    , page : Transition msg
    , pages :
        List
            { path : Path
            , transition : Transition msg
            }
    }


view :
    { bundle :
        layoutModel
        -> Page.Bundle route layoutMsg globalModel globalMsg (Msg globalMsg layoutMsg)
    , fromUrl : Url -> route
    , transitions : Transitions (Msg globalMsg layoutMsg)
    }
    -> Model flags globalModel layoutModel
    -> Browser.Document (Msg globalMsg layoutMsg)
view config model =
    let
        bundle =
            config.bundle
                model.page
                { fromGlobalMsg = Global
                , fromPageMsg = Page
                , path = model.path
                , visibility = model.visibilities.page
                , transitions = pageTransitions config.transitions
                }
                { global = model.global
                , route = config.fromUrl model.url
                , queryParameters = queryParameters model.url
                }
    in
    { title = bundle.title
    , body =
        [ Transition.view
            config.transitions.layout
            model.visibilities.layout
            bundle.view
        ]
    }



-- Transition magic


chooseFrom :
    { transitions : List { path : Path, transition : Transition ui_msg }
    , from : Url
    , to : Url
    }
    -> Maybe { path : Path, transition : Transition ui_msg }
chooseFrom options =
    let
        ( fromPath, toPath ) =
            ( options.from, options.to )
                |> Tuple.mapBoth urlPath urlPath
    in
    options.transitions
        |> List.reverse
        |> List.filter
            (\{ path, transition } ->
                Path.within fromPath path
                    && Path.within toPath path
                    && (transition /= Transition.optOut)
            )
        |> List.head


urlPath : Url -> List String
urlPath url =
    url.path |> String.dropLeft 1 |> String.split "/"


pageTransitions : Transitions ui_msg -> List { path : Path, transition : Transition ui_msg }
pageTransitions transitions =
    ({ path = [], transition = transitions.page } :: transitions.pages)
        |> List.sortBy (.path >> List.length)



-- QUERY PARAMETERS


queryParameters : { a | query : Maybe String } -> Dict String String
queryParameters url =
    let
        toDict : String -> Dict String String
        toDict query =
            query
                |> String.split "&"
                |> List.map (String.split "=")
                |> List.map (\pieces -> ( List.head pieces, List.drop 1 pieces |> List.head ))
                |> List.map (Tuple.mapBoth (Maybe.withDefault "") (Maybe.withDefault ""))
                |> List.filter (\( key, _ ) -> not (String.isEmpty key))
                |> Dict.fromList
    in
    Maybe.map toDict url.query |> Maybe.withDefault Dict.empty
