import at/did
import at/did_document
import at/handle
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri.{type Uri}
import homestead/browser
import homestead/identity
import homestead/json_text
import homestead/json_view
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(account: String, identity: Remote(Identity), copied: Copied)
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

  case did.from_string(account) {
    Ok(did) -> #(
      Model(account:, identity: Loading, copied: NothingCopied),
      rsvp.send(
        identity.document_request(directory, did),
        rsvp.expect_ok_response(fn(response) {
          DirectoryReturnedDocument(
            result.replace_error(response, tranquil.Unreachable)
            |> result.try(fn(response) { read(response.body) }),
          )
        }),
      ),
    )
    Error(_) -> #(
      Model(
        account:,
        identity: Failed(tranquil.NotUnderstood),
        copied: NothingCopied,
      ),
      effect.none(),
    )
  }
}

pub fn departure(_model: Model) -> Option(Departure) {
  None
}

pub opaque type Message {
  DirectoryReturnedDocument(result: Result(Identity, Problem))
  UserClickedCopy(text: String, copied: Copied)
  BrowserCopiedText(copied: Copied, result: Result(Nil, Nil))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    DirectoryReturnedDocument(result:) -> #(
      Model(..model, identity: remote.from_result(result)),
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
    Loading -> []

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
    ]
  })
}
