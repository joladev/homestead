import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/browser
import homestead/layout
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const send_button_id = "send-deletion-code"

const code_id = "deletion-code"

const password_id = "deletion-password"

pub opaque type Model {
  Model(session: Session, step: Step)
}

type Step {
  Resting
  Requesting
  RequestRefused(problem: Problem)
  Confirming(code: String, password: String, submission: Submission)
  Deleted
}

type Submission {
  Idle
  Sending
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(Model(session:, step: Resting), effect.none())
}

pub fn departure(model: Model) -> Option(Departure) {
  case model.step {
    Deleted -> Some(session.SignedOut)
    RequestRefused(tranquil.SessionEnded) -> Some(session.Ended)
    Resting | Requesting | RequestRefused(_) | Confirming(..) -> None
  }
}

pub opaque type Message {
  UserClickedSendCode
  ServerSentCode(result: Result(Nil, Problem))
  UserTypedCode(code: String)
  UserTypedPassword(password: String)
  UserSubmittedDeletion(code: String, password: String)
  UserCancelled
  ServerDeletedAccount(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserClickedSendCode -> #(
      Model(..model, step: Requesting),
      tranquil.perform(
        model.session,
        tranquil.request_account_deletion(),
        ServerSentCode,
      ),
    )

    ServerSentCode(result: Ok(Nil)) -> #(
      Model(..model, step: Confirming(code: "", password: "", submission: Idle)),
      browser.focus(code_id),
    )

    ServerSentCode(result: Error(problem)) -> #(
      Model(..model, step: RequestRefused(problem:)),
      effect.none(),
    )

    UserTypedCode(code:) ->
      case model.step {
        Confirming(password:, ..) -> #(
          Model(..model, step: Confirming(code:, password:, submission: Idle)),
          effect.none(),
        )
        Resting | Requesting | RequestRefused(_) | Deleted -> #(
          model,
          effect.none(),
        )
      }

    UserTypedPassword(password:) ->
      case model.step {
        Confirming(code:, ..) -> #(
          Model(..model, step: Confirming(code:, password:, submission: Idle)),
          effect.none(),
        )
        Resting | Requesting | RequestRefused(_) | Deleted -> #(
          model,
          effect.none(),
        )
      }

    UserSubmittedDeletion(code:, password:) -> #(
      Model(..model, step: Confirming(code:, password:, submission: Sending)),
      tranquil.delete_account(
        model.session,
        password,
        string.trim(code),
        ServerDeletedAccount,
      ),
    )

    UserCancelled -> #(
      Model(..model, step: Resting),
      browser.focus(send_button_id),
    )

    ServerDeletedAccount(result: Ok(Nil)) -> #(
      Model(..model, step: Deleted),
      effect.none(),
    )

    ServerDeletedAccount(result: Error(problem)) ->
      case model.step {
        Confirming(code:, password:, ..) -> #(
          Model(
            ..model,
            step: Confirming(code:, password:, submission: Refused(problem:)),
          ),
          effect.none(),
        )
        Resting | Requesting | RequestRefused(_) | Deleted -> #(
          model,
          effect.none(),
        )
      }
  }
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("AuthenticationFailed", _) -> "That password isn't right"
    tranquil.Refused("InvalidToken", _) -> "That code isn't right"
    tranquil.Refused("ExpiredToken", _) -> "That code has expired"
    tranquil.Refused("InvalidRequest", message) if message != "" -> message
    tranquil.Refused("RateLimitExceeded", _) ->
      "Too many attempts. Try again later"
    tranquil.Unreachable -> "Couldn't reach the server"
    tranquil.Refused(_, _) | tranquil.NotUnderstood | tranquil.SessionEnded ->
      "The server didn't accept that"
  }
}

pub fn view(model: Model) -> Element(Message) {
  let statement = fn(actions) {
    layout.row(
      tone: layout.Plain,
      name: "Delete",
      details: [html.text("Everything in this account is removed for good")],
      actions:,
    )
  }
  let send_button = fn(is_requesting) {
    html.button(
      [
        attribute.id(send_button_id),
        attribute.class("action"),
        attribute.disabled(is_requesting),
        event.on_click(UserClickedSendCode),
      ],
      [html.text("Send code")],
    )
  }

  layout.page([
    layout.title_section("delete-account", [
      layout.block(case model.step {
        Resting -> [statement([send_button(False)])]
        Requesting -> [statement([send_button(True)])]
        RequestRefused(problem:) -> [
          statement([send_button(False)]),
          layout.problem(describe_refusal(problem)),
        ]
        Confirming(code:, password:, submission:) -> [
          statement([]),
          view_form(code, password, submission),
        ]
        Deleted -> [statement([])]
      }),
    ]),
  ])
}

fn view_form(
  code: String,
  password: String,
  submission: Submission,
) -> Element(Message) {
  let is_sending = submission == Sending

  html.form([event.on_submit(fn(_) { UserSubmittedDeletion(code, password) })], [
    layout.field(
      html.label([attribute.for(code_id)], [html.text("Code")]),
      html.div([attribute.class("inline")], [
        html.input([
          attribute.id(code_id),
          attribute.type_("text"),
          attribute.autocomplete("one-time-code"),
          attribute.value(code),
          attribute.disabled(is_sending),
          event.on_input(UserTypedCode),
        ]),
        layout.dim("sent to you \u{00B7} valid 15 minutes"),
      ]),
    ),
    layout.field(
      html.label([attribute.for(password_id)], [html.text("Password")]),
      html.input([
        attribute.id(password_id),
        attribute.type_("password"),
        attribute.autocomplete("current-password"),
        attribute.value(password),
        attribute.disabled(is_sending),
        event.on_input(UserTypedPassword),
      ]),
    ),
    case submission {
      Refused(problem:) -> layout.problem(describe_refusal(problem))
      Idle | Sending -> element.none()
    },
    layout.details_row([
      html.div([attribute.class("inline")], [
        html.button(
          [
            attribute.class("action accept"),
            attribute.disabled(
              is_sending || string.trim(code) == "" || password == "",
            ),
          ],
          [html.text("Delete account")],
        ),
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            event.on_click(UserCancelled),
          ],
          [html.text("Cancel")],
        ),
      ]),
    ]),
  ])
}
