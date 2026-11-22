import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/reauth
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Passkey, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    passkeys: Remote(List(Passkey)),
    action: Action,
  )
}

type Action {
  Resting
  Renaming(passkey: Passkey, name: String, is_saving: Bool)
  ConfirmingDelete(passkey: Passkey)
  Deleting(passkey: Passkey)
  SigningInAgain(passkey: Passkey, reauth: reauth.Model)
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      passkeys: Loading,
      action: Resting,
    ),
    load(session),
  )
}

pub fn has_any(model: Model) -> Bool {
  case model.passkeys {
    Loaded(value: [_, ..]) -> True
    Loaded(value: []) | Loading | Failed(_) -> False
  }
}

pub opaque type Message {
  ServerReturnedPasskeys(result: Result(List(Passkey), Problem))
  UserClickedRename(passkey: Passkey)
  UserTypedName(name: String)
  UserSubmittedName
  UserCancelledRename(passkey: Passkey)
  ServerRenamedPasskey(result: Result(Nil, Problem))
  UserClickedDelete(passkey: Passkey)
  UserCancelledDelete(passkey: Passkey)
  UserConfirmedDelete(passkey: Passkey)
  ServerDeletedPasskey(passkey: Passkey, result: Result(Nil, Problem))
  ReauthProducedMessage(message: reauth.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedPasskeys(result:) -> #(
      Model(..model, passkeys: remote.from_result(result)),
      effect.none(),
    )

    UserClickedRename(passkey:) -> #(
      Model(
        ..model,
        action: Renaming(
          passkey:,
          name: option.unwrap(passkey.name, ""),
          is_saving: False,
        ),
      ),
      browser.focus(name_input_id),
    )

    UserTypedName(name:) ->
      case model.action {
        Renaming(passkey:, ..) -> #(
          Model(..model, action: Renaming(passkey:, name:, is_saving: False)),
          effect.none(),
        )
        Resting
        | ConfirmingDelete(_)
        | Deleting(_)
        | SigningInAgain(..)
        | Refused(_) -> #(model, effect.none())
      }

    UserSubmittedName ->
      case model.action {
        Renaming(passkey:, name:, ..) -> #(
          Model(..model, action: Renaming(passkey:, name:, is_saving: True)),
          tranquil.perform(
            session,
            tranquil.rename_passkey(passkey.id, string.trim(name)),
            ServerRenamedPasskey,
          ),
        )
        Resting
        | ConfirmingDelete(_)
        | Deleting(_)
        | SigningInAgain(..)
        | Refused(_) -> #(model, effect.none())
      }

    UserCancelledRename(passkey:) -> #(
      Model(..model, action: Resting),
      browser.focus(rename_button_id(passkey)),
    )

    ServerRenamedPasskey(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerRenamedPasskey(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserClickedDelete(passkey:) -> #(
      Model(..model, action: ConfirmingDelete(passkey:)),
      confirmation.focus_cancel(),
    )

    UserCancelledDelete(passkey:) -> #(
      Model(..model, action: Resting),
      browser.focus(delete_button_id(passkey)),
    )

    UserConfirmedDelete(passkey:) -> #(
      Model(..model, action: Deleting(passkey:)),
      delete(session, passkey),
    )

    ServerDeletedPasskey(result: Ok(Nil), ..) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerDeletedPasskey(
      passkey:,
      result: Error(tranquil.Refused("ReauthRequired", _)),
    ) -> {
      let #(reauth, effect) = reauth.init(session)

      #(
        Model(..model, action: SigningInAgain(passkey:, reauth:)),
        effect.map(effect, ReauthProducedMessage),
      )
    }

    ServerDeletedPasskey(result: Error(problem), ..) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    ReauthProducedMessage(message:) ->
      case model.action {
        SigningInAgain(passkey:, reauth:) -> {
          let #(reauth, effect) = reauth.update(reauth, message)

          case reauth.outcome(reauth) {
            reauth.Waiting -> #(
              Model(..model, action: SigningInAgain(passkey:, reauth:)),
              effect.map(effect, ReauthProducedMessage),
            )
            reauth.Confirmed -> #(
              Model(..model, action: Deleting(passkey:)),
              delete(session, passkey),
            )
            reauth.Cancelled -> #(
              Model(..model, action: Resting),
              browser.focus(delete_button_id(passkey)),
            )
          }
        }
        Resting
        | Renaming(..)
        | ConfirmingDelete(_)
        | Deleting(_)
        | Refused(_) -> #(model, effect.none())
      }
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.passkeys(), ServerReturnedPasskeys)
}

fn delete(session: Session, passkey: Passkey) -> Effect(Message) {
  tranquil.perform(
    session,
    tranquil.delete_passkey(passkey.id),
    ServerDeletedPasskey(passkey, _),
  )
}

const name_input_id = "passkey-name"

fn rename_button_id(passkey: Passkey) -> String {
  "rename-passkey-" <> passkey.id
}

fn delete_button_id(passkey: Passkey) -> String {
  "delete-passkey-" <> passkey.id
}

pub fn describe_name(passkey: Passkey) -> String {
  case passkey.name {
    Some(name) -> name
    None -> "Passkey"
  }
}

pub fn view_actions(model: Model) -> List(Element(message)) {
  let server = session.server(model.session)

  [
    html.a(
      [
        attribute.class("action"),
        attribute.href("https://" <> server <> "/app/security"),
      ],
      [html.text("Add on " <> server)],
    ),
  ]
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        case model.passkeys {
          Loading -> [layout.loading(1)]
          Failed(_) -> [layout.problem("Couldn't load")]
          Loaded(value: []) -> [layout.note("No passkeys", [])]
          Loaded(value: passkeys) -> list.map(passkeys, view_passkey(_, model))
        },
        case model.action {
          Refused(_) -> [layout.problem("The server didn't accept that")]
          Resting
          | Renaming(..)
          | ConfirmingDelete(_)
          | Deleting(_)
          | SigningInAgain(..) -> []
        },
      ]),
    ),
    case model.action {
      SigningInAgain(reauth:, ..) ->
        reauth.view(reauth) |> element.map(ReauthProducedMessage)
      Resting | Renaming(..) | ConfirmingDelete(_) | Deleting(_) | Refused(_) ->
        element.none()
    },
  ]
}

fn view_passkey(passkey: Passkey, model: Model) -> Element(Message) {
  case model.action {
    Renaming(passkey: renaming, name:, is_saving:) if renaming == passkey ->
      layout.name_form(
        id: name_input_id,
        name:,
        is_saving:,
        on_input: UserTypedName,
        on_submit: UserSubmittedName,
        on_cancel: UserCancelledRename(passkey),
      )

    ConfirmingDelete(passkey: confirming) if confirming == passkey ->
      confirmation.view(
        question: "Delete?",
        consequence: describe_name(passkey) <> " can no longer sign you in.",
        accept: "Delete passkey",
        on_cancel: UserCancelledDelete(passkey),
        on_accept: UserConfirmedDelete(passkey),
      )

    _ ->
      layout.row(
        tone: layout.Plain,
        name: describe_name(passkey),
        details: [
          layout.dim(
            "added "
            <> date.describe(passkey.created, model.local_offset)
            <> " \u{00B7} "
            <> case passkey.last_used {
              Some(used) ->
                "last used " <> date.describe(used, model.local_offset)
              None -> "never used"
            },
          ),
        ],
        actions: [
          html.button(
            [
              attribute.id(rename_button_id(passkey)),
              attribute.class("action"),
              event.on_click(UserClickedRename(passkey)),
            ],
            [html.text("Rename")],
          ),
          html.button(
            [
              attribute.id(delete_button_id(passkey)),
              attribute.class("action"),
              event.on_click(UserClickedDelete(passkey)),
            ],
            [html.text("Delete")],
          ),
        ],
      )
  }
}
