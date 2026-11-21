import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri.{Uri}
import homestead/browser
import homestead/confirmation
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/sessions
import homestead/tranquil.{type Problem, type RememberedApp}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    sessions: sessions.Model,
    remembered: Remembered,
    forgetting: Forgetting,
  )
}

type Forgetting {
  NotForgetting
  ConfirmingForget(app: RememberedApp)
  Forgetting
}

type Remembered {
  NotSupported
  Remembered(apps: Remote(List(RememberedApp)))
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  let #(sessions, effect) = sessions.init(session, sessions.ThroughApps)

  #(
    Model(
      session:,
      sessions:,
      remembered: Remembered(apps: Loading),
      forgetting: NotForgetting,
    ),
    effect.batch([
      effect.map(effect, SessionsProducedMessage),
      load_remembered(session),
    ]),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  case sessions.departure(model.sessions), model.remembered {
    Some(departure), _ -> Some(departure)
    None, Remembered(apps: Failed(tranquil.SessionEnded)) -> Some(session.Ended)
    None, Remembered(_) | None, NotSupported -> None
  }
}

pub opaque type Message {
  SessionsProducedMessage(sessions.Message)
  ServerReturnedRememberedApps(result: Result(List(RememberedApp), Problem))
  UserClickedForget(app: RememberedApp)
  UserCancelledForget(app: RememberedApp)
  UserConfirmedForget(app: RememberedApp)
  ServerForgotApp(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    SessionsProducedMessage(message) -> {
      let #(sessions, effect) = sessions.update(model.sessions, message)

      #(Model(..model, sessions:), effect.map(effect, SessionsProducedMessage))
    }

    ServerReturnedRememberedApps(result: Error(tranquil.Refused(
      "MethodNotImplemented",
    ))) -> #(Model(..model, remembered: NotSupported), effect.none())

    ServerReturnedRememberedApps(result:) -> #(
      Model(
        ..model,
        remembered: Remembered(apps: remote.from_result(result)),
        forgetting: NotForgetting,
      ),
      effect.none(),
    )

    UserClickedForget(app:) -> #(
      Model(..model, forgetting: ConfirmingForget(app:)),
      confirmation.focus_cancel(),
    )

    UserCancelledForget(app:) -> #(
      Model(..model, forgetting: NotForgetting),
      browser.focus(forget_button_id(app)),
    )

    UserConfirmedForget(app:) -> #(
      Model(..model, forgetting: Forgetting),
      tranquil.perform(
        model.session,
        tranquil.forget_remembered_app(app.client_id),
        ServerForgotApp,
      ),
    )

    ServerForgotApp(result: Ok(Nil)) -> #(model, load_remembered(model.session))

    ServerForgotApp(result: Error(problem)) -> #(
      Model(
        ..model,
        remembered: Remembered(apps: Failed(problem:)),
        forgetting: NotForgetting,
      ),
      effect.none(),
    )
  }
}

fn forget_button_id(app: RememberedApp) -> String {
  "forget-" <> app.client_id
}

fn load_remembered(session: Session) -> Effect(Message) {
  tranquil.load(
    session,
    tranquil.remembered_apps(),
    ServerReturnedRememberedApps,
  )
}

pub fn describe_app(client_id: String) -> String {
  case uri.parse(client_id) {
    Ok(Uri(host: Some("localhost"), ..))
    | Ok(Uri(host: Some("127.0.0.1"), ..)) -> "Localhost App"
    Ok(Uri(host: Some(host), ..)) -> host
    Ok(Uri(host: None, ..)) | Error(Nil) -> client_id
  }
}

pub fn view(model: Model) -> Element(Message) {
  html.main([attribute.class("page")], [
    html.h1([attribute.class("prompt")], [html.text("apps")]),
    sessions.view_list(model.sessions) |> element.map(SessionsProducedMessage),
    case model.remembered {
      NotSupported | Remembered(apps: Loading) -> element.none()

      Remembered(apps: Failed(_)) ->
        view_remembered([
          html.p([attribute.class("problem")], [html.text("Couldn't load")]),
        ])

      Remembered(apps: Loaded(value: [])) ->
        view_remembered([html.p([], [html.text("none")])])

      Remembered(apps: Loaded(value: apps)) ->
        view_remembered([
          html.div(
            [attribute.class("rows")],
            list.map(apps, view_app(_, model.forgetting)),
          ),
        ])
    },
  ])
}

fn view_remembered(content: List(Element(Message))) -> Element(Message) {
  html.section([], [
    html.h2([attribute.class("prompt")], [html.text("remembered")]),
    ..content
  ])
}

fn view_app(app: RememberedApp, forgetting: Forgetting) -> Element(Message) {
  let name = describe_app(app.client_id)
  let permissions = case list.length(app.scopes) {
    1 -> "1 permission"
    count -> int.to_string(count) <> " permissions"
  }

  case forgetting == ConfirmingForget(app:) {
    True ->
      confirmation.view(
        question: "Forget?",
        consequence: name <> " will ask for permission again.",
        accept: "Forget",
        on_cancel: UserCancelledForget(app),
        on_accept: UserConfirmedForget(app),
      )

    False ->
      html.div([attribute.class("row")], [
        html.span([], [html.text(name)]),
        html.span([], [html.text(permissions)]),
        html.button(
          [
            attribute.id(forget_button_id(app)),
            attribute.class("action"),
            attribute.disabled(forgetting == Forgetting),
            event.on_click(UserClickedForget(app)),
          ],
          [html.text("Forget")],
        ),
      ])
  }
}
