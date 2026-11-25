import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/uri.{Uri}
import homestead/active_session
import homestead/browser
import homestead/confirmation
import homestead/layout
import homestead/remote.{type Remote, Failed, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem, type RememberedApp}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    sessions: active_session.Model,
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

pub fn init(
  session: Session,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  let #(sessions, effect) =
    active_session.init(session, local_offset, active_session.ThroughApps)

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
  active_session.departure(model.sessions)
}

pub opaque type Message {
  SessionsProducedMessage(active_session.Message)
  ServerReturnedRememberedApps(result: Result(List(RememberedApp), Problem))
  UserClickedForget(app: RememberedApp)
  UserCancelledForget(app: RememberedApp)
  UserConfirmedForget(app: RememberedApp)
  ServerForgotApp(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    SessionsProducedMessage(message) -> {
      let #(sessions, effect) = active_session.update(model.sessions, message)

      #(Model(..model, sessions:), effect.map(effect, SessionsProducedMessage))
    }

    ServerReturnedRememberedApps(result: Error(tranquil.Problem(
      reason: tranquil.Refused("MethodNotImplemented", _),
      ..,
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
  layout.page([
    layout.title_section("apps", [
      active_session.view_list(model.sessions)
      |> element.map(SessionsProducedMessage),
    ]),
    case model.remembered {
      NotSupported | Remembered(apps: Loading) -> element.none()

      Remembered(apps:) ->
        layout.section("remembered", [
          layout.block({
            use apps <- layout.rows(apps, placeholders: 1)

            layout.listing(
              empty: "No remembered apps",
              rows: list.map(apps, fn(item) {
                #(item.client_id, view_app(item, model.forgetting))
              }),
              actions: [],
            )
          }),
        ])
    },
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
      layout.row(
        tone: layout.Plain,
        name:,
        details: [html.text(permissions)],
        actions: [
          html.button(
            [
              attribute.id(forget_button_id(app)),
              attribute.class("action"),
              attribute.disabled(forgetting == Forgetting),
              event.on_click(UserClickedForget(app)),
            ],
            [html.text("Forget")],
          ),
        ],
      )
  }
}
