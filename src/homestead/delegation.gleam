import gleam/list
import gleam/time/duration.{type Duration}
import homestead/delegation/controlled
import homestead/delegation/controller
import homestead/delegation/log
import homestead/layout
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type AccessLevel, type Problem}
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub opaque type Model {
  Model(
    levels: Remote(List(AccessLevel)),
    controllers: controller.Model,
    controlled: controlled.Model,
    log: log.Model,
  )
}

pub fn init(
  session: Session,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  let #(controllers, controllers_effect) =
    controller.init(session, local_offset)
  let #(controlled, controlled_effect) = controlled.init(session, local_offset)
  let #(log, log_effect) = log.init(session, local_offset)

  #(
    Model(levels: Loading, controllers:, controlled:, log:),
    effect.batch([
      tranquil.load(session, tranquil.access_levels(), ServerReturnedLevels),
      effect.map(controllers_effect, ControllersProducedMessage),
      effect.map(controlled_effect, ControlledProducedMessage),
      effect.map(log_effect, LogProducedMessage),
    ]),
  )
}

pub opaque type Message {
  ServerReturnedLevels(result: Result(List(AccessLevel), Problem))
  ControllersProducedMessage(message: controller.Message)
  ControlledProducedMessage(message: controlled.Message)
  LogProducedMessage(message: log.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedLevels(result:) -> #(
      Model(..model, levels: remote.from_result(result)),
      effect.none(),
    )

    ControllersProducedMessage(message:) -> {
      let #(controllers, effect) = controller.update(model.controllers, message)

      #(
        Model(..model, controllers:),
        effect.map(effect, ControllersProducedMessage),
      )
    }

    ControlledProducedMessage(message:) -> {
      let #(controlled, effect) = controlled.update(model.controlled, message)

      #(
        Model(..model, controlled:),
        effect.map(effect, ControlledProducedMessage),
      )
    }

    LogProducedMessage(message:) -> {
      let #(log, effect) = log.update(model.log, message)

      #(Model(..model, log:), effect.map(effect, LogProducedMessage))
    }
  }
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section_with_actions(
      "controllers",
      controller.view_actions(
        model.controllers,
        controlled.has_any(model.controlled),
      )
        |> list.map(element.map(_, ControllersProducedMessage)),
      [
        map(
          controller.view(
            model.controllers,
            model.levels,
            controlled.has_any(model.controlled),
          ),
          ControllersProducedMessage,
        ),
      ],
    ),
    layout.section_with_actions(
      "controlled-accounts",
      controlled.view_actions(
        model.controlled,
        controller.has_any(model.controllers),
      )
        |> list.map(element.map(_, ControlledProducedMessage)),
      [
        map(
          controlled.view(
            model.controlled,
            model.levels,
            controller.has_any(model.controllers),
          ),
          ControlledProducedMessage,
        ),
      ],
    ),
    layout.section("log", [
      map(
        log.view(
          model.log,
          list.append(
            controller.names(model.controllers),
            controlled.names(model.controlled),
          ),
        ),
        LogProducedMessage,
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
