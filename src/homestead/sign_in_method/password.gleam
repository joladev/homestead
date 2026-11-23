import homestead/browser
import homestead/confirmation
import homestead/layout
import homestead/reauth
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const change_button_id = "change-password"

const remove_button_id = "remove-password"

const set_button_id = "set-password"

const current_id = "current-password"

const new_id = "new-password"

pub opaque type Model {
  Model(session: Session, has_password: Remote(Bool), action: Action)
}

type Action {
  Resting
  Changing(current: String, new: String, submission: Submission)
  Setting(new: String, submission: Submission)
  ConfirmingRemove
  Removing
  SigningInAgain(pending: Pending, reauth: reauth.Model)
  Changed
  Refused(problem: Problem)
}

type Pending {
  RemovingPassword
  SettingPassword(new: String)
}

type Submission {
  Idle
  Sending
  SubmissionRefused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(Model(session:, has_password: Loading, action: Resting), load(session))
}

pub opaque type Message {
  ServerReturnedStatus(result: Result(Bool, Problem))
  UserClickedChange
  UserTypedCurrent(password: String)
  UserTypedNew(password: String)
  UserSubmittedChange(current: String, new: String)
  ServerChangedPassword(result: Result(Nil, Problem))
  UserClickedSet
  UserSubmittedNew(new: String)
  ServerSetPassword(new: String, result: Result(Nil, Problem))
  UserCancelledForm(return_to: String)
  UserClickedRemove
  UserCancelledRemove
  UserConfirmedRemove
  ServerRemovedPassword(result: Result(Nil, Problem))
  ReauthProducedMessage(message: reauth.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedStatus(result:) -> #(
      Model(..model, has_password: remote.from_result(result)),
      effect.none(),
    )

    UserClickedChange -> #(
      Model(..model, action: Changing(current: "", new: "", submission: Idle)),
      browser.focus(current_id),
    )

    UserTypedCurrent(password:) ->
      case model.action {
        Changing(new:, ..) -> #(
          Model(
            ..model,
            action: Changing(current: password, new:, submission: Idle),
          ),
          effect.none(),
        )
        Resting
        | Setting(..)
        | ConfirmingRemove
        | Removing
        | SigningInAgain(..)
        | Changed
        | Refused(_) -> #(model, effect.none())
      }

    UserTypedNew(password:) ->
      case model.action {
        Changing(current:, ..) -> #(
          Model(
            ..model,
            action: Changing(current:, new: password, submission: Idle),
          ),
          effect.none(),
        )
        Setting(..) -> #(
          Model(..model, action: Setting(new: password, submission: Idle)),
          effect.none(),
        )
        Resting
        | ConfirmingRemove
        | Removing
        | SigningInAgain(..)
        | Changed
        | Refused(_) -> #(model, effect.none())
      }

    UserSubmittedChange(current:, new:) -> #(
      Model(..model, action: Changing(current:, new:, submission: Sending)),
      tranquil.perform(
        session,
        tranquil.change_password(current, new),
        ServerChangedPassword,
      ),
    )

    ServerChangedPassword(result: Ok(Nil)) -> #(
      Model(..model, action: Changed),
      effect.none(),
    )

    ServerChangedPassword(result: Error(problem)) ->
      case model.action {
        Changing(current:, new:, ..) -> #(
          Model(
            ..model,
            action: Changing(
              current:,
              new:,
              submission: SubmissionRefused(problem:),
            ),
          ),
          effect.none(),
        )
        Resting
        | Setting(..)
        | ConfirmingRemove
        | Removing
        | SigningInAgain(..)
        | Changed
        | Refused(_) -> #(model, effect.none())
      }

    UserClickedSet -> #(
      Model(..model, action: Setting(new: "", submission: Idle)),
      browser.focus(new_id),
    )

    UserSubmittedNew(new:) -> #(
      Model(..model, action: Setting(new:, submission: Sending)),
      set(session, new),
    )

    ServerSetPassword(result: Ok(Nil), ..) -> #(
      Model(..model, action: Changed),
      load(session),
    )

    ServerSetPassword(
      new:,
      result: Error(tranquil.Refused("ReauthRequired", _)),
    ) -> sign_in_again(model, SettingPassword(new:))

    ServerSetPassword(new:, result: Error(problem)) -> #(
      Model(
        ..model,
        action: Setting(new:, submission: SubmissionRefused(problem:)),
      ),
      effect.none(),
    )

    UserCancelledForm(return_to:) -> #(
      Model(..model, action: Resting),
      browser.focus(return_to),
    )

    UserClickedRemove -> #(
      Model(..model, action: ConfirmingRemove),
      confirmation.focus_cancel(),
    )

    UserCancelledRemove -> #(
      Model(..model, action: Resting),
      browser.focus(remove_button_id),
    )

    UserConfirmedRemove -> #(Model(..model, action: Removing), remove(session))

    ServerRemovedPassword(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerRemovedPassword(result: Error(tranquil.Refused("ReauthRequired", _))) ->
      sign_in_again(model, RemovingPassword)

    ServerRemovedPassword(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    ReauthProducedMessage(message:) ->
      case model.action {
        SigningInAgain(pending:, reauth:) -> {
          let #(reauth, effect) = reauth.update(reauth, message)

          case reauth.outcome(reauth), pending {
            reauth.Waiting, _ -> #(
              Model(..model, action: SigningInAgain(pending:, reauth:)),
              effect.map(effect, ReauthProducedMessage),
            )
            reauth.Confirmed, RemovingPassword -> #(
              Model(..model, action: Removing),
              remove(session),
            )
            reauth.Confirmed, SettingPassword(new:) -> #(
              Model(..model, action: Setting(new:, submission: Sending)),
              set(session, new),
            )
            reauth.Cancelled, RemovingPassword -> #(
              Model(..model, action: Resting),
              browser.focus(remove_button_id),
            )
            reauth.Cancelled, SettingPassword(new:) -> #(
              Model(..model, action: Setting(new:, submission: Idle)),
              browser.focus(new_id),
            )
          }
        }
        Resting
        | Changing(..)
        | Setting(..)
        | ConfirmingRemove
        | Removing
        | Changed
        | Refused(_) -> #(model, effect.none())
      }
  }
}

fn sign_in_again(model: Model, pending: Pending) -> #(Model, Effect(Message)) {
  let #(reauth, effect) = reauth.init(model.session)

  #(
    Model(..model, action: SigningInAgain(pending:, reauth:)),
    effect.map(effect, ReauthProducedMessage),
  )
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.has_password(), ServerReturnedStatus)
}

fn set(session: Session, new: String) -> Effect(Message) {
  tranquil.perform(session, tranquil.set_password(new), ServerSetPassword(
    new,
    _,
  ))
}

fn remove(session: Session) -> Effect(Message) {
  tranquil.perform(session, tranquil.remove_password(), ServerRemovedPassword)
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("InvalidPassword", _) -> "That password isn't right"
    tranquil.Refused("InvalidRequest", message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view(model: Model, has_passkey: Bool) -> List(Element(Message)) {
  let status = {
    use has_password <- layout.awaited_row(
      name: "Password",
      of: model.has_password,
    )

    view_status(has_password, has_passkey, model.action)
  }

  [
    layout.block(case model.action {
      Changing(current:, new:, submission:) ->
        view_change(current, new, submission)

      Setting(new:, submission:) -> view_set(new, submission)
      SigningInAgain(pending: SettingPassword(new:), ..) ->
        view_set(new, Sending)

      ConfirmingRemove -> [
        confirmation.view(
          question: "Remove?",
          consequence: "Only your passkeys will sign you in.",
          accept: "Remove password",
          on_cancel: UserCancelledRemove,
          on_accept: UserConfirmedRemove,
        ),
      ]

      Refused(problem:) -> [status, layout.problem(describe_refusal(problem))]

      Resting
      | Changed
      | Removing
      | SigningInAgain(pending: RemovingPassword, ..) -> [status]
    }),
    case model.action {
      SigningInAgain(reauth:, ..) ->
        reauth.view(reauth) |> element.map(ReauthProducedMessage)
      Resting
      | Changing(..)
      | Setting(..)
      | ConfirmingRemove
      | Removing
      | Changed
      | Refused(_) -> element.none()
    },
  ]
}

fn view_status(
  has_password: Bool,
  has_passkey: Bool,
  action: Action,
) -> Element(Message) {
  case has_password {
    True ->
      layout.row(
        tone: layout.Plain,
        name: "Password",
        details: [
          html.text("set "),
          case action {
            Changed -> layout.dim("\u{00B7} changed")
            Resting
            | Changing(..)
            | Setting(..)
            | ConfirmingRemove
            | Removing
            | SigningInAgain(..)
            | Refused(_) -> element.none()
          },
        ],
        actions: [
          html.button(
            [
              attribute.id(change_button_id),
              attribute.class("action"),
              event.on_click(UserClickedChange),
            ],
            [html.text("Change")],
          ),
          case has_passkey {
            True ->
              html.button(
                [
                  attribute.id(remove_button_id),
                  attribute.class("action"),
                  event.on_click(UserClickedRemove),
                ],
                [html.text("Remove")],
              )
            False -> element.none()
          },
        ],
      )

    False ->
      layout.row(
        tone: layout.Plain,
        name: "Password",
        details: [html.text("none")],
        actions: [
          html.button(
            [
              attribute.id(set_button_id),
              attribute.class("action"),
              event.on_click(UserClickedSet),
            ],
            [html.text("Set")],
          ),
        ],
      )
  }
}

fn view_change(
  current: String,
  new: String,
  submission: Submission,
) -> List(Element(Message)) {
  let is_sending = submission == Sending

  [
    html.form([event.on_submit(fn(_) { UserSubmittedChange(current, new) })], [
      layout.field(
        html.label([attribute.for(current_id)], [html.text("Current password")]),
        html.input([
          attribute.id(current_id),
          attribute.type_("password"),
          attribute.autocomplete("current-password"),
          attribute.value(current),
          attribute.disabled(is_sending),
          event.on_input(UserTypedCurrent),
        ]),
      ),
      view_new_field(new:, is_sending:),
      view_refusal(submission),
      view_form_actions(
        label: "Change",
        is_disabled: is_sending || current == "" || new == "",
        return_to: change_button_id,
      ),
    ]),
  ]
}

fn view_set(new: String, submission: Submission) -> List(Element(Message)) {
  let is_sending = submission == Sending

  [
    html.form([event.on_submit(fn(_) { UserSubmittedNew(new) })], [
      view_new_field(new:, is_sending:),
      view_refusal(submission),
      view_form_actions(
        label: "Set",
        is_disabled: is_sending || new == "",
        return_to: set_button_id,
      ),
    ]),
  ]
}

fn view_new_field(
  new new: String,
  is_sending is_sending: Bool,
) -> Element(Message) {
  layout.field(
    html.label([attribute.for(new_id)], [html.text("New password")]),
    html.input([
      attribute.id(new_id),
      attribute.type_("password"),
      attribute.autocomplete("new-password"),
      attribute.value(new),
      attribute.disabled(is_sending),
      event.on_input(UserTypedNew),
    ]),
  )
}

fn view_refusal(submission: Submission) -> Element(Message) {
  case submission {
    SubmissionRefused(problem:) -> layout.problem(describe_refusal(problem))
    Idle | Sending -> element.none()
  }
}

fn view_form_actions(
  label label: String,
  is_disabled is_disabled: Bool,
  return_to return_to: String,
) -> Element(Message) {
  layout.details_row([
    html.div([attribute.class("inline")], [
      html.button(
        [attribute.class("action primary"), attribute.disabled(is_disabled)],
        [html.text(label)],
      ),
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          event.on_click(UserCancelledForm(return_to)),
        ],
        [html.text("Cancel")],
      ),
    ]),
  ])
}
