import at/did
import at/handle
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import homestead/browser
import homestead/handle_check.{type Finding}
import homestead/layout
import homestead/remote.{
  type Remote, type Submission, Failed, Idle, Loaded, Loading, Refused, Sending,
}
import homestead/session.{type Session}
import homestead/slingshot
import homestead/tranquil.{
  type Account, type Channel, type ContactPreferences, type Problem, type Server,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

const code_channel = tranquil.Signal

pub opaque type Model {
  Model(
    session: Session,
    account: Remote(Account),
    server: Remote(Server),
    handle: HandleForm,
    check: Check,
    verification: Verification,
    email: EmailForm,
    contact: Remote(ContactForm),
  )
}

type Check {
  Check(
    verified: Remote(Option(String)),
    record: Remote(Finding),
    file: Remote(Finding),
  )
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
    preferred: Channel,
    usernames: List(#(Channel, String)),
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
      check: Check(verified: Loading, record: Loading, file: Loading),
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

pub opaque type Message {
  ServerReturnedAccount(result: Result(Account, Problem))
  ServerReturnedServer(result: Result(Server, Problem))
  ServerReturnedContact(result: Result(ContactPreferences, Problem))
  UserTypedHandle(name: String)
  UserPickedDomain(domain: Domain)
  UserSubmittedHandle
  ServerChangedHandle(result: Result(Nil, Problem))
  UserClickedCheckHandle
  SlingshotReturnedHandle(result: Result(String, rsvp.Error(String)))
  DnsReturnedRecords(result: Result(Response(String), rsvp.Error(String)))
  HandleHostReturnedFile(result: Result(Response(String), rsvp.Error(String)))
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
  UserPickedChannel(channel: Channel)
  UserTypedUsername(channel: Channel, username: String)
  UserSubmittedContact
  ServerUpdatedContact(result: Result(Nil, Problem))
  UserTypedChannelCode(code: String)
  UserSubmittedChannelCode(username: String)
  ServerConfirmedChannel(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedAccount(result:) -> {
      let account = remote.from_result(result)
      let #(check, checking) = check_handle(session, account)

      #(Model(..model, account:, check:), checking)
    }

    UserClickedCheckHandle -> {
      let #(check, checking) = check_handle(session, model.account)

      #(Model(..model, check:), checking)
    }

    SlingshotReturnedHandle(result: returned) -> #(
      Model(
        ..model,
        check: Check(
          ..model.check,
          verified: handle_check.verified_handle(returned)
            |> result.replace_error(tranquil.Unreachable)
            |> remote.from_result,
        ),
      ),
      effect.none(),
    )

    DnsReturnedRecords(result: returned) -> #(
      Model(
        ..model,
        check: Check(
          ..model.check,
          record: handle_check.record_finding(
              returned,
              session.account(session),
            )
            |> result.replace_error(tranquil.Unreachable)
            |> remote.from_result,
        ),
      ),
      effect.none(),
    )

    HandleHostReturnedFile(result: returned) -> #(
      Model(
        ..model,
        check: Check(
          ..model.check,
          file: Loaded(handle_check.file_finding(
            returned,
            session.account(session),
          )),
        ),
      ),
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

fn check_handle(
  session: Session,
  account: Remote(Account),
) -> #(Check, Effect(Message)) {
  let handle = case account {
    Loaded(value: account) -> handle.from_string(account.handle)
    Loading | Failed(_) -> Error(Nil)
  }

  case handle {
    Ok(handle) -> #(
      Check(verified: Loading, record: Loading, file: Loading),
      effect.batch([
        rsvp.send(
          slingshot.identity_request(session.account(session)),
          rsvp.expect_json(slingshot.handle_decoder(), SlingshotReturnedHandle),
        ),
        rsvp.send(
          handle_check.record_request(handle),
          rsvp.expect_ok_response(DnsReturnedRecords),
        ),
        rsvp.send(
          handle.resolve(handle),
          rsvp.expect_ok_response(HandleHostReturnedFile),
        ),
      ]),
    )
    Error(Nil) -> #(
      Check(
        verified: Failed(tranquil.NotUnderstood),
        record: Failed(tranquil.NotUnderstood),
        file: Failed(tranquil.NotUnderstood),
      ),
      effect.none(),
    )
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
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view(model: Model) -> Element(Message) {
  case model.account {
    Loading -> layout.page([layout.loading_section()])

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
            model.check,
            account,
            model.server,
            did.to_string(session.account(model.session)),
          ),
        ]),
        layout.section("email", [
          view_email(model.verification, model.email, account),
        ]),
        case model.server, model.contact {
          Loaded(value: server), Loaded(value: form) ->
            case
              list.filter(server.contact_channels, fn(channel) {
                channel != tranquil.Email
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
  check: Check,
  account: Account,
  server: Remote(Server),
  did: String,
) -> Element(Message) {
  let domains = case server {
    Loaded(value: server) ->
      list.map(server.handle_domains, fn(domain) { ServerDomain(domain:) })
    Loading | Failed(_) -> []
  }

  let resolves =
    remote.map(check.verified, fn(verified) { verified == Some(account.handle) })
  let is_checking =
    check.verified == Loading
    || check.record == Loading
    || check.file == Loading

  layout.block([
    layout.row(
      tone: case resolves {
        Loaded(value: False) -> layout.Warning
        Loading | Loaded(value: True) | Failed(_) -> layout.Plain
      },
      name: "Handle",
      details: [
        html.span([attribute.class("lines")], [
          html.code([], [html.text("@" <> account.handle)]),
          case resolves {
            Loading -> layout.pending()
            Loaded(value: True) -> layout.dim("Resolves to this account")
            Loaded(value: False) ->
              html.span([], [html.text("Doesn't resolve to this account")])
            Failed(_) -> layout.dim("Couldn't check whether it resolves")
          },
          view_finding("DNS record", check.record),
          view_finding("File", check.file),
        ]),
      ],
      actions: [
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            attribute.disabled(is_checking),
            event.on_click(UserClickedCheckHandle),
          ],
          [html.text("Check again")],
        ),
      ],
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

fn view_finding(subject: String, finding: Remote(Finding)) -> Element(Message) {
  case finding {
    Loading -> layout.pending()
    Failed(_) -> layout.dim(subject <> " couldn't be checked")
    Loaded(value: handle_check.PointsHere) ->
      layout.dim(subject <> " points to this account")
    Loaded(value: handle_check.PointsElsewhere) ->
      layout.dim(subject <> " points to another account")
    Loaded(value: handle_check.Malformed) ->
      layout.dim(subject <> " doesn't contain a DID")
    Loaded(value: handle_check.Absent) -> layout.dim(subject <> " not found")
    Loaded(value: handle_check.Unreadable) ->
      layout.dim(subject <> " can't be read from a browser")
  }
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
  let awaits_verification = fn(channel: Channel, username: String) {
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
              html.span([], [html.text(tranquil.channel_label(channel))]),
            ])
          }),
        ),
      ),
      element.fragment(
        list.filter_map(form.usernames, fn(entry) {
          let #(channel, username) = entry
          let id = "username-" <> tranquil.channel_name(channel)
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
                      html.text(tranquil.channel_label(channel)),
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
  channel: Channel,
  server: Server,
  handle: String,
) -> Element(Message) {
  let start = string.replace(handle, each: ".", with: "_")
  let bot = case channel {
    tranquil.Discord ->
      option.map(server.discord_bot, fn(bot) {
        #(
          bot,
          option.map(server.discord_app_id, fn(id) {
            "https://discord.com/users/" <> id
          }),
        )
      })
    tranquil.Telegram ->
      option.map(server.telegram_bot, fn(bot) {
        #(bot, Some("https://t.me/" <> bot <> "?start=" <> start))
      })
    tranquil.Email | tranquil.Signal | tranquil.OtherChannel(_) -> None
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
              [html.text("Open " <> tranquil.channel_label(channel))],
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
      layout.dim("Sent to you on " <> tranquil.channel_label(code_channel)),
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
