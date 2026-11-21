import at/oauth.{type Client}
import gleam/javascript/promise
import gleam/option.{None, Some}
import gleam/uri.{type Uri, Uri}
import homestead/dashboard
import homestead/route.{type Route, Overview}
import homestead/session.{type Session}
import homestead/sign_in
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
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", directory)

  Nil
}

type Model {
  Model(directory: Uri, client: Client, state: State)
}

type State {
  SignedOut(sign_in: sign_in.Model)
  CompletingSignIn
  SignedIn(session: Session, route: Route)
}

fn init(directory: Uri) -> #(Model, Effect(Message)) {
  let assert Ok(uri) = modem.initial_uri()
  let client = session.client(uri)

  let #(state, effect) = case uri.path == session.callback_path {
    True -> #(CompletingSignIn, complete_sign_in(uri))
    False ->
      case session.restore() {
        Ok(session) -> #(
          SignedIn(session:, route: route.from_uri(uri)),
          effect.none(),
        )
        Error(_) -> #(
          SignedOut(sign_in: sign_in.init(directory, client)),
          effect.none(),
        )
      }
  }

  #(
    Model(directory:, client:, state:),
    effect.batch([modem.init(UserNavigatedTo), effect]),
  )
}

type Message {
  SignInProducedMessage(sign_in.Message)
  ServerIssuedSession(result: Result(Session, session.Problem))
  UserNavigatedTo(uri: Uri)
  UserClickedSignOut
  ServerEndedSession(result: Result(Nil, session.Problem))
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let sign_in = sign_in.init(model.directory, model.client)

  case model.state, message {
    SignedOut(sign_in:), SignInProducedMessage(message) -> {
      let #(sign_in, effect) = sign_in.update(sign_in, message)

      #(
        Model(..model, state: SignedOut(sign_in:)),
        effect.map(effect, SignInProducedMessage),
      )
    }

    CompletingSignIn, ServerIssuedSession(result: Ok(session)) -> #(
      Model(..model, state: SignedIn(session:, route: Overview)),
      show_overview(),
    )

    CompletingSignIn, ServerIssuedSession(result: Error(_)) -> #(
      Model(
        ..model,
        state: SignedOut(sign_in.report_incomplete_sign_in(sign_in)),
      ),
      show_overview(),
    )

    SignedIn(session:, ..), UserNavigatedTo(uri:) -> #(
      Model(..model, state: SignedIn(session:, route: route.from_uri(uri))),
      effect.none(),
    )

    SignedIn(session:, ..), UserClickedSignOut -> #(model, end_session(session))

    SignedIn(..), ServerEndedSession(result: Ok(Nil)) -> #(
      Model(..model, state: SignedOut(sign_in:)),
      show_overview(),
    )

    SignedIn(..), ServerEndedSession(result: Error(_)) -> #(
      Model(
        ..model,
        state: SignedOut(sign_in.report_session_not_ended(sign_in)),
      ),
      show_overview(),
    )

    SignedOut(_), ServerIssuedSession(_)
    | SignedOut(_), UserNavigatedTo(_)
    | SignedOut(_), UserClickedSignOut
    | SignedOut(_), ServerEndedSession(_)
    | CompletingSignIn, SignInProducedMessage(_)
    | CompletingSignIn, UserNavigatedTo(_)
    | CompletingSignIn, UserClickedSignOut
    | CompletingSignIn, ServerEndedSession(_)
    | SignedIn(..), SignInProducedMessage(_)
    | SignedIn(..), ServerIssuedSession(_)
    -> #(model, effect.none())
  }
}

fn show_overview() -> Effect(Message) {
  modem.replace(route.to_path(Overview), None, None)
}

fn complete_sign_in(callback: Uri) -> Effect(Message) {
  use dispatch <- effect.from

  session.complete(callback)
  |> promise.tap(fn(issued) { dispatch(ServerIssuedSession(issued)) })

  Nil
}

fn end_session(session: Session) -> Effect(Message) {
  use dispatch <- effect.from

  session.end(session)
  |> promise.tap(fn(ended) { dispatch(ServerEndedSession(ended)) })

  Nil
}

fn view(model: Model) -> Element(Message) {
  case model.state {
    SignedOut(sign_in:) ->
      sign_in.view(sign_in) |> element.map(SignInProducedMessage)

    CompletingSignIn ->
      html.main([attribute.class("page")], [
        html.p([], [html.text("Signing you in…")]),
      ])

    SignedIn(session:, route:) ->
      dashboard.view(route, session.handle(session), UserClickedSignOut)
  }
}
