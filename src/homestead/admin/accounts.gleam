import at/did.{type Did}
import at/handle
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type AccountPage, type ListedAccount, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const delete_button_id = "delete-listed-account"

const invites_id = "listed-account-invites"

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    typed: String,
    searched: String,
    accounts: Remote(List(ListedAccount)),
    next: Option(String),
    more: More,
    opened: Option(Did),
    action: Action,
    copied: Copied,
  )
}

type More {
  NotLoadingMore
  LoadingMore
  MoreRefused(problem: Problem)
}

type Action {
  Resting
  SavingInvites
  ConfirmingDelete
  Deleting
  Refused(problem: Problem)
}

type Copied {
  NotCopied
  Copied
  CopyFailed
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      typed: "",
      searched: "",
      accounts: Loading,
      next: None,
      more: NotLoadingMore,
      opened: None,
      action: Resting,
      copied: NotCopied,
    ),
    search(session, ""),
  )
}

pub opaque type Message {
  ServerReturnedAccounts(result: Result(AccountPage, Problem))
  UserTypedHandle(handle: String)
  UserSubmittedSearch
  UserClickedMore(after: String)
  ServerReturnedMoreAccounts(result: Result(AccountPage, Problem))
  UserToggledAccount(did: Did)
  UserClickedCopy(did: Did)
  BrowserCopiedText(result: Result(Nil, Nil))
  UserPickedInvites(account: ListedAccount, enabled: Bool)
  ServerSavedInvites(
    account: ListedAccount,
    enabled: Bool,
    result: Result(Nil, Problem),
  )
  UserClickedDelete
  UserCancelledDelete
  UserConfirmedDelete(account: ListedAccount)
  ServerDeletedAccount(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedAccounts(result:) -> #(
      Model(
        ..model,
        accounts: remote.from_result(result)
          |> remote.map(fn(page) { page.accounts }),
        next: result.map(result, fn(page) { page.next }) |> result.unwrap(None),
        more: NotLoadingMore,
      ),
      effect.none(),
    )

    UserTypedHandle(handle:) -> #(Model(..model, typed: handle), effect.none())

    UserSubmittedSearch -> {
      let searched = string.trim(model.typed)

      #(
        Model(
          ..model,
          searched:,
          accounts: Loading,
          next: None,
          opened: None,
          action: Resting,
        ),
        search(session, searched),
      )
    }

    UserClickedMore(after:) -> #(
      Model(..model, more: LoadingMore),
      tranquil.load(
        session,
        tranquil.find_accounts(model.searched, Some(after)),
        ServerReturnedMoreAccounts,
      ),
    )

    ServerReturnedMoreAccounts(result: Ok(page)) -> #(
      Model(
        ..model,
        accounts: remote.map(model.accounts, list.append(_, page.accounts)),
        next: page.next,
        more: NotLoadingMore,
      ),
      effect.none(),
    )

    ServerReturnedMoreAccounts(result: Error(problem)) -> #(
      Model(..model, more: MoreRefused(problem:)),
      effect.none(),
    )

    UserToggledAccount(did:) -> #(
      Model(
        ..model,
        opened: case model.opened == Some(did) {
          True -> None
          False -> Some(did)
        },
        action: Resting,
        copied: NotCopied,
      ),
      effect.none(),
    )

    UserClickedCopy(did:) -> #(
      model,
      browser.copy(did.to_string(did), BrowserCopiedText),
    )

    BrowserCopiedText(result:) -> #(
      Model(..model, copied: case result {
        Ok(Nil) -> Copied
        Error(Nil) -> CopyFailed
      }),
      effect.none(),
    )

    UserPickedInvites(account:, enabled:) -> #(
      Model(..model, action: SavingInvites),
      tranquil.perform(
        session,
        tranquil.set_account_invites(account.did, enabled),
        ServerSavedInvites(account, enabled, _),
      ),
    )

    ServerSavedInvites(account:, enabled:, result: Ok(Nil)) -> #(
      Model(
        ..model,
        accounts: remote.map(model.accounts, fn(accounts) {
          list.map(accounts, fn(listed) {
            case listed.did == account.did {
              True -> tranquil.ListedAccount(..listed, has_invites: enabled)
              False -> listed
            }
          })
        }),
        action: Resting,
      ),
      effect.none(),
    )

    ServerSavedInvites(result: Error(problem), ..) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserClickedDelete -> #(
      Model(..model, action: ConfirmingDelete),
      confirmation.focus_cancel(),
    )

    UserCancelledDelete -> #(
      Model(..model, action: Resting),
      browser.focus(delete_button_id),
    )

    UserConfirmedDelete(account:) -> #(
      Model(..model, action: Deleting),
      tranquil.perform(
        session,
        tranquil.delete_account_as_admin(account.did),
        ServerDeletedAccount,
      ),
    )

    ServerDeletedAccount(result: Ok(Nil)) -> #(
      Model(..model, opened: None, action: Resting),
      search(session, model.searched),
    )

    ServerDeletedAccount(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )
  }
}

fn search(session: Session, handle: String) -> Effect(Message) {
  tranquil.load(
    session,
    tranquil.find_accounts(handle, None),
    ServerReturnedAccounts,
  )
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        [
          html.form([event.on_submit(fn(_) { UserSubmittedSearch })], [
            layout.field(
              html.label([attribute.for("account-search")], [
                html.text("Handle"),
              ]),
              html.div([attribute.class("inline")], [
                html.input([
                  attribute.id("account-search"),
                  attribute.type_("search"),
                  attribute.value(model.typed),
                  attribute.autocomplete("off"),
                  attribute.autocapitalize("none"),
                  attribute.spellcheck(False),
                  event.on_input(UserTypedHandle),
                ]),
                html.button([attribute.class("action")], [html.text("Search")]),
              ]),
            ),
          ]),
        ],
        {
          use accounts <- layout.rows(model.accounts, placeholders: 3)
          layout.listing(
            empty: "No accounts",
            rows: list.map(accounts, fn(account) {
              #(
                did.to_string(account.did),
                element.fragment(view_account(account, model)),
              )
            }),
            actions: case model.next {
              Some(after) -> [
                html.button(
                  [
                    attribute.class("action"),
                    attribute.disabled(model.more == LoadingMore),
                    event.on_click(UserClickedMore(after)),
                  ],
                  [html.text("More")],
                ),
              ]
              None -> []
            },
          )
        },
        case model.more {
          MoreRefused(_) -> [layout.problem("Couldn't load more")]
          NotLoadingMore | LoadingMore -> []
        },
      ]),
    ),
  ]
}

fn view_account(
  account: ListedAccount,
  model: Model,
) -> List(Element(Message)) {
  let is_open = model.opened == Some(account.did)
  let summary =
    layout.row(
      tone: layout.Plain,
      name: handle.to_string(account.handle),
      details: [
        html.text(option.unwrap(account.email, "no email") <> " "),
        layout.dim(string.join(
          list.flatten([
            [
              "\u{00B7} since "
              <> date.describe(account.since, model.local_offset),
            ],
            case account.is_verified {
              True -> ["verified"]
              False -> ["not verified"]
            },
            case account.is_deactivated {
              True -> ["deactivated"]
              False -> []
            },
          ]),
          " \u{00B7} ",
        )),
      ],
      actions: [
        html.button(
          [
            attribute.class("action"),
            attribute.aria_expanded(is_open),
            event.on_click(UserToggledAccount(account.did)),
          ],
          [
            html.text(case is_open {
              True -> "Close"
              False -> "Open"
            }),
          ],
        ),
      ],
    )

  case is_open {
    False -> [summary]
    True -> [
      summary,
      layout.copy_row(
        name: "DID",
        value: did.to_string(account.did),
        note: case model.copied {
          Copied -> Some("copied")
          CopyFailed -> Some("couldn't copy")
          NotCopied -> None
        },
        on_copy: UserClickedCopy(account.did),
      ),
      layout.row(
        tone: layout.Plain,
        name: "Invites",
        details: [html.text("May hand out invite codes")],
        actions: [
          layout.switch(
            id: invites_id,
            label: "Invites",
            is_on: account.has_invites,
            is_disabled: model.action == SavingInvites,
            on_pick: UserPickedInvites(account, _),
          ),
        ],
      ),
      case model.action {
        Refused(_) -> layout.problem("The server didn't accept that")
        Resting | SavingInvites | ConfirmingDelete | Deleting -> element.none()
      },
      case model.action {
        ConfirmingDelete ->
          confirmation.view(
            question: "Delete?",
            consequence: "Everything in "
              <> handle.to_string(account.handle)
              <> " is removed for good.",
            accept: "Delete account",
            on_cancel: UserCancelledDelete,
            on_accept: UserConfirmedDelete(account),
          )
        Resting | SavingInvites | Deleting | Refused(_) ->
          layout.actions_row([
            html.button(
              [
                attribute.id(delete_button_id),
                attribute.class("action"),
                attribute.disabled(model.action == Deleting),
                event.on_click(UserClickedDelete),
              ],
              [html.text("Delete account")],
            ),
          ])
      },
    ]
  }
}
