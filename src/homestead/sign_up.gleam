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
    address: String,
    lookup: Lookup,
    invited: Option(Invitation),
    form: Option(Form),
    created: Option(Unverified),
  )
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

type Form {
  Form(
    server: Request(String),
    description: Server,
    is_invited: Bool,
    is_filling: Bool,
    name: String,
    domain: String,
    availability: HandleCheck,
    password: String,
    invite_code: String,
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
  let linked = case address {
    "" -> Error(NotStarted)
    address ->
      tranquil.server_address(address)
      |> result.replace_error(Failed(AddressNotUnderstood))
  }
  let model =
    Model(
      leading: settings.password_entry,
      listed: list.map(settings.sign_up_servers, Listed(_, offer: Checking)),
      address:,
      lookup: NotStarted,
      invited: None,
      form: None,
      created: None,
    )
  let listed_checks = list.map(settings.sign_up_servers, check_health)

  case linked {
    Ok(server) -> #(
      Model(
        ..model,
        lookup: CheckingServer(server:),
        invited: route.query(location, "invite")
          |> option.map(Invitation(server:, code: _)),
      ),
      effect.batch(case list.contains(settings.sign_up_servers, server) {
        True -> listed_checks
        False -> [check_health(server), ..listed_checks]
      }),
    )
    Error(lookup) -> #(Model(..model, lookup:), effect.batch(listed_checks))
  }
}

pub fn created(model: Model) -> Option(Unverified) {
  model.created
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
  case message {
    UserPickedServer(server:, description:) -> offer(model, server, description)

    UserTypedAddress(address:) -> #(
      Model(..model, address:, lookup: NotStarted),
      effect.none(),
    )

    UserSubmittedAddress ->
      case tranquil.server_address(model.address) {
        Ok(server) -> #(
          Model(..model, lookup: CheckingServer(server:)),
          check_health(server),
        )
        Error(Nil) -> #(
          Model(..model, lookup: Failed(AddressNotUnderstood)),
          effect.none(),
        )
      }

    ServerReturnedHealth(server:, result: Ok(Tranquil(_))) -> #(
      model,
      tranquil.ask(server, tranquil.server(), ServerDescribedItself(server, _)),
    )

    ServerReturnedHealth(server:, result:) ->
      decline(model, server, case result {
        Error(rsvp.NetworkError) -> ServerUnreachable
        Error(rsvp.HttpError(response)) if response.status == 503 ->
          ServerUnavailable
        Ok(Tranquil(_))
        | Ok(OtherSoftware)
        | Error(rsvp.HttpError(_))
        | Error(rsvp.JsonError(_))
        | Error(rsvp.UnhandledResponse(_))
        | Error(rsvp.BadBody)
        | Error(rsvp.BadUrl(_)) -> NotTranquil
      })

    ServerDescribedItself(server:, result: Ok(description)) -> {
      let model = mark(model, server, Offered(description:))

      case model.lookup == CheckingServer(server:) {
        True -> offer(model, server, description)
        False -> #(model, effect.none())
      }
    }

    ServerDescribedItself(server:, result: Error(tranquil.Unreachable)) ->
      decline(model, server, ServerUnreachable)

    ServerDescribedItself(server:, result: Error(tranquil.Refused(_, _)))
    | ServerDescribedItself(server:, result: Error(tranquil.NotUnderstood)) ->
      decline(model, server, NotTranquil)

    UserChoseAnotherServer -> #(
      Model(..model, lookup: NotStarted, form: None),
      effect.none(),
    )

    UserTypedName(name:) -> {
      use form <- with_form(model)
      let form = Form(..form, name:, availability: NotChecked)

      #(form, case is_valid_name(name) {
        True ->
          browser.after(
            typing_pause_milliseconds,
            UserPausedTypingName(name, form.domain),
          )
        False -> effect.none()
      })
    }

    UserPausedTypingName(name:, domain:) -> {
      use form <- with_form(model)

      case form.name == name && form.domain == domain {
        True -> check_handle(form)
        False -> #(form, effect.none())
      }
    }

    UserPickedDomain(domain:) -> {
      use form <- with_form(model)
      let form = Form(..form, domain:, availability: NotChecked)

      case is_valid_name(form.name) {
        True -> check_handle(form)
        False -> #(form, effect.none())
      }
    }

    ServerReturnedAvailability(name:, domain:, result:) -> {
      use form <- with_form(model)

      case form.name == name && form.domain == domain, result {
        True, Ok(availability) -> #(
          Form(..form, availability: Checked(availability:)),
          effect.none(),
        )
        True, Error(_) -> #(
          Form(..form, availability: CouldNotCheck),
          effect.none(),
        )
        False, _ -> #(form, effect.none())
      }
    }

    UserTypedPassword(password:) -> {
      use form <- with_form(model)

      #(Form(..form, password:, submission: Idle), effect.none())
    }

    UserTypedInviteCode(invite_code:) -> {
      use form <- with_form(model)

      #(Form(..form, invite_code:, submission: Idle), effect.none())
    }

    UserPickedChannel(name:) -> {
      use form <- with_form(model)
      let channel =
        list.find(form.description.contact_channels, fn(channel) {
          tranquil.channel_name(channel) == name
        })

      case channel {
        Ok(channel) -> #(
          Form(..form, channel:, username: "", submission: Idle),
          effect.none(),
        )
        Error(Nil) -> #(form, effect.none())
      }
    }

    UserTypedEmail(email:) -> {
      use form <- with_form(model)

      #(Form(..form, email:, submission: Idle), effect.none())
    }

    UserTypedUsername(username:) -> {
      use form <- with_form(model)

      #(Form(..form, username:, submission: Idle), effect.none())
    }

    UserSubmittedAccount -> {
      use form <- with_form(model)

      case new_account(form) {
        Ok(new) -> #(
          Form(..form, submission: Sending),
          tranquil.submit(
            form.server,
            tranquil.create_account(new),
            ServerCreatedAccount,
          ),
        )
        Error(Nil) -> #(form, effect.none())
      }
    }

    ServerCreatedAccount(result: Ok(account)) ->
      case model.form {
        Some(form) -> #(
          Model(
            ..model,
            created: Some(Unverified(
              account: account.account,
              name: handle.to_string(account.handle),
              server: form.server,
              description: form.description,
              channel: form.channel,
              password: form.password,
            )),
          ),
          tranquil.close_session(
            form.server,
            account.token,
            ServerClosedSession,
          ),
        )
        None -> #(model, effect.none())
      }

    ServerCreatedAccount(result: Error(problem)) -> {
      use form <- with_form(model)

      #(Form(..form, submission: Refused(problem:)), effect.none())
    }

    ServerClosedSession(_) -> #(model, effect.none())

    UserChoseServerPage ->
      case model.form {
        Some(form) -> #(
          Model(..model, lookup: NotStarted),
          browser.await(
            fn() { session.begin_sign_up(form.server) },
            ServerPreparedSignUp,
          ),
        )
        None -> #(model, effect.none())
      }

    UserChoseForm -> {
      use form <- with_form(model)

      #(Form(..form, is_filling: True), browser.focus(name_id))
    }

    ServerPreparedSignUp(result: Ok(registration)) -> #(
      model,
      modem.load(registration),
    )

    ServerPreparedSignUp(result: Error(_)) -> #(
      Model(..model, lookup: Failed(SignUpNotPrepared)),
      effect.none(),
    )
  }
}

fn with_form(
  model: Model,
  change: fn(Form) -> #(Form, Effect(Message)),
) -> #(Model, Effect(Message)) {
  case model.form {
    Some(form) -> {
      let #(form, effect) = change(form)

      #(Model(..model, form: Some(form)), effect)
    }
    None -> #(model, effect.none())
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

  case model.lookup == CheckingServer(server:) {
    True -> #(Model(..model, lookup: Failed(problem:)), effect.none())
    False -> #(model, effect.none())
  }
}

fn offer(
  model: Model,
  server: Request(String),
  description: Server,
) -> #(Model, Effect(Message)) {
  let invite_code = case model.invited {
    Some(Invitation(server: invited, code:)) if invited == server -> Some(code)
    Some(_) | None -> None
  }

  case description.handle_domains {
    [domain, ..] -> #(
      Model(
        ..model,
        lookup: NotStarted,
        form: Some(Form(
          server:,
          description:,
          is_invited: option.is_some(invite_code),
          is_filling: model.leading == HomesteadFirst
            || option.is_some(invite_code),
          name: "",
          domain:,
          availability: NotChecked,
          password: "",
          invite_code: option.unwrap(invite_code, ""),
          channel: case usable_channels(description) {
            [channel, ..] -> channel
            [] -> tranquil.Email
          },
          email: "",
          username: "",
          submission: Idle,
        )),
      ),
      browser.focus(case model.leading, invite_code {
        ServerFirst, None -> server_page_id
        HomesteadFirst, _ | ServerFirst, Some(_) -> name_id
      }),
    )
    [] -> #(Model(..model, lookup: Failed(SignUpNotPrepared)), effect.none())
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

fn check_handle(form: Form) -> #(Form, Effect(Message)) {
  #(
    Form(..form, availability: CheckingHandle),
    tranquil.ask(
      form.server,
      tranquil.handle_availability(form.name, form.domain),
      ServerReturnedAvailability(form.name, form.domain, _),
    ),
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
  use invite_code <- result.map(
    case form.description.invite_required, string.trim(form.invite_code) {
      True, "" -> Error(Nil)
      False, "" -> Ok(None)
      True, code | False, code -> Ok(Some(code))
    },
  )

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
  landing.view(case model.form {
    Some(Form(is_filling: True, ..) as form) -> view_form(form, model.lookup)
    Some(Form(is_filling: False, ..) as form) -> view_choice(form, model.lookup)
    None -> view_servers(model)
  })
}

fn view_servers(model: Model) -> List(Element(Message)) {
  let is_checking = case model.lookup {
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
    view_lookup(model.lookup),
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

fn view_choice(form: Form, lookup: Lookup) -> List(Element(Message)) {
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
    view_lookup(lookup),
  ]
}

fn view_form(form: Form, lookup: Lookup) -> List(Element(Message)) {
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
    view_lookup(lookup),
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
  case form.description.invite_required || form.is_invited {
    False -> []
    True -> [
      html.label([attribute.for("sign-up-invite")], [html.text("Invite code")]),
      html.input([
        attribute.id("sign-up-invite"),
        attribute.name("invite"),
        attribute.type_("text"),
        attribute.value(form.invite_code),
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
            SignUpNotPrepared -> "Couldn't start signing up on that server."
          }),
        ]),
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
