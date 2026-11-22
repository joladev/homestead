import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/admin/accounts
import homestead/admin/invite_codes
import homestead/admin/server_page
import homestead/admin/signal
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem, type ServerTotals}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

pub opaque type Model {
  Model(
    totals: Remote(ServerTotals),
    accounts: accounts.Model,
    invite_codes: invite_codes.Model,
    signal: signal.Model,
    server_page: server_page.Model,
  )
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  let #(accounts, accounts_effect) = accounts.init(session)
  let #(invite_codes, invite_codes_effect) = invite_codes.init(session)
  let #(signal, signal_effect) = signal.init(session)
  let #(server_page, server_page_effect) = server_page.init(session)

  #(
    Model(totals: Loading, accounts:, invite_codes:, signal:, server_page:),
    effect.batch([
      tranquil.load(session, tranquil.server_totals(), ServerReturnedTotals),
      effect.map(accounts_effect, AccountsProducedMessage),
      effect.map(invite_codes_effect, InviteCodesProducedMessage),
      effect.map(signal_effect, SignalProducedMessage),
      effect.map(server_page_effect, ServerPageProducedMessage),
    ]),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    remote.has_ended_session(model.totals)
    || accounts.has_ended_session(model.accounts)
    || invite_codes.has_ended_session(model.invite_codes)
    || signal.has_ended_session(model.signal)
    || server_page.has_ended_session(model.server_page)

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedTotals(result: Result(ServerTotals, Problem))
  AccountsProducedMessage(message: accounts.Message)
  InviteCodesProducedMessage(message: invite_codes.Message)
  SignalProducedMessage(message: signal.Message)
  ServerPageProducedMessage(message: server_page.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedTotals(result:) -> #(
      Model(..model, totals: remote.from_result(result)),
      effect.none(),
    )

    AccountsProducedMessage(message:) -> {
      let #(accounts, effect) = accounts.update(model.accounts, message)

      #(Model(..model, accounts:), effect.map(effect, AccountsProducedMessage))
    }

    InviteCodesProducedMessage(message:) -> {
      let #(invite_codes, effect) =
        invite_codes.update(model.invite_codes, message)

      #(
        Model(..model, invite_codes:),
        effect.map(effect, InviteCodesProducedMessage),
      )
    }

    SignalProducedMessage(message:) -> {
      let #(signal, effect) = signal.update(model.signal, message)

      #(Model(..model, signal:), effect.map(effect, SignalProducedMessage))
    }

    ServerPageProducedMessage(message:) -> {
      let #(server_page, effect) =
        server_page.update(model.server_page, message)

      #(
        Model(..model, server_page:),
        effect.map(effect, ServerPageProducedMessage),
      )
    }
  }
}

pub fn describe_size(bytes: Int) -> String {
  let scaled = fn(unit: Int, name: String) {
    float.to_string(
      int.to_float(float.round(int.to_float(bytes * 10) /. int.to_float(unit)))
      /. 10.0,
    )
    <> " "
    <> name
  }

  case bytes {
    bytes if bytes < 1024 -> int.to_string(bytes) <> " B"
    bytes if bytes < 1_048_576 -> scaled(1024, "KB")
    bytes if bytes < 1_073_741_824 -> scaled(1_048_576, "MB")
    _ -> scaled(1_073_741_824, "GB")
  }
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section("server", [
      layout.block(case model.totals {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: totals) -> [
          layout.row(
            tone: layout.Plain,
            name: "Totals",
            details: [
              html.text(string.join(
                [
                  int.to_string(totals.accounts) <> " accounts",
                  int.to_string(totals.repositories) <> " repositories",
                  int.to_string(totals.records) <> " records",
                  describe_size(totals.media_bytes) <> " media",
                ],
                " \u{00B7} ",
              )),
            ],
            actions: [],
          ),
        ]
      }),
    ]),
    layout.section("accounts", [
      map(accounts.view(model.accounts), AccountsProducedMessage),
    ]),
    case invite_codes.is_offered(model.invite_codes) {
      True ->
        layout.section_with_actions(
          "invite-codes",
          invite_codes.view_actions(model.invite_codes)
            |> list.map(element.map(_, InviteCodesProducedMessage)),
          [
            map(
              invite_codes.view(model.invite_codes),
              InviteCodesProducedMessage,
            ),
          ],
        )
      False -> element.none()
    },
    layout.section("signal", [
      map(signal.view(model.signal), SignalProducedMessage),
    ]),
    layout.section("server-page", [
      map(server_page.view(model.server_page), ServerPageProducedMessage),
    ]),
  ])
}

fn map(
  elements: List(Element(message)),
  to_message: fn(message) -> Message,
) -> Element(Message) {
  element.fragment(elements) |> element.map(to_message)
}
