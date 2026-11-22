import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem, type SentMessage}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    login_alerts: Remote(Bool),
    saving: Saving,
    messages: Remote(List(SentMessage)),
    shown: List(Int),
  )
}

type Saving {
  NotSaving
  Saving
  SaveRefused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      login_alerts: Loading,
      saving: NotSaving,
      messages: Loading,
      shown: [],
    ),
    effect.batch([
      tranquil.load(session, tranquil.login_alerts(), ServerReturnedLoginAlerts),
      tranquil.load(session, tranquil.sent_messages(), ServerReturnedMessages),
    ]),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    remote.has_ended_session(model.login_alerts)
    || remote.has_ended_session(model.messages)
    || model.saving == SaveRefused(tranquil.SessionEnded)

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedLoginAlerts(result: Result(Bool, Problem))
  ServerReturnedMessages(result: Result(List(SentMessage), Problem))
  UserPickedLoginAlerts(enabled: Bool)
  ServerSavedLoginAlerts(enabled: Bool, result: Result(Nil, Problem))
  UserToggledMessage(index: Int)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedLoginAlerts(result:) -> #(
      Model(..model, login_alerts: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedMessages(result:) -> #(
      Model(..model, messages: remote.from_result(result)),
      effect.none(),
    )

    UserPickedLoginAlerts(enabled:) -> #(
      Model(..model, saving: Saving),
      tranquil.perform(
        model.session,
        tranquil.set_login_alerts(enabled),
        ServerSavedLoginAlerts(enabled, _),
      ),
    )

    ServerSavedLoginAlerts(enabled:, result: Ok(Nil)) -> #(
      Model(..model, login_alerts: Loaded(enabled), saving: NotSaving),
      effect.none(),
    )

    ServerSavedLoginAlerts(result: Error(problem), ..) -> #(
      Model(..model, saving: SaveRefused(problem:)),
      effect.none(),
    )

    UserToggledMessage(index:) -> #(
      Model(..model, shown: case list.contains(model.shown, index) {
        True -> list.filter(model.shown, fn(shown) { shown != index })
        False -> [index, ..model.shown]
      }),
      effect.none(),
    )
  }
}

pub fn describe_title(message: SentMessage) -> String {
  case message.subject {
    Some(subject) -> subject
    None ->
      string.capitalise(string.replace(message.kind, each: "_", with: " "))
  }
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section("alerts", [
      layout.block(case model.login_alerts {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: enabled) -> [
          layout.row(
            tone: layout.Plain,
            name: "Password sign-in",
            details: [
              html.text(
                "Message me when someone signs in with only the password",
              ),
            ],
            actions: [view_switch(enabled, model.saving == Saving)],
          ),
          case model.saving {
            SaveRefused(_) -> layout.problem("The server didn't save that")
            NotSaving | Saving -> element.none()
          },
        ]
      }),
    ]),
    layout.section("messages", [
      layout.block(case model.messages {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: []) -> [layout.details_row([layout.dim("None sent")])]
        Loaded(value: messages) ->
          list.index_map(messages, fn(message, index) {
            view_message(model, message, index)
          })
      }),
    ]),
  ])
}

fn view_switch(enabled: Bool, is_saving: Bool) -> Element(Message) {
  html.div(
    [
      attribute.class("choices"),
      attribute.role("radiogroup"),
      attribute.aria_label("Password sign-in alert"),
    ],
    list.map([#("On", True), #("Off", False)], fn(choice) {
      let #(label, value) = choice

      html.label([], [
        html.input([
          attribute.type_("radio"),
          attribute.name("login-alerts"),
          attribute.checked(value == enabled),
          attribute.disabled(is_saving),
          event.on_click(UserPickedLoginAlerts(value)),
        ]),
        html.span([], [html.text(label)]),
      ])
    }),
  )
}

fn view_message(
  model: Model,
  message: SentMessage,
  index: Int,
) -> Element(Message) {
  let is_shown = list.contains(model.shown, index)
  let status = string.lowercase(message.status)

  element.fragment([
    layout.row(
      tone: case status {
        "failed" -> layout.Warning
        _ -> layout.Plain
      },
      name: date.describe_moment(message.sent, model.local_offset),
      details: [
        html.text(describe_title(message) <> " "),
        layout.dim("\u{00B7} " <> message.channel <> " \u{00B7} " <> status),
      ],
      actions: [
        html.button(
          [
            attribute.class("action"),
            attribute.aria_expanded(is_shown),
            event.on_click(UserToggledMessage(index)),
          ],
          [
            html.text(case is_shown {
              True -> "Hide"
              False -> "Show"
            }),
          ],
        ),
      ],
    ),
    case is_shown {
      True ->
        layout.details_row([
          html.span([attribute.class("message-body")], [
            html.text(message.body),
          ]),
        ])
      False -> element.none()
    },
  ])
}
