import at/did.{type Did}
import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/browser
import homestead/session.{type Attempt}
import homestead/setting.{type PasswordEntry, HomesteadFirst, ServerFirst}
import homestead/tranquil.{
  type Channel, type Problem, type Server, type SignInStep,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem

const password_id = "sign-in-password"

const code_id = "sign-in-code"

const server_page_id = "sign-in-server-page"

const verification_wait_milliseconds = 3000

pub opaque type Model {
  Model(
    account: Did,
    name: String,
    server: Request(String),
    password: String,
    step: Step,
    progress: Progress,
    is_cancelled: Bool,
  )
}

type Step {
  Choosing
  Password
  Code(request: String, source: CodeSource, code: String)
  Verification(
    channel: Channel,
    description: Option(Server),
    code: String,
    is_resent: Bool,
  )
}

type CodeSource {
  Authenticator
  SentOver(channel: String)
}

type Progress {
  Idle
  Working
  Stopped(trouble: Trouble)
}

type Trouble {
  NotPrepared
  TookTooLong
  Refused(problem: Problem)
}

pub type Unverified {
  Unverified(
    account: Did,
    name: String,
    server: Request(String),
    description: Server,
    channel: Channel,
    password: String,
  )
}

pub fn init(
  account account: Did,
  name name: String,
  server server: Request(String),
  leading leading: PasswordEntry,
) -> #(Model, Effect(Message)) {
  let model =
    Model(
      account:,
      name:,
      server:,
      password: "",
      step: Choosing,
      progress: Idle,
      is_cancelled: False,
    )

  case leading {
    ServerFirst -> #(model, browser.focus(server_page_id))
    HomesteadFirst -> #(
      Model(..model, step: Password),
      browser.focus(password_id),
    )
  }
}

pub fn verify(unverified: Unverified) -> #(Model, Effect(Message)) {
  let Unverified(account:, name:, server:, description:, channel:, password:) =
    unverified

  #(
    Model(
      account:,
      name:,
      server:,
      password:,
      step: Verification(
        channel:,
        description: Some(description),
        code: "",
        is_resent: False,
      ),
      progress: Idle,
      is_cancelled: False,
    ),
    effect.batch([browser.focus(code_id), wait_for_verification()]),
  )
}

pub fn is_cancelled(model: Model) -> Bool {
  model.is_cancelled
}

pub opaque type Message {
  UserTypedPassword(password: String)
  UserSubmittedPassword
  ServerPreparedRequest(result: Result(Attempt, session.Problem))
  ServerAnsweredSignIn(request: String, result: Result(SignInStep, Problem))
  UserTypedCode(code: String)
  UserSubmittedCode
  ServerConfirmedAccount(result: Result(String, Problem))
  ServerClosedSession(result: Result(Nil, Problem))
  UserAskedForNewCode
  ServerSentNewCode(result: Result(Nil, Problem))
  BrowserWaitedForVerification
  ServerReturnedVerification(result: Result(Bool, Problem))
  ServerDescribedItself(result: Result(Server, Problem))
  UserChoseServerPage
  UserChoseForm
  ServerPreparedServerPage(result: Result(Attempt, session.Problem))
  UserChoseAnotherAccount
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserTypedPassword(password:) -> #(
      Model(..model, password:, progress: Idle),
      effect.none(),
    )

    UserSubmittedPassword -> sign_in(model)

    ServerPreparedRequest(result: Ok(attempt)) -> #(
      model,
      tranquil.enter_password(
        model.server,
        attempt.request,
        model.account,
        model.password,
        ServerAnsweredSignIn(attempt.request, _),
      ),
    )

    ServerPreparedRequest(result: Error(_))
    | ServerPreparedServerPage(result: Error(_)) -> #(
      Model(..model, progress: Stopped(NotPrepared)),
      effect.none(),
    )

    ServerAnsweredSignIn(request:, result: Ok(step)) ->
      take_step(model, request, step)

    ServerAnsweredSignIn(result: Error(problem), ..) -> refuse(model, problem)

    UserTypedCode(code:) -> {
      let step = case model.step {
        Choosing | Password -> model.step
        Code(..) as step -> Code(..step, code:)
        Verification(..) as step -> Verification(..step, code:)
      }

      #(Model(..model, step:, progress: Idle), effect.none())
    }

    UserSubmittedCode ->
      case model.step {
        Choosing | Password -> #(model, effect.none())

        Code(request:, code:, ..) -> #(
          Model(..model, progress: Working),
          tranquil.submit(
            model.server,
            tranquil.enter_code(request, string.trim(code)),
            ServerAnsweredSignIn(request, _),
          ),
        )

        Verification(code:, ..) -> #(
          Model(..model, progress: Working),
          tranquil.submit(
            model.server,
            tranquil.confirm_sign_up(model.account, string.trim(code)),
            ServerConfirmedAccount,
          ),
        )
      }

    ServerConfirmedAccount(result: Ok(token)) -> {
      let #(model, effect) = sign_in(model)

      #(
        model,
        effect.batch([
          tranquil.close_session(model.server, token, ServerClosedSession),
          effect,
        ]),
      )
    }

    ServerConfirmedAccount(result: Error(problem))
    | ServerSentNewCode(result: Error(problem)) -> #(
      Model(..model, progress: Stopped(Refused(problem:))),
      effect.none(),
    )

    ServerClosedSession(_) -> #(model, effect.none())

    UserAskedForNewCode -> #(
      Model(..model, progress: Working),
      tranquil.submit(
        model.server,
        tranquil.resend_verification(model.account),
        ServerSentNewCode,
      ),
    )

    ServerSentNewCode(result: Ok(Nil)) -> {
      let step = case model.step {
        Verification(..) as step -> Verification(..step, is_resent: True)
        Choosing | Password | Code(..) -> model.step
      }

      #(Model(..model, step:, progress: Idle), browser.focus(code_id))
    }

    BrowserWaitedForVerification ->
      case model.step, model.progress {
        Verification(channel:, ..), Idle
        | Verification(channel:, ..), Stopped(_)
        -> #(
          model,
          tranquil.submit(
            model.server,
            tranquil.is_verified(model.account, channel),
            ServerReturnedVerification,
          ),
        )
        Verification(..), Working -> #(model, wait_for_verification())
        Choosing, _ | Password, _ | Code(..), _ -> #(model, effect.none())
      }

    ServerReturnedVerification(result:) ->
      case model.step, model.progress, result {
        Verification(..), Idle, Ok(True)
        | Verification(..), Stopped(_), Ok(True)
        -> {
          let #(model, effect) = sign_in(model)

          #(model, effect.batch([wait_for_verification(), effect]))
        }
        Verification(..), _, _ -> #(model, wait_for_verification())
        Choosing, _, _ | Password, _, _ | Code(..), _, _ -> #(
          model,
          effect.none(),
        )
      }

    ServerDescribedItself(result:) -> {
      let step = case model.step, result {
        Verification(..) as step, Ok(description) ->
          Verification(..step, description: Some(description))
        Verification(..), Error(_) | Choosing, _ | Password, _ | Code(..), _ ->
          model.step
      }

      #(Model(..model, step:), effect.none())
    }

    UserChoseServerPage -> #(
      Model(..model, progress: Working),
      prepare_server_page(model),
    )

    UserChoseForm -> #(
      Model(..model, step: Password, progress: Idle),
      browser.focus(password_id),
    )

    ServerPreparedServerPage(result: Ok(attempt)) -> #(
      model,
      modem.load(attempt.server_page),
    )

    UserChoseAnotherAccount -> #(
      Model(..model, is_cancelled: True),
      effect.none(),
    )
  }
}

fn sign_in(model: Model) -> #(Model, Effect(Message)) {
  #(
    Model(..model, progress: Working),
    browser.await(fn() { session.begin(model.account) }, ServerPreparedRequest),
  )
}

fn prepare_server_page(model: Model) -> Effect(Message) {
  browser.await(fn() { session.begin(model.account) }, ServerPreparedServerPage)
}

fn wait_for_verification() -> Effect(Message) {
  browser.after(verification_wait_milliseconds, BrowserWaitedForVerification)
}

fn take_step(
  model: Model,
  request: String,
  step: SignInStep,
) -> #(Model, Effect(Message)) {
  case step {
    tranquil.SignedIn(continue:) -> #(model, modem.load(continue))

    tranquil.NeedsApproval -> #(
      model,
      tranquil.submit(
        model.server,
        tranquil.approve(request, session.scopes),
        ServerAnsweredSignIn(request, _),
      ),
    )

    tranquil.NeedsAuthenticatorCode ->
      ask_for_code(model, request, Authenticator)

    tranquil.NeedsSentCode(channel:) ->
      ask_for_code(model, request, SentOver(channel:))

    tranquil.NeedsServerPage -> #(model, prepare_server_page(model))

    tranquil.NeedsVerification(channel:) ->
      case model.step {
        Verification(..) -> #(Model(..model, progress: Idle), effect.none())
        Choosing | Password | Code(..) -> #(
          Model(
            ..model,
            step: Verification(
              channel:,
              description: None,
              code: "",
              is_resent: False,
            ),
            progress: Idle,
          ),
          effect.batch([
            browser.focus(code_id),
            wait_for_verification(),
            tranquil.ask(model.server, tranquil.server(), ServerDescribedItself),
          ]),
        )
      }
  }
}

fn ask_for_code(
  model: Model,
  request: String,
  source: CodeSource,
) -> #(Model, Effect(Message)) {
  #(
    Model(..model, step: Code(request:, source:, code: ""), progress: Idle),
    browser.focus(code_id),
  )
}

fn refuse(model: Model, problem: Problem) -> #(Model, Effect(Message)) {
  case model.step, problem {
    Code(..), tranquil.Refused("invalid_request", _) -> #(
      Model(..model, step: Password, progress: Stopped(TookTooLong)),
      browser.focus(password_id),
    )

    Code(..), tranquil.Refused("access_denied", _) -> #(
      Model(..model, step: Password, progress: Stopped(Refused(problem:))),
      browser.focus(password_id),
    )

    Code(..), tranquil.Refused(_, _)
    | Code(..), tranquil.Unreachable
    | Code(..), tranquil.NotUnderstood
    -> #(
      Model(..model, progress: Stopped(Refused(problem:))),
      browser.focus(code_id),
    )

    Choosing, _ | Password, _ -> #(
      Model(..model, step: Password, progress: Stopped(Refused(problem:))),
      browser.focus(password_id),
    )

    Verification(..), _ -> #(
      Model(..model, progress: Stopped(Refused(problem:))),
      effect.none(),
    )
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  let is_working = model.progress == Working
  let server = tranquil.server_name(model.server)
  let another_account =
    html.button(
      [
        attribute.class("action"),
        attribute.type_("button"),
        attribute.disabled(is_working),
        event.on_click(UserChoseAnotherAccount),
      ],
      [html.text("Use another account")],
    )

  let on_server =
    html.button(
      [
        attribute.class("action"),
        attribute.type_("button"),
        attribute.disabled(is_working),
        event.on_click(UserChoseServerPage),
      ],
      [html.text("Sign in on " <> server <> " instead")],
    )

  case model.step {
    Choosing -> [
      html.h2([], [html.text("Sign in")]),
      view_account(model, server),
      html.p([], [
        html.text(
          "Signing in on " <> server <> " keeps your password off this site.",
        ),
      ]),
      html.div([attribute.class("ways")], [
        html.button(
          [
            attribute.id(server_page_id),
            attribute.class("button"),
            attribute.type_("button"),
            attribute.disabled(is_working),
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
            attribute.disabled(is_working),
            event.on_click(UserChoseForm),
          ],
          [html.text("Enter your password here")],
        ),
        another_account,
      ]),
      view_progress(model.progress, "Going to " <> server <> "…"),
    ]

    Password -> [
      html.h2([], [html.text("Sign in")]),
      view_account(model, server),
      html.form([event.on_submit(fn(_) { UserSubmittedPassword })], [
        html.input([
          attribute.type_("text"),
          attribute.name("username"),
          attribute.autocomplete("username"),
          attribute.value(model.name),
          attribute.readonly(True),
          attribute.hidden(True),
        ]),
        html.label([attribute.for(password_id)], [html.text("Password")]),
        html.div([attribute.class("field")], [
          html.input([
            attribute.id(password_id),
            attribute.name("password"),
            attribute.type_("password"),
            attribute.autocomplete("current-password"),
            attribute.value(model.password),
            attribute.disabled(is_working),
            event.on_input(UserTypedPassword),
          ]),
          html.button(
            [
              attribute.class("button"),
              attribute.disabled(is_working || model.password == ""),
            ],
            [html.text("Sign in")],
          ),
        ]),
      ]),
      html.div([attribute.class("ways")], [on_server, another_account]),
      view_progress(model.progress, "Signing in…"),
    ]

    Code(source:, code:, ..) -> [
      html.h2([], [html.text("Sign in")]),
      view_account(model, server),
      html.form([event.on_submit(fn(_) { UserSubmittedCode })], [
        html.label([attribute.for(code_id)], [
          html.text(case source {
            Authenticator -> "Authenticator or backup code"
            SentOver(channel:) -> "Code sent to your " <> channel
          }),
        ]),
        html.div([attribute.class("field")], [
          html.input([
            attribute.id(code_id),
            attribute.name("code"),
            attribute.type_("text"),
            attribute.autocomplete("one-time-code"),
            attribute.autocapitalize("none"),
            attribute.spellcheck(False),
            attribute.value(code),
            attribute.disabled(is_working),
            event.on_input(UserTypedCode),
          ]),
          html.button(
            [
              attribute.class("button"),
              attribute.disabled(is_working || string.trim(code) == ""),
            ],
            [html.text("Sign in")],
          ),
        ]),
      ]),
      html.div([attribute.class("ways")], [another_account]),
      view_progress(model.progress, "Signing in…"),
    ]

    Verification(channel:, description:, code:, is_resent:) -> [
      html.h2([], [html.text("Verify your account")]),
      view_account(model, server),
      html.p([], [
        html.text(case channel {
          tranquil.Discord | tranquil.Telegram ->
            "Message the bot to verify, or paste the code you were sent."
          tranquil.Email | tranquil.Signal | tranquil.OtherChannel(_) ->
            "A code was sent to your "
            <> tranquil.channel_name(channel)
            <> ". Paste it here, or open the link in that message."
        }),
      ]),
      view_bot(channel, description, model.name),
      html.form([event.on_submit(fn(_) { UserSubmittedCode })], [
        html.label([attribute.for(code_id)], [html.text("Code")]),
        html.div([attribute.class("field")], [
          html.input([
            attribute.id(code_id),
            attribute.name("code"),
            attribute.type_("text"),
            attribute.autocomplete("one-time-code"),
            attribute.autocapitalize("none"),
            attribute.spellcheck(False),
            attribute.value(code),
            attribute.disabled(is_working),
            event.on_input(UserTypedCode),
          ]),
          html.button(
            [
              attribute.class("button"),
              attribute.disabled(is_working || string.trim(code) == ""),
            ],
            [html.text("Verify")],
          ),
        ]),
      ]),
      html.div([attribute.class("ways")], [
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            attribute.disabled(is_working),
            event.on_click(UserAskedForNewCode),
          ],
          [html.text("Send a new code")],
        ),
        another_account,
      ]),
      case is_resent, model.progress {
        True, Idle ->
          html.div([attribute.class("lookup"), attribute.aria_live("polite")], [
            html.p([], [html.text("A new code was sent.")]),
          ])
        True, Working | True, Stopped(_) | False, _ ->
          view_progress(model.progress, "Working…")
      },
    ]
  }
}

fn view_account(model: Model, server: String) -> Element(message) {
  html.p([attribute.class("signing-in-as")], [
    html.code([], [html.text(model.name)]),
    html.text(" on " <> server),
  ])
}

fn view_bot(
  channel: Channel,
  description: Option(Server),
  name: String,
) -> Element(message) {
  let start = string.replace(name, each: ".", with: "_")
  let instruction = fn(bot, link) {
    html.p([], [
      html.text("Send "),
      html.code([], [html.text("/start " <> start)]),
      html.text(" to @" <> bot <> ". "),
      case link {
        Some(link) ->
          html.a(
            [
              attribute.href(link),
              attribute.target("_blank"),
              attribute.rel("noopener"),
            ],
            [html.text("Open " <> tranquil.channel_label(channel))],
          )
        None -> element.none()
      },
    ])
  }

  case channel, description {
    tranquil.Discord,
      Some(tranquil.Server(discord_bot: Some(bot), ..) as server)
    ->
      instruction(
        bot,
        option.map(server.discord_app_id, fn(id) {
          "https://discord.com/users/" <> id
        }),
      )
    tranquil.Telegram, Some(tranquil.Server(telegram_bot: Some(bot), ..)) ->
      instruction(bot, Some("https://t.me/" <> bot <> "?start=" <> start))
    tranquil.Discord, _
    | tranquil.Telegram, _
    | tranquil.Email, _
    | tranquil.Signal, _
    | tranquil.OtherChannel(_), _
    -> element.none()
  }
}

fn view_progress(progress: Progress, working: String) -> Element(message) {
  html.div(
    [attribute.class("lookup"), attribute.aria_live("polite")],
    case progress {
      Idle -> []
      Working -> [html.p([], [html.text(working)])]
      Stopped(trouble:) -> [
        html.h3([attribute.class("attention")], [html.text(describe(trouble))]),
      ]
    },
  )
}

fn describe(trouble: Trouble) -> String {
  case trouble {
    NotPrepared -> "Couldn't start signing in on that server."
    TookTooLong -> "That took too long. Sign in again."
    Refused(problem: tranquil.Refused(
      "access_denied",
      "Invalid identifier or password.",
    )) -> "That password isn't right."
    Refused(problem: tranquil.Refused("invalid_code", _))
    | Refused(problem: tranquil.Refused(
        "InvalidRequest",
        "Invalid verification code",
      )) -> "That code isn't right."
    Refused(problem: tranquil.Refused("ExpiredToken", _)) ->
      "That code has expired. Send a new one."
    Refused(problem:) -> tranquil.describe_failed_load(problem)
  }
}
