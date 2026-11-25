import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/browser
import homestead/layout.{Plain, Warning}
import homestead/relay.{
  type ServerView, Banned, Connected, Idle, NotKnown, Offline, OtherServerStatus,
  ServerView, Throttled,
}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/tranquil
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

const reconnect_wait_milliseconds = 3000

pub opaque type Model {
  Model(server: String, relays: List(Relay))
}

type Relay {
  Relay(
    address: Request(String),
    view: Remote(ServerView),
    reconnect: Option(Reconnect),
  )
}

type Reconnect {
  Asking
  Asked
  Refused
  CouldNotAsk
}

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  let server = tranquil.server_name(session.server_address(session))

  #(
    Model(
      server:,
      relays: list.map(settings.relays, fn(address) {
        Relay(address:, view: Loading, reconnect: None)
      }),
    ),
    effect.batch(list.map(settings.relays, ask(_, server))),
  )
}

pub opaque type Message {
  RelayReturnedServer(
    relay: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
  UserAskedToReconnect(relay: Request(String))
  RelayAnsweredReconnect(
    relay: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
  BrowserWaitedForRelay(relay: Request(String))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    RelayReturnedServer(relay: address, result:) -> #(
      change(model, address, fn(row) {
        Relay(..row, view: relay.read_server_view(result))
      }),
      effect.none(),
    )

    UserAskedToReconnect(relay: address) -> #(
      change(model, address, fn(row) { Relay(..row, reconnect: Some(Asking)) }),
      rsvp.send(
        relay.reconnect_request(address, model.server),
        rsvp.expect_any_response(RelayAnsweredReconnect(address, _)),
      ),
    )

    RelayAnsweredReconnect(relay: address, result: Ok(response))
      if response.status == 200
    -> #(
      change(model, address, fn(row) { Relay(..row, reconnect: Some(Asked)) }),
      browser.after(reconnect_wait_milliseconds, BrowserWaitedForRelay(address)),
    )

    RelayAnsweredReconnect(relay: address, result: Ok(_)) -> #(
      change(model, address, fn(row) { Relay(..row, reconnect: Some(Refused)) }),
      effect.none(),
    )

    RelayAnsweredReconnect(relay: address, result: Error(_)) -> #(
      change(model, address, fn(row) {
        Relay(..row, reconnect: Some(CouldNotAsk))
      }),
      effect.none(),
    )

    BrowserWaitedForRelay(relay: address) -> #(
      change(model, address, fn(row) { Relay(..row, view: Loading) }),
      ask(address, model.server),
    )
  }
}

fn change(
  model: Model,
  address: Request(String),
  with: fn(Relay) -> Relay,
) -> Model {
  Model(
    ..model,
    relays: list.map(model.relays, fn(row) {
      case row.address == address {
        True -> with(row)
        False -> row
      }
    }),
  )
}

fn ask(address: Request(String), server: String) -> Effect(Message) {
  rsvp.send(
    relay.server_request(address, server),
    rsvp.expect_any_response(RelayReturnedServer(address, _)),
  )
}

pub fn view(model: Model, own_accounts: Option(Int)) -> List(Element(Message)) {
  [
    html.div([attribute.class("relays")], [
      layout.block(list.map(model.relays, view_relay(_, own_accounts))),
    ]),
  ]
}

fn view_relay(row: Relay, own_accounts: Option(Int)) -> Element(Message) {
  let name = tranquil.server_name(row.address)

  case row.view {
    Loading ->
      layout.row(tone: Plain, name:, details: [layout.pending()], actions: [])

    Failed(_) ->
      layout.row(
        tone: Warning,
        name:,
        details: [html.text("Couldn't reach this relay")],
        actions: [],
      )

    Loaded(value: ServerView(status:, accounts:)) -> {
      let status_fact = case status {
        Connected -> "connected"
        Idle -> "idle"
        Offline -> "offline"
        Throttled -> "throttled"
        Banned -> "banned"
        OtherServerStatus(name:) -> name
        NotKnown -> "not known"
      }
      let account_fact = case accounts, own_accounts {
        Some(seen), Some(own) -> [
          int.to_string(seen) <> " of " <> int.to_string(own) <> " accounts",
        ]
        Some(seen), None -> [int.to_string(seen) <> " accounts"]
        None, _ -> []
      }
      let reconnect_fact = case row.reconnect {
        None -> []
        Some(Asking) -> ["asking to reconnect"]
        Some(Asked) -> ["asked to reconnect"]
        Some(Refused) -> ["the relay refused to reconnect"]
        Some(CouldNotAsk) -> ["this relay can't be asked from a browser"]
      }
      let can_reconnect = case status {
        Offline | Idle | NotKnown -> True
        Connected | Throttled | Banned | OtherServerStatus(_) -> False
      }

      layout.row(
        tone: case status {
          Connected | Idle -> Plain
          Offline | Throttled | Banned | OtherServerStatus(_) | NotKnown ->
            Warning
        },
        name:,
        details: [
          html.text(string.join(
            list.flatten([[status_fact], account_fact, reconnect_fact]),
            " \u{00B7} ",
          )),
        ],
        actions: case can_reconnect, row.reconnect {
          True, None -> [
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserAskedToReconnect(row.address)),
              ],
              [html.text("Ask to reconnect")],
            ),
          ]
          True, Some(_) | False, _ -> []
        },
      )
    }
  }
}
