import at/handle
import gleam/bool
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import homestead/browser
import homestead/landing
import homestead/password_sign_in.{type Unverified, Unverified}
import homestead/remote.{type Submission, Idle, Refused, Sending}
import homestead/route
import homestead/session
import homestead/setting.{
  type PasswordEntry, type Settings, HomesteadFirst, ServerFirst,
}
import homestead/tranquil.{
  type Availability, type Channel, type Contact, type CreatedAccount,
  type NewAccount, type Server, type Software, NewAccount, OtherSoftware,
  Tranquil,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import rsvp

const name_id = "sign-up-handle"

const server_page_id = "sign-up-server-page"

const typing_pause_milliseconds = 400

const not_prepared = "Couldn't start signing up on that server."

const name_characters = "abcdefghijklmnopqrstuvwxyz0123456789-"

const common_passwords = [
  "password", "password1", "password123", "passw0rd", "passw0rd!", "12345678",
  "123456789", "1234567890", "qwerty123", "qwertyui", "letmein1", "welcome1",
  "admin123", "password1!", "iloveyou", "iloveyou1", "monkey123", "dragon12",
  "dragon123", "master12", "master123", "login123", "abc12345", "football",
  "football1", "baseball", "baseball1", "trustno1", "sunshine", "sunshine1",
  "princess", "princess1", "computer", "computer1", "whatever", "whatever1",
  "nintendo", "nintendo1", "bluesky1", "bluesky123",
]

pub opaque type Model {
  Model(
    leading: PasswordEntry,
    listed: List(Listed),
    invited: Option(Invitation),
    address: String,
    step: Step,
  )
}

type Step {
  PickingServer(lookup: Lookup)
  ChoosingWay(form: Form, handoff: Handoff)
  FillingForm(form: Form, handoff: Handoff)
  Created(account: Unverified)
}

type Invitation {
  Invitation(server: Request(String), code: String)
}

type Listed {
  Listed(server: Request(String), offer: Offer)
}

type Offer {
  Checking
  Offered(description: Server)
  NotOffered(problem: Problem)
}

type Lookup {
  NotStarted
  CheckingServer(server: Request(String))
  Failed(problem: Problem)
}

type Problem {
  AddressNotUnderstood
  ServerUnreachable
  ServerUnavailable
  NotTranquil
  SignUpNotPrepared
}

type Handoff {
  NotTried
  NotPrepared
}

type Form {
  Form(
    server: Request(String),
    description: Server,
    name: String,
    domain: String,
    availability: HandleCheck,
    password: String,
    invite_code: Option(String),
    channel: Channel,
    email: String,
    username: String,
    submission: Submission,
  )
}

type HandleCheck {
  NotChecked
  CheckingHandle
  Checked(availability: Availability)
  CouldNotCheck
}

pub type Rule {
  Rule(requirement: String, is_met: Bool)
}

pub fn init(settings: Settings, location: Uri) -> #(Model, Effect(Message)) {
  let address = option.unwrap(route.query(location, "server"), "")
  let model =
    Model(
      leading: settings.password_entry,
      listed: list.map(settings.sign_up_servers, Listed(_, offer: Checking)),
      invited: None,
      address:,
      step: PickingServer(lookup: NotStarted),
    )
  let listed_checks = list.map(settings.sign_up_servers, check_health)

  case address, tranquil.server_address(address) {
    "", _ -> #(model, effect.batch(listed_checks))

    _, Ok(server) -> #(
      Model(
        ..model,
        invited: route.query(location, "invite")
          |> option.map(Invitation(server:, code: _)),
        step: PickingServer(lookup: CheckingServer(server:)),
      ),
      effect.batch(case list.contains(settings.sign_up_servers, server) {
        True -> listed_checks
        False -> [check_health(server), ..listed_checks]
      }),
    )

    _, Error(Nil) -> #(
      Model(..model, step: PickingServer(lookup: Failed(AddressNotUnderstood))),
      effect.batch(listed_checks),
    )
  }
}

pub fn created(model: Model) -> Option(Unverified) {
  case model.step {
    Created(account:) -> Some(account)
    PickingServer(_) | ChoosingWay(..) | FillingForm(..) -> None
  }
}

pub opaque type Message {
  UserPickedServer(server: Request(String), description: Server)
  UserTypedAddress(address: String)
  UserSubmittedAddress
  ServerReturnedHealth(
    server: Request(String),
    result: Result(Software, rsvp.Error(String)),
  )
  ServerDescribedItself(
    server: Request(String),
    result: Result(Server, tranquil.Problem),
  )
  UserChoseAnotherServer
  UserTypedName(name: String)
  UserPausedTypingName(name: String, domain: String)
  UserPickedDomain(domain: String)
  ServerReturnedAvailability(
    name: String,
    domain: String,
    result: Result(Availability, tranquil.Problem),
  )
  UserTypedPassword(password: String)
  UserTypedInviteCode(invite_code: String)
  UserPickedChannel(name: String)
  UserTypedEmail(email: String)
  UserTypedUsername(username: String)
  UserSubmittedAccount
  ServerCreatedAccount(result: Result(CreatedAccount, tranquil.Problem))
  ServerClosedSession(result: Result(Nil, tranquil.Problem))
  UserChoseServerPage
  UserChoseForm
  ServerPreparedSignUp(result: Result(Uri, session.Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model.step {
    PickingServer(_) -> update_while_picking(model, message)
    ChoosingWay(form:, ..) -> update_while_choosing(model, form, message)
    FillingForm(form:, handoff:) ->
      update_while_filling(model, form, handoff, message)
    Created(_) -> #(model, effect.none())
  }
}

fn update_while_picking(
  model: Model,
  message: Message,
) -> #(Model, Effect(Message)) {
  case message {
    UserPickedServer(server:, description:) -> offer(model, server, description)

    UserTypedAddress(address:) -> #(
      Model(..model, address:, step: PickingServer(lookup: NotStarted)),
      effect.none(),
    )

    UserSubmittedAddress ->
      case tranquil.server_address(model.address) {
        Ok(server) -> #(
          Model(..model, step: PickingServer(lookup: CheckingServer(server:))),
          check_health(server),
        )
        Error(Nil) -> #(
          Model(
            ..model,
            step: PickingServer(lookup: Failed(AddressNotUnderstood)),
          ),
          effect.none(),
        )
      }

    ServerReturnedHealth(server:, result:) ->
      record_health(model, server, result)

    ServerDescribedItself(server:, result:) ->
      record_description(model, server, result)

    UserChoseAnotherServer
    | UserTypedName(_)
    | UserPausedTypingName(..)
    | UserPickedDomain(_)
    | ServerReturnedAvailability(..)
    | UserTypedPassword(_)
    | UserTypedInviteCode(_)
    | UserPickedChannel(_)
    | UserTypedEmail(_)
    | UserTypedUsername(_)
    | UserSubmittedAccount
    | ServerCreatedAccount(_)
    | ServerClosedSession(_)
    | UserChoseServerPage
    | UserChoseForm
    | ServerPreparedSignUp(_) -> #(model, effect.none())
  }
}

fn update_while_choosing(
  model: Model,
  form: Form,
  message: Message,
) -> #(Model, Effect(Message)) {
  case message {
    UserChoseServerPage -> #(
      Model(..model, step: ChoosingWay(form:, handoff: NotTried)),
      prepare_server_page(form),
    )

    UserChoseForm -> #(
      Model(..model, step: FillingForm(form:, handoff: NotTried)),
      browser.focus(name_id),
    )

    UserChoseAnotherServer -> pick_another_server(model)

    ServerPreparedSignUp(result: Ok(registration)) -> #(
      model,
      modem.load(registration),
    )

    ServerPreparedSignUp(result: Error(_)) -> #(
      Model(..model, step: ChoosingWay(form:, handoff: NotPrepared)),
      effect.none(),
    )

    ServerReturnedHealth(server:, result:) ->
      record_health(model, server, result)

    ServerDescribedItself(server:, result:) ->
      record_description(model, server, result)

    UserPickedServer(..)
    | UserTypedAddress(_)
    | UserSubmittedAddress
    | UserTypedName(_)
    | UserPausedTypingName(..)
    | UserPickedDomain(_)
    | ServerReturnedAvailability(..)
    | UserTypedPassword(_)
    | UserTypedInviteCode(_)
    | UserPickedChannel(_)
    | UserTypedEmail(_)
    | UserTypedUsername(_)
    | UserSubmittedAccount
    | ServerCreatedAccount(_)
    | ServerClosedSession(_) -> #(model, effect.none())
  }
}

fn update_while_filling(
  model: Model,
  form: Form,
  handoff: Handoff,
  message: Message,
) -> #(Model, Effect(Message)) {
  let fill = fn(form, effect) {
    #(Model(..model, step: FillingForm(form:, handoff:)), effect)
  }

  case message {
    UserTypedName(name:) -> {
      let form = Form(..form, name:, availability: NotChecked)

      fill(form, case is_valid_name(name) {
        True ->
          browser.after(
            typing_pause_milliseconds,
            UserPausedTypingName(name, form.domain),
          )
        False -> effect.none()
      })
    }

    UserPausedTypingName(name:, domain:) ->
      case form.name == name && form.domain == domain {
        True ->
          fill(Form(..form, availability: CheckingHandle), check_handle(form))
        False -> #(model, effect.none())
      }

    UserPickedDomain(domain:) -> {
      let form = Form(..form, domain:, availability: NotChecked)

      case is_valid_name(form.name) {
        True ->
          fill(Form(..form, availability: CheckingHandle), check_handle(form))
        False -> fill(form, effect.none())
      }
    }

    ServerReturnedAvailability(name:, domain:, result:) ->
      case form.name == name && form.domain == domain, result {
        True, Ok(availability) ->
          fill(
            Form(..form, availability: Checked(availability:)),
            effect.none(),
          )
        True, Error(_) ->
          fill(Form(..form, availability: CouldNotCheck), effect.none())
        False, _ -> #(model, effect.none())
      }

    UserTypedPassword(password:) ->
      fill(Form(..form, password:, submission: Idle), effect.none())

    UserTypedInviteCode(invite_code:) ->
      fill(
        Form(..form, invite_code: Some(invite_code), submission: Idle),
        effect.none(),
      )

    UserPickedChannel(name:) -> {
      let channel =
        list.find(form.description.contact_channels, fn(channel) {
          tranquil.channel_name(channel) == name
        })

      case channel {
        Ok(channel) ->
          fill(
            Form(..form, channel:, username: "", submission: Idle),
            effect.none(),
          )
        Error(Nil) -> #(model, effect.none())
      }
    }

    UserTypedEmail(email:) ->
      fill(Form(..form, email:, submission: Idle), effect.none())

    UserTypedUsername(username:) ->
      fill(Form(..form, username:, submission: Idle), effect.none())

    UserSubmittedAccount ->
      case new_account(form) {
        Ok(new) ->
          fill(
            Form(..form, submission: Sending),
            tranquil.submit(
              form.server,
              tranquil.create_account(new),
              ServerCreatedAccount,
            ),
          )
        Error(Nil) -> #(model, effect.none())
      }

    ServerCreatedAccount(result: Ok(account)) -> #(
      Model(
        ..model,
        step: Created(Unverified(
          account: account.account,
          name: handle.to_string(account.handle),
          server: form.server,
          description: form.description,
          channel: form.channel,
          password: form.password,
        )),
      ),
      tranquil.close_session(form.server, account.token, ServerClosedSession),
    )

    ServerCreatedAccount(result: Error(problem)) ->
      fill(Form(..form, submission: Refused(problem:)), effect.none())

    UserChoseServerPage -> #(
      Model(..model, step: FillingForm(form:, handoff: NotTried)),
      prepare_server_page(form),
    )

    UserChoseAnotherServer -> pick_another_server(model)

    ServerPreparedSignUp(result: Ok(registration)) -> #(
      model,
      modem.load(registration),
    )

    ServerPreparedSignUp(result: Error(_)) -> #(
      Model(..model, step: FillingForm(form:, handoff: NotPrepared)),
      effect.none(),
    )

    ServerReturnedHealth(server:, result:) ->
      record_health(model, server, result)

    ServerDescribedItself(server:, result:) ->
      record_description(model, server, result)

    UserPickedServer(..)
    | UserTypedAddress(_)
    | UserSubmittedAddress
    | ServerClosedSession(_)
    | UserChoseForm -> #(model, effect.none())
  }
}

fn pick_another_server(model: Model) -> #(Model, Effect(Message)) {
  #(Model(..model, step: PickingServer(lookup: NotStarted)), effect.none())
}

fn prepare_server_page(form: Form) -> Effect(Message) {
  browser.await(
    fn() { session.begin_sign_up(form.server) },
    ServerPreparedSignUp,
  )
}

fn record_health(
  model: Model,
  server: Request(String),
  result: Result(Software, rsvp.Error(String)),
) -> #(Model, Effect(Message)) {
  case result {
    Ok(Tranquil(_)) -> #(
      model,
      tranquil.ask(server, tranquil.server(), ServerDescribedItself(server, _)),
    )

    Error(rsvp.NetworkError) -> decline(model, server, ServerUnreachable)

    Error(rsvp.HttpError(response)) ->
      decline(model, server, case response.status {
        503 -> ServerUnavailable
        _ -> NotTranquil
      })

    Ok(OtherSoftware)
    | Error(rsvp.JsonError(_))
    | Error(rsvp.UnhandledResponse(_))
    | Error(rsvp.BadBody)
    | Error(rsvp.BadUrl(_)) -> decline(model, server, NotTranquil)
  }
}

fn record_description(
  model: Model,
  server: Request(String),
  result: Result(Server, tranquil.Problem),
) -> #(Model, Effect(Message)) {
  case result {
    Ok(description) -> {
      let model = mark(model, server, Offered(description:))

      case model.step {
        PickingServer(lookup: CheckingServer(server: checking))
          if checking == server
        -> offer(model, server, description)
        PickingServer(_) | ChoosingWay(..) | FillingForm(..) | Created(_) -> #(
          model,
          effect.none(),
        )
      }
    }

    Error(tranquil.Unreachable) -> decline(model, server, ServerUnreachable)

    Error(tranquil.Refused(_, _)) | Error(tranquil.NotUnderstood) ->
      decline(model, server, NotTranquil)
  }
}

fn mark(model: Model, server: Request(String), offer: Offer) -> Model {
  Model(
    ..model,
    listed: list.map(model.listed, fn(listed) {
      case listed.server == server {
        True -> Listed(..listed, offer:)
        False -> listed
      }
    }),
  )
}

fn decline(
  model: Model,
  server: Request(String),
  problem: Problem,
) -> #(Model, Effect(Message)) {
  let model = mark(model, server, NotOffered(problem:))

  case model.step {
    PickingServer(lookup: CheckingServer(server: checking))
      if checking == server
    -> #(
      Model(..model, step: PickingServer(lookup: Failed(problem:))),
      effect.none(),
    )
    PickingServer(_) | ChoosingWay(..) | FillingForm(..) | Created(_) -> #(
      model,
      effect.none(),
    )
  }
}

fn offer(
  model: Model,
  server: Request(String),
  description: Server,
) -> #(Model, Effect(Message)) {
  let linked = case model.invited {
    Some(Invitation(server: invited, code:)) if invited == server -> Some(code)
    Some(_) | None -> None
  }

  case description.handle_domains {
    [domain, ..] -> {
      let form =
        Form(
          server:,
          description:,
          name: "",
          domain:,
          availability: NotChecked,
          password: "",
          invite_code: case linked, description.invite_required {
            Some(code), _ -> Some(code)
            None, True -> Some("")
            None, False -> None
          },
          channel: case usable_channels(description) {
            [channel, ..] -> channel
            [] -> tranquil.Email
          },
          email: "",
          username: "",
          submission: Idle,
        )

      case model.leading, linked {
        ServerFirst, None -> #(
          Model(..model, step: ChoosingWay(form:, handoff: NotTried)),
          browser.focus(server_page_id),
        )
        HomesteadFirst, _ | ServerFirst, Some(_) -> #(
          Model(..model, step: FillingForm(form:, handoff: NotTried)),
          browser.focus(name_id),
        )
      }
    }

    [] -> #(
      Model(..model, step: PickingServer(lookup: Failed(SignUpNotPrepared))),
      effect.none(),
    )
  }
}

fn usable_channels(description: Server) -> List(Channel) {
  list.filter(description.contact_channels, fn(channel) {
    case channel {
      tranquil.Email | tranquil.Signal | tranquil.Discord | tranquil.Telegram ->
        True
      tranquil.OtherChannel(_) -> False
    }
  })
}

fn check_health(server: Request(String)) -> Effect(Message) {
  rsvp.send(
    tranquil.health_request(server),
    rsvp.expect_json(tranquil.health_decoder(), ServerReturnedHealth(server, _)),
  )
}

fn check_handle(form: Form) -> Effect(Message) {
  tranquil.ask(
    form.server,
    tranquil.handle_availability(form.name, form.domain),
    ServerReturnedAvailability(form.name, form.domain, _),
  )
}

pub fn is_valid_name(name: String) -> Bool {
  let length = string.length(name)

  length >= 3
  && length <= 18
  && !string.starts_with(name, "-")
  && !string.ends_with(name, "-")
  && list.all(string.to_graphemes(string.lowercase(name)), string.contains(
    name_characters,
    _,
  ))
}

pub fn password_rules(password: String) -> List(Rule) {
  let size = string.byte_size(password)
  let has = fn(characters) {
    list.any(string.to_graphemes(password), string.contains(characters, _))
  }

  [
    Rule(requirement: "8 to 256 characters", is_met: size >= 8 && size <= 256),
    Rule(
      requirement: "A lowercase letter",
      is_met: has("abcdefghijklmnopqrstuvwxyz"),
    ),
    Rule(
      requirement: "An uppercase letter",
      is_met: has("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
    ),
    Rule(requirement: "A digit", is_met: has("0123456789")),
    Rule(
      requirement: "Not a common password",
      is_met: password != ""
        && !list.contains(common_passwords, string.lowercase(password)),
    ),
  ]
}

fn new_account(form: Form) -> Result(NewAccount, Nil) {
  let is_available = case form.availability {
    NotChecked | CouldNotCheck | Checked(tranquil.Available) -> True
    CheckingHandle | Checked(tranquil.Unavailable(_)) -> False
  }
  let is_acceptable =
    is_available
    && is_valid_name(form.name)
    && list.all(password_rules(form.password), fn(rule) { rule.is_met })

  use <- bool.guard(!is_acceptable, Error(Nil))
  use handle <- result.try(handle.from_string(
    string.lowercase(form.name) <> "." <> form.domain,
  ))
  use contact <- result.try(contact(form))
  use invite_code <- result.map(case form.invite_code {
    None -> Ok(None)
    Some(code) ->
      case string.trim(code), form.description.invite_required {
        "", True -> Error(Nil)
        "", False -> Ok(None)
        code, _ -> Ok(Some(code))
      }
  })

  NewAccount(handle:, password: form.password, invite_code:, contact:)
}

fn contact(form: Form) -> Result(Contact, Nil) {
  let email = string.trim(form.email)
  let username = string.trim(form.username)

  case form.channel, email, username {
    tranquil.Email, "", _
    | tranquil.Signal, _, ""
    | tranquil.Discord, "", _
    | tranquil.Discord, _, ""
    | tranquil.Telegram, "", _
    | tranquil.Telegram, _, ""
    | tranquil.OtherChannel(_), _, _
    -> Error(Nil)
    tranquil.Email, address, _ -> Ok(tranquil.ByEmail(address:))
    tranquil.Signal, _, username -> Ok(tranquil.BySignal(username:))
    tranquil.Discord, email, username ->
      Ok(tranquil.ByDiscord(username:, email:))
    tranquil.Telegram, email, username ->
      Ok(tranquil.ByTelegram(username:, email:))
  }
}

pub fn view(model: Model) -> Element(Message) {
  landing.view(case model.step {
    PickingServer(lookup:) -> view_servers(model, lookup)
    ChoosingWay(form:, handoff:) -> view_choice(form, handoff)
    FillingForm(form:, handoff:) -> view_form(form, handoff)
    Created(_) -> []
  })
}

fn view_servers(model: Model, lookup: Lookup) -> List(Element(Message)) {
  let is_checking = case lookup {
    CheckingServer(_) -> True
    NotStarted | Failed(_) -> False
  }

  [
    html.h2([], [html.text("Create an account")]),
    case model.listed {
      [] -> element.none()
      [_, ..] ->
        html.ul(
          [attribute.class("accounts"), attribute.aria_label("Servers")],
          list.map(model.listed, view_listed),
        )
    },
    html.form([event.on_submit(fn(_) { UserSubmittedAddress })], [
      html.label([attribute.for("server")], [
        html.text(case model.listed {
          [] -> "Server"
          [_, ..] -> "Another server"
        }),
      ]),
      html.div([attribute.class("field")], [
        html.input([
          attribute.id("server"),
          attribute.name("server"),
          attribute.type_("text"),
          attribute.value(model.address),
          attribute.placeholder("pds.example.com"),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(is_checking),
          event.on_input(UserTypedAddress),
        ]),
        html.button(
          [attribute.class("button"), attribute.disabled(is_checking)],
          [html.text("Continue")],
        ),
      ]),
    ]),
    view_sign_in_link(),
    view_lookup(lookup),
  ]
}

fn view_listed(listed: Listed) -> Element(Message) {
  let name = tranquil.server_name(listed.server)

  html.li([], [
    case listed.offer {
      Offered(description:) ->
        html.button(
          [
            attribute.class("account"),
            event.on_click(UserPickedServer(listed.server, description)),
          ],
          [html.text(name)],
        )
      Checking | NotOffered(_) ->
        html.button([attribute.class("account"), attribute.disabled(True)], [
          html.text(name),
        ])
    },
    html.span([attribute.class("offer")], [
      html.text(case listed.offer {
        Checking -> "checking…"
        Offered(description:) ->
          case description.invite_required {
            True -> "invite only"
            False -> "open"
          }
        NotOffered(problem: ServerUnreachable) -> "unreachable"
        NotOffered(problem: ServerUnavailable) -> "unavailable"
        NotOffered(problem: NotTranquil)
        | NotOffered(problem: AddressNotUnderstood)
        | NotOffered(problem: SignUpNotPrepared) -> "not available"
      }),
    ]),
  ])
}

fn view_choice(form: Form, handoff: Handoff) -> List(Element(Message)) {
  let server = tranquil.server_name(form.server)

  [
    html.h2([], [html.text("Create an account")]),
    html.p([attribute.class("signing-in-as")], [
      html.text("on "),
      html.code([], [html.text(server)]),
    ]),
    html.p([], [
      html.text(
        "Creating it on " <> server <> " keeps your password off this site.",
      ),
    ]),
    html.div([attribute.class("ways")], [
      html.button(
        [
          attribute.id(server_page_id),
          attribute.class("button"),
          attribute.type_("button"),
          event.on_click(UserChoseServerPage),
        ],
        [html.text("Continue on " <> server)],
      ),
    ]),
    html.div([attribute.class("ways")], [
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          event.on_click(UserChoseForm),
        ],
        [html.text("Create it here")],
      ),
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          event.on_click(UserChoseAnotherServer),
        ],
        [html.text("Use another server")],
      ),
    ]),
    view_sign_in_link(),
    view_handoff(handoff),
  ]
}

fn view_form(form: Form, handoff: Handoff) -> List(Element(Message)) {
  let server = tranquil.server_name(form.server)
  let is_sending = form.submission == Sending

  [
    html.h2([], [html.text("Create an account")]),
    html.p([attribute.class("signing-in-as")], [
      html.text("on "),
      html.code([], [html.text(server)]),
    ]),
    html.form(
      [
        attribute.class("sign-up"),
        event.on_submit(fn(_) { UserSubmittedAccount }),
      ],
      list.flatten([
        view_handle(form, is_sending),
        view_password(form, is_sending),
        view_invite_code(form, is_sending),
        view_contact(form, is_sending),
        [
          view_links(form.description),
          html.p([], [
            html.text("Creating the account signs Homestead in to manage it."),
          ]),
          html.button(
            [
              attribute.class("button"),
              attribute.disabled(
                is_sending || result.is_error(new_account(form)),
              ),
            ],
            [html.text("Create account")],
          ),
        ],
      ]),
    ),
    html.div(
      [attribute.class("lookup"), attribute.aria_live("polite")],
      case form.submission {
        Idle -> []
        Sending -> [html.p([], [html.text("Creating your account…")])]
        Refused(problem:) -> [
          html.h3([attribute.class("attention")], [
            html.text(describe_refusal(problem)),
          ]),
        ]
      },
    ),
    html.div([attribute.class("ways")], [
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          attribute.disabled(is_sending),
          event.on_click(UserChoseServerPage),
        ],
        [html.text("Create it on " <> server <> " instead")],
      ),
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          attribute.disabled(is_sending),
          event.on_click(UserChoseAnotherServer),
        ],
        [html.text("Use another server")],
      ),
    ]),
    view_sign_in_link(),
    view_handoff(handoff),
  ]
}

fn view_handle(form: Form, is_sending: Bool) -> List(Element(Message)) {
  let is_refused = case form.availability {
    Checked(tranquil.Unavailable(_)) | CouldNotCheck -> True
    NotChecked -> form.name != "" && !is_valid_name(form.name)
    CheckingHandle | Checked(tranquil.Available) -> False
  }

  [
    html.label([attribute.for(name_id)], [html.text("Handle")]),
    html.div([attribute.class("field")], [
      html.input([
        attribute.id(name_id),
        attribute.name("username"),
        attribute.type_("text"),
        attribute.value(form.name),
        attribute.placeholder("yourname"),
        attribute.autocomplete("username"),
        attribute.autocapitalize("none"),
        attribute.spellcheck(False),
        attribute.disabled(is_sending),
        event.on_input(UserTypedName),
      ]),
      case form.description.handle_domains {
        [] | [_] ->
          html.span([attribute.class("domain")], [
            html.text("." <> form.domain),
          ])
        [_, _, ..] as domains ->
          html.select(
            [
              attribute.aria_label("Handle domain"),
              attribute.disabled(is_sending),
              event.on_change(UserPickedDomain),
            ],
            list.map(domains, fn(domain) {
              html.option(
                [
                  attribute.value(domain),
                  attribute.selected(domain == form.domain),
                ],
                "." <> domain,
              )
            }),
          )
      },
    ]),
    html.p(
      [
        attribute.classes([#("requirement", True), #("unmet", is_refused)]),
        attribute.aria_live("polite"),
      ],
      [
        html.text(case form.availability {
          NotChecked -> "3 to 18 letters, digits or hyphens"
          CheckingHandle -> "Checking…"
          Checked(tranquil.Available) ->
            string.lowercase(form.name) <> "." <> form.domain <> " is available"
          Checked(tranquil.Unavailable(reason: Some(reason))) -> reason
          Checked(tranquil.Unavailable(reason: None)) ->
            "That handle isn't available"
          CouldNotCheck -> "Couldn't check that handle"
        }),
      ],
    ),
  ]
}

fn view_password(form: Form, is_sending: Bool) -> List(Element(Message)) {
  [
    html.label([attribute.for("sign-up-password")], [html.text("Password")]),
    html.input([
      attribute.id("sign-up-password"),
      attribute.name("password"),
      attribute.type_("password"),
      attribute.value(form.password),
      attribute.autocomplete("new-password"),
      attribute.disabled(is_sending),
      event.on_input(UserTypedPassword),
    ]),
    html.ul(
      [attribute.class("rules"), attribute.aria_label("Password rules")],
      list.map(password_rules(form.password), fn(rule) {
        html.li(
          [
            attribute.classes([#("met", rule.is_met)]),
            attribute.aria_label(
              rule.requirement
              <> case rule.is_met {
                True -> ": met"
                False -> ": not met"
              },
            ),
          ],
          [html.text(rule.requirement)],
        )
      }),
    ),
  ]
}

fn view_invite_code(form: Form, is_sending: Bool) -> List(Element(Message)) {
  case form.invite_code {
    None -> []
    Some(invite_code) -> [
      html.label([attribute.for("sign-up-invite")], [html.text("Invite code")]),
      html.input([
        attribute.id("sign-up-invite"),
        attribute.name("invite"),
        attribute.type_("text"),
        attribute.value(invite_code),
        attribute.autocomplete("off"),
        attribute.autocapitalize("none"),
        attribute.spellcheck(False),
        attribute.disabled(is_sending),
        event.on_input(UserTypedInviteCode),
      ]),
    ]
  }
}

fn view_contact(form: Form, is_sending: Bool) -> List(Element(Message)) {
  let email = [
    html.label([attribute.for("sign-up-email")], [html.text("Email")]),
    html.input([
      attribute.id("sign-up-email"),
      attribute.name("email"),
      attribute.type_("email"),
      attribute.value(form.email),
      attribute.autocomplete("email"),
      attribute.disabled(is_sending),
      event.on_input(UserTypedEmail),
    ]),
  ]
  let username = fn(placeholder) {
    [
      html.label([attribute.for("sign-up-contact")], [
        html.text(tranquil.channel_label(form.channel) <> " username"),
      ]),
      html.input([
        attribute.id("sign-up-contact"),
        attribute.name("contact"),
        attribute.type_("text"),
        attribute.value(form.username),
        attribute.placeholder(placeholder),
        attribute.autocomplete("off"),
        attribute.autocapitalize("none"),
        attribute.spellcheck(False),
        attribute.disabled(is_sending),
        event.on_input(UserTypedUsername),
      ]),
    ]
  }

  list.flatten([
    case usable_channels(form.description) {
      [] | [_] -> []
      [_, _, ..] as channels -> [
        html.label([attribute.for("sign-up-channel")], [html.text("Verify by")]),
        html.select(
          [
            attribute.id("sign-up-channel"),
            attribute.disabled(is_sending),
            event.on_change(UserPickedChannel),
          ],
          list.map(channels, fn(channel) {
            html.option(
              [
                attribute.value(tranquil.channel_name(channel)),
                attribute.selected(channel == form.channel),
              ],
              tranquil.channel_label(channel),
            )
          }),
        ),
      ]
    },
    case form.channel {
      tranquil.Email | tranquil.OtherChannel(_) -> email
      tranquil.Signal -> username("username.01")
      tranquil.Discord -> list.append(username("yourusername"), email)
      tranquil.Telegram -> list.append(username("@yourusername"), email)
    },
  ])
}

fn view_links(description: Server) -> Element(message) {
  let link = fn(address, name) {
    case address {
      Some(address) -> [
        html.a(
          [
            attribute.href(address),
            attribute.target("_blank"),
            attribute.rel("noopener"),
          ],
          [html.text(name)],
        ),
      ]
      None -> []
    }
  }

  case
    list.append(
      link(description.terms_of_service, "Terms of service"),
      link(description.privacy_policy, "Privacy policy"),
    )
  {
    [] -> element.none()
    [_, ..] as links -> html.p([attribute.class("links")], links)
  }
}

fn view_sign_in_link() -> Element(message) {
  html.a([attribute.class("create-account"), attribute.href("/")], [
    html.text("Have an account? Sign in"),
  ])
}

fn view_lookup(lookup: Lookup) -> Element(message) {
  html.div(
    [attribute.class("lookup"), attribute.aria_live("polite")],
    case lookup {
      NotStarted -> []
      CheckingServer(_) -> [html.p([], [html.text("Checking that server…")])]
      Failed(problem:) -> [
        html.h3([attribute.class("attention")], [
          html.text(case problem {
            AddressNotUnderstood -> "That doesn't look like a server address."
            ServerUnreachable -> "Couldn't reach that server."
            ServerUnavailable -> "That server is unavailable right now."
            NotTranquil ->
              "That isn't a Tranquil server, so accounts can't be created from here."
            SignUpNotPrepared -> not_prepared
          }),
        ]),
      ]
    },
  )
}

fn view_handoff(handoff: Handoff) -> Element(message) {
  html.div(
    [attribute.class("lookup"), attribute.aria_live("polite")],
    case handoff {
      NotTried -> []
      NotPrepared -> [
        html.h3([attribute.class("attention")], [html.text(not_prepared)]),
      ]
    },
  )
}

fn describe_refusal(problem: tranquil.Problem) -> String {
  case problem {
    tranquil.Refused("HandleTaken", _)
    | tranquil.Refused("HandleNotAvailable", _) -> "That handle is taken"
    tranquil.Refused("InvalidInviteCode", _) -> "That invite code isn't valid"
    tranquil.Refused("InviteCodeRequired", _) ->
      "This server needs an invite code"
    tranquil.Refused("InvalidEmail", _) -> "That email address isn't valid"
    tranquil.Refused("EmailTaken", _) ->
      "That email address is already used on this server"
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe_failed_load(problem)
  }
}
