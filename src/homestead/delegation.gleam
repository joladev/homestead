import gleam/list
import gleam/option.{type Option, None, Some}
import homestead/delegation/controlled
import homestead/delegation/controllers
import homestead/delegation/log
import homestead/layout
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type AccessLevel, type Problem}
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub opaque type Model {
  Model(
    levels: Remote(List(AccessLevel)),
    controllers: controllers.Model,
    controlled: controlled.Model,
    log: log.Model,
  )
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  let #(controllers, controllers_effect) = controllers.init(session)
  let #(controlled, controlled_effect) = controlled.init(session)
  let #(log, log_effect) = log.init(session)

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

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    remote.has_ended_session(model.levels)
    || controllers.has_ended_session(model.controllers)
    || controlled.has_ended_session(model.controlled)
    || log.has_ended_session(model.log)

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedLevels(result: Result(List(AccessLevel), Problem))
  ControllersProducedMessage(message: controllers.Message)
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
      let #(controllers, effect) =
        controllers.update(model.controllers, message)

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
    layout.title_section("controllers", [
      map(
        controllers.view(
          model.controllers,
          model.levels,
          controlled.has_any(model.controlled),
        ),
        ControllersProducedMessage,
      ),
    ]),
    layout.section("controlled-accounts", [
      map(
        controlled.view(
          model.controlled,
          model.levels,
          controllers.has_any(model.controllers),
        ),
        ControlledProducedMessage,
      ),
    ]),
    layout.section("log", [
      map(
        log.view(
          model.log,
          list.append(
            controllers.names(model.controllers),
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
