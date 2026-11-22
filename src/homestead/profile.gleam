import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/browser
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{
  type Account, type ContactPreferences, type Problem, type Server,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const code_channel = "signal"

pub opaque type Model {
  Model(
    session: Session,
    account: Remote(Account),
    server: Remote(Server),
    handle: HandleForm,
    verification: Verification,
    email: EmailForm,
    contact: Remote(ContactForm),
  )
}

type Submission {
  Idle
  Sending
  Refused(problem: Problem)
}

type HandleForm {
  HandleForm(
    name: String,
    domain: Domain,
    submission: Submission,
    copied: Copied,
  )
}

type Copied {
  NothingCopied
  CopiedRecord
  CopiedFileContent
  CopyFailed
}

type Domain {
  ServerDomain(domain: String)
  OwnDomain
}

type Verification {
  Verification(code: String, submission: Submission, resending: Resending)
}

type Resending {
  NotResent
  Resending
  Resent
  ResendRefused(problem: Problem)
}

type EmailForm {
  EmailForm(new_email: String, step: EmailStep, submission: Submission)
}

type EmailStep {
  EnteringEmail
  EnteringCode(code: String)
}

type ContactForm {
  ContactForm(
    preferred: String,
    usernames: List(#(String, String)),
    saved: ContactPreferences,
    submission: Submission,
    code: String,
    confirmation: Submission,
  )
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      account: Loading,
      server: Loading,
      handle: HandleForm(
        name: "",
        domain: OwnDomain,
        submission: Idle,
        copied: NothingCopied,
      ),
      verification: Verification(
        code: "",
        submission: Idle,
        resending: NotResent,
      ),
      email: EmailForm(new_email: "", step: EnteringEmail, submission: Idle),
      contact: Loading,
    ),
    effect.batch([
      load_account(session),
      tranquil.load(session, tranquil.server(), ServerReturnedServer),
      load_contact(session),
    ]),
  )
}

pub fn account(model: Model) -> Remote(Account) {
  model.account
}

pub fn departure(model: Model) -> Option(Departure) {
  let ended = Refused(tranquil.SessionEnded)
  let has_ended_session =
    remote.has_ended_session(model.account)
    || remote.has_ended_session(model.server)
    || remote.has_ended_session(model.contact)
    || model.handle.submission == ended
    || model.verification.submission == ended
    || model.verification.resending == ResendRefused(tranquil.SessionEnded)
    || model.email.submission == ended
    || case model.contact {
      Loaded(value: form) ->
        form.submission == ended || form.confirmation == ended
      Loading | Failed(_) -> False
    }

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedAccount(result: Result(Account, Problem))
  ServerReturnedServer(result: Result(Server, Problem))
  ServerReturnedContact(result: Result(ContactPreferences, Problem))
  UserTypedHandle(name: String)
  UserPickedDomain(domain: Domain)
  UserSubmittedHandle
  ServerChangedHandle(result: Result(Nil, Problem))
  UserClickedCopy(text: String, copied: Copied)
  BrowserCopiedText(copied: Copied, result: Result(Nil, Nil))
  UserClickedResend
  ServerResentVerification(result: Result(Nil, Problem))
  UserTypedVerificationCode(code: String)
  UserSubmittedVerification(email: String)
  ServerConfirmedEmail(result: Result(Nil, Problem))
  UserTypedNewEmail(email: String)
  UserSubmittedNewEmail
  ServerPreparedEmailChange(result: Result(Bool, Problem))
  UserTypedEmailCode(code: String)
  UserSubmittedEmailCode(code: String)
  UserCancelledEmailChange
  ServerChangedEmail(result: Result(Nil, Problem))
  UserPickedChannel(channel: String)
  UserTypedUsername(channel: String, username: String)
  UserSubmittedContact
  ServerUpdatedContact(result: Result(Nil, Problem))
  UserTypedChannelCode(code: String)
  UserSubmittedChannelCode(username: String)
  ServerConfirmedChannel(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedAccount(result:) -> #(
      Model(..model, account: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedServer(result:) -> {
      let domain = case result {
        Ok(tranquil.Server(handle_domains: [domain, ..], ..)) ->
          ServerDomain(domain:)
        Ok(tranquil.Server(handle_domains: [], ..)) | Error(_) -> OwnDomain
      }

      #(
        Model(
          ..model,
          server: remote.from_result(result),
          handle: HandleForm(..model.handle, domain:),
        ),
        effect.none(),
      )
    }

    ServerReturnedContact(result:) -> #(
      Model(
        ..model,
        contact: remote.map(remote.from_result(result), fn(saved) {
          ContactForm(
            preferred: saved.preferred,
            usernames: list.map(saved.usernames, fn(entry) {
              #(entry.channel, entry.username)
            }),
            saved:,
            submission: Idle,
            code: "",
            confirmation: Idle,
          )
        }),
      ),
      effect.none(),
    )

    UserTypedHandle(name:) -> #(
      Model(
        ..model,
        handle: HandleForm(..model.handle, name:, submission: Idle),
      ),
      effect.none(),
    )

    UserPickedDomain(domain:) -> #(
      Model(..model, handle: HandleForm(..model.handle, domain:)),
      effect.none(),
    )

    UserSubmittedHandle -> #(
      Model(..model, handle: HandleForm(..model.handle, submission: Sending)),
      tranquil.perform(
        session,
        tranquil.change_handle(full_handle(model.handle)),
        ServerChangedHandle,
      ),
    )

    ServerChangedHandle(result: Ok(Nil)) -> #(
      Model(
        ..model,
        handle: HandleForm(..model.handle, name: "", submission: Idle),
      ),
      load_account(session),
    )

    ServerChangedHandle(result: Error(problem)) -> #(
      Model(
        ..model,
        handle: HandleForm(..model.handle, submission: Refused(problem:)),
      ),
      effect.none(),
    )

    UserClickedCopy(text:, copied:) -> #(
      model,
      browser.copy(text, BrowserCopiedText(copied, _)),
    )

    BrowserCopiedText(copied:, result:) -> #(
      Model(
        ..model,
        handle: HandleForm(..model.handle, copied: case result {
          Ok(Nil) -> copied
          Error(Nil) -> CopyFailed
        }),
      ),
      effect.none(),
    )

    UserClickedResend -> #(
      Model(
        ..model,
        verification: Verification(..model.verification, resending: Resending),
      ),
      tranquil.perform(
        session,
        tranquil.resend_verification(session.account(session)),
        ServerResentVerification,
      ),
    )

    ServerResentVerification(result:) -> #(
      Model(
        ..model,
        verification: Verification(
          ..model.verification,
          resending: case result {
            Ok(Nil) -> Resent
            Error(problem) -> ResendRefused(problem:)
          },
        ),
      ),
      effect.none(),
    )

    UserTypedVerificationCode(code:) -> #(
      Model(
        ..model,
        verification: Verification(
          ..model.verification,
          code:,
          submission: Idle,
        ),
      ),
      effect.none(),
    )

    UserSubmittedVerification(email:) -> #(
      Model(
        ..model,
        verification: Verification(..model.verification, submission: Sending),
      ),
      tranquil.perform(
        session,
        tranquil.confirm_email(email, string.trim(model.verification.code)),
        ServerConfirmedEmail,
      ),
    )

    ServerConfirmedEmail(result: Ok(Nil)) -> #(
      Model(
        ..model,
        verification: Verification(
          code: "",
          submission: Idle,
          resending: NotResent,
        ),
      ),
      load_account(session),
    )

    ServerConfirmedEmail(result: Error(problem)) -> #(
      Model(
        ..model,
        verification: Verification(
          ..model.verification,
          submission: Refused(problem:),
        ),
      ),
      effect.none(),
    )

    UserTypedNewEmail(email:) -> #(
      Model(
        ..model,
        email: EmailForm(..model.email, new_email: email, submission: Idle),
      ),
      effect.none(),
    )

    UserSubmittedNewEmail -> #(
      Model(..model, email: EmailForm(..model.email, submission: Sending)),
      tranquil.perform(
        session,
        tranquil.request_email_change(string.trim(model.email.new_email)),
        ServerPreparedEmailChange,
      ),
    )

    ServerPreparedEmailChange(result: Ok(True)) -> #(
      Model(
        ..model,
        email: EmailForm(
          ..model.email,
          step: EnteringCode(code: ""),
          submission: Idle,
        ),
      ),
      effect.none(),
    )

    ServerPreparedEmailChange(result: Ok(False)) -> #(
      model,
      change_email(session, model.email.new_email, None),
    )

    ServerPreparedEmailChange(result: Error(problem)) -> #(
      Model(
        ..model,
        email: EmailForm(..model.email, submission: Refused(problem:)),
      ),
      effect.none(),
    )

    UserTypedEmailCode(code:) -> #(
      Model(
        ..model,
        email: EmailForm(
          ..model.email,
          step: EnteringCode(code:),
          submission: Idle,
        ),
      ),
      effect.none(),
    )

    UserSubmittedEmailCode(code:) -> #(
      Model(..model, email: EmailForm(..model.email, submission: Sending)),
      change_email(session, model.email.new_email, Some(string.trim(code))),
    )

    UserCancelledEmailChange -> #(
      Model(
        ..model,
        email: EmailForm(..model.email, step: EnteringEmail, submission: Idle),
      ),
      effect.none(),
    )

    ServerChangedEmail(result: Ok(Nil)) -> #(
      Model(
        ..model,
        email: EmailForm(new_email: "", step: EnteringEmail, submission: Idle),
      ),
      load_account(session),
    )

    ServerChangedEmail(result: Error(problem)) -> #(
      Model(
        ..model,
        email: EmailForm(..model.email, submission: Refused(problem:)),
      ),
      effect.none(),
    )

    UserPickedChannel(channel:) -> #(
      update_contact(model, fn(form) { ContactForm(..form, preferred: channel) }),
      effect.none(),
    )

    UserTypedUsername(channel:, username:) -> #(
      update_contact(model, fn(form) {
        ContactForm(
          ..form,
          usernames: list.key_set(form.usernames, channel, username),
          submission: Idle,
        )
      }),
      effect.none(),
    )

    UserSubmittedContact ->
      case model.contact {
        Loaded(value: form) -> {
          let changed =
            list.filter(form.usernames, fn(entry) {
              !list.any(form.saved.usernames, fn(saved) {
                saved.channel == entry.0 && saved.username == entry.1
              })
            })

          #(
            update_contact(model, fn(form) {
              ContactForm(..form, submission: Sending)
            }),
            tranquil.perform(
              session,
              tranquil.update_contact(form.preferred, changed),
              ServerUpdatedContact,
            ),
          )
        }
        Loading | Failed(_) -> #(model, effect.none())
      }

    ServerUpdatedContact(result: Ok(Nil)) -> #(model, load_contact(session))

    ServerUpdatedContact(result: Error(problem)) -> #(
      update_contact(model, fn(form) {
        ContactForm(..form, submission: Refused(problem:))
      }),
      effect.none(),
    )

    UserTypedChannelCode(code:) -> #(
      update_contact(model, fn(form) {
        ContactForm(..form, code:, confirmation: Idle)
      }),
      effect.none(),
    )

    UserSubmittedChannelCode(username:) ->
      case model.contact {
        Loaded(value: form) -> #(
          update_contact(model, fn(form) {
            ContactForm(..form, confirmation: Sending)
          }),
          tranquil.perform(
            session,
            tranquil.confirm_channel(
              code_channel,
              username,
              string.trim(form.code),
            ),
            ServerConfirmedChannel,
          ),
        )
        Loading | Failed(_) -> #(model, effect.none())
      }

    ServerConfirmedChannel(result: Ok(Nil)) -> #(
      model,
      effect.batch([load_contact(session), load_account(session)]),
    )

    ServerConfirmedChannel(result: Error(problem)) -> #(
      update_contact(model, fn(form) {
        ContactForm(..form, confirmation: Refused(problem:))
      }),
      effect.none(),
    )
  }
}

fn update_contact(model: Model, with: fn(ContactForm) -> ContactForm) -> Model {
  Model(..model, contact: remote.map(model.contact, with))
}

fn full_handle(form: HandleForm) -> String {
  case form.domain {
    ServerDomain(domain:) -> string.trim(form.name) <> "." <> domain
    OwnDomain -> string.trim(form.name)
  }
}

fn load_account(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.account(), ServerReturnedAccount)
}

fn load_contact(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.contact_preferences(), ServerReturnedContact)
}

fn change_email(
  session: Session,
  email: String,
  code: Option(String),
) -> Effect(Message) {
  tranquil.perform(
    session,
    tranquil.change_email(string.trim(email), code),
    ServerChangedEmail,
  )
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("InvalidHandle", message) if message != "" -> message
    tranquil.Refused("HandleTaken", _) -> "That handle is taken"
    tranquil.Refused("HandleNotAvailable", message) ->
      case message {
        "Handle points to different DID" <> _ -> message
        _ -> "No DNS record or file found for that domain"
      }
    tranquil.Refused("InvalidEmail", _) -> "That isn't a valid email address"
    tranquil.Refused("EmailTaken", _) -> "That email is already in use"
    tranquil.Refused("TokenRequired", _) -> "Enter the code first"
    tranquil.Refused("InvalidToken", _) -> "That code isn't right"
    tranquil.Refused("ExpiredToken", _) -> "That code has expired"
    tranquil.Refused("RateLimitExceeded", _) ->
      "Too many attempts. Try again later"
    tranquil.Unreachable -> "Couldn't reach the server"
    tranquil.Refused(_, _) | tranquil.NotUnderstood | tranquil.SessionEnded ->
      "The server didn't accept that"
  }
}

pub fn view(model: Model) -> Element(Message) {
  case model.account {
    Loading -> layout.page([])

    Failed(_) ->
      layout.page([
        layout.title_section("handle", [
          layout.block([layout.problem("Couldn't load")]),
        ]),
      ])

    Loaded(value: account) ->
      layout.page([
        layout.title_section("handle", [
          view_handle(
            model.handle,
            account,
            model.server,
            session.account(model.session),
          ),
        ]),
        layout.section("email", [
          view_email(model.verification, model.email, account),
        ]),
        case model.server, model.contact {
          Loaded(value: server), Loaded(value: form) ->
            case
              list.filter(server.contact_channels, fn(channel) {
                channel != "email"
              })
            {
              [] -> element.none()
              [_, ..] ->
                layout.section("contact", [
                  view_contact(form, server, account.handle),
                ])
            }
          _, _ -> element.none()
        },
      ])
  }
}

fn view_handle(
  form: HandleForm,
  account: Account,
  server: Remote(Server),
  did: String,
) -> Element(Message) {
  let domains = case server {
    Loaded(value: server) ->
      list.map(server.handle_domains, fn(domain) { ServerDomain(domain:) })
    Loading | Failed(_) -> []
  }

  layout.block([
    layout.row(
      tone: layout.Plain,
      name: "Handle",
      details: [html.code([], [html.text("@" <> account.handle)])],
      actions: [],
    ),
    html.form([event.on_submit(fn(_) { UserSubmittedHandle })], [
      layout.field(
        html.label([attribute.for("new-handle")], [html.text("New handle")]),
        html.div([attribute.class("inline")], [
          html.input([
            attribute.id("new-handle"),
            attribute.type_("text"),
            attribute.value(form.name),
            attribute.autocomplete("off"),
            attribute.autocapitalize("none"),
            attribute.spellcheck(False),
            attribute.disabled(form.submission == Sending),
            event.on_input(UserTypedHandle),
          ]),
          html.div(
            [
              attribute.class("choices"),
              attribute.role("radiogroup"),
              attribute.aria_label("Domain"),
            ],
            list.map(list.append(domains, [OwnDomain]), fn(domain) {
              html.label([], [
                html.input([
                  attribute.type_("radio"),
                  attribute.name("handle-domain"),
                  attribute.checked(domain == form.domain),
                  event.on_click(UserPickedDomain(domain)),
                ]),
                html.span([], [
                  html.text(case domain {
                    ServerDomain(domain:) -> "." <> domain
                    OwnDomain -> "My own domain"
                  }),
                ]),
              ])
            }),
          ),
        ]),
      ),
      case form.domain {
        OwnDomain -> view_domain_setup(form, did)
        ServerDomain(_) -> element.none()
      },
      view_refusal(form.submission),
      layout.details_row([
        view_submit("Change", form.submission, string.trim(form.name) == ""),
      ]),
    ]),
  ])
}

fn view_domain_setup(form: HandleForm, did: String) -> Element(Message) {
  let domain = case string.trim(form.name) {
    "" -> "yourdomain.com"
    name -> name
  }
  let record = "did=" <> did
  let code = fn(text: String) {
    html.code([attribute.class("long")], [html.text(text)])
  }
  let note = fn(kind: Copied) {
    case form.copied {
      CopyFailed -> layout.dim(" couldn't copy")
      copied if copied == kind -> layout.dim(" copied")
      NothingCopied | CopiedRecord | CopiedFileContent -> element.none()
    }
  }
  let copy = fn(text: String, kind: Copied) {
    html.button(
      [
        attribute.class("action"),
        attribute.type_("button"),
        event.on_click(UserClickedCopy(text, kind)),
      ],
      [html.text("Copy")],
    )
  }

  element.fragment([
    layout.row(
      tone: layout.Plain,
      name: "DNS record",
      details: [
        html.span([attribute.class("lines")], [
          html.span([], [html.text("TXT "), code("_atproto." <> domain)]),
          html.span([], [code(record), note(CopiedRecord)]),
        ]),
      ],
      actions: [copy(record, CopiedRecord)],
    ),
    layout.row(
      tone: layout.Plain,
      name: "Or a file",
      details: [
        html.span([attribute.class("lines")], [
          code("https://" <> domain <> "/.well-known/atproto-did"),
          html.span([], [
            html.text("containing "),
            code(did),
            note(CopiedFileContent),
          ]),
        ]),
      ],
      actions: [copy(did, CopiedFileContent)],
    ),
  ])
}

fn view_email(
  verification: Verification,
  form: EmailForm,
  account: Account,
) -> Element(Message) {
  let address = option.unwrap(account.email, "")

  layout.block([
    layout.row(
      tone: layout.Plain,
      name: "Email",
      details: [
        html.text(address <> " "),
        layout.dim(case account.email_verified, verification.resending {
          True, _ -> "\u{00B7} verified"
          False, Resent -> "\u{00B7} not verified \u{00B7} code sent"
          False, ResendRefused(_) ->
            "\u{00B7} not verified \u{00B7} couldn't send a code"
          False, NotResent | False, Resending -> "\u{00B7} not verified"
        }),
      ],
      actions: case account.email_verified {
        True -> []
        False -> [
          html.button(
            [
              attribute.class("action"),
              attribute.disabled(verification.resending == Resending),
              event.on_click(UserClickedResend),
            ],
            [html.text("Resend code")],
          ),
        ]
      },
    ),
    case account.email_verified {
      True -> element.none()
      False ->
        html.form(
          [event.on_submit(fn(_) { UserSubmittedVerification(address) })],
          [
            layout.field(
              html.label([attribute.for("verification-code")], [
                html.text("Code"),
              ]),
              html.input([
                attribute.id("verification-code"),
                attribute.type_("text"),
                attribute.value(verification.code),
                attribute.autocomplete("one-time-code"),
                attribute.disabled(verification.submission == Sending),
                event.on_input(UserTypedVerificationCode),
              ]),
            ),
            view_refusal(verification.submission),
            layout.details_row([
              view_submit(
                "Verify",
                verification.submission,
                string.trim(verification.code) == "",
              ),
            ]),
          ],
        )
    },
    case form.step {
      EnteringEmail ->
        html.form([event.on_submit(fn(_) { UserSubmittedNewEmail })], [
          layout.field(
            html.label([attribute.for("new-email")], [html.text("New email")]),
            html.input([
              attribute.id("new-email"),
              attribute.type_("email"),
              attribute.value(form.new_email),
              attribute.autocomplete("email"),
              attribute.disabled(form.submission == Sending),
              event.on_input(UserTypedNewEmail),
            ]),
          ),
          view_refusal(form.submission),
          layout.details_row([
            view_submit(
              "Change",
              form.submission,
              string.trim(form.new_email) == "",
            ),
          ]),
        ])

      EnteringCode(code:) ->
        html.form([event.on_submit(fn(_) { UserSubmittedEmailCode(code) })], [
          layout.row(
            tone: layout.Plain,
            name: "New email",
            details: [html.text(form.new_email)],
            actions: [],
          ),
          layout.field(
            html.label([attribute.for("email-change-code")], [html.text("Code")]),
            html.input([
              attribute.id("email-change-code"),
              attribute.type_("text"),
              attribute.value(code),
              attribute.autocomplete("one-time-code"),
              attribute.disabled(form.submission == Sending),
              event.on_input(UserTypedEmailCode),
            ]),
          ),
          layout.details_row([
            layout.dim("Sent to " <> address),
          ]),
          view_refusal(form.submission),
          layout.details_row([
            html.div([attribute.class("inline")], [
              view_submit("Confirm", form.submission, string.trim(code) == ""),
              html.button(
                [
                  attribute.class("action"),
                  attribute.type_("button"),
                  event.on_click(UserCancelledEmailChange),
                ],
                [html.text("Cancel")],
              ),
            ]),
          ]),
        ])
    },
  ])
}

fn view_contact(
  form: ContactForm,
  server: Server,
  handle: String,
) -> Element(Message) {
  let is_sending = form.submission == Sending
  let channels = server.contact_channels
  let awaits_verification = fn(channel: String, username: String) {
    username != ""
    && list.contains(
      form.saved.usernames,
      tranquil.ChannelUsername(channel:, username:, verified: False),
    )
  }

  layout.block([
    html.form([event.on_submit(fn(_) { UserSubmittedContact })], [
      layout.field(
        html.span(
          [attribute.id("preferred-channel"), attribute.class("label")],
          [html.text("Preferred")],
        ),
        html.div(
          [
            attribute.class("choices"),
            attribute.role("radiogroup"),
            attribute.aria_labelledby("preferred-channel"),
          ],
          list.map(channels, fn(channel) {
            html.label([], [
              html.input([
                attribute.type_("radio"),
                attribute.name("preferred-channel"),
                attribute.checked(channel == form.preferred),
                attribute.disabled(is_sending),
                event.on_click(UserPickedChannel(channel)),
              ]),
              html.span([], [html.text(string.capitalise(channel))]),
            ])
          }),
        ),
      ),
      element.fragment(
        list.filter_map(form.usernames, fn(entry) {
          let #(channel, username) = entry
          let id = "username-" <> channel
          let is_verified =
            list.contains(
              form.saved.usernames,
              tranquil.ChannelUsername(channel:, username:, verified: True),
            )

          case list.contains(channels, channel) {
            False -> Error(Nil)
            True ->
              Ok(
                element.fragment([
                  layout.field(
                    html.label([attribute.for(id)], [
                      html.text(string.capitalise(channel)),
                    ]),
                    html.div([attribute.class("inline")], [
                      html.input([
                        attribute.id(id),
                        attribute.type_("text"),
                        attribute.value(username),
                        attribute.autocomplete("off"),
                        attribute.disabled(is_sending),
                        event.on_input(UserTypedUsername(channel, _)),
                      ]),
                      case username, is_verified {
                        "", _ -> element.none()
                        _, True -> layout.dim("verified")
                        _, False -> layout.dim("not verified")
                      },
                    ]),
                  ),
                  case awaits_verification(channel, username) {
                    True -> view_bot_step(channel, server, handle)
                    False -> element.none()
                  },
                ]),
              )
          }
        }),
      ),
      view_refusal(form.submission),
      layout.details_row([view_submit("Save", form.submission, False)]),
    ]),
    case list.key_find(form.usernames, code_channel) {
      Ok(username) ->
        case awaits_verification(code_channel, username) {
          True -> view_code_step(form, username)
          False -> element.none()
        }
      Error(Nil) -> element.none()
    },
  ])
}

fn view_bot_step(
  channel: String,
  server: Server,
  handle: String,
) -> Element(Message) {
  let start = string.replace(handle, each: ".", with: "_")
  let bot = case channel {
    "discord" ->
      option.map(server.discord_bot, fn(bot) {
        #(
          bot,
          option.map(server.discord_app_id, fn(id) {
            "https://discord.com/users/" <> id
          }),
        )
      })
    "telegram" ->
      option.map(server.telegram_bot, fn(bot) {
        #(bot, Some("https://t.me/" <> bot <> "?start=" <> start))
      })
    _ -> None
  }

  case bot {
    None -> element.none()
    Some(#(bot, link)) ->
      layout.hint(
        details: [
          html.text("Send "),
          html.code([], [html.text("/start " <> start)]),
          html.text(" to @" <> bot),
        ],
        actions: case link {
          Some(link) -> [
            html.a(
              [
                attribute.href(link),
                attribute.target("_blank"),
                attribute.rel("noopener"),
              ],
              [html.text("Open " <> string.capitalise(channel))],
            ),
          ]
          None -> []
        },
      )
  }
}

fn view_code_step(form: ContactForm, username: String) -> Element(Message) {
  html.form([event.on_submit(fn(_) { UserSubmittedChannelCode(username) })], [
    layout.field(
      html.label([attribute.for("channel-code")], [html.text("Code")]),
      html.input([
        attribute.id("channel-code"),
        attribute.type_("text"),
        attribute.value(form.code),
        attribute.autocomplete("one-time-code"),
        attribute.disabled(form.confirmation == Sending),
        event.on_input(UserTypedChannelCode),
      ]),
    ),
    layout.details_row([
      layout.dim("Sent to you on " <> string.capitalise(code_channel)),
    ]),
    view_refusal(form.confirmation),
    layout.details_row([
      view_submit("Verify", form.confirmation, string.trim(form.code) == ""),
    ]),
  ])
}

fn view_refusal(submission: Submission) -> Element(Message) {
  case submission {
    Refused(problem:) -> layout.problem(describe_refusal(problem))
    Idle | Sending -> element.none()
  }
}

fn view_submit(
  label: String,
  submission: Submission,
  is_incomplete: Bool,
) -> Element(Message) {
  html.button(
    [
      attribute.class("action primary"),
      attribute.disabled(submission == Sending || is_incomplete),
    ],
    [html.text(label)],
  )
}
