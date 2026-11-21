import at/did.{type Did}
import at/did_document
import at/handle.{type Handle}
import gleam/bool
import gleam/dynamic/decode
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import homestead/tern.{type Actor}
import homestead/tranquil.{type Software, OtherSoftware, Tranquil}
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(identifier: String, suggestions: Suggestions, lookup: Lookup)
}

type Suggestions {
  Hidden(actors: List(Actor))
  Shown(actors: List(Actor), highlighted: Option(Int))
}

type Lookup {
  NotStarted
  Looking
  Found(did: Did, server: Uri, version: String)
  Failed(problem: Problem)
}

type Problem {
  IdentifierNotUnderstood
  HandleNotResolved
  DocumentNotFound
  ServerNotListed
  ServerUnreachable
  ServerUnavailable
  NotTranquil
}

pub fn init() -> Model {
  Model(identifier: "", suggestions: Hidden(actors: []), lookup: NotStarted)
}

pub opaque type Message {
  UserTypedIdentifier(identifier: String)
  UserPausedTyping(query: String)
  UserPressedArrow(direction: Direction)
  UserDismissedSuggestions
  UserPickedSuggestion(actor: Actor)
  UserSubmittedForm(fields: List(#(String, String)))
  TernReturnedActors(
    query: String,
    result: Result(List(Actor), rsvp.Error(String)),
  )
  HandleHostReturnedDid(result: Result(String, rsvp.Error(String)))
  DirectoryReturnedDocument(
    did: Did,
    result: Result(Response(String), rsvp.Error(String)),
  )
  ServerReturnedHealth(
    did: Did,
    server: Uri,
    result: Result(Software, rsvp.Error(String)),
  )
}

type Direction {
  Up
  Down
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model.lookup {
    Looking -> update_while_looking(model, message)
    NotStarted | Found(..) | Failed(_) -> update_while_idle(model, message)
  }
}

fn update_while_idle(
  model: Model,
  message: Message,
) -> #(Model, Effect(Message)) {
  case message {
    UserTypedIdentifier(identifier:) -> {
      let model = Model(..model, identifier:, lookup: NotStarted)

      case string.trim(identifier) {
        "" | "did:" <> _ -> #(
          Model(..model, suggestions: Hidden(actors: [])),
          effect.none(),
        )
        query -> #(model, pause_before_searching(query))
      }
    }

    UserPausedTyping(query:) -> {
      use <- bool.guard(!is_being_typed(model, query), #(model, effect.none()))

      #(model, search(query))
    }

    TernReturnedActors(query:, result: found) -> {
      use <- bool.guard(!is_being_typed(model, query), #(model, effect.none()))

      let suggestions = case found {
        Ok(actors) -> Shown(actors:, highlighted: None)
        Error(_) -> Hidden(actors: [])
      }

      #(Model(..model, suggestions:), effect.none())
    }

    UserPressedArrow(direction:) -> #(
      Model(..model, suggestions: move_highlight(model.suggestions, direction)),
      effect.none(),
    )

    UserDismissedSuggestions -> #(
      Model(..model, suggestions: Hidden(actors: model.suggestions.actors)),
      effect.none(),
    )

    UserPickedSuggestion(actor:) -> #(
      Model(
        identifier: actor.handle,
        suggestions: Hidden(actors: []),
        lookup: Looking,
      ),
      fetch_document(actor.did),
    )

    UserSubmittedForm(fields:) -> {
      let assert Ok(identifier) = list.key_find(fields, "identifier")

      start_lookup(model, identifier)
    }

    HandleHostReturnedDid(..)
    | DirectoryReturnedDocument(..)
    | ServerReturnedHealth(..) -> #(model, effect.none())
  }
}

fn update_while_looking(
  model: Model,
  message: Message,
) -> #(Model, Effect(Message)) {
  case message {
    HandleHostReturnedDid(result: resolved) -> {
      let did = {
        use body <- result.try(result.replace_error(resolved, Nil))
        did.from_string(string.trim(body))
      }

      case did {
        Ok(did) -> #(model, fetch_document(did))
        Error(Nil) -> #(
          Model(..model, lookup: Failed(HandleNotResolved)),
          effect.none(),
        )
      }
    }

    DirectoryReturnedDocument(did:, result: fetched) -> {
      let health_check = {
        use response <- result.try(result.replace_error(
          fetched,
          DocumentNotFound,
        ))
        use document <- result.try(
          json.parse(response.body, did_document.decoder())
          |> result.replace_error(DocumentNotFound),
        )
        use server <- result.try(
          did_document.pds(document)
          |> result.replace_error(ServerNotListed),
        )
        use request <- result.map(
          tranquil.health_request(server)
          |> result.replace_error(ServerNotListed),
        )

        check_health(did, server, request)
      }

      case health_check {
        Ok(effect) -> #(model, effect)
        Error(problem) -> #(
          Model(..model, lookup: Failed(problem:)),
          effect.none(),
        )
      }
    }

    ServerReturnedHealth(did:, server:, result: health) -> {
      let lookup = case health {
        Ok(Tranquil(version:)) -> Found(did:, server:, version:)
        Ok(OtherSoftware) -> Failed(NotTranquil)
        Error(rsvp.NetworkError) -> Failed(ServerUnreachable)
        Error(rsvp.HttpError(response)) if response.status == 503 ->
          Failed(ServerUnavailable)
        Error(rsvp.HttpError(_))
        | Error(rsvp.JsonError(_))
        | Error(rsvp.UnhandledResponse(_))
        | Error(rsvp.BadBody)
        | Error(rsvp.BadUrl(_)) -> Failed(NotTranquil)
      }

      #(Model(..model, lookup:), effect.none())
    }

    UserTypedIdentifier(..)
    | UserPausedTyping(..)
    | UserPressedArrow(..)
    | UserDismissedSuggestions
    | UserPickedSuggestion(..)
    | UserSubmittedForm(..)
    | TernReturnedActors(..) -> #(model, effect.none())
  }
}

fn is_being_typed(model: Model, query: String) -> Bool {
  model.lookup == NotStarted && query == string.trim(model.identifier)
}

fn move_highlight(
  suggestions: Suggestions,
  direction: Direction,
) -> Suggestions {
  let count = list.length(suggestions.actors)
  let target = case suggestions, direction {
    Shown(highlighted: Some(index), ..), Down -> index + 1
    Shown(highlighted: Some(index), ..), Up -> index - 1
    Shown(highlighted: None, ..), Down | Hidden(_), Down -> 0
    Shown(highlighted: None, ..), Up | Hidden(_), Up -> count - 1
  }

  case int.modulo(target, count) {
    Ok(index) -> Shown(actors: suggestions.actors, highlighted: Some(index))
    Error(Nil) -> suggestions
  }
}

fn start_lookup(model: Model, text: String) -> #(Model, Effect(Message)) {
  let identifier = case string.trim(text) {
    "@" <> handle -> handle
    identifier -> identifier
  }
  let suggested =
    list.find(model.suggestions.actors, fn(actor) {
      actor.handle == string.lowercase(identifier)
    })
  let looking =
    Model(identifier:, suggestions: Hidden(actors: []), lookup: Looking)

  case suggested, did.from_string(identifier), handle.from_string(identifier) {
    Ok(actor), _, _ -> #(looking, fetch_document(actor.did))
    Error(Nil), Ok(did), _ -> #(looking, fetch_document(did))
    Error(Nil), Error(Nil), Ok(handle) -> #(looking, resolve_handle(handle))
    Error(Nil), Error(Nil), Error(Nil) -> #(
      Model(..looking, lookup: Failed(IdentifierNotUnderstood)),
      effect.none(),
    )
  }
}

const typing_pause_milliseconds = 200

fn pause_before_searching(query: String) -> Effect(Message) {
  use dispatch <- effect.from

  promise.wait(typing_pause_milliseconds)
  |> promise.tap(fn(_) { dispatch(UserPausedTyping(query)) })

  Nil
}

fn search(query: String) -> Effect(Message) {
  rsvp.send(
    tern.search_request(query),
    rsvp.expect_json(tern.search_decoder(), TernReturnedActors(query, _)),
  )
}

fn resolve_handle(handle: Handle) -> Effect(Message) {
  rsvp.send(handle.resolve(handle), rsvp.expect_text(HandleHostReturnedDid))
}

fn fetch_document(did: Did) -> Effect(Message) {
  rsvp.send(
    did.document_request(did),
    rsvp.expect_ok_response(DirectoryReturnedDocument(did, _)),
  )
}

fn check_health(
  did: Did,
  server: Uri,
  request: Request(String),
) -> Effect(Message) {
  rsvp.send(
    request,
    rsvp.expect_json(tranquil.health_decoder(), ServerReturnedHealth(
      did,
      server,
      _,
    )),
  )
}

pub fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("landing")], [
    html.section([attribute.class("about")], [
      html.span([attribute.class("brand")], [html.text("Homestead")]),
      html.div([], [
        html.h1([], [html.text("A portable Tranquil frontend dashboard.")]),
        html.p([], [
          html.text(
            "Homestead is a fully browser based frontend for the Tranquil PDS, log into any backend safely from your browser, or run your own.",
          ),
        ]),
      ]),
      html.ul([attribute.class("assurances")], [
        html.li([], [html.text("Lorem ipsum dolor sit amet")]),
        html.li([], [html.text("Consectetur adipiscing elit")]),
      ]),
    ]),
    html.main([attribute.class("sign-in")], [
      html.div([], [
        html.h2([], [html.text("Sign in")]),
        view_form(model),
        html.a([attribute.class("create-account"), attribute.href("/sign-up")], [
          html.text("No account yet? Create one"),
        ]),
        view_lookup(model.lookup),
      ]),
    ]),
  ])
}

fn view_form(model: Model) -> Element(Message) {
  let is_looking = model.lookup == Looking
  let #(actors, highlighted) = case model.suggestions {
    Shown(actors:, highlighted:) -> #(actors, highlighted)
    Hidden(_) -> #([], None)
  }

  html.form([event.on_submit(UserSubmittedForm)], [
    html.label([attribute.for("identifier")], [html.text("Your handle")]),
    html.div([attribute.class("field")], [
      html.div([attribute.class("combobox")], [
        html.input([
          attribute.id("identifier"),
          attribute.name("identifier"),
          attribute.type_("text"),
          attribute.value(model.identifier),
          attribute.placeholder("you.example.com"),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.role("combobox"),
          attribute.aria_autocomplete("list"),
          attribute.aria_controls("suggestions"),
          attribute.aria_expanded(actors != []),
          case highlighted {
            Some(index) -> attribute.aria_activedescendant(option_id(index))
            None -> attribute.none()
          },
          attribute.disabled(is_looking),
          event.on_input(UserTypedIdentifier),
          on_suggestion_key(model.suggestions),
          event.on_blur(UserDismissedSuggestions),
        ]),
        view_suggestions(actors, highlighted),
      ]),
      html.button([attribute.class("button"), attribute.disabled(is_looking)], [
        html.text("Find my server"),
      ]),
    ]),
  ])
}

fn on_suggestion_key(suggestions: Suggestions) -> Attribute(Message) {
  let handle = fn(message) {
    decode.success(event.handler(
      dispatch: message,
      prevent_default: True,
      stop_propagation: False,
    ))
  }
  let leave_to_browser =
    decode.failure(
      event.handler(
        dispatch: UserDismissedSuggestions,
        prevent_default: False,
        stop_propagation: False,
      ),
      "a key the suggestions respond to",
    )

  event.advanced("keydown", {
    use key <- decode.field("key", decode.string)

    case key, suggestions {
      "ArrowDown", Shown(actors: [_, ..], ..) | "ArrowDown", Hidden([_, ..]) ->
        handle(UserPressedArrow(Down))
      "ArrowUp", Shown(actors: [_, ..], ..) | "ArrowUp", Hidden([_, ..]) ->
        handle(UserPressedArrow(Up))
      "Escape", Shown(actors: [_, ..], ..) -> handle(UserDismissedSuggestions)
      "Enter", Shown(actors:, highlighted: Some(index)) ->
        case list.drop(actors, index) {
          [actor, ..] -> handle(UserPickedSuggestion(actor))
          [] -> leave_to_browser
        }
      _, _ -> leave_to_browser
    }
  })
}

fn option_id(index: Int) -> String {
  "suggestion-" <> int.to_string(index)
}

fn view_suggestions(
  actors: List(Actor),
  highlighted: Option(Int),
) -> Element(Message) {
  case actors {
    [] -> element.none()
    [_, ..] ->
      html.ul(
        [
          attribute.id("suggestions"),
          attribute.class("suggestions"),
          attribute.role("listbox"),
          attribute.aria_label("Matching accounts"),
        ],
        list.index_map(actors, fn(actor, index) {
          html.li(
            [
              attribute.id(option_id(index)),
              attribute.role("option"),
              attribute.aria_selected(highlighted == Some(index)),
              event.on_mouse_down(UserPickedSuggestion(actor))
                |> event.prevent_default,
            ],
            [
              case actor.avatar {
                Some(url) ->
                  html.img([
                    attribute.src(url),
                    attribute.alt(""),
                    attribute.width(32),
                    attribute.height(32),
                    attribute.loading("lazy"),
                  ])
                None -> html.span([attribute.class("no-avatar")], [])
              },
              html.span([attribute.class("who")], [
                case actor.display_name {
                  Some(name) -> html.span([], [html.text(name)])
                  None -> element.none()
                },
                html.code([], [html.text("@" <> actor.handle)]),
              ]),
            ],
          )
        }),
      )
  }
}

fn view_lookup(lookup: Lookup) -> Element(message) {
  html.div(
    [attribute.class("lookup"), attribute.aria_live("polite")],
    case lookup {
      NotStarted -> []

      Looking -> [html.p([], [html.text("Looking up your server…")])]

      Found(did:, server:, version:) -> [
        html.h3([attribute.class("good")], [html.text("Tranquil server found")]),
        html.dl([], [
          html.dt([], [html.text("Server")]),
          html.dd([], [html.code([], [html.text(uri.to_string(server))])]),
          html.dt([], [html.text("Version")]),
          html.dd([], [html.code([], [html.text(version)])]),
          html.dt([], [html.text("Account")]),
          html.dd([], [html.code([], [html.text(did.to_string(did))])]),
        ]),
      ]

      Failed(problem:) -> [
        html.h3([attribute.class("attention")], [
          html.text(problem_message(problem)),
        ]),
      ]
    },
  )
}

fn problem_message(problem: Problem) -> String {
  case problem {
    IdentifierNotUnderstood -> "That doesn't look like a handle or a DID."
    HandleNotResolved -> "Couldn't find an account for that handle."
    DocumentNotFound -> "Couldn't find an identity document for that account."
    ServerNotListed -> "That account's identity document doesn't name a server."
    ServerUnreachable -> "Couldn't reach that account's server."
    ServerUnavailable -> "That account's server is unavailable right now."
    NotTranquil ->
      "That account isn't on a Tranquil server, so it can't be managed here."
  }
}
