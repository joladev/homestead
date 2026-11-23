import gleam/list
import homestead/browser
import homestead/dialog
import homestead/remote.{
  type Remote, type Submission, Failed, Idle, Loaded, Loading, Refused, Sending,
}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem, type SignInAgainMethod}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const dialog_id = "sign-in-again"

const secret_id = "sign-in-again-secret"

pub opaque type Model {
  Model(
    session: Session,
    methods: Remote(List(SignInAgainMethod)),
    method: SignInAgainMethod,
    secret: String,
    submission: Submission,
    outcome: Outcome,
  )
}

pub type Outcome {
  Waiting
  Confirmed
  Cancelled
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      methods: Loading,
      method: tranquil.Password,
      secret: "",
      submission: Idle,
      outcome: Waiting,
    ),
    effect.batch([
      dialog.open(dialog_id),
      tranquil.load(
        session,
        tranquil.sign_in_again_methods(),
        ServerReturnedMethods,
      ),
    ]),
  )
}

pub fn outcome(model: Model) -> Outcome {
  model.outcome
}

pub opaque type Message {
  ServerReturnedMethods(result: Result(List(SignInAgainMethod), Problem))
  UserPickedMethod(method: SignInAgainMethod)
  UserTypedSecret(secret: String)
  UserSubmittedSecret
  ServerConfirmedSignIn(result: Result(Nil, Problem))
  UserCancelled
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedMethods(result:) -> {
      let methods = remote.from_result(result)
      let method = case methods {
        Loaded(value: [method, ..]) -> method
        Loaded(value: []) | Loading | Failed(_) -> model.method
      }

      #(Model(..model, methods:, method:), browser.focus(secret_id))
    }

    UserPickedMethod(method:) -> #(
      Model(..model, method:, secret: "", submission: Idle),
      browser.focus(secret_id),
    )

    UserTypedSecret(secret:) -> #(
      Model(..model, secret:, submission: Idle),
      effect.none(),
    )

    UserSubmittedSecret -> #(
      Model(..model, submission: Sending),
      tranquil.perform(
        model.session,
        case model.method {
          tranquil.Password ->
            tranquil.sign_in_again_with_password(model.secret)
          tranquil.AuthenticatorCode ->
            tranquil.sign_in_again_with_code(model.secret)
        },
        ServerConfirmedSignIn,
      ),
    )

    ServerConfirmedSignIn(result: Ok(Nil)) -> #(
      Model(..model, outcome: Confirmed),
      effect.none(),
    )

    ServerConfirmedSignIn(result: Error(problem)) -> #(
      Model(..model, submission: Refused(problem:)),
      browser.focus(secret_id),
    )

    UserCancelled -> #(Model(..model, outcome: Cancelled), effect.none())
  }
}

pub fn view(model: Model) -> Element(Message) {
  let cancel =
    html.button(
      [
        attribute.class("action"),
        attribute.type_("button"),
        event.on_click(UserCancelled),
      ],
      [html.text("Cancel")],
    )

  dialog.view(
    id: dialog_id,
    title: "sign in again",
    on_cancel: UserCancelled,
    content: case model.methods {
      Loading -> [dialog.actions([cancel])]

      Failed(_) -> [dialog.problem("Couldn't load"), dialog.actions([cancel])]

      Loaded(value: []) -> {
        let server = session.server(model.session)

        [
          html.p([], [
            html.text("This needs a passkey, which only works on " <> server),
          ]),
          dialog.actions([
            cancel,
            html.a([attribute.href("https://" <> server <> "/app/security")], [
              html.text("Open " <> server),
            ]),
          ]),
        ]
      }

      Loaded(value: methods) -> [
        html.form([event.on_submit(fn(_) { UserSubmittedSecret })], [
          case methods {
            [_, _, ..] -> view_methods(methods, model.method)
            [] | [_] -> element.none()
          },
          view_secret(model),
          case model.submission {
            Refused(problem:) -> dialog.problem(describe_refusal(problem))
            Idle | Sending -> element.none()
          },
          dialog.actions([
            cancel,
            html.button(
              [
                attribute.class("action primary"),
                attribute.disabled(
                  model.submission == Sending || model.secret == "",
                ),
              ],
              [html.text("Continue")],
            ),
          ]),
        ]),
      ]
    },
  )
}

fn view_methods(
  methods: List(SignInAgainMethod),
  picked: SignInAgainMethod,
) -> Element(Message) {
  html.div(
    [
      attribute.class("choices"),
      attribute.role("radiogroup"),
      attribute.aria_label("Sign in with"),
    ],
    list.map(methods, fn(method) {
      html.label([], [
        html.input([
          attribute.type_("radio"),
          attribute.name("sign-in-again-method"),
          attribute.checked(method == picked),
          event.on_click(UserPickedMethod(method)),
        ]),
        html.span([], [
          html.text(case method {
            tranquil.Password -> "Password"
            tranquil.AuthenticatorCode -> "Authenticator code"
          }),
        ]),
      ])
    }),
  )
}

fn view_secret(model: Model) -> Element(Message) {
  let id = secret_id
  let shared = [
    attribute.id(id),
    attribute.value(model.secret),
    attribute.disabled(model.submission == Sending),
    event.on_input(UserTypedSecret),
  ]

  case model.method {
    tranquil.Password ->
      dialog.field(
        id:,
        label: "Password",
        control: html.input([
          attribute.type_("password"),
          attribute.autocomplete("current-password"),
          ..shared
        ]),
      )
    tranquil.AuthenticatorCode ->
      dialog.field(
        id:,
        label: "Authenticator code",
        control: html.input([
          attribute.type_("text"),
          attribute.inputmode("numeric"),
          attribute.autocomplete("one-time-code"),
          ..shared
        ]),
      )
  }
}

fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("InvalidPassword", _) -> "That password isn't right"
    tranquil.Refused("InvalidCode", _) -> "That code isn't right"
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}
