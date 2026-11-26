import at/did.{type Did}
import at/handle.{type Handle}
import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import homestead/browser
import homestead/layout
import homestead/remote.{
  type Remote, type Submission, Failed, Idle, Loaded, Loading, Refused, Sending,
}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
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
    settings: Settings,
    account: Remote(Account),
    server: Remote(Server),
    handle: HandleForm,
    check: Check,
    verification: Verification,
    email: EmailForm,
    contact: Remote(ContactForm),
  )
}

type WellKnown {
  Readable(finding: Finding)
  NoCorsHeader
}

type Check {
  Check(
    verified: Remote(Option(Handle)),
    record: Remote(Finding),
    file: Remote(WellKnown),
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

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      settings:,
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
  SlingshotReturnedHandle(result: Result(Handle, rsvp.Error(String)))
  DnsReturnedRecords(result: Result(Response(BitArray), rsvp.Error(BitArray)))
  HandleHostReturnedFile(
    handle: Handle,
    result: Result(Response(String), rsvp.Error(String)),
  )
  BrowserProbedHandleHost(handle: Handle, probe: browser.Probe)
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
      let #(check, checking) = check_handle(session, model.settings, account)

      #(Model(..model, account:, check:), checking)
    }

    UserClickedCheckHandle -> {
      let #(check, checking) =
        check_handle(session, model.settings, model.account)

      #(Model(..model, check:), checking)
    }

    SlingshotReturnedHandle(result: returned) -> #(
      Model(
        ..model,
        check: Check(
          ..model.check,
          verified: slingshot.verified_handle(returned)
            |> result.map_error(tranquil.error_to_problem(
              _,
              from: "the identity resolver",
            ))
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
          record: record_finding(returned, session.account(session))
            |> remote.from_result,
        ),
      ),
      effect.none(),
    )

    HandleHostReturnedFile(handle:, result: returned) -> {
      case file_finding(returned, session.account(session)) {
        Ok(finding) -> #(
          Model(
            ..model,
            check: Check(..model.check, file: Loaded(Readable(finding:))),
          ),
          effect.none(),
        )
        Error(Nil) -> #(
          model,
          browser.probe(well_known_address(handle), BrowserProbedHandleHost(
            handle,
            _,
          )),
        )
      }
    }

    BrowserProbedHandleHost(handle:, probe:) -> #(
      Model(
        ..model,
        check: Check(..model.check, file: case probe {
          browser.Answered -> Loaded(NoCorsHeader)
          browser.Unanswered ->
            Failed(tranquil.Problem(
              service: handle.to_string(handle),
              reason: tranquil.Unreachable,
            ))
        }),
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
              let #(channel, username) = entry

              !list.any(form.saved.usernames, fn(saved) {
                saved.channel == channel && saved.username == username
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
  settings: Settings,
  account: Remote(Account),
) -> #(Check, Effect(Message)) {
  case account {
    Loaded(value: tranquil.Account(handle:, ..)) -> #(
      Check(verified: Loading, record: Loading, file: Loading),
      effect.batch([
        rsvp.send(
          slingshot.identity_request(
            settings.slingshot,
            session.account(session),
          ),
          rsvp.expect_json(slingshot.handle_decoder(), SlingshotReturnedHandle),
        ),
        rsvp.send_bits(
          record_request(settings.dns, handle),
          rsvp.expect_ok_response(DnsReturnedRecords),
        ),
        rsvp.send(
          handle.resolve(handle),
          rsvp.expect_ok_response(HandleHostReturnedFile(handle, _)),
        ),
      ]),
    )
    Loading -> #(
      Check(verified: Loading, record: Loading, file: Loading),
      effect.none(),
    )
    Failed(problem:) -> #(
      Check(
        verified: Failed(problem:),
        record: Failed(problem:),
        file: Failed(problem:),
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
  case problem.reason {
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
  let contact = {
    use form <- remote.then(model.contact)
    use account <- remote.map(model.account)

    #(form, account)
  }

  layout.page([
    layout.title_section("handle", [
      view_handle(
        model.settings,
        model.handle,
        model.check,
        model.account,
        model.server,
        session.account(model.session),
      ),
    ]),
    layout.section("email", [
      view_email(model.verification, model.email, model.account),
    ]),
    case model.server {
      Loading | Failed(_) -> element.none()
      Loaded(value: server) ->
        case
          list.filter(server.contact_channels, fn(channel) {
            channel != tranquil.Email
          })
        {
          [] -> element.none()
          [_, ..] ->
            layout.section("contact", [
              layout.block({
                use #(form, account) <- layout.rows(contact, placeholders: 2)

                view_contact(form, server, account.handle)
              }),
            ])
        }
    },
  ])
}

fn well_known_address(handle: Handle) -> String {
  handle.resolve(handle) |> request.to_uri |> uri.to_string
}

fn view_handle(
  settings: Settings,
  form: HandleForm,
  check: Check,
  account: Remote(Account),
  server: Remote(Server),
  owner: Did,
) -> Element(Message) {
  let current = case account {
    Loaded(value: account) -> Some(account.handle)
    Loading | Failed(_) -> None
  }
  let resolves = {
    use account <- remote.then(account)
    use verified <- remote.map(check.verified)

    verified == Some(account.handle)
  }
  let is_checking =
    check.verified == Loading
    || check.record == Loading
    || check.file == Loading

  element.fragment([
    layout.block([
      layout.row(
        tone: layout.Plain,
        name: "Handle",
        details: [
          {
            use account <- layout.value(account)

            html.code([], [html.text("@" <> handle.to_string(account.handle))])
          },
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
      view_resolver(
        resolves,
        "Checked with " <> tranquil.server_name(settings.slingshot) <> ".",
      ),
      view_record(
        check.record,
        option.map(current, fn(handle) {
          "TXT "
          <> handle.dns_hostname(handle)
          <> " via "
          <> tranquil.server_name(settings.dns)
          <> "."
        }),
      ),
      view_file(check.file, option.map(current, well_known_address)),
    ]),
    layout.block_apart([
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
            {
              use server <- layout.value(server)
              let domains = list.map(server.handle_domains, ServerDomain)

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
              )
            },
          ]),
        ),
        case form.domain, server {
          OwnDomain, Loaded(_) | OwnDomain, Failed(_) ->
            view_domain_setup(form, owner)
          OwnDomain, Loading | ServerDomain(_), _ -> element.none()
        },
        view_refusal(form.submission),
        layout.details_row([
          view_submit(
            label: "Change",
            submission: form.submission,
            is_incomplete: string.trim(form.name) == "",
          ),
        ]),
      ]),
    ]),
  ])
}

type Mark {
  Confirms
  Contradicts
  Silent
}

fn view_resolver(resolves: Remote(Bool), detail: String) -> Element(Message) {
  let name = "Identity resolver"
  let detail = Some(detail)

  case resolves {
    Loading -> view_pending_check(name)
    Loaded(value: True) ->
      view_check(name, Confirms, "resolves to this account", detail)
    Loaded(value: False) ->
      view_check(name, Contradicts, "doesn't resolve to this account", detail)
    Failed(problem:) ->
      view_check(name, Silent, describe_check_failure(problem), detail)
  }
}

fn view_record(
  record: Remote(Finding),
  detail: Option(String),
) -> Element(Message) {
  let name = "DNS record"

  case record {
    Loading -> view_pending_check(name)
    Failed(problem:) ->
      view_check(name, Silent, describe_check_failure(problem), detail)
    Loaded(value: finding) -> view_finding(name, finding, detail)
  }
}

fn view_file(
  file: Remote(WellKnown),
  address: Option(String),
) -> Element(Message) {
  let name = "Well-known file"

  case file {
    Loading -> view_pending_check(name)
    Failed(problem:) ->
      view_check(name, Silent, describe_check_failure(problem), address)
    Loaded(value: Readable(finding:)) -> view_finding(name, finding, address)
    Loaded(value: NoCorsHeader) ->
      view_check(
        name,
        Silent,
        "no CORS header",
        option.map(address, fn(address) {
          address <> ". The response has no Access-Control-Allow-Origin header."
        }),
      )
  }
}

fn view_finding(
  name: String,
  finding: Finding,
  detail: Option(String),
) -> Element(Message) {
  case finding {
    PointsHere -> view_check(name, Confirms, "points to this account", detail)
    PointsElsewhere ->
      view_check(name, Contradicts, "points to another account", detail)
    Malformed -> view_check(name, Silent, "doesn't contain a DID", detail)
    Absent -> view_check(name, Silent, "not found", detail)
  }
}

fn describe_check_failure(problem: tranquil.Problem) -> String {
  case problem.reason {
    tranquil.Unreachable -> "couldn't reach " <> problem.service
    tranquil.Refused(error:, ..) -> problem.service <> " answered " <> error
    tranquil.NotUnderstood -> "couldn't read " <> problem.service <> "'s answer"
  }
}

fn view_check(
  name: String,
  mark: Mark,
  fact: String,
  detail: Option(String),
) -> Element(Message) {
  let summary = [
    html.span([attribute.class("mark"), attribute.aria_hidden(True)], [
      html.text(case mark {
        Confirms -> "\u{2713}"
        Contradicts -> "\u{2717}"
        Silent -> "\u{2013}"
      }),
    ]),
    html.span([attribute.class("fact")], [html.text(fact)]),
  ]

  layout.row(
    tone: case mark {
      Contradicts -> layout.Warning
      Confirms | Silent -> layout.Plain
    },
    name:,
    details: [
      case detail {
        None -> html.span([attribute.class("check")], summary)
        Some(detail) ->
          html.details([attribute.class("check")], [
            html.summary([], summary),
            html.p([], [html.text(detail)]),
          ])
      },
    ],
    actions: [],
  )
}

fn view_pending_check(name: String) -> Element(Message) {
  layout.row(
    tone: layout.Plain,
    name:,
    details: [layout.pending()],
    actions: [],
  )
}

fn view_domain_setup(form: HandleForm, account: Did) -> Element(Message) {
  let domain = case string.trim(form.name) {
    "" -> "yourdomain.com"
    name -> name
  }
  let identifier = did.to_string(account)
  let record = "did=" <> identifier
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
            code(identifier),
            note(CopiedFileContent),
          ]),
        ]),
      ],
      actions: [copy(identifier, CopiedFileContent)],
    ),
  ])
}

fn view_email(
  verification: Verification,
  form: EmailForm,
  account: Remote(Account),
) -> Element(Message) {
  let unverified = case account {
    Loaded(value: tranquil.Account(email_verified: False, email:, ..)) ->
      Ok(option.unwrap(email, ""))
    Loaded(value: tranquil.Account(email_verified: True, ..))
    | Loading
    | Failed(_) -> Error(Nil)
  }

  layout.block([
    layout.row(
      tone: layout.Plain,
      name: "Email",
      details: [
        {
          use account <- layout.value(account)

          element.fragment([
            html.text(option.unwrap(account.email, "") <> " "),
            layout.dim(case account.email_verified, verification.resending {
              True, _ -> "\u{00B7} verified"
              False, Resent -> "\u{00B7} not verified \u{00B7} code sent"
              False, ResendRefused(_) ->
                "\u{00B7} not verified \u{00B7} couldn't send a code"
              False, NotResent | False, Resending -> "\u{00B7} not verified"
            }),
          ])
        },
      ],
      actions: case unverified {
        Error(Nil) -> []
        Ok(_) -> [
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
    case unverified {
      Error(Nil) -> element.none()
      Ok(address) ->
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
                label: "Verify",
                submission: verification.submission,
                is_incomplete: string.trim(verification.code) == "",
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
              label: "Change",
              submission: form.submission,
              is_incomplete: string.trim(form.new_email) == "",
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
            {
              use account <- layout.value(account)

              layout.dim("Sent to " <> option.unwrap(account.email, ""))
            },
          ]),
          view_refusal(form.submission),
          layout.details_row([
            html.div([attribute.class("inline")], [
              view_submit(
                label: "Confirm",
                submission: form.submission,
                is_incomplete: string.trim(code) == "",
              ),
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
  handle: Handle,
) -> List(Element(Message)) {
  let is_sending = form.submission == Sending
  let channels = server.contact_channels
  let awaits_verification = fn(channel: Channel, username: String) {
    username != ""
    && list.contains(
      form.saved.usernames,
      tranquil.ChannelUsername(channel:, username:, verified: False),
    )
  }

  [
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
      layout.details_row([
        view_submit(
          label: "Save",
          submission: form.submission,
          is_incomplete: False,
        ),
      ]),
    ]),
    case list.key_find(form.usernames, code_channel) {
      Ok(username) ->
        case awaits_verification(code_channel, username) {
          True -> view_code_step(form, username)
          False -> element.none()
        }
      Error(Nil) -> element.none()
    },
  ]
}

fn view_bot_step(
  channel: Channel,
  server: Server,
  handle: Handle,
) -> Element(Message) {
  let start = string.replace(handle.to_string(handle), each: ".", with: "_")
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
      view_submit(
        label: "Verify",
        submission: form.confirmation,
        is_incomplete: string.trim(form.code) == "",
      ),
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
  label label: String,
  submission submission: Submission,
  is_incomplete is_incomplete: Bool,
) -> Element(Message) {
  html.button(
    [
      attribute.class("action primary"),
      attribute.disabled(submission == Sending || is_incomplete),
    ],
    [html.text(label)],
  )
}

const dns_service = "the DNS service"

const text_record = 16

pub type Finding {
  PointsHere
  PointsElsewhere
  Malformed
  Absent
}

pub fn record_request(
  resolver: Request(String),
  handle: Handle,
) -> Request(BitArray) {
  let name =
    string.split(handle.dns_hostname(handle), on: ".")
    |> list.map(fn(label) {
      let length = string.byte_size(label)

      <<length, label:utf8>>
    })
    |> bit_array.concat
  let question = <<
    0:16, 0x0100:16, 1:16, 0:48, name:bits, 0, text_record:16, 1:16,
  >>

  resolver
  |> request.set_query([
    #("dns", bit_array.base64_url_encode(question, False)),
  ])
  |> request.set_header("accept", "application/dns-message")
  |> request.set_body(<<>>)
}

fn text_records(reply: BitArray) -> Result(List(String), Nil) {
  case reply {
    <<_:24, flags, questions:16, answers:16, _:32, rest:bytes>> ->
      case int.bitwise_and(flags, 15) {
        0 | 3 -> {
          use rest <- result.try(skip_questions(rest, questions))

          read_answers(rest, answers, [])
        }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn skip_questions(data: BitArray, count: Int) -> Result(BitArray, Nil) {
  case count, skip_name(data) {
    0, _ -> Ok(data)
    _, Ok(<<_:32, rest:bytes>>) -> skip_questions(rest, count - 1)
    _, Ok(_) | _, Error(Nil) -> Error(Nil)
  }
}

fn skip_name(data: BitArray) -> Result(BitArray, Nil) {
  case data {
    <<0, rest:bytes>> -> Ok(rest)
    <<first, _, rest:bytes>> if first >= 192 -> Ok(rest)
    <<length, _:bytes-size(length), rest:bytes>> -> skip_name(rest)
    _ -> Error(Nil)
  }
}

fn read_answers(
  data: BitArray,
  count: Int,
  found: List(String),
) -> Result(List(String), Nil) {
  case count, skip_name(data) {
    0, _ -> Ok(list.reverse(found))
    _, Ok(<<kind:16, _:48, length:16, value:bytes-size(length), rest:bytes>>) ->
      case kind == text_record {
        True -> {
          use text <- result.try(read_text(value, ""))

          read_answers(rest, count - 1, [text, ..found])
        }
        False -> read_answers(rest, count - 1, found)
      }
    _, Ok(_) | _, Error(Nil) -> Error(Nil)
  }
}

fn read_text(value: BitArray, read: String) -> Result(String, Nil) {
  case value {
    <<>> -> Ok(read)
    <<length, part:bytes-size(length), rest:bytes>> -> {
      use part <- result.try(bit_array.to_string(part))

      read_text(rest, read <> part)
    }
    _ -> Error(Nil)
  }
}

pub fn record_finding(
  result: Result(Response(BitArray), rsvp.Error(BitArray)),
  account: Did,
) -> Result(Finding, tranquil.Problem) {
  use response <- result.try(
    result.map_error(result, tranquil.error_to_problem(_, from: dns_service)),
  )
  use records <- result.map(
    text_records(response.body)
    |> result.replace_error(tranquil.Problem(
      service: dns_service,
      reason: tranquil.NotUnderstood,
    )),
  )

  case did.from_txt_records(records) {
    Ok(named) if named == account -> PointsHere
    Ok(_) -> PointsElsewhere
    Error(Nil) -> Absent
  }
}

pub fn file_finding(
  result: Result(Response(String), rsvp.Error(String)),
  account: Did,
) -> Result(Finding, Nil) {
  case result {
    Ok(response) ->
      Ok(case did.from_string(string.trim(response.body)) {
        Ok(named) if named == account -> PointsHere
        Ok(_) -> PointsElsewhere
        Error(Nil) -> Malformed
      })
    Error(rsvp.HttpError(_)) -> Ok(Absent)
    Error(rsvp.BadBody)
    | Error(rsvp.JsonError(_))
    | Error(rsvp.UnhandledResponse(_)) -> Ok(Malformed)
    Error(rsvp.NetworkError) | Error(rsvp.BadUrl(_)) -> Error(Nil)
  }
}
