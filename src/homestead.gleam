import at/did.{type Did}
import gleam/function
import gleam/http/request
import gleam/javascript/promise
import gleam/option.{None, Some}
import gleam/uri.{type Uri, Uri}
import homestead/about
import homestead/browser
import homestead/dashboard
import homestead/route.{type Route, Overview}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/sign_in
import homestead/sign_up
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem

pub fn main() -> Nil {
  start(with: function.identity)
}

pub fn start(with adjust: fn(Settings) -> Settings) -> Nil {
  let assert Ok(location) = modem.initial_uri()

  promise.map(setting.load(location), fn(settings) {
    case settings {
      Ok(settings) -> run(adjust(settings), location)
      Error(Nil) -> report_unreadable_settings()
    }
  })

  Nil
}

fn run(settings: Settings, location: Uri) -> Nil {
  session.configure(
    session.client(location),
    request.to_uri(settings.directory),
  )

  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Start(settings:, location:))

  Nil
}

fn report_unreadable_settings() -> Nil {
  let assert Ok(_) =
    lustre.start(lustre.element(view_unreadable_settings()), "#app", Nil)

  Nil
}

fn view_unreadable_settings() -> Element(message) {
  element.fragment([
    html.header([attribute.class("top-bar")], [
      html.a([attribute.class("brand"), attribute.href("/")], [
        html.text("Homestead"),
      ]),
    ]),
    html.main([attribute.class("page")], [
      html.p([attribute.class("failure")], [
        html.text("Couldn't load Homestead's settings. "),
        html.a([attribute.href("")], [html.text("Try again")]),
      ]),
    ]),
  ])
}

type Start {
  Start(settings: Settings, location: Uri)
}

type Model {
  Model(settings: Settings, state: State)
}

type State {
  Restoring(location: Uri)
  CompletingSignIn
  SignedOut(sign_in: sign_in.Model)
  AddingAccount(sign_in: sign_in.Model)
  SigningUp(sign_up: sign_up.Model)
  SignedIn(dashboard: dashboard.Model)
  ReadingAbout
}

fn init(start: Start) -> #(Model, Effect(Message)) {
  let Start(settings:, location:) = start

  let #(state, effect) = case
    location.path == session.callback_path,
    location.fragment
  {
    True, Some(answer) -> #(CompletingSignIn, complete_sign_in(answer))
    True, None -> #(
      SignedOut(new_sign_in(settings) |> sign_in.report_incomplete_sign_in),
      show_overview(),
    )
    False, _ -> enter(settings, location)
  }

  #(
    Model(settings:, state:),
    effect.batch([modem.init(UserNavigatedTo), effect]),
  )
}

type Message {
  SignInProducedMessage(sign_in.Message)
  SignUpProducedMessage(sign_up.Message)
  BrowserRestoredSession(result: Result(Session, session.Problem))
  ServerIssuedSession(result: Result(Session, session.Problem))
  UserNavigatedTo(uri: Uri)
  DashboardProducedMessage(dashboard.Message)
  ServerEndedSession(account: Did)
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model.state, message {
    SignedOut(sign_in:), SignInProducedMessage(message) ->
      update_sign_in(model, sign_in, message, SignedOut)

    AddingAccount(sign_in:), SignInProducedMessage(message) ->
      update_sign_in(model, sign_in, message, AddingAccount)

    SigningUp(sign_up:), SignUpProducedMessage(message) -> {
      let #(sign_up, effect) = sign_up.update(sign_up, message)

      #(
        Model(..model, state: SigningUp(sign_up:)),
        effect.map(effect, SignUpProducedMessage),
      )
    }

    AddingAccount(_), UserNavigatedTo(uri:)
    | SigningUp(_), UserNavigatedTo(uri:)
    | ReadingAbout, UserNavigatedTo(uri:)
    -> {
      let #(state, effect) = enter(model.settings, uri)

      #(Model(..model, state:), effect)
    }

    SignedOut(_), UserNavigatedTo(uri:) ->
      case front_page(model.settings, uri) {
        Ok(state) -> #(Model(..model, state:), effect.none())
        Error(Nil) -> #(model, effect.none())
      }

    Restoring(location:), BrowserRestoredSession(result: Ok(session)) ->
      start_dashboard(model, session, route.from_uri(location))

    Restoring(_), BrowserRestoredSession(result: Error(session.NothingStored))
    -> #(
      Model(..model, state: SignedOut(new_sign_in(model.settings))),
      effect.none(),
    )

    Restoring(_), BrowserRestoredSession(result: Error(_)) -> #(
      Model(..model, state: ended_session(model.settings)),
      effect.none(),
    )

    CompletingSignIn, ServerIssuedSession(result: Ok(session)) -> {
      let #(model, effect) = start_dashboard(model, session, Overview)

      #(model, effect.batch([show_overview(), effect]))
    }

    CompletingSignIn, ServerIssuedSession(result: Error(_)) -> #(
      Model(
        ..model,
        state: SignedOut(
          new_sign_in(model.settings) |> sign_in.report_incomplete_sign_in,
        ),
      ),
      show_overview(),
    )

    SignedIn(dashboard:), UserNavigatedTo(uri:) ->
      case front_page(model.settings, uri) {
        Ok(state) -> #(Model(..model, state:), effect.none())
        Error(Nil) ->
          open_dashboard(model, dashboard.show(dashboard, route.from_uri(uri)))
      }

    SignedIn(dashboard:), DashboardProducedMessage(message) -> {
      let #(dashboard, effect) = dashboard.update(dashboard, message)

      case dashboard.departure(dashboard) {
        None -> open_dashboard(model, #(dashboard, effect))

        Some(session.SignedOut) -> #(
          Model(..model, state: Restoring(location: overview())),
          effect.batch([show_overview(), restore_session()]),
        )

        Some(session.SwitchedAccount(account:)) ->
          switch_account(model, account, route.page(dashboard.route(dashboard)))
      }
    }

    SignedIn(dashboard:), ServerEndedSession(account:) ->
      case dashboard.account(dashboard) == account {
        True -> #(
          Model(..model, state: ended_session(model.settings)),
          show_overview(),
        )
        False -> #(model, effect.none())
      }

    Restoring(_), SignInProducedMessage(_)
    | Restoring(_), ServerIssuedSession(_)
    | Restoring(_), UserNavigatedTo(_)
    | Restoring(_), DashboardProducedMessage(_)
    | CompletingSignIn, SignInProducedMessage(_)
    | CompletingSignIn, BrowserRestoredSession(_)
    | CompletingSignIn, UserNavigatedTo(_)
    | CompletingSignIn, DashboardProducedMessage(_)
    | SignedOut(_), BrowserRestoredSession(_)
    | SignedOut(_), ServerIssuedSession(_)
    | SignedOut(_), SignUpProducedMessage(_)
    | AddingAccount(_), BrowserRestoredSession(_)
    | AddingAccount(_), ServerIssuedSession(_)
    | AddingAccount(_), SignUpProducedMessage(_)
    | AddingAccount(_), DashboardProducedMessage(_)
    | ReadingAbout, SignInProducedMessage(_)
    | ReadingAbout, SignUpProducedMessage(_)
    | ReadingAbout, BrowserRestoredSession(_)
    | ReadingAbout, ServerIssuedSession(_)
    | ReadingAbout, DashboardProducedMessage(_)
    | SigningUp(_), SignInProducedMessage(_)
    | SigningUp(_), BrowserRestoredSession(_)
    | SigningUp(_), ServerIssuedSession(_)
    | SigningUp(_), DashboardProducedMessage(_)
    | Restoring(_), SignUpProducedMessage(_)
    | CompletingSignIn, SignUpProducedMessage(_)
    | SignedIn(_), SignUpProducedMessage(_)
    | SignedOut(_), DashboardProducedMessage(_)
    | SignedIn(_), SignInProducedMessage(_)
    | SignedIn(_), BrowserRestoredSession(_)
    | SignedIn(_), ServerIssuedSession(_)
    | Restoring(_), ServerEndedSession(_)
    | CompletingSignIn, ServerEndedSession(_)
    | SignedOut(_), ServerEndedSession(_)
    | AddingAccount(_), ServerEndedSession(_)
    | SigningUp(_), ServerEndedSession(_)
    | ReadingAbout, ServerEndedSession(_)
    -> #(model, effect.none())
  }
}

fn start_dashboard(
  model: Model,
  session: Session,
  route: Route,
) -> #(Model, Effect(Message)) {
  let #(model, effect) =
    open_dashboard(model, dashboard.init(session, model.settings, route))

  #(model, effect.batch([watch(session), effect]))
}

fn watch(session: Session) -> Effect(Message) {
  use dispatch <- effect.from

  session.when_expired(session, fn() {
    dispatch(ServerEndedSession(session.account(session)))
  })
}

fn open_dashboard(
  model: Model,
  opened: #(dashboard.Model, Effect(dashboard.Message)),
) -> #(Model, Effect(Message)) {
  let #(dashboard, effect) = opened

  #(
    Model(..model, state: SignedIn(dashboard:)),
    effect.map(effect, DashboardProducedMessage),
  )
}

fn enter(settings: Settings, location: Uri) -> #(State, Effect(Message)) {
  case front_page(settings, location) {
    Ok(state) -> #(state, effect.none())
    Error(Nil) -> #(Restoring(location:), restore_session())
  }
}

fn front_page(settings: Settings, location: Uri) -> Result(State, Nil) {
  case location.path {
    path if path == about.path -> Ok(ReadingAbout)
    path if path == sign_in.path -> Ok(AddingAccount(new_sign_in(settings)))
    "/sign-up" -> Ok(SigningUp(sign_up.init()))
    _ -> Error(Nil)
  }
}

fn new_sign_in(settings: Settings) -> sign_in.Model {
  sign_in.init(settings, session.stored_accounts())
}

fn ended_session(settings: Settings) -> State {
  SignedOut(new_sign_in(settings) |> sign_in.report_ended_session)
}

fn update_sign_in(
  model: Model,
  sign_in: sign_in.Model,
  message: sign_in.Message,
  to_state: fn(sign_in.Model) -> State,
) -> #(Model, Effect(Message)) {
  let #(sign_in, effect) = sign_in.update(sign_in, message)

  case sign_in.chosen_account(sign_in) {
    Some(account) -> switch_account(model, account, Overview)
    None -> #(
      Model(..model, state: to_state(sign_in)),
      effect.map(effect, SignInProducedMessage),
    )
  }
}

fn switch_account(
  model: Model,
  account: Did,
  to: Route,
) -> #(Model, Effect(Message)) {
  let path = route.to_path(to)

  #(
    Model(..model, state: Restoring(location: Uri(..uri.empty, path:))),
    effect.batch([modem.replace(path, None, None), restore_account(account)]),
  )
}

fn overview() -> Uri {
  Uri(..uri.empty, path: route.to_path(Overview))
}

fn show_overview() -> Effect(Message) {
  modem.replace(route.to_path(Overview), None, None)
}

fn restore_session() -> Effect(Message) {
  browser.await(session.restore, BrowserRestoredSession)
}

fn restore_account(account: Did) -> Effect(Message) {
  browser.await(fn() { session.switch_to(account) }, BrowserRestoredSession)
}

fn complete_sign_in(answer: String) -> Effect(Message) {
  browser.await(fn() { session.complete(answer) }, ServerIssuedSession)
}

fn view(model: Model) -> Element(Message) {
  case model.state {
    Restoring(_) -> element.none()

    CompletingSignIn ->
      html.main([attribute.class("page")], [
        html.p([], [html.text("Signing you in…")]),
      ])

    SignedOut(sign_in:) | AddingAccount(sign_in:) ->
      sign_in.view(sign_in) |> element.map(SignInProducedMessage)

    SigningUp(sign_up:) ->
      sign_up.view(sign_up) |> element.map(SignUpProducedMessage)

    ReadingAbout -> about.view()

    SignedIn(dashboard:) ->
      dashboard.view(dashboard) |> element.map(DashboardProducedMessage)
  }
}
