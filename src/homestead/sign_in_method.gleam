import gleam/time/duration.{type Duration}
import homestead/layout
import homestead/session.{type Session}
import homestead/sign_in_method/authenticator
import homestead/sign_in_method/device
import homestead/sign_in_method/linked_account
import homestead/sign_in_method/older_app
import homestead/sign_in_method/passkey
import homestead/sign_in_method/password
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub opaque type Model {
  Model(
    passkeys: passkey.Model,
    authenticator: authenticator.Model,
    password: password.Model,
    linked_accounts: linked_account.Model,
    older_apps: older_app.Model,
    devices: device.Model,
  )
}

pub fn init(
  session: Session,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  let #(passkeys, passkeys_effect) = passkey.init(session, local_offset)
  let #(authenticator, authenticator_effect) = authenticator.init(session)
  let #(password, password_effect) = password.init(session)
  let #(linked_accounts, linked_accounts_effect) =
    linked_account.init(session, local_offset)
  let #(older_apps, older_apps_effect) = older_app.init(session)
  let #(devices, devices_effect) = device.init(session, local_offset)

  #(
    Model(
      passkeys:,
      authenticator:,
      password:,
      linked_accounts:,
      older_apps:,
      devices:,
    ),
    effect.batch([
      effect.map(passkeys_effect, PasskeysProducedMessage),
      effect.map(authenticator_effect, AuthenticatorProducedMessage),
      effect.map(password_effect, PasswordProducedMessage),
      effect.map(linked_accounts_effect, LinkedAccountsProducedMessage),
      effect.map(older_apps_effect, OlderAppsProducedMessage),
      effect.map(devices_effect, DevicesProducedMessage),
    ]),
  )
}

pub opaque type Message {
  PasskeysProducedMessage(message: passkey.Message)
  AuthenticatorProducedMessage(message: authenticator.Message)
  PasswordProducedMessage(message: password.Message)
  LinkedAccountsProducedMessage(message: linked_account.Message)
  OlderAppsProducedMessage(message: older_app.Message)
  DevicesProducedMessage(message: device.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    PasskeysProducedMessage(message:) -> {
      let #(passkeys, effect) = passkey.update(model.passkeys, message)

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

    LinkedAccountsProducedMessage(message:) -> {
      let #(linked_accounts, effect) =
        linked_account.update(model.linked_accounts, message)

      #(
        Model(..model, linked_accounts:),
        effect.map(effect, LinkedAccountsProducedMessage),
      )
    }

    OlderAppsProducedMessage(message:) -> {
      let #(older_apps, effect) = older_app.update(model.older_apps, message)

      #(
        Model(..model, older_apps:),
        effect.map(effect, OlderAppsProducedMessage),
      )
    }

    DevicesProducedMessage(message:) -> {
      let #(devices, effect) = device.update(model.devices, message)

      #(Model(..model, devices:), effect.map(effect, DevicesProducedMessage))
    }
  }
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section_with_actions(
      "passkeys",
      passkey.view_actions(model.passkeys),
      [map(passkey.view(model.passkeys), PasskeysProducedMessage)],
    ),
    layout.section("authenticator", [
      map(authenticator.view(model.authenticator), AuthenticatorProducedMessage),
    ]),
    layout.section("password", [
      map(
        password.view(model.password, passkey.has_any(model.passkeys)),
        PasswordProducedMessage,
      ),
    ]),
    case linked_account.is_offered(model.linked_accounts) {
      True ->
        layout.section_with_actions(
          "linked-accounts",
          linked_account.view_actions(model.linked_accounts),
          [
            map(
              linked_account.view(model.linked_accounts),
              LinkedAccountsProducedMessage,
            ),
          ],
        )
      False -> element.none()
    },
    case older_app.is_offered(model.older_apps) {
      True ->
        layout.section("older-apps", [
          map(older_app.view(model.older_apps), OlderAppsProducedMessage),
        ])
      False -> element.none()
    },
    layout.section("remembered-devices", [
      map(device.view(model.devices), DevicesProducedMessage),
    ]),
  ])
}

fn map(
  elements: List(Element(message)),
  to_message: fn(message) -> Message,
) -> Element(Message) {
  element.fragment(elements) |> element.map(to_message)
}
