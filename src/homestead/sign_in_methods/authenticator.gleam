import gleam/int
import gleam/list
import gleam/string
import homestead/browser
import homestead/dialog
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{
  type Authenticator, type AuthenticatorSetup, type Problem,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const dialog_id = "authenticator-check"

const password_id = "authenticator-check-password"

const setup_button_id = "set-up-authenticator"

pub opaque type Model {
  Model(session: Session, status: Remote(Authenticator), action: Action)
}

type Action {
  Resting
  Preparing
  Scanning(setup: AuthenticatorSetup, code: String, submission: Submission)
  Checking(
    purpose: Purpose,
    password: String,
    code: String,
    submission: Submission,
  )
  ShowingCodes(codes: List(String), copying: Copying)
  Refused(problem: Problem)
}

type Purpose {
  TurningOff
  ReplacingCodes
}

type Submission {
  Idle
  Sending
  SubmissionRefused(problem: Problem)
}

type Copying {
  NotCopied
  Copied
  CopyFailed
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(Model(session:, status: Loading, action: Resting), load(session))
}

pub opaque type Message {
  ServerReturnedStatus(result: Result(Authenticator, Problem))
  UserClickedSetUp
  ServerPreparedSetup(result: Result(AuthenticatorSetup, Problem))
  UserTypedSetupCode(code: String)
  UserSubmittedSetupCode
  UserCancelledSetup
  ServerEnabledAuthenticator(result: Result(List(String), Problem))
  UserClickedCopy(text: String)
  BrowserCopiedText(result: Result(Nil, Nil))
  UserClickedDone
  UserOpenedCheck(purpose: Purpose)
  UserTypedPassword(password: String)
  UserTypedCheckCode(code: String)
  UserSubmittedCheck
  UserCancelledCheck(purpose: Purpose)
  ServerDisabledAuthenticator(result: Result(Nil, Problem))
  ServerReplacedCodes(result: Result(List(String), Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedStatus(result:) -> #(
      Model(..model, status: remote.from_result(result)),
      effect.none(),
    )

    UserClickedSetUp -> #(
      Model(..model, action: Preparing),
      tranquil.perform(
        session,
        tranquil.prepare_authenticator(),
        ServerPreparedSetup,
      ),
    )

    ServerPreparedSetup(result: Ok(setup)) -> #(
      Model(..model, action: Scanning(setup:, code: "", submission: Idle)),
      browser.focus(setup_code_id),
    )

    ServerPreparedSetup(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserTypedSetupCode(code:) ->
      case model.action {
        Scanning(setup:, ..) -> #(
          Model(..model, action: Scanning(setup:, code:, submission: Idle)),
          effect.none(),
        )
        Resting | Preparing | Checking(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserSubmittedSetupCode ->
      case model.action {
        Scanning(setup:, code:, ..) -> #(
          Model(..model, action: Scanning(setup:, code:, submission: Sending)),
          tranquil.perform(
            session,
            tranquil.enable_authenticator(string.trim(code)),
            ServerEnabledAuthenticator,
          ),
        )
        Resting | Preparing | Checking(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserCancelledSetup -> #(
      Model(..model, action: Resting),
      browser.focus(setup_button_id),
    )

    ServerEnabledAuthenticator(result: Ok(codes)) -> #(
      Model(..model, action: ShowingCodes(codes:, copying: NotCopied)),
      load(session),
    )

    ServerEnabledAuthenticator(result: Error(problem)) ->
      case model.action {
        Scanning(setup:, code:, ..) -> #(
          Model(
            ..model,
            action: Scanning(
              setup:,
              code:,
              submission: SubmissionRefused(problem:),
            ),
          ),
          effect.none(),
        )
        Resting | Preparing | Checking(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserClickedCopy(text:) -> #(model, browser.copy(text, BrowserCopiedText))

    BrowserCopiedText(result:) ->
      case model.action {
        ShowingCodes(codes:, ..) -> #(
          Model(
            ..model,
            action: ShowingCodes(codes:, copying: case result {
              Ok(Nil) -> Copied
              Error(Nil) -> CopyFailed
            }),
          ),
          effect.none(),
        )
        Resting | Preparing | Scanning(..) | Checking(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserClickedDone -> #(Model(..model, action: Resting), effect.none())

    UserOpenedCheck(purpose:) -> #(
      Model(
        ..model,
        action: Checking(purpose:, password: "", code: "", submission: Idle),
      ),
      effect.batch([dialog.open(dialog_id), browser.focus(password_id)]),
    )

    UserTypedPassword(password:) ->
      case model.action {
        Checking(purpose:, code:, ..) -> #(
          Model(
            ..model,
            action: Checking(purpose:, password:, code:, submission: Idle),
          ),
          effect.none(),
        )
        Resting | Preparing | Scanning(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserTypedCheckCode(code:) ->
      case model.action {
        Checking(purpose:, password:, ..) -> #(
          Model(
            ..model,
            action: Checking(purpose:, password:, code:, submission: Idle),
          ),
          effect.none(),
        )
        Resting | Preparing | Scanning(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserSubmittedCheck ->
      case model.action {
        Checking(purpose:, password:, code:, ..) -> #(
          Model(
            ..model,
            action: Checking(purpose:, password:, code:, submission: Sending),
          ),
          case purpose {
            TurningOff ->
              tranquil.perform(
                session,
                tranquil.disable_authenticator(password, string.trim(code)),
                ServerDisabledAuthenticator,
              )
            ReplacingCodes ->
              tranquil.perform(
                session,
                tranquil.replace_backup_codes(password, string.trim(code)),
                ServerReplacedCodes,
              )
          },
        )
        Resting | Preparing | Scanning(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserCancelledCheck(purpose:) -> #(
      Model(..model, action: Resting),
      browser.focus(check_button_id(purpose)),
    )

    ServerDisabledAuthenticator(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerReplacedCodes(result: Ok(codes)) -> #(
      Model(..model, action: ShowingCodes(codes:, copying: NotCopied)),
      load(session),
    )

    ServerDisabledAuthenticator(result: Error(problem))
    | ServerReplacedCodes(result: Error(problem)) ->
      case model.action {
        Checking(purpose:, password:, code:, ..) -> #(
          Model(
            ..model,
            action: Checking(
              purpose:,
              password:,
              code:,
              submission: SubmissionRefused(problem:),
            ),
          ),
          effect.none(),
        )
        Resting | Preparing | Scanning(..) | ShowingCodes(..) | Refused(_) -> #(
          model,
          effect.none(),
        )
      }
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.authenticator(), ServerReturnedStatus)
}

const setup_code_id = "authenticator-setup-code"

fn check_button_id(purpose: Purpose) -> String {
  case purpose {
    TurningOff -> "turn-off-authenticator"
    ReplacingCodes -> "replace-backup-codes"
  }
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("InvalidPassword", _) -> "That password isn't right"
    tranquil.Refused("InvalidCode", _) -> "That code isn't right"
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(case model.status, model.action {
      Loading, _ -> []
      Failed(_), _ -> [layout.problem("Couldn't load")]
      Loaded(_), Scanning(setup:, code:, submission:) ->
        view_setup(setup, code, submission)
      Loaded(_), ShowingCodes(codes:, copying:) -> view_codes(codes, copying)
      Loaded(value: status), Refused(problem:) -> [
        view_status(status, False),
        layout.problem(describe_refusal(problem)),
      ]
      Loaded(value: status), Preparing -> [view_status(status, True)]
      Loaded(value: status), Resting | Loaded(value: status), Checking(..) -> [
        view_status(status, False),
      ]
    }),
    case model.action {
      Checking(purpose:, password:, code:, submission:) ->
        view_check(purpose, password, code, submission)
      Resting | Preparing | Scanning(..) | ShowingCodes(..) | Refused(_) ->
        element.none()
    },
  ]
}

fn view_status(status: Authenticator, is_preparing: Bool) -> Element(Message) {
  case status.enabled {
    False ->
      layout.row(
        tone: layout.Plain,
        name: "Authenticator",
        details: [html.text("off")],
        actions: [
          html.button(
            [
              attribute.id(setup_button_id),
              attribute.class("action"),
              attribute.disabled(is_preparing),
              event.on_click(UserClickedSetUp),
            ],
            [html.text("Set up")],
          ),
        ],
      )

    True ->
      layout.row(
        tone: layout.Plain,
        name: "Authenticator",
        details: [
          html.text("on "),
          layout.dim(
            "\u{00B7} "
            <> int.to_string(status.backup_codes_remaining)
            <> " backup codes left",
          ),
        ],
        actions: [
          html.button(
            [
              attribute.id(check_button_id(ReplacingCodes)),
              attribute.class("action"),
              event.on_click(UserOpenedCheck(ReplacingCodes)),
            ],
            [html.text("New backup codes")],
          ),
          html.button(
            [
              attribute.id(check_button_id(TurningOff)),
              attribute.class("action"),
              event.on_click(UserOpenedCheck(TurningOff)),
            ],
            [html.text("Turn off")],
          ),
        ],
      )
  }
}

fn view_setup(
  setup: AuthenticatorSetup,
  code: String,
  submission: Submission,
) -> List(Element(Message)) {
  [
    layout.row(
      tone: layout.Plain,
      name: "Scan",
      details: [
        html.img([
          attribute.class("qr"),
          attribute.src("data:image/png;base64," <> setup.qr_image),
          attribute.alt("QR code for your authenticator app"),
        ]),
      ],
      actions: [],
    ),
    layout.row(
      tone: layout.Plain,
      name: "Or type",
      details: [html.code([], [html.text(setup.secret)])],
      actions: [],
    ),
    html.form([event.on_submit(fn(_) { UserSubmittedSetupCode })], [
      layout.field(
        html.label([attribute.for(setup_code_id)], [html.text("Code")]),
        html.input([
          attribute.id(setup_code_id),
          attribute.type_("text"),
          attribute.inputmode("numeric"),
          attribute.autocomplete("one-time-code"),
          attribute.value(code),
          attribute.disabled(submission == Sending),
          event.on_input(UserTypedSetupCode),
        ]),
      ),
      case submission {
        SubmissionRefused(problem:) -> layout.problem(describe_refusal(problem))
        Idle | Sending -> element.none()
      },
      layout.details_row([
        html.div([attribute.class("inline")], [
          html.button(
            [
              attribute.class("action primary"),
              attribute.disabled(
                submission == Sending || string.trim(code) == "",
              ),
            ],
            [html.text("Turn on")],
          ),
          html.button(
            [
              attribute.class("action"),
              attribute.type_("button"),
              event.on_click(UserCancelledSetup),
            ],
            [html.text("Cancel")],
          ),
        ]),
      ]),
    ]),
  ]
}

fn view_codes(codes: List(String), copying: Copying) -> List(Element(Message)) {
  [
    layout.row(
      tone: layout.Warning,
      name: "Backup codes",
      details: [
        html.code(
          [attribute.class("codes")],
          list.map(codes, fn(code) { html.span([], [html.text(code)]) }),
        ),
        layout.dim(case copying {
          NotCopied -> "shown once"
          Copied -> "shown once \u{00B7} copied"
          CopyFailed -> "shown once \u{00B7} couldn't copy"
        }),
      ],
      actions: [
        html.button(
          [
            attribute.class("action"),
            event.on_click(UserClickedCopy(string.join(codes, "\n"))),
          ],
          [html.text("Copy")],
        ),
        html.button(
          [attribute.class("action"), event.on_click(UserClickedDone)],
          [html.text("Done")],
        ),
      ],
    ),
  ]
}

fn view_check(
  purpose: Purpose,
  password: String,
  code: String,
  submission: Submission,
) -> Element(Message) {
  let code_id = "authenticator-check-code"
  let is_sending = submission == Sending

  dialog.view(
    id: dialog_id,
    title: case purpose {
      TurningOff -> "turn off authenticator"
      ReplacingCodes -> "new backup codes"
    },
    on_cancel: UserCancelledCheck(purpose),
    content: [
      html.form([event.on_submit(fn(_) { UserSubmittedCheck })], [
        case purpose {
          TurningOff -> element.none()
          ReplacingCodes ->
            html.p([], [html.text("The current backup codes stop working.")])
        },
        dialog.field(
          id: password_id,
          label: "Password",
          control: html.input([
            attribute.id(password_id),
            attribute.type_("password"),
            attribute.autocomplete("current-password"),
            attribute.value(password),
            attribute.disabled(is_sending),
            event.on_input(UserTypedPassword),
          ]),
        ),
        dialog.field(
          id: code_id,
          label: "Authenticator code",
          control: html.input([
            attribute.id(code_id),
            attribute.type_("text"),
            attribute.inputmode("numeric"),
            attribute.autocomplete("one-time-code"),
            attribute.value(code),
            attribute.disabled(is_sending),
            event.on_input(UserTypedCheckCode),
          ]),
        ),
        case submission {
          SubmissionRefused(problem:) ->
            dialog.problem(describe_refusal(problem))
          Idle | Sending -> element.none()
        },
        dialog.actions([
          html.button(
            [
              attribute.class("action"),
              attribute.type_("button"),
              event.on_click(UserCancelledCheck(purpose)),
            ],
            [html.text("Cancel")],
          ),
          html.button(
            [
              attribute.class("action accept"),
              attribute.disabled(
                is_sending || password == "" || string.trim(code) == "",
              ),
            ],
            [
              html.text(case purpose {
                TurningOff -> "Turn off"
                ReplacingCodes -> "Replace codes"
              }),
            ],
          ),
        ]),
      ]),
    ],
  )
}
