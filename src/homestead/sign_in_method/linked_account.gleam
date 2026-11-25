import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type LinkedAccount, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    providers: Remote(List(String)),
    accounts: Remote(List(LinkedAccount)),
    action: Action,
  )
}

type Action {
  Resting
  ConfirmingUnlink(account: LinkedAccount)
  Unlinking
  Refused(problem: Problem)
}

pub fn init(
  session: Session,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset:,
      providers: Loading,
      accounts: Loading,
      action: Resting,
    ),
    effect.batch([
      tranquil.load(
        session,
        tranquil.linked_account_providers(),
        ServerReturnedProviders,
      ),
      load(session),
    ]),
  )
}

pub fn is_offered(model: Model) -> Bool {
  case model.providers {
    Loaded(value: [_, ..]) -> True
    Loaded(value: []) | Loading | Failed(_) -> False
  }
}

pub opaque type Message {
  ServerReturnedProviders(result: Result(List(String), Problem))
  ServerReturnedAccounts(result: Result(List(LinkedAccount), Problem))
  UserClickedUnlink(account: LinkedAccount)
  UserCancelledUnlink(account: LinkedAccount)
  UserConfirmedUnlink(account: LinkedAccount)
  ServerUnlinkedAccount(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedProviders(result:) -> #(
      Model(..model, providers: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedAccounts(result:) -> #(
      Model(..model, accounts: remote.from_result(result)),
      effect.none(),
    )

    UserClickedUnlink(account:) -> #(
      Model(..model, action: ConfirmingUnlink(account:)),
      confirmation.focus_cancel(),
    )

    UserCancelledUnlink(account:) -> #(
      Model(..model, action: Resting),
      browser.focus(unlink_button_id(account)),
    )

    UserConfirmedUnlink(account:) -> #(
      Model(..model, action: Unlinking),
      tranquil.perform(
        model.session,
        tranquil.unlink_account(account.id),
        ServerUnlinkedAccount,
      ),
    )

    ServerUnlinkedAccount(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(model.session),
    )

    ServerUnlinkedAccount(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.linked_accounts(), ServerReturnedAccounts)
}

fn unlink_button_id(account: LinkedAccount) -> String {
  "unlink-" <> account.id
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem.reason {
    tranquil.Refused("InvalidRequest", message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
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
      [html.text("Link on " <> server)],
    ),
  ]
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        {
          use accounts <- layout.rows(model.accounts, placeholders: 1)

          layout.listing(
            empty: "No linked accounts",
            rows: list.map(accounts, fn(item) {
              #(item.id, view_account(item, model))
            }),
            actions: [],
          )
        },
        case model.action {
          Refused(problem:) -> [layout.problem(describe_refusal(problem))]
          Resting | ConfirmingUnlink(_) | Unlinking -> []
        },
      ]),
    ),
  ]
}

fn view_account(account: LinkedAccount, model: Model) -> Element(Message) {
  case model.action == ConfirmingUnlink(account:) {
    True ->
      confirmation.view(
        question: "Unlink?",
        consequence: account.provider <> " can no longer sign you in.",
        accept: "Unlink account",
        on_cancel: UserCancelledUnlink(account),
        on_accept: UserConfirmedUnlink(account),
      )

    False -> {
      let linked =
        "linked " <> date.describe(account.linked, model.local_offset)

      layout.row(
        tone: layout.Plain,
        name: account.provider,
        details: case option.or(account.username, account.email) {
          Some(identity) -> [
            html.text(identity <> " "),
            layout.dim("\u{00B7} " <> linked),
          ]
          None -> [layout.dim(linked)]
        },
        actions: [
          html.button(
            [
              attribute.id(unlink_button_id(account)),
              attribute.class("action"),
              event.on_click(UserClickedUnlink(account)),
            ],
            [html.text("Unlink")],
          ),
        ],
      )
    }
  }
}
