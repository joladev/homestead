import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dict.{type Dict}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/label.{type Event, type Label}
import homestead/layout.{Plain, Warning}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/tranquil.{
  type AccountDetails, type AccountPage, type AccountState, type HostedPage,
  type ListedAccount, type Problem,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

const accounts_per_label_request = 20

const label_requests_at_once = 4

pub type Listing {
  Everyone
  Flagged
}

pub opaque type Model {
  Model(
    session: Session,
    settings: Settings,
    local_offset: Duration,
    load: Load,
    now: Timestamp,
    typed: String,
    accounts: Gathering(List(ListedAccount)),
    states: Gathering(Dict(Did, AccountState)),
    flags: Flags,
    opened: Option(Opened),
    copied: Copied,
  )
}

type Load {
  Load(started: Timestamp)
}

pub type Gathering(value) {
  Gathering(so_far: value)
  Gathered(all: value)
  NotGathered(problem: Problem)
}

type Flags {
  NotWanted
  Awaited
  LookingUp(events: List(Event), running: Int)
  Found(by_account: Dict(Did, List(Label)))
  LookupFailed
}

type Opened {
  Opened(
    account: Did,
    details: Remote(AccountDetails),
    password: String,
    handle: String,
    email: String,
    subject: String,
    text: String,
    action: Action,
  )
}

type Action {
  Resting
  Working
  Confirming(step: Step)
  Refused(problem: Problem)
  Done(change: Change)
}

type Step {
  TakingDown
  RemovingAdmin
  Deleting
}

type Change {
  TookDown
  Restored
  SetPassword
  ChangedHandle(handle: Handle)
  ChangedEmail(email: String)
  SentEmail
  SetInvites(is_enabled: Bool)
  MadeAdmin
  RemovedAdmin
  Deleted
}

type Copied {
  NotCopied
  Copied
  CopyFailed
}

type Shown {
  Shown(
    everyone: List(ListedAccount),
    listed: List(ListedAccount),
    states: Dict(Did, AccountState),
    flags: Dict(Did, List(Label)),
  )
}

type Listed {
  Listed(shown: Shown)
  FlagsUnavailable
}

pub fn init(
  session: Session,
  settings: Settings,
  listing: Listing,
) -> #(Model, Effect(Message)) {
  let now = timestamp.system_time()
  let load = Load(started: now)

  #(
    Model(
      session:,
      settings:,
      local_offset: calendar.local_offset(),
      load:,
      now:,
      typed: "",
      accounts: Gathering(so_far: []),
      states: Gathering(so_far: dict.new()),
      flags: case listing {
        Everyone -> NotWanted
        Flagged -> Awaited
      },
      opened: None,
      copied: NotCopied,
    ),
    effect.batch([
      tranquil.load(session, tranquil.accounts(None), ServerReturnedAccounts(
        load,
        _,
      )),
      tranquil.load(
        session,
        tranquil.hosted_accounts(None),
        ServerReturnedStates(load, _),
      ),
    ]),
  )
}

pub opaque type Message {
  ServerReturnedAccounts(load: Load, result: Result(AccountPage, Problem))
  ServerReturnedStates(load: Load, result: Result(HostedPage, Problem))
  RelayReturnedLabels(
    load: Load,
    batch: List(Did),
    remaining: List(List(Did)),
    result: Result(Response(String), rsvp.Error(String)),
  )
  UserClickedTryAgain
  UserTypedSearch(text: String)
  UserToggledAccount(account: ListedAccount)
  ServerReturnedDetails(account: Did, result: Result(AccountDetails, Problem))
  UserClickedCopy(did: Did)
  BrowserCopiedText(result: Result(Nil, Nil))
  UserTypedPassword(password: String)
  UserClickedGenerate
  BrowserGeneratedPassword(password: String)
  UserSubmittedPassword
  UserTypedHandle(handle: String)
  UserSubmittedHandle
  UserTypedEmail(email: String)
  UserSubmittedEmail
  UserTypedSubject(subject: String)
  UserTypedText(text: String)
  UserSubmittedMessage
  UserPickedInvites(is_enabled: Bool)
  UserClickedRestore
  UserClickedMakeAdmin
  UserAsked(step: Step, account: ListedAccount)
  UserCancelled
  UserConfirmed
  ServerMadeChange(account: Did, change: Change, result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedAccounts(load:, ..)
      | ServerReturnedStates(load:, ..)
      | RelayReturnedLabels(load:, ..)
      if load != model.load
    -> #(model, effect.none())

    ServerReturnedAccounts(result: Ok(page), ..) -> #(
      Model(..model, accounts: add_accounts(model.accounts, page)),
      case page.next {
        Some(after) ->
          tranquil.load(
            session,
            tranquil.accounts(Some(after)),
            ServerReturnedAccounts(model.load, _),
          )
        None -> effect.none()
      },
    )

    ServerReturnedAccounts(result: Error(problem), ..) -> #(
      Model(..model, accounts: NotGathered(problem:)),
      effect.none(),
    )

    ServerReturnedStates(result: Ok(page), ..) -> {
      let states = add_states(model.states, page)
      let model = Model(..model, states:)

      case page.next {
        Some(after) -> #(
          model,
          tranquil.load(
            session,
            tranquil.hosted_accounts(Some(after)),
            ServerReturnedStates(model.load, _),
          ),
        )
        None ->
          case states, model.flags {
            Gathered(all:), Awaited -> look_up_labels(model, dict.keys(all))
            Gathered(_), NotWanted
            | Gathered(_), LookingUp(..)
            | Gathered(_), Found(_)
            | Gathered(_), LookupFailed
            | Gathering(_), _
            | NotGathered(_), _
            -> #(model, effect.none())
          }
      }
    }

    ServerReturnedStates(result: Error(problem), ..) -> #(
      Model(..model, states: NotGathered(problem:)),
      effect.none(),
    )

    RelayReturnedLabels(batch:, remaining:, result:, ..) ->
      case model.flags {
        LookingUp(events: so_far, running:) -> {
          let page =
            result.replace_error(result, Nil)
            |> result.try(fn(response) { label.read(response.body) })

          case page, remaining {
            Ok(label.Page(events:, next: Some(after), ..)), _ -> #(
              Model(
                ..model,
                flags: LookingUp(events: list.append(events, so_far), running:),
              ),
              ask_about_labels(model, batch, remaining, Some(after)),
            )
            Ok(label.Page(events:, next: None, ..)), [next, ..rest] -> #(
              Model(
                ..model,
                flags: LookingUp(events: list.append(events, so_far), running:),
              ),
              ask_about_labels(model, next, rest, None),
            )
            Ok(label.Page(events:, next: None, ..)), [] -> {
              let events = list.append(events, so_far)

              #(
                Model(..model, flags: case running {
                  1 -> Found(by_account: flags(events, model.now))
                  _ -> LookingUp(events:, running: running - 1)
                }),
                effect.none(),
              )
            }
            Error(Nil), _ -> #(
              Model(..model, flags: LookupFailed),
              effect.none(),
            )
          }
        }
        NotWanted | Awaited | Found(_) | LookupFailed -> #(model, effect.none())
      }

    UserClickedTryAgain ->
      case model.flags, model.accounts, model.states {
        LookupFailed, Gathered(_), Gathered(all:) ->
          look_up_labels(
            Model(..model, load: Load(started: timestamp.system_time())),
            dict.keys(all),
          )
        LookupFailed, _, _
        | NotWanted, _, _
        | Awaited, _, _
        | LookingUp(..), _, _
        | Found(_), _, _
        -> #(model, effect.none())
      }

    UserTypedSearch(text:) -> #(Model(..model, typed: text), effect.none())

    UserToggledAccount(account:) ->
      case model.opened {
        Some(Opened(account: opened, ..)) if opened == account.did -> #(
          Model(..model, opened: None, copied: NotCopied),
          effect.none(),
        )
        Some(_) | None -> #(
          Model(
            ..model,
            opened: Some(open(account, Resting)),
            copied: NotCopied,
          ),
          load_details(session, account.did),
        )
      }

    ServerReturnedDetails(account:, result:) -> {
      use opened <- with_opened(model)

      case opened.account == account {
        True -> #(
          Opened(..opened, details: remote.from_result(result)),
          effect.none(),
        )
        False -> #(opened, effect.none())
      }
    }

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

    UserTypedPassword(password:) | BrowserGeneratedPassword(password:) -> {
      use opened <- with_opened(model)

      #(Opened(..opened, password:, action: Resting), effect.none())
    }

    UserClickedGenerate -> #(
      model,
      browser.generate_password(BrowserGeneratedPassword),
    )

    UserSubmittedPassword -> {
      use opened <- with_opened(model)

      change(
        session,
        opened,
        SetPassword,
        tranquil.reset_account_password(opened.account, opened.password),
      )
    }

    UserTypedHandle(handle:) -> {
      use opened <- with_opened(model)

      #(Opened(..opened, handle:, action: Resting), effect.none())
    }

    UserSubmittedHandle -> {
      use opened <- with_opened(model)

      case handle.from_string(string.trim(opened.handle)) {
        Ok(handle) ->
          change(
            session,
            opened,
            ChangedHandle(handle:),
            tranquil.change_account_handle(opened.account, handle),
          )
        Error(Nil) -> #(opened, effect.none())
      }
    }

    UserTypedEmail(email:) -> {
      use opened <- with_opened(model)

      #(Opened(..opened, email:, action: Resting), effect.none())
    }

    UserSubmittedEmail -> {
      use opened <- with_opened(model)
      let email = string.trim(opened.email)

      change(
        session,
        opened,
        ChangedEmail(email:),
        tranquil.change_account_email(opened.account, email),
      )
    }

    UserTypedSubject(subject:) -> {
      use opened <- with_opened(model)

      #(Opened(..opened, subject:, action: Resting), effect.none())
    }

    UserTypedText(text:) -> {
      use opened <- with_opened(model)

      #(Opened(..opened, text:, action: Resting), effect.none())
    }

    UserSubmittedMessage -> {
      use opened <- with_opened(model)

      change(
        session,
        opened,
        SentEmail,
        tranquil.send_email(
          to: opened.account,
          from: session.account(session),
          subject: string.trim(opened.subject),
          text: opened.text,
        ),
      )
    }

    UserPickedInvites(is_enabled:) -> {
      use opened <- with_opened(model)

      change(
        session,
        opened,
        SetInvites(is_enabled:),
        tranquil.set_account_invites(opened.account, is_enabled),
      )
    }

    UserClickedRestore -> {
      use opened <- with_opened(model)

      change(
        session,
        opened,
        Restored,
        tranquil.set_takedown(opened.account, False),
      )
    }

    UserClickedMakeAdmin -> {
      use opened <- with_opened(model)

      change(
        session,
        opened,
        MadeAdmin,
        tranquil.set_admin(opened.account, True),
      )
    }

    UserAsked(step:, account:) ->
      case model.opened {
        Some(Opened(account: opened, ..) as panel) if opened == account.did -> #(
          Model(
            ..model,
            opened: Some(Opened(..panel, action: Confirming(step:))),
          ),
          confirmation.focus_cancel(),
        )
        Some(_) | None -> #(
          Model(..model, opened: Some(open(account, Confirming(step:)))),
          effect.batch([
            confirmation.focus_cancel(),
            load_details(session, account.did),
          ]),
        )
      }

    UserCancelled -> {
      use opened <- with_opened(model)

      #(Opened(..opened, action: Resting), effect.none())
    }

    UserConfirmed -> {
      use opened <- with_opened(model)

      case opened.action {
        Confirming(step: TakingDown) ->
          change(
            session,
            opened,
            TookDown,
            tranquil.set_takedown(opened.account, True),
          )
        Confirming(step: RemovingAdmin) ->
          change(
            session,
            opened,
            RemovedAdmin,
            tranquil.set_admin(opened.account, False),
          )
        Confirming(step: Deleting) ->
          change(
            session,
            opened,
            Deleted,
            tranquil.delete_account_as_admin(opened.account),
          )
        Resting | Working | Refused(_) | Done(_) -> #(opened, effect.none())
      }
    }

    ServerMadeChange(account:, change:, result: Ok(Nil)) -> #(
      record(model, account, change),
      effect.none(),
    )

    ServerMadeChange(account:, result: Error(problem), ..) -> {
      use opened <- with_opened(model)

      case opened.account == account {
        True -> #(Opened(..opened, action: Refused(problem:)), effect.none())
        False -> #(opened, effect.none())
      }
    }
  }
}

pub fn add_accounts(
  gathering: Gathering(List(ListedAccount)),
  page: AccountPage,
) -> Gathering(List(ListedAccount)) {
  case gathering, page.next {
    Gathering(so_far:), Some(_) ->
      Gathering(so_far: list.append(so_far, page.accounts))
    Gathering(so_far:), None ->
      Gathered(
        all: list.append(so_far, page.accounts)
        |> list.sort(fn(one, other) {
          timestamp.compare(other.since, one.since)
        }),
      )
    Gathered(_), _ | NotGathered(_), _ -> gathering
  }
}

pub fn add_states(
  gathering: Gathering(Dict(Did, AccountState)),
  page: HostedPage,
) -> Gathering(Dict(Did, AccountState)) {
  case gathering {
    Gathering(so_far:) -> {
      let states =
        list.fold(page.accounts, so_far, fn(states, account) {
          dict.insert(states, account.did, account.state)
        })

      case page.next {
        Some(_) -> Gathering(so_far: states)
        None -> Gathered(all: states)
      }
    }
    Gathered(_) | NotGathered(_) -> gathering
  }
}

fn open(account: ListedAccount, action: Action) -> Opened {
  Opened(
    account: account.did,
    details: Loading,
    password: "",
    handle: handle.to_string(account.handle),
    email: option.unwrap(account.email, ""),
    subject: "",
    text: "",
    action:,
  )
}

fn load_details(session: Session, account: Did) -> Effect(Message) {
  tranquil.load(
    session,
    tranquil.account_details(account),
    ServerReturnedDetails(account, _),
  )
}

fn with_opened(
  model: Model,
  with: fn(Opened) -> #(Opened, Effect(Message)),
) -> #(Model, Effect(Message)) {
  case model.opened {
    Some(opened) -> {
      let #(opened, effect) = with(opened)

      #(Model(..model, opened: Some(opened)), effect)
    }
    None -> #(model, effect.none())
  }
}

fn change(
  session: Session,
  opened: Opened,
  change: Change,
  command: tranquil.Command(Nil),
) -> #(Opened, Effect(Message)) {
  #(
    Opened(..opened, action: Working),
    tranquil.perform(session, command, ServerMadeChange(
      opened.account,
      change,
      _,
    )),
  )
}

fn record(model: Model, account: Did, change: Change) -> Model {
  let in_accounts = fn(with: fn(ListedAccount) -> ListedAccount) {
    case model.accounts {
      Gathered(all:) ->
        Gathered(
          all: list.map(all, fn(listed) {
            case listed.did == account {
              True -> with(listed)
              False -> listed
            }
          }),
        )
      Gathering(_) | NotGathered(_) -> model.accounts
    }
  }
  let in_states = fn(state: AccountState) {
    case model.states {
      Gathered(all:) -> Gathered(all: dict.insert(all, account, state))
      Gathering(_) | NotGathered(_) -> model.states
    }
  }
  let opened = case model.opened {
    Some(Opened(account: opened, ..) as panel) if opened == account ->
      Some(Opened(..panel, action: Done(change:)))
    Some(_) | None -> model.opened
  }
  let model = Model(..model, opened:)

  case change {
    TookDown -> Model(..model, states: in_states(tranquil.TakenDown))
    Restored -> Model(..model, states: in_states(tranquil.Running))
    ChangedHandle(handle:) ->
      Model(
        ..model,
        accounts: in_accounts(fn(listed) {
          tranquil.ListedAccount(..listed, handle:)
        }),
      )
    ChangedEmail(email:) ->
      Model(
        ..model,
        accounts: in_accounts(fn(listed) {
          tranquil.ListedAccount(
            ..listed,
            email: Some(email),
            is_verified: False,
          )
        }),
      )
    SetInvites(is_enabled:) ->
      Model(
        ..model,
        accounts: in_accounts(fn(listed) {
          tranquil.ListedAccount(..listed, has_invites: is_enabled)
        }),
      )
    Deleted ->
      Model(..model, opened: None, accounts: case model.accounts {
        Gathered(all:) ->
          Gathered(all: list.filter(all, fn(listed) { listed.did != account }))
        Gathering(_) | NotGathered(_) -> model.accounts
      })
    SetPassword | SentEmail | MadeAdmin | RemovedAdmin -> model
  }
}

fn look_up_labels(
  model: Model,
  accounts: List(Did),
) -> #(Model, Effect(Message)) {
  let batches = list.sized_chunk(accounts, into: accounts_per_label_request)
  let chains = case batches {
    [] -> []
    [_, ..] ->
      list.sized_chunk(
        batches,
        into: { list.length(batches) + label_requests_at_once - 1 }
          / label_requests_at_once,
      )
  }

  case chains {
    [] -> #(Model(..model, flags: Found(by_account: dict.new())), effect.none())
    [_, ..] -> #(
      Model(..model, flags: LookingUp(events: [], running: list.length(chains))),
      effect.batch(
        list.filter_map(chains, fn(chain) {
          case chain {
            [batch, ..remaining] ->
              Ok(ask_about_labels(model, batch, remaining, None))
            [] -> Error(Nil)
          }
        }),
      ),
    )
  }
}

fn ask_about_labels(
  model: Model,
  batch: List(Did),
  remaining: List(List(Did)),
  after: Option(String),
) -> Effect(Message) {
  rsvp.send(
    label.accounts_request(
      model.settings.label_relay,
      batch,
      model.settings.admin_labelers,
      after,
    ),
    rsvp.expect_ok_response(RelayReturnedLabels(model.load, batch, remaining, _)),
  )
}

pub fn flags(events: List(Event), now: Timestamp) -> Dict(Did, List(Label)) {
  list.group(events, fn(event) { event.subject })
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(subject, events) = entry
    let in_force =
      label.history(events, now)
      |> list.filter(fn(label) {
        case label.state {
          label.Active(..) -> True
          label.Expired(..) | label.Removed(..) -> False
        }
      })

    case did.from_string(subject), in_force {
      Ok(account), [_, ..] -> Ok(#(account, in_force))
      Ok(_), [] | Error(Nil), _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

fn settled(gathering: Gathering(value)) -> Remote(value) {
  case gathering {
    Gathering(_) -> Loading
    Gathered(all:) -> Loaded(value: all)
    NotGathered(problem:) -> Failed(problem:)
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  let listed = {
    use everyone <- remote.then(settled(model.accounts))
    use states <- remote.then(settled(model.states))

    case model.flags {
      NotWanted ->
        Loaded(
          Listed(Shown(everyone:, listed: everyone, states:, flags: dict.new())),
        )
      Awaited | LookingUp(..) -> Loading
      LookupFailed -> Loaded(FlagsUnavailable)
      Found(by_account: flags) ->
        Loaded(
          Listed(Shown(
            everyone:,
            listed: list.filter(everyone, fn(account) {
              dict.has_key(flags, account.did)
            }),
            states:,
            flags:,
          )),
        )
    }
  }

  [
    layout.block(
      list.flatten([
        [
          layout.field(
            html.label([attribute.for("account-search")], [html.text("Search")]),
            html.input([
              attribute.id("account-search"),
              attribute.type_("search"),
              attribute.value(model.typed),
              attribute.placeholder("handle or email"),
              attribute.autocomplete("off"),
              attribute.autocapitalize("none"),
              attribute.spellcheck(False),
              event.on_input(UserTypedSearch),
            ]),
          ),
        ],
        {
          use listed <- layout.rows(listed, placeholders: 3)

          case listed {
            FlagsUnavailable -> [view_lookup_failure()]
            Listed(shown:) ->
              layout.listing(
                empty: case model.flags {
                  NotWanted -> "No accounts"
                  Awaited | LookingUp(..) | Found(_) | LookupFailed ->
                    "No flagged accounts"
                },
                rows: list.filter(shown.listed, fn(account) {
                  is_open(model, account) || matches(account, model.typed)
                })
                  |> list.map(fn(account) {
                    #(
                      did.to_string(account.did),
                      element.fragment(view_account(model, account, shown)),
                    )
                  }),
                actions: [],
              )
          }
        },
      ]),
    ),
  ]
}

fn view_lookup_failure() -> Element(Message) {
  layout.row(
    tone: Warning,
    name: "error",
    details: [html.text("Couldn't reach the label relay")],
    actions: [
      html.button(
        [attribute.class("action"), event.on_click(UserClickedTryAgain)],
        [html.text("Try again")],
      ),
    ],
  )
}

fn is_open(model: Model, account: ListedAccount) -> Bool {
  case model.opened {
    Some(opened) -> opened.account == account.did
    None -> False
  }
}

fn matches(account: ListedAccount, typed: String) -> Bool {
  let wanted = string.lowercase(string.trim(typed))

  wanted == ""
  || string.contains(string.lowercase(handle.to_string(account.handle)), wanted)
  || string.contains(string.lowercase(option.unwrap(account.email, "")), wanted)
}

fn view_account(
  model: Model,
  account: ListedAccount,
  shown: Shown,
) -> List(Element(Message)) {
  let state = dict.get(shown.states, account.did)
  let flags = dict.get(shown.flags, account.did) |> result.unwrap([])
  let opened = case model.opened {
    Some(Opened(account: opened, ..) as panel) if opened == account.did ->
      Some(panel)
    Some(_) | None -> None
  }
  let facts =
    list.flatten([
      ["since " <> date.describe_day(account.since, model.local_offset)],
      case account.is_verified {
        True -> ["verified"]
        False -> ["not verified"]
      },
      case state {
        Ok(tranquil.Running) | Error(Nil) -> []
        Ok(tranquil.TakenDown) -> ["taken down"]
        Ok(tranquil.Deactivated) -> ["deactivated"]
        Ok(tranquil.OtherState(name:)) -> [name]
      },
      list.map(flags, fn(flag) {
        case flag.state {
          label.Active(since:, ..) ->
            flag.value
            <> " since "
            <> date.describe_day(since, model.local_offset)
          label.Expired(..) | label.Removed(..) -> flag.value
        }
      }),
    ])
  let summary =
    layout.row(
      tone: case flags {
        [] -> Plain
        [_, ..] -> Warning
      },
      name: handle.to_string(account.handle),
      details: [
        html.text(option.unwrap(account.email, "no email") <> " "),
        layout.dim("\u{00B7} " <> string.join(facts, " \u{00B7} ")),
      ],
      actions: list.flatten([
        case flags, state, opened {
          [_, ..], Ok(tranquil.Running), None -> [
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserAsked(TakingDown, account)),
              ],
              [html.text("Take down")],
            ),
          ]
          [_, ..], Ok(tranquil.Running), Some(_)
          | [_, ..], Ok(tranquil.TakenDown), _
          | [_, ..], Ok(tranquil.Deactivated), _
          | [_, ..], Ok(tranquil.OtherState(_)), _
          | [_, ..], Error(Nil), _
          | [], _, _
          -> []
        },
        [
          html.button(
            [
              attribute.class("action"),
              attribute.aria_expanded(option.is_some(opened)),
              event.on_click(UserToggledAccount(account)),
            ],
            [
              html.text(case opened {
                Some(_) -> "Close"
                None -> "Open"
              }),
            ],
          ),
        ],
      ]),
    )

  case opened {
    None -> [summary]
    Some(Opened(action: Confirming(step:), ..)) -> [
      summary,
      view_confirmation(step, handle.to_string(account.handle)),
    ]
    Some(opened) -> [
      summary,
      view_identity(model, account),
      view_inviter(opened, shown.everyone),
      view_state(opened, account, state),
      view_handle(opened, account),
      view_email(opened, account),
      view_password(opened),
      view_message(opened, account),
      view_invites(opened, account),
      view_admin(opened, account),
      view_outcome(opened.action),
      layout.actions_row([
        action_button(opened, "Delete account", UserAsked(Deleting, account)),
      ]),
    ]
  }
}

fn action_button(
  opened: Opened,
  text: String,
  message: Message,
) -> Element(Message) {
  html.button(
    [
      attribute.class("action"),
      attribute.type_("button"),
      attribute.disabled(opened.action == Working),
      event.on_click(message),
    ],
    [html.text(text)],
  )
}

fn submit_button(
  opened: Opened,
  text: String,
  is_ready: Bool,
) -> Element(Message) {
  html.button(
    [
      attribute.class("action"),
      attribute.disabled(opened.action == Working || !is_ready),
    ],
    [html.text(text)],
  )
}

fn view_confirmation(step: Step, name: String) -> Element(Message) {
  confirmation.view(
    question: case step {
      TakingDown -> "Take down?"
      RemovingAdmin -> "Remove admin?"
      Deleting -> "Delete?"
    },
    consequence: case step {
      TakingDown -> name <> " stops being served until it is restored."
      RemovingAdmin -> name <> " loses access to these admin pages."
      Deleting -> "Everything in " <> name <> " is removed for good."
    },
    accept: case step {
      TakingDown -> "Take down"
      RemovingAdmin -> "Remove admin"
      Deleting -> "Delete account"
    },
    on_cancel: UserCancelled,
    on_accept: UserConfirmed,
  )
}

fn view_identity(model: Model, account: ListedAccount) -> Element(Message) {
  layout.copy_row(
    name: "DID",
    value: did.to_string(account.did),
    note: case model.copied {
      Copied -> Some("copied")
      CopyFailed -> Some("couldn't copy")
      NotCopied -> None
    },
    on_copy: UserClickedCopy(account.did),
  )
}

fn view_inviter(
  opened: Opened,
  everyone: List(ListedAccount),
) -> Element(Message) {
  use details <- layout.awaited_row(name: "Invited by", of: opened.details)

  layout.row(
    tone: Plain,
    name: "Invited by",
    details: [
      html.text(case details.invited_by {
        Some(inviter) ->
          list.find(everyone, fn(listed) { listed.did == inviter })
          |> result.map(fn(listed) { handle.to_string(listed.handle) })
          |> result.unwrap(did.to_string(inviter))
        None -> "no invite"
      }),
    ],
    actions: [],
  )
}

fn view_state(
  opened: Opened,
  account: ListedAccount,
  state: Result(AccountState, Nil),
) -> Element(Message) {
  layout.row(
    tone: Plain,
    name: "State",
    details: [
      html.text(case state {
        Ok(tranquil.Running) -> "active"
        Ok(tranquil.TakenDown) -> "taken down"
        Ok(tranquil.Deactivated) -> "deactivated"
        Ok(tranquil.OtherState(name:)) -> name
        Error(Nil) -> "not listed"
      }),
    ],
    actions: case state {
      Ok(tranquil.TakenDown) -> [
        action_button(opened, "Restore", UserClickedRestore),
      ]
      Ok(tranquil.Running)
      | Ok(tranquil.Deactivated)
      | Ok(tranquil.OtherState(_))
      | Error(Nil) -> [
        action_button(opened, "Take down", UserAsked(TakingDown, account)),
      ]
    },
  )
}

fn view_handle(opened: Opened, account: ListedAccount) -> Element(Message) {
  let typed = string.trim(opened.handle)

  html.form([event.on_submit(fn(_) { UserSubmittedHandle })], [
    layout.field(
      html.label([attribute.for("admin-handle")], [html.text("Handle")]),
      html.div([attribute.class("inline")], [
        html.input([
          attribute.id("admin-handle"),
          attribute.type_("text"),
          attribute.value(opened.handle),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(opened.action == Working),
          event.on_input(UserTypedHandle),
        ]),
        submit_button(
          opened,
          "Change handle",
          typed != handle.to_string(account.handle)
            && result.is_ok(handle.from_string(typed)),
        ),
      ]),
    ),
  ])
}

fn view_email(opened: Opened, account: ListedAccount) -> Element(Message) {
  let typed = string.trim(opened.email)

  html.form([event.on_submit(fn(_) { UserSubmittedEmail })], [
    layout.field(
      html.label([attribute.for("admin-email")], [html.text("Email")]),
      html.div([attribute.class("inline")], [
        html.input([
          attribute.id("admin-email"),
          attribute.type_("email"),
          attribute.value(opened.email),
          attribute.autocomplete("off"),
          attribute.disabled(opened.action == Working),
          event.on_input(UserTypedEmail),
        ]),
        submit_button(
          opened,
          "Change email",
          typed != "" && Some(typed) != account.email,
        ),
      ]),
    ),
  ])
}

fn view_password(opened: Opened) -> Element(Message) {
  html.form([event.on_submit(fn(_) { UserSubmittedPassword })], [
    layout.field(
      html.label([attribute.for("admin-password")], [html.text("New password")]),
      html.div([attribute.class("inline")], [
        html.input([
          attribute.id("admin-password"),
          attribute.type_("text"),
          attribute.value(opened.password),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(opened.action == Working),
          event.on_input(UserTypedPassword),
        ]),
        action_button(opened, "Generate", UserClickedGenerate),
        submit_button(opened, "Set password", opened.password != ""),
      ]),
    ),
  ])
}

fn view_message(opened: Opened, account: ListedAccount) -> Element(Message) {
  html.form([event.on_submit(fn(_) { UserSubmittedMessage })], [
    layout.field(
      html.label([attribute.for("admin-subject")], [html.text("Email subject")]),
      html.input([
        attribute.id("admin-subject"),
        attribute.type_("text"),
        attribute.value(opened.subject),
        attribute.autocomplete("off"),
        attribute.disabled(opened.action == Working),
        event.on_input(UserTypedSubject),
      ]),
    ),
    layout.field(
      html.label([attribute.for("admin-text")], [html.text("Email text")]),
      html.div([attribute.class("inline")], [
        html.textarea(
          [
            attribute.id("admin-text"),
            attribute.rows(4),
            attribute.disabled(opened.action == Working),
            event.on_input(UserTypedText),
          ],
          opened.text,
        ),
        submit_button(
          opened,
          "Send email",
          string.trim(opened.subject) != ""
            && string.trim(opened.text) != ""
            && option.is_some(account.email),
        ),
      ]),
    ),
  ])
}

fn view_invites(opened: Opened, account: ListedAccount) -> Element(Message) {
  layout.row(
    tone: Plain,
    name: "Invites",
    details: [html.text("May hand out invite codes")],
    actions: [
      layout.switch(
        id: "listed-account-invites",
        label: "Invites",
        is_on: account.has_invites,
        is_disabled: opened.action == Working,
        on_pick: UserPickedInvites,
      ),
    ],
  )
}

fn view_admin(opened: Opened, account: ListedAccount) -> Element(Message) {
  layout.row(
    tone: Plain,
    name: "Admin",
    details: [html.text("May use these admin pages")],
    actions: [
      action_button(opened, "Make admin", UserClickedMakeAdmin),
      action_button(opened, "Remove admin", UserAsked(RemovingAdmin, account)),
    ],
  )
}

fn view_outcome(action: Action) -> Element(Message) {
  case action {
    Refused(problem:) -> layout.problem(tranquil.describe_failed_load(problem))
    Done(change:) ->
      layout.note(
        case change {
          TookDown -> "Taken down"
          Restored -> "Restored"
          SetPassword -> "Password set"
          ChangedHandle(_) -> "Handle changed"
          ChangedEmail(_) -> "Email changed"
          SentEmail -> "Email sent"
          SetInvites(_) -> "Invites saved"
          MadeAdmin -> "Made admin"
          RemovedAdmin -> "Admin removed"
          Deleted -> "Deleted"
        },
        [],
      )
    Resting | Working | Confirming(_) -> element.none()
  }
}
