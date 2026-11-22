import at/did
import at/did_document
import at/handle
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/uri.{type Uri}
import homestead/browser
import homestead/date
import homestead/identity
import homestead/identity_history.{type Change, type Event}
import homestead/json_text
import homestead/json_view
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(
    account: String,
    local_offset: Duration,
    identity: Remote(Identity),
    history: History,
    copied: Copied,
  )
}

type History {
  NotRecorded
  Recorded(log: Remote(identity_history.History))
}

pub type Identity {
  Identity(
    handle: Option(String),
    server: Option(String),
    signing_key: Option(String),
    json: String,
  )
}

type Copied {
  NothingCopied
  CopiedDid
  CopiedSigningKey
  CopiedDocument
  CopyFailed
}

pub fn init(session: Session, directory: Uri) -> #(Model, Effect(Message)) {
  let account = session.account(session)
  let #(history, load_history) = case
    identity.history_request(directory, account)
  {
    Ok(request) -> #(
      Recorded(log: Loading),
      rsvp.send(
        request,
        rsvp.expect_ok_response(fn(response) {
          DirectoryReturnedHistory(
            result.replace_error(response, tranquil.Unreachable)
            |> result.try(fn(response) {
              identity_history.read(response.body)
              |> result.replace_error(tranquil.NotUnderstood)
            }),
          )
        }),
      ),
    )
    Error(Nil) -> #(NotRecorded, effect.none())
  }

  #(
    Model(
      account: did.to_string(account),
      local_offset: calendar.local_offset(),
      identity: Loading,
      history:,
      copied: NothingCopied,
    ),
    effect.batch([
      rsvp.send(
        identity.document_request(directory, account),
        rsvp.expect_ok_response(fn(response) {
          DirectoryReturnedDocument(
            result.replace_error(response, tranquil.Unreachable)
            |> result.try(fn(response) { read(response.body) }),
          )
        }),
      ),
      load_history,
    ]),
  )
}

pub opaque type Message {
  DirectoryReturnedDocument(result: Result(Identity, Problem))
  DirectoryReturnedHistory(result: Result(identity_history.History, Problem))
  UserClickedCopy(text: String, copied: Copied)
  BrowserCopiedText(copied: Copied, result: Result(Nil, Nil))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    DirectoryReturnedDocument(result:) -> #(
      Model(..model, identity: remote.from_result(result)),
      effect.none(),
    )

    DirectoryReturnedHistory(result:) -> #(
      Model(..model, history: Recorded(log: remote.from_result(result))),
      effect.none(),
    )

    UserClickedCopy(text:, copied:) -> #(
      model,
      browser.copy(text, BrowserCopiedText(copied, _)),
    )

    BrowserCopiedText(copied:, result:) -> #(
      Model(..model, copied: case result {
        Ok(Nil) -> copied
        Error(Nil) -> CopyFailed
      }),
      effect.none(),
    )
  }
}

pub fn read(body: String) -> Result(Identity, Problem) {
  {
    use document <- result.try(json.parse(body, did_document.decoder()))
    use raw <- result.map(json.parse(body, decode.dynamic))

    Identity(
      handle: did_document.also_known_as(document)
        |> result.map(handle.to_string)
        |> option.from_result,
      server: did_document.pds(document)
        |> result.map(uri.to_string)
        |> option.from_result,
      signing_key: did_document.signing_key(document) |> option.from_result,
      json: json_text.pretty(raw),
    )
  }
  |> result.replace_error(tranquil.NotUnderstood)
}

pub fn view(model: Model) -> Element(Message) {
  let note = fn(kind: Copied) {
    case model.copied {
      CopyFailed -> Some("couldn't copy")
      copied if copied == kind -> Some("copied")
      NothingCopied | CopiedDid | CopiedSigningKey | CopiedDocument -> None
    }
  }
  let plain = fn(name: String, value: Option(String)) {
    layout.row(
      tone: layout.Plain,
      name:,
      details: [
        case value {
          Some(value) -> html.text(value)
          None -> layout.dim("none")
        },
      ],
      actions: [],
    )
  }

  layout.page(case model.identity {
    Loading -> [layout.loading_section()]

    Failed(_) -> [
      layout.title_section("identity", [
        layout.block([layout.problem("Couldn't load")]),
      ]),
    ]

    Loaded(value: identity) -> [
      layout.title_section("identity", [
        layout.block([
          layout.copy_row(
            name: "DID",
            value: model.account,
            note: note(CopiedDid),
            on_copy: UserClickedCopy(model.account, CopiedDid),
          ),
          plain("Handle", identity.handle),
          plain("Server", identity.server),
          case identity.signing_key {
            Some(key) ->
              layout.copy_row(
                name: "Signing key",
                value: key,
                note: note(CopiedSigningKey),
                on_copy: UserClickedCopy(key, CopiedSigningKey),
              )
            None -> plain("Signing key", None)
          },
          case model.history {
            Recorded(log: Loaded(value: history)) ->
              layout.row(
                tone: layout.Plain,
                name: "Rotation keys",
                details: case history.rotation_keys {
                  [] -> [layout.dim("none")]
                  [_, ..] as keys -> [
                    html.span(
                      [attribute.class("lines")],
                      list.map(keys, fn(key) {
                        html.code([attribute.class("long")], [html.text(key)])
                      }),
                    ),
                  ]
                },
                actions: [],
              )
            NotRecorded | Recorded(log: Loading) | Recorded(log: Failed(_)) ->
              element.none()
          },
        ]),
      ]),
      layout.section("document", [
        layout.block([
          layout.wide_row([
            json_view.view(identity.json),
          ]),
          layout.actions_row([
            case note(CopiedDocument) {
              Some(note) -> layout.dim(note)
              None -> element.none()
            },
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserClickedCopy(identity.json, CopiedDocument)),
              ],
              [html.text("Copy")],
            ),
          ]),
        ]),
      ]),
      layout.section("history", [
        layout.block(case model.history {
          NotRecorded -> [
            layout.note("did:web identities have no recorded history", []),
          ]
          Recorded(log: Loading) -> []
          Recorded(log: Failed(_)) -> [layout.problem("Couldn't load")]
          Recorded(log: Loaded(value: history)) ->
            list.map(history.events, view_event(_, model.local_offset))
        }),
      ]),
    ]
  })
}

fn view_event(event: Event, local_offset: Duration) -> Element(message) {
  let changes =
    list.map(event.changes, fn(change) { html.span([], view_change(change)) })

  layout.row(
    tone: layout.Plain,
    name: date.describe_moment_with_year(event.at, local_offset),
    details: [
      html.span(
        [
          attribute.classes([
            #("lines", True),
            #("dim", event.is_cancelled),
          ]),
        ],
        case event.is_cancelled {
          True -> [html.span([], [html.text("Cancelled")]), ..changes]
          False -> changes
        },
      ),
    ],
    actions: [],
  )
}

fn view_change(change: Change) -> List(Element(message)) {
  let key = fn(key: String) {
    html.code([attribute.class("long")], [html.text(key)])
  }

  case change {
    identity_history.Created(handle:, server:) -> [
      html.text(string.join(
        list.flatten([
          ["Created"],
          option.map(handle, fn(handle) { ["handle " <> handle] })
            |> option.unwrap([]),
          option.map(server, fn(server) { ["server " <> server] })
            |> option.unwrap([]),
        ]),
        " \u{00B7} ",
      )),
    ]
    identity_history.HandleChanged(to: Some(handle)) -> [
      html.text("Handle changed to " <> handle),
    ]
    identity_history.HandleChanged(to: None) -> [html.text("Handle removed")]
    identity_history.ServerChanged(to: Some(server)) -> [
      html.text("Server changed to " <> server),
    ]
    identity_history.ServerChanged(to: None) -> [html.text("Server removed")]
    identity_history.SigningKeyChanged -> [html.text("Signing key changed")]
    identity_history.RotationKeyAdded(key: added) -> [
      html.text("Rotation key added "),
      key(added),
    ]
    identity_history.RotationKeyRemoved(key: removed) -> [
      html.text("Rotation key removed "),
      key(removed),
    ]
    identity_history.Deleted -> [html.text("Identity deleted")]
    identity_history.OtherDetailsChanged -> [
      html.text("Other details changed"),
    ]
  }
}
