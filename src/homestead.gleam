import gleam/javascript/promise
import gleam/option.{None, Some}
import gleam/uri.{type Uri, Uri}
import homestead/about
import homestead/dashboard
import homestead/route.{Overview}
import homestead/session.{type Session}
import homestead/sign_in
import homestead/sign_up
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem

const public_directory =
  Uri(
    scheme: Some("https"),
    userinfo: None,
    host: Some("plc.directory"),
    port: None,
    path: "",
    query: None,
    fragment: None,
  )

pub fn main() -> Nil {
  start(public_directory)
}

pub fn start(directory: Uri) -> Nil {
  let assert Ok(location) = modem.initial_uri()
  session.configure(session.client(location), directory)

  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Start(directory:, location:))

  Nil
}

type Start {
  Start(directory: Uri, location: Uri)
}

type Model {
  Model(directory: Uri, state: State)
}

type State {
  Restoring(location: Uri)
  CompletingSignIn
  SignedOut(sign_in: sign_in.Model)
  SigningUp(sign_up: sign_up.Model)
  SignedIn(dashboard: dashboard.Model)
  ReadingAbout
}

fn init(start: Start) -> #(Model, Effect(Message)) {
  let Start(directory:, location:) = start

  let #(state, effect) = case
    location.path == session.callback_path,
    location.fragment
  {
    True, Some(answer) -> #(CompletingSignIn, complete_sign_in(answer))
    True, None -> #(
      SignedOut(sign_in.init(directory) |> sign_in.report_incomplete_sign_in),
      show_overview(),
    )
    False, _ if location.path == about.path -> #(ReadingAbout, effect.none())
    False, _ -> #(Restoring(location:), restore_session())
  }

  #(
    Model(directory:, state:),
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
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let sign_in = sign_in.init(model.directory)

  case model.state, message {
    SignedOut(sign_in:), SignInProducedMessage(message) -> {
      let #(sign_in, effect) = sign_in.update(sign_in, message)

      #(
        Model(..model, state: SignedOut(sign_in:)),
        effect.map(effect, SignInProducedMessage),
      )
    }

    SigningUp(sign_up:), SignUpProducedMessage(message) -> {
      let #(sign_up, effect) = sign_up.update(sign_up, message)

      #(
        Model(..model, state: SigningUp(sign_up:)),
        effect.map(effect, SignUpProducedMessage),
      )
    }

    _, UserNavigatedTo(uri:) if uri.path == about.path -> #(
      Model(..model, state: ReadingAbout),
      effect.none(),
    )

    ReadingAbout, UserNavigatedTo(uri:) -> #(
      Model(..model, state: Restoring(location: uri)),
      restore_session(),
    )

    SignedOut(_), UserNavigatedTo(uri:) | SigningUp(_), UserNavigatedTo(uri:) -> #(
      Model(..model, state: signed_out(uri, sign_in)),
      effect.none(),
    )

    Restoring(location:), BrowserRestoredSession(result: Ok(session)) ->
      open_dashboard(
        model,
        dashboard.init(session, model.directory, route.from_uri(location)),
      )

    Restoring(location:),
      BrowserRestoredSession(result: Error(session.NothingStored))
    -> #(Model(..model, state: signed_out(location, sign_in)), effect.none())

    Restoring(_), BrowserRestoredSession(result: Error(_)) -> #(
      Model(..model, state: SignedOut(sign_in.report_ended_session(sign_in))),
      effect.none(),
    )

    CompletingSignIn, ServerIssuedSession(result: Ok(session)) -> {
      let #(model, effect) =
        open_dashboard(
          model,
          dashboard.init(session, model.directory, Overview),
        )

      #(model, effect.batch([show_overview(), effect]))
    }

    CompletingSignIn, ServerIssuedSession(result: Error(_)) -> #(
      Model(
        ..model,
        state: SignedOut(sign_in.report_incomplete_sign_in(sign_in)),
      ),
      show_overview(),
    )

    SignedIn(dashboard:), UserNavigatedTo(uri:) ->
      open_dashboard(model, dashboard.show(dashboard, route.from_uri(uri)))

    SignedIn(dashboard:), DashboardProducedMessage(message) -> {
      let #(dashboard, effect) = dashboard.update(dashboard, message)

      case dashboard.departure(dashboard) {
        None -> open_dashboard(model, #(dashboard, effect))

        Some(session.SignedOut) -> #(
          Model(..model, state: Restoring(location: overview())),
          effect.batch([show_overview(), restore_session()]),
        )

        Some(session.Ended) -> #(
          Model(
            ..model,
            state: SignedOut(sign_in.report_ended_session(sign_in)),
          ),
          show_overview(),
        )
      }
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
    -> #(model, effect.none())
  }
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

fn signed_out(location: Uri, sign_in: sign_in.Model) -> State {
  case location.path {
    "/sign-up" -> SigningUp(sign_up.init())
    _ -> SignedOut(sign_in:)
  }
}

fn overview() -> Uri {
  Uri(..uri.empty, path: route.to_path(Overview))
}

fn show_overview() -> Effect(Message) {
  modem.replace(route.to_path(Overview), None, None)
}

fn restore_session() -> Effect(Message) {
  use dispatch <- effect.from

  session.restore()
  |> promise.tap(fn(restored) { dispatch(BrowserRestoredSession(restored)) })

  Nil
}

fn complete_sign_in(answer: String) -> Effect(Message) {
  use dispatch <- effect.from

  session.complete(answer)
  |> promise.tap(fn(issued) { dispatch(ServerIssuedSession(issued)) })

  Nil
}

fn view(model: Model) -> Element(Message) {
  case model.state {
    Restoring(_) -> element.none()

    CompletingSignIn ->
      html.main([attribute.class("page")], [
        html.p([], [html.text("Signing you in…")]),
      ])

    SignedOut(sign_in:) ->
      sign_in.view(sign_in) |> element.map(SignInProducedMessage)

    SigningUp(sign_up:) ->
      sign_up.view(sign_up) |> element.map(SignUpProducedMessage)

    ReadingAbout -> about.view()

    SignedIn(dashboard:) ->
      dashboard.view(dashboard) |> element.map(DashboardProducedMessage)
  }
}
