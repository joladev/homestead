import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{type Uri}
import homestead/browser
import homestead/landing
import homestead/session
import homestead/tranquil.{type Software, OtherSoftware, Tranquil}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import rsvp

pub opaque type Model {
  Model(address: String, lookup: Lookup)
}

type Lookup {
  NotStarted
  Checking
  Failed(problem: Problem)
}

type Problem {
  AddressNotUnderstood
  ServerUnreachable
  ServerUnavailable
  NotTranquil
  SignUpNotPrepared
}

pub fn init() -> Model {
  Model(address: "", lookup: NotStarted)
}

pub opaque type Message {
  UserTypedAddress(address: String)
  UserSubmittedForm
  ServerReturnedHealth(
    server: Uri,
    result: Result(Software, rsvp.Error(String)),
  )
  ServerPreparedSignUp(result: Result(Uri, session.Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserTypedAddress(address:) -> #(
      Model(address:, lookup: NotStarted),
      effect.none(),
    )

    UserSubmittedForm ->
      case parse_address(model.address) {
        Ok(server) ->
          case tranquil.health_request(server) {
            Ok(request) -> #(
              Model(..model, lookup: Checking),
              rsvp.send(
                request,
                rsvp.expect_json(
                  tranquil.health_decoder(),
                  ServerReturnedHealth(server, _),
                ),
              ),
            )
            Error(Nil) -> #(
              Model(..model, lookup: Failed(AddressNotUnderstood)),
              effect.none(),
            )
          }
        Error(Nil) -> #(
          Model(..model, lookup: Failed(AddressNotUnderstood)),
          effect.none(),
        )
      }

    ServerReturnedHealth(server:, result: Ok(Tranquil(_))) -> #(
      model,
      browser.await(
        fn() { session.begin_sign_up(server) },
        ServerPreparedSignUp,
      ),
    )

    ServerReturnedHealth(result:, ..) -> #(
      Model(
        ..model,
        lookup: Failed(case result {
          Error(rsvp.NetworkError) -> ServerUnreachable
          Error(rsvp.HttpError(response)) if response.status == 503 ->
            ServerUnavailable
          Ok(Tranquil(_))
          | Ok(OtherSoftware)
          | Error(rsvp.HttpError(_))
          | Error(rsvp.JsonError(_))
          | Error(rsvp.UnhandledResponse(_))
          | Error(rsvp.BadBody)
          | Error(rsvp.BadUrl(_)) -> NotTranquil
        }),
      ),
      effect.none(),
    )

    ServerPreparedSignUp(result: Ok(registration)) -> #(
      Model(..model, lookup: NotStarted),
      modem.load(registration),
    )

    ServerPreparedSignUp(result: Error(_)) -> #(
      Model(..model, lookup: Failed(SignUpNotPrepared)),
      effect.none(),
    )
  }
}

pub fn parse_address(address: String) -> Result(Uri, Nil) {
  let address = string.trim(address)
  let address = case string.contains(address, "://") {
    True -> address
    False -> "https://" <> address
  }

  case uri.parse(address) {
    Ok(uri.Uri(scheme: Some(_), host: Some(host), ..) as server) if host != "" ->
      Ok(uri.Uri(..server, path: "", query: None, fragment: None))
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

pub fn view(model: Model) -> Element(Message) {
  let is_checking = model.lookup == Checking

  landing.view([
    html.h2([], [html.text("Create an account")]),
    html.form([event.on_submit(fn(_) { UserSubmittedForm })], [
      html.label([attribute.for("server")], [html.text("Server")]),
      html.div([attribute.class("field")], [
        html.input([
          attribute.id("server"),
          attribute.name("server"),
          attribute.type_("text"),
          attribute.value(model.address),
          attribute.placeholder("pds.example.com"),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(is_checking),
          event.on_input(UserTypedAddress),
        ]),
        html.button(
          [attribute.class("button"), attribute.disabled(is_checking)],
          [html.text("Continue")],
        ),
      ]),
    ]),
    html.a([attribute.class("create-account"), attribute.href("/")], [
      html.text("Have an account? Sign in"),
    ]),
    html.div(
      [attribute.class("lookup"), attribute.aria_live("polite")],
      case model.lookup {
        NotStarted -> []
        Checking -> [html.p([], [html.text("Checking that server…")])]
        Failed(problem:) -> [
          html.h3([attribute.class("attention")], [
            html.text(case problem {
              AddressNotUnderstood -> "That doesn't look like a server address."
              ServerUnreachable -> "Couldn't reach that server."
              ServerUnavailable -> "That server is unavailable right now."
              NotTranquil ->
                "That isn't a Tranquil server, so accounts can't be created from here."
              SignUpNotPrepared -> "Couldn't start signing up on that server."
            }),
          ]),
        ]
      },
    ),
  ])
}
