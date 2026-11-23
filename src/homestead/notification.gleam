import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem, type SentMessage}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const default_language = "en"

const languages = [
  #("en", "English"),
  #("zh", "\u{4E2D}\u{6587}"),
  #("ja", "\u{65E5}\u{672C}\u{8A9E}"),
  #("ko", "\u{D55C}\u{AD6D}\u{C5B4}"),
  #("sv", "Svenska"),
  #("fi", "Suomi"),
  #("fr", "Fran\u{00E7}ais"),
]

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    login_alerts: Remote(Bool),
    saving: Saving,
    language: Remote(Option(String)),
    saving_language: Saving,
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
      language: Loading,
      saving_language: NotSaving,
      messages: Loading,
      shown: [],
    ),
    effect.batch([
      tranquil.load(session, tranquil.login_alerts(), ServerReturnedLoginAlerts),
      tranquil.load(session, tranquil.sent_messages(), ServerReturnedMessages),
      tranquil.load(session, tranquil.language(), ServerReturnedLanguage),
    ]),
  )
}

pub opaque type Message {
  ServerReturnedLoginAlerts(result: Result(Bool, Problem))
  ServerReturnedMessages(result: Result(List(SentMessage), Problem))
  UserPickedLoginAlerts(enabled: Bool)
  ServerSavedLoginAlerts(enabled: Bool, result: Result(Nil, Problem))
  UserToggledMessage(index: Int)
  ServerReturnedLanguage(result: Result(Option(String), Problem))
  UserPickedLanguage(code: String)
  ServerSavedLanguage(
    previous: Remote(Option(String)),
    result: Result(Nil, Problem),
  )
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

    ServerReturnedLanguage(result:) -> #(
      Model(..model, language: remote.from_result(result)),
      effect.none(),
    )

    UserPickedLanguage(code:) -> #(
      Model(..model, language: Loaded(Some(code)), saving_language: Saving),
      tranquil.perform(
        model.session,
        tranquil.set_language(code),
        ServerSavedLanguage(model.language, _),
      ),
    )

    ServerSavedLanguage(result: Ok(Nil), ..) -> #(
      Model(..model, saving_language: NotSaving),
      effect.none(),
    )

    ServerSavedLanguage(previous:, result: Error(problem)) -> #(
      Model(..model, language: previous, saving_language: SaveRefused(problem:)),
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
      layout.block([
        layout.row(
          tone: layout.Plain,
          name: "Password sign-in",
          details: [
            html.text("Message me when someone signs in with only the password"),
          ],
          actions: [
            {
              use enabled <- layout.value(model.login_alerts)

              layout.switch(
                id: "login-alerts",
                label: "Password sign-in alert",
                is_on: enabled,
                is_disabled: model.saving == Saving,
                on_pick: UserPickedLoginAlerts,
              )
            },
          ],
        ),
        case model.saving {
          SaveRefused(_) -> layout.problem("The server didn't save that")
          NotSaving | Saving -> element.none()
        },
      ]),
    ]),
    layout.section("language", [
      layout.block([
        layout.row(
          tone: layout.Plain,
          name: "Messages",
          details: [
            {
              use language <- layout.value(model.language)

              layout.select(
                id: "language",
                label: "Language of messages",
                options: languages,
                picked: option.unwrap(language, default_language),
                is_disabled: model.saving_language == Saving,
                on_pick: UserPickedLanguage,
              )
            },
          ],
          actions: [],
        ),
        case model.saving_language {
          SaveRefused(_) -> layout.problem("The server didn't save that")
          NotSaving | Saving -> element.none()
        },
      ]),
    ]),
    layout.section("messages", [
      layout.block({
        use messages <- layout.rows(model.messages, placeholders: 3)

        layout.listing(
          empty: "No messages",
          rows: list.index_map(messages, fn(message, index) {
            #(int.to_string(index), view_message(model, message, index))
          }),
          actions: [],
        )
      }),
    ]),
  ])
}

fn view_message(
  model: Model,
  message: SentMessage,
  index: Int,
) -> Element(Message) {
  let is_shown = list.contains(model.shown, index)

  element.fragment([
    layout.row(
      tone: case message.status {
        tranquil.FailedToSend -> layout.Warning
        tranquil.Pending
        | tranquil.Processing
        | tranquil.Sent
        | tranquil.OtherStatus(_) -> layout.Plain
      },
      name: date.describe_moment(message.sent, model.local_offset),
      details: [
        html.text(describe_title(message) <> " "),
        layout.dim(
          "\u{00B7} "
          <> tranquil.channel_name(message.channel)
          <> " \u{00B7} "
          <> tranquil.status_name(message.status),
        ),
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
