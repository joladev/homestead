import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/uri.{type Uri}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/delegation/access
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{
  type AccessLevel, type ControlledAccount, type Problem,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem

const new_button_id = "new-controlled-account"

const handle_id = "controlled-handle"

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    accounts: Remote(List(ControlledAccount)),
    action: Action,
  )
}

type Action {
  Resting
  Creating(handle: String, email: String, level: String, submission: Submission)
  ConfirmingDelete(account: ControlledAccount)
  Deleting
  StartingToActAs
  ActAsRefused
  Refused(problem: Problem)
}

type Submission {
  Idle
  Sending
  SubmissionRefused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      accounts: Loading,
      action: Resting,
    ),
    load(session),
  )
}

pub fn has_ended_session(model: Model) -> Bool {
  let ended = tranquil.SessionEnded

  remote.has_ended_session(model.accounts)
  || case model.action {
    Refused(problem:) -> problem == ended
    Creating(submission:, ..) -> submission == SubmissionRefused(ended)
    Resting | ConfirmingDelete(_) | Deleting | StartingToActAs | ActAsRefused ->
      False
  }
}

pub fn has_any(model: Model) -> Bool {
  case model.accounts {
    Loaded(value: [_, ..]) -> True
    Loaded(value: []) | Loading | Failed(_) -> False
  }
}

pub fn names(model: Model) -> List(#(String, String)) {
  case model.accounts {
    Loaded(value: accounts) ->
      list.filter_map(accounts, fn(account) {
        option.to_result(account.handle, Nil)
        |> result.map(fn(handle) { #(account.did, handle) })
      })
    Loading | Failed(_) -> []
  }
}

pub opaque type Message {
  ServerReturnedAccounts(result: Result(List(ControlledAccount), Problem))
  UserClickedNew
  UserTypedHandle(handle: String)
  UserTypedEmail(email: String)
  UserPickedLevel(level: String)
  UserSubmittedAccount(scopes: String)
  UserCancelledNew
  ServerCreatedAccount(result: Result(Nil, Problem))
  UserClickedDelete(account: ControlledAccount)
  UserCancelledDelete(account: ControlledAccount)
  UserConfirmedDelete(account: ControlledAccount)
  ServerDeletedAccount(result: Result(Nil, Problem))
  UserClickedActAs(account: ControlledAccount)
  ServerPreparedActAs(result: Result(Uri, session.Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message, model.action {
    ServerReturnedAccounts(result:), _ -> #(
      Model(..model, accounts: remote.from_result(result)),
      effect.none(),
    )

    UserClickedNew, _ -> #(
      Model(
        ..model,
        action: Creating(handle: "", email: "", level: "", submission: Idle),
      ),
      browser.focus(handle_id),
    )

    UserTypedHandle(handle:), Creating(..) as form -> #(
      Model(..model, action: Creating(..form, handle:, submission: Idle)),
      effect.none(),
    )

    UserTypedEmail(email:), Creating(..) as form -> #(
      Model(..model, action: Creating(..form, email:, submission: Idle)),
      effect.none(),
    )

    UserPickedLevel(level:), Creating(..) as form -> #(
      Model(..model, action: Creating(..form, level:)),
      effect.none(),
    )

    UserSubmittedAccount(scopes:), Creating(handle:, email:, ..) as form -> #(
      Model(..model, action: Creating(..form, submission: Sending)),
      tranquil.perform(
        session,
        tranquil.create_controlled_account(
          string.trim(handle),
          case string.trim(email) {
            "" -> None
            email -> Some(email)
          },
          scopes,
        ),
        ServerCreatedAccount,
      ),
    )

    UserCancelledNew, _ -> #(
      Model(..model, action: Resting),
      browser.focus(new_button_id),
    )

    ServerCreatedAccount(result: Ok(Nil)), _ -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerCreatedAccount(result: Error(problem)), Creating(..) as form -> #(
      Model(
        ..model,
        action: Creating(..form, submission: SubmissionRefused(problem:)),
      ),
      effect.none(),
    )

    UserClickedDelete(account:), _ -> #(
      Model(..model, action: ConfirmingDelete(account:)),
      confirmation.focus_cancel(),
    )

    UserCancelledDelete(account:), _ -> #(
      Model(..model, action: Resting),
      browser.focus(delete_button_id(account)),
    )

    UserConfirmedDelete(account:), _ -> #(
      Model(..model, action: Deleting),
      tranquil.perform(
        session,
        tranquil.delete_controlled_account(account.did),
        ServerDeletedAccount,
      ),
    )

    ServerDeletedAccount(result: Ok(Nil)), _ -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerDeletedAccount(result: Error(problem)), _ -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserClickedActAs(account:), _ -> #(
      Model(..model, action: StartingToActAs),
      {
        use dispatch <- effect.from

        session.act_as(session, account.did)
        |> promise.tap(fn(prepared) { dispatch(ServerPreparedActAs(prepared)) })

        Nil
      },
    )

    ServerPreparedActAs(result: Ok(login)), _ -> #(model, modem.load(login))

    ServerPreparedActAs(result: Error(_)), _ -> #(
      Model(..model, action: ActAsRefused),
      effect.none(),
    )

    UserTypedHandle(_), _
    | UserTypedEmail(_), _
    | UserPickedLevel(_), _
    | UserSubmittedAccount(_), _
    | ServerCreatedAccount(_), _
    -> #(model, effect.none())
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.controlled_accounts(), ServerReturnedAccounts)
}

fn delete_button_id(account: ControlledAccount) -> String {
  "delete-controlled-" <> account.did
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("MethodNotImplemented", _) ->
      "This server can't delete controlled accounts"
    tranquil.Refused("HandleNotAvailable", _) -> "That handle is taken"
    tranquil.Refused("EmailTaken", _) -> "That email is already in use"
    tranquil.Refused("InvalidEmail", _) -> "That isn't a valid email address"
    tranquil.Refused("InvalidRequest", message)
      | tranquil.Refused("InvalidDelegation", message)
      if message != ""
    -> message
    tranquil.Unreachable -> "Couldn't reach the server"
    tranquil.Refused(_, _) | tranquil.NotUnderstood | tranquil.SessionEnded ->
      "The server didn't accept that"
  }
}

pub fn view(
  model: Model,
  levels: Remote(List(AccessLevel)),
  has_controllers: Bool,
) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        case model.accounts {
          Loading -> []
          Failed(_) -> [layout.problem("Couldn't load")]
          Loaded(value: []) -> [layout.details_row([layout.dim("none")])]
          Loaded(value: accounts) ->
            list.map(accounts, view_account(_, model, levels))
        },
        case model.action, has_controllers {
          Creating(handle:, email:, level:, submission:), _ -> [
            view_form(handle, email, level, submission, levels),
          ]

          Refused(problem:), _ -> [
            layout.problem(describe_refusal(problem)),
            view_new_button(),
          ]

          ActAsRefused, _ -> [
            layout.problem("Couldn't sign in as that account"),
            view_new_button(),
          ]

          Resting, True
          | ConfirmingDelete(_), True
          | Deleting, True
          | StartingToActAs, True
          -> [
            layout.details_row([
              layout.dim(
                "This account has controllers, so it cannot control other accounts",
              ),
            ]),
          ]

          Resting, False
          | ConfirmingDelete(_), False
          | Deleting, False
          | StartingToActAs, False
          -> [view_new_button()]
        },
      ]),
    ),
  ]
}

fn view_new_button() -> Element(Message) {
  layout.actions_row([
    html.button(
      [
        attribute.id(new_button_id),
        attribute.class("action"),
        event.on_click(UserClickedNew),
      ],
      [html.text("New account")],
    ),
  ])
}

fn view_account(
  account: ControlledAccount,
  model: Model,
  levels: Remote(List(AccessLevel)),
) -> Element(Message) {
  let name = option.unwrap(account.handle, account.did)

  case model.action == ConfirmingDelete(account:) {
    True ->
      confirmation.view(
        question: "Delete?",
        consequence: "Everything in " <> name <> " is removed for good.",
        accept: "Delete account",
        on_cancel: UserCancelledDelete(account),
        on_accept: UserConfirmedDelete(account),
      )

    False ->
      layout.row(
        tone: layout.Plain,
        name:,
        details: [
          html.text(access.describe(levels, account.access) <> " "),
          layout.dim(
            "\u{00B7} since "
            <> date.describe(account.since, model.local_offset),
          ),
        ],
        actions: [
          html.button(
            [
              attribute.class("action"),
              attribute.disabled(model.action == StartingToActAs),
              event.on_click(UserClickedActAs(account)),
            ],
            [html.text("Act as")],
          ),
          html.button(
            [
              attribute.id(delete_button_id(account)),
              attribute.class("action"),
              event.on_click(UserClickedDelete(account)),
            ],
            [html.text("Delete")],
          ),
        ],
      )
  }
}

fn view_form(
  handle: String,
  email: String,
  level: String,
  submission: Submission,
  levels: Remote(List(AccessLevel)),
) -> Element(Message) {
  let is_sending = submission == Sending
  let level = case level {
    "" -> access.first(levels)
    level -> level
  }

  html.form(
    [
      event.on_submit(fn(_) {
        UserSubmittedAccount(access.scopes(levels, level))
      }),
    ],
    [
      layout.field(
        html.label([attribute.for(handle_id)], [html.text("Handle")]),
        html.input([
          attribute.id(handle_id),
          attribute.type_("text"),
          attribute.value(handle),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(is_sending),
          event.on_input(UserTypedHandle),
        ]),
      ),
      layout.field(
        html.label([attribute.for("controlled-email")], [html.text("Email")]),
        html.div([attribute.class("inline")], [
          html.input([
            attribute.id("controlled-email"),
            attribute.type_("email"),
            attribute.value(email),
            attribute.autocomplete("off"),
            attribute.disabled(is_sending),
            event.on_input(UserTypedEmail),
          ]),
          layout.dim("optional"),
        ]),
      ),
      layout.row(
        tone: layout.Plain,
        name: "Your access",
        details: [
          access.view_choice(
            id: "controlled-access",
            levels:,
            picked: level,
            is_disabled: is_sending,
            on_pick: UserPickedLevel,
          ),
        ],
        actions: [],
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
              attribute.disabled(is_sending || string.trim(handle) == ""),
            ],
            [html.text("Create")],
          ),
          html.button(
            [
              attribute.class("action"),
              attribute.type_("button"),
              event.on_click(UserCancelledNew),
            ],
            [html.text("Cancel")],
          ),
        ]),
      ]),
    ],
  )
}
