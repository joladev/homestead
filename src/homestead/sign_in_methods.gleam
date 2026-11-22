import gleam/option.{type Option, None, Some}
import homestead/layout
import homestead/session.{type Departure, type Session}
import homestead/sign_in_methods/authenticator
import homestead/sign_in_methods/passkeys
import homestead/sign_in_methods/password
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub opaque type Model {
  Model(
    passkeys: passkeys.Model,
    authenticator: authenticator.Model,
    password: password.Model,
  )
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  let #(passkeys, passkeys_effect) = passkeys.init(session)
  let #(authenticator, authenticator_effect) = authenticator.init(session)
  let #(password, password_effect) = password.init(session)

  #(
    Model(passkeys:, authenticator:, password:),
    effect.batch([
      effect.map(passkeys_effect, PasskeysProducedMessage),
      effect.map(authenticator_effect, AuthenticatorProducedMessage),
      effect.map(password_effect, PasswordProducedMessage),
    ]),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    passkeys.has_ended_session(model.passkeys)
    || authenticator.has_ended_session(model.authenticator)
    || password.has_ended_session(model.password)

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  PasskeysProducedMessage(message: passkeys.Message)
  AuthenticatorProducedMessage(message: authenticator.Message)
  PasswordProducedMessage(message: password.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    PasskeysProducedMessage(message:) -> {
      let #(passkeys, effect) = passkeys.update(model.passkeys, message)

      #(Model(..model, passkeys:), effect.map(effect, PasskeysProducedMessage))
    }

    AuthenticatorProducedMessage(message:) -> {
      let #(authenticator, effect) =
        authenticator.update(model.authenticator, message)

      #(
        Model(..model, authenticator:),
        effect.map(effect, AuthenticatorProducedMessage),
      )
    }

    PasswordProducedMessage(message:) -> {
      let #(password, effect) = password.update(model.password, message)

      #(Model(..model, password:), effect.map(effect, PasswordProducedMessage))
    }
  }
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section("passkeys", [
      map(passkeys.view(model.passkeys), PasskeysProducedMessage),
    ]),
    layout.section("authenticator", [
      map(authenticator.view(model.authenticator), AuthenticatorProducedMessage),
    ]),
    layout.section("password", [
      map(
        password.view(model.password, passkeys.has_any(model.passkeys)),
        PasswordProducedMessage,
      ),
    ]),
  ])
}

fn map(
  elements: List(Element(message)),
  to_message: fn(message) -> Message,
) -> Element(Message) {
  element.fragment(elements) |> element.map(to_message)
}
