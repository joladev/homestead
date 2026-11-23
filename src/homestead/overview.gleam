import at/did
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import homestead/browser
import homestead/layout.{type Tone, Plain, Warning}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{
  type Route, Access, Account, ConnectedApps, Data, Export, Profile, Sessions,
  SignInMethods,
}
import homestead/session.{type Session}
import homestead/slingshot
import homestead/tranquil.{
  type ActiveSession, type Authenticator, type Passkey, type Problem,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(
    display_name: Remote(Option(String)),
    passkeys: Remote(List(Passkey)),
    authenticator: Remote(Authenticator),
    has_password: Remote(Bool),
    sessions: Remote(List(ActiveSession)),
    verified_handle: Remote(Option(String)),
    copying: Copying,
  )
}

type Copying {
  NotCopied
  Copied
  CopyFailed
}

type Row {
  Row(
    label: String,
    tone: Tone,
    facts: Remote(String),
    action: #(String, Route),
  )
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  let model =
    Model(
      display_name: Loading,
      passkeys: Loading,
      authenticator: Loading,
      has_password: Loading,
      sessions: Loading,
      verified_handle: Loading,
      copying: NotCopied,
    )
  let display_name = tranquil.display_name(session.account(session))

  #(
    model,
    effect.batch([
      tranquil.load(session, display_name, ServerReturnedDisplayName),
      tranquil.load(session, tranquil.passkeys(), ServerReturnedPasskeys),
      tranquil.load(
        session,
        tranquil.authenticator(),
        ServerReturnedAuthenticator,
      ),
      tranquil.load(
        session,
        tranquil.has_password(),
        ServerReturnedPasswordStatus,
      ),
      tranquil.load(session, tranquil.sessions(), ServerReturnedSessions),
      rsvp.send(
        slingshot.identity_request(session.account(session)),
        rsvp.expect_json(slingshot.handle_decoder(), SlingshotReturnedHandle),
      ),
    ]),
  )
}

pub opaque type Message {
  ServerReturnedDisplayName(result: Result(Option(String), Problem))
  ServerReturnedPasskeys(result: Result(List(Passkey), Problem))
  ServerReturnedAuthenticator(result: Result(Authenticator, Problem))
  ServerReturnedPasswordStatus(result: Result(Bool, Problem))
  ServerReturnedSessions(result: Result(List(ActiveSession), Problem))
  SlingshotReturnedHandle(result: Result(String, rsvp.Error(String)))
  UserClickedCopy(text: String)
  BrowserCopiedText(result: Result(Nil, Nil))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedDisplayName(result: Error(tranquil.Refused(
      "RecordNotFound",
      _,
    ))) -> #(Model(..model, display_name: Loaded(None)), effect.none())

    ServerReturnedDisplayName(result:) -> #(
      Model(..model, display_name: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedPasskeys(result:) -> #(
      Model(..model, passkeys: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedAuthenticator(result:) -> #(
      Model(..model, authenticator: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedPasswordStatus(result:) -> #(
      Model(..model, has_password: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedSessions(result:) -> #(
      Model(..model, sessions: remote.from_result(result)),
      effect.none(),
    )

    SlingshotReturnedHandle(result: returned) -> #(
      Model(
        ..model,
        verified_handle: slingshot.verified_handle(returned)
          |> result.replace_error(tranquil.Unreachable)
          |> remote.from_result,
      ),
      effect.none(),
    )

    UserClickedCopy(text:) -> #(model, browser.copy(text, BrowserCopiedText))

    BrowserCopiedText(result: Ok(Nil)) -> #(
      Model(..model, copying: Copied),
      effect.none(),
    )

    BrowserCopiedText(result: Error(Nil)) -> #(
      Model(..model, copying: CopyFailed),
      effect.none(),
    )
  }
}

fn rows(
  model: Model,
  account: Remote(tranquil.Account),
  server: String,
) -> List(Row) {
  let contact = case account {
    Loaded(value: tranquil.Account(contact_verified: True, ..))
    | Loading
    | Failed(_) -> []
    Loaded(value: tranquil.Account(contact_channel: tranquil.Email, ..)) -> [
      Row(
        label: "warn",
        tone: Warning,
        facts: Loaded("Email not verified"),
        action: #("Verify email", Account(Profile)),
      ),
    ]
    Loaded(value: tranquil.Account(contact_channel: channel, ..)) -> [
      Row(
        label: "warn",
        tone: Warning,
        facts: Loaded(tranquil.channel_label(channel) <> " not verified"),
        action: #("Verify contact", Account(Profile)),
      ),
    ]
  }

  let resolves = {
    use account <- remote.then(account)
    use verified <- remote.map(model.verified_handle)

    verified == Some(account.handle)
  }

  list.append(contact, [
    Row(
      label: "Handle",
      tone: case resolves {
        Loaded(value: False) -> Warning
        Loading | Loaded(value: True) | Failed(_) -> Plain
      },
      facts: remote.map(resolves, fn(resolves) {
        case resolves {
          True -> "resolves"
          False -> "doesn't resolve"
        }
      }),
      action: #("Details", Account(Profile)),
    ),
    Row(label: "Sign-in", tone: Plain, facts: sign_in_methods(model), action: #(
      "Manage",
      Access(SignInMethods),
    )),
    Row(
      label: "Sessions",
      tone: Plain,
      facts: remote.map(model.sessions, describe_sessions),
      action: #("Review", Access(Sessions)),
    ),
    Row(
      label: "Apps",
      tone: Plain,
      facts: remote.map(model.sessions, describe_apps),
      action: #("Review", Access(ConnectedApps)),
    ),
    Row(
      label: "Data",
      tone: Plain,
      facts: Loaded("Stored on " <> server),
      action: #("Export", Data(Export)),
    ),
  ])
}

fn sign_in_methods(model: Model) -> Remote(String) {
  use passkeys <- remote.then(model.passkeys)
  use authenticator <- remote.then(model.authenticator)
  use has_password <- remote.map(model.has_password)

  describe_sign_in_methods(list.length(passkeys), authenticator, has_password)
}

pub fn describe_sign_in_methods(
  passkeys: Int,
  authenticator: Authenticator,
  has_password: Bool,
) -> String {
  let facts = [
    case passkeys {
      0 -> "no passkeys"
      _ -> count(passkeys, "passkey", "passkeys")
    },
    case authenticator.enabled {
      True -> "authenticator on"
      False -> "authenticator off"
    },
    case has_password {
      True -> "password set"
      False -> "no password"
    },
  ]
  let backup_codes = case authenticator.enabled {
    True -> [
      count(authenticator.backup_codes_remaining, "backup code", "backup codes"),
    ]
    False -> []
  }

  string.join(list.append(facts, backup_codes), " \u{00B7} ")
}

pub fn describe_sessions(sessions: List(ActiveSession)) -> String {
  int.to_string(list.length(sessions)) <> " open"
}

pub fn describe_apps(sessions: List(ActiveSession)) -> String {
  let apps =
    sessions
    |> list.filter_map(fn(session) { option.to_result(session.app, Nil) })
    |> list.unique
  let total = int.to_string(list.length(apps)) <> " with access: "

  case apps {
    [] -> "none with access"
    [_] | [_, _] | [_, _, _] -> total <> string.join(apps, ", ")
    [first, second, third, ..rest] ->
      total
      <> string.join([first, second, third], ", ")
      <> ", "
      <> int.to_string(list.length(rest))
      <> " more"
  }
}

fn count(number: Int, singular: String, plural: String) -> String {
  case number {
    1 -> "1 " <> singular
    _ -> int.to_string(number) <> " " <> plural
  }
}

pub fn view(
  model: Model,
  session: Session,
  account: Remote(tranquil.Account),
) -> Element(Message) {
  let server = session.server(session)
  let account_did = did.to_string(session.account(session))
  let names = {
    use account <- remote.then(account)
    use display_name <- remote.map(model.display_name)

    #(display_name, "@" <> account.handle)
  }

  layout.page([
    html.section([], [
      html.p([attribute.class("prompt")], [html.text("whoami")]),
      html.h1([], [
        {
          use #(display_name, handle) <- layout.value(names)

          html.text(option.unwrap(display_name, handle))
        },
      ]),
      html.p([], [
        case names {
          Loaded(value: #(Some(_), handle)) ->
            html.code([], [html.text(handle)])
          Loaded(value: #(None, _)) | Loading | Failed(_) -> element.none()
        },
        html.text(" on " <> server),
      ]),
      html.p([attribute.class("did")], [
        html.code([], [html.text(account_did)]),
        html.button(
          [
            attribute.class("action"),
            event.on_click(UserClickedCopy(account_did)),
          ],
          [
            html.text(case model.copying {
              NotCopied -> "Copy"
              Copied -> "Copied"
              CopyFailed -> "Couldn't copy"
            }),
          ],
        ),
      ]),
    ]),
    layout.section("status", [
      layout.block(list.map(rows(model, account, server), view_row)),
    ]),
  ])
}

fn view_row(row: Row) -> Element(Message) {
  layout.row(
    tone: row.tone,
    name: row.label,
    details: [
      layout.value(row.facts, html.text),
    ],
    actions: [html.a([route.href(row.action.1)], [html.text(row.action.0)])],
  )
}
