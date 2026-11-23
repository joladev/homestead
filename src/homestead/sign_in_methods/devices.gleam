import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem, type RememberedDevice}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const name_input_id = "device-name"

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    devices: Remote(List(RememberedDevice)),
    action: Action,
  )
}

type Action {
  Resting
  Renaming(device: RememberedDevice, name: String)
  SavingName(device: RememberedDevice, name: String)
  ConfirmingForget(device: RememberedDevice)
  Forgetting
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      devices: Loading,
      action: Resting,
    ),
    load(session),
  )
}

pub opaque type Message {
  ServerReturnedDevices(result: Result(List(RememberedDevice), Problem))
  UserClickedRename(device: RememberedDevice)
  UserTypedName(name: String)
  UserSubmittedName
  UserCancelledRename(device: RememberedDevice)
  ServerRenamedDevice(result: Result(Nil, Problem))
  UserClickedForget(device: RememberedDevice)
  UserCancelledForget(device: RememberedDevice)
  UserConfirmedForget(device: RememberedDevice)
  ServerForgotDevice(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedDevices(result:) -> #(
      Model(..model, devices: remote.from_result(result)),
      effect.none(),
    )

    UserClickedRename(device:) -> #(
      Model(
        ..model,
        action: Renaming(device:, name: option.unwrap(device.name, "")),
      ),
      browser.focus(name_input_id),
    )

    UserTypedName(name:) ->
      case model.action {
        Renaming(device:, ..) -> #(
          Model(..model, action: Renaming(device:, name:)),
          effect.none(),
        )
        SavingName(..)
        | Resting
        | ConfirmingForget(_)
        | Forgetting
        | Refused(_) -> #(model, effect.none())
      }

    UserSubmittedName ->
      case model.action {
        Renaming(device:, name:) -> #(
          Model(..model, action: SavingName(device:, name:)),
          tranquil.perform(
            session,
            tranquil.rename_device(device.id, string.trim(name)),
            ServerRenamedDevice,
          ),
        )
        SavingName(..)
        | Resting
        | ConfirmingForget(_)
        | Forgetting
        | Refused(_) -> #(model, effect.none())
      }

    UserCancelledRename(device:) -> #(
      Model(..model, action: Resting),
      browser.focus(rename_button_id(device)),
    )

    UserClickedForget(device:) -> #(
      Model(..model, action: ConfirmingForget(device:)),
      confirmation.focus_cancel(),
    )

    UserCancelledForget(device:) -> #(
      Model(..model, action: Resting),
      browser.focus(forget_button_id(device)),
    )

    UserConfirmedForget(device:) -> #(
      Model(..model, action: Forgetting),
      tranquil.perform(
        session,
        tranquil.forget_device(device.id),
        ServerForgotDevice,
      ),
    )

    ServerRenamedDevice(result: Ok(Nil))
    | ServerForgotDevice(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerRenamedDevice(result: Error(problem))
    | ServerForgotDevice(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.remembered_devices(), ServerReturnedDevices)
}

fn rename_button_id(device: RememberedDevice) -> String {
  "rename-device-" <> device.id
}

fn forget_button_id(device: RememberedDevice) -> String {
  "forget-device-" <> device.id
}

pub fn describe_name(device: RememberedDevice) -> String {
  case device.name, device.user_agent {
    Some(name), _ -> name
    None, Some(user_agent) -> describe_browser(user_agent)
    None, None -> "Unknown device"
  }
}

fn describe_browser(user_agent: String) -> String {
  let browsers = [
    #("Firefox", "Firefox"),
    #("Edg/", "Edge"),
    #("Chrome", "Chrome"),
    #("Safari", "Safari"),
  ]

  case
    list.find(browsers, fn(browser) {
      let #(marker, _) = browser

      string.contains(user_agent, marker)
    })
  {
    Ok(#(_, name)) -> name
    Error(Nil) -> "Browser"
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        {
          use devices <- layout.rows(model.devices, placeholders: 1)

          layout.listing(
            empty: "No remembered devices",
            rows: list.map(devices, fn(item) {
              #(item.id, view_device(item, model))
            }),
            actions: [],
          )
        },
        case model.action {
          Refused(_) -> [layout.problem("The server didn't accept that")]
          Resting
          | Renaming(..)
          | SavingName(..)
          | ConfirmingForget(_)
          | Forgetting -> []
        },
      ]),
    ),
  ]
}

fn view_device(device: RememberedDevice, model: Model) -> Element(Message) {
  case model.action {
    Renaming(device: renaming, name:) if renaming == device ->
      layout.name_form(
        id: name_input_id,
        name:,
        is_saving: False,
        on_input: UserTypedName,
        on_submit: UserSubmittedName,
        on_cancel: UserCancelledRename(device),
      )

    SavingName(device: renaming, name:) if renaming == device ->
      layout.name_form(
        id: name_input_id,
        name:,
        is_saving: True,
        on_input: UserTypedName,
        on_submit: UserSubmittedName,
        on_cancel: UserCancelledRename(device),
      )

    ConfirmingForget(device: confirming) if confirming == device ->
      confirmation.view(
        question: "Forget?",
        consequence: describe_name(device)
          <> " will be asked for the second step again.",
        accept: "Forget device",
        on_cancel: UserCancelledForget(device),
        on_accept: UserConfirmedForget(device),
      )

    _ ->
      layout.row(
        tone: layout.Plain,
        name: describe_name(device),
        details: [
          layout.dim(
            "until "
            <> date.describe(device.remembered_until, model.local_offset)
            <> " \u{00B7} last used "
            <> date.describe(device.last_seen, model.local_offset),
          ),
        ],
        actions: [
          html.button(
            [
              attribute.id(rename_button_id(device)),
              attribute.class("action"),
              event.on_click(UserClickedRename(device)),
            ],
            [html.text("Rename")],
          ),
          html.button(
            [
              attribute.id(forget_button_id(device)),
              attribute.class("action"),
              event.on_click(UserClickedForget(device)),
            ],
            [html.text("Forget")],
          ),
        ],
      )
  }
}
