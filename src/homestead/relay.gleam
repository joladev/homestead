import at/did.{type Did}
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import homestead/browser
import homestead/layout.{Plain, Warning}
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

pub opaque type Checks {
  Checks(
    account: Did,
    server: Request(String),
    own: Remote(AccountStatus),
    relays: List(Relay),
  )
}

type Relay {
  Relay(
    address: Request(String),
    server: Remote(ServerStatus),
    account: Remote(AccountStatus),
  )
}

pub type ServerStatus {
  Connected
  Idle
  Offline
  Throttled
  Banned
  OtherServerStatus(name: String)
  NotKnown
}

pub type AccountStatus {
  Active(revision: Option(String))
  Inactive(reason: Option(String))
  NotFound
}

pub type Standing {
  UpToDate
  Behind
  Missing
  Stopped(reason: Option(String))
}

pub type Summary {
  Summary(current: Int, total: Int)
}

type Finding {
  Pending
  Unreached
  Reached(server: Option(ServerStatus), standing: Option(Standing))
}

pub opaque type Answer {
  ServerReturnedAccount(result: Result(Response(String), rsvp.Error(String)))
  RelayReturnedServer(
    relay: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
  RelayReturnedAccount(
    relay: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
}

pub fn check(
  session: Session,
  settings: Settings,
) -> #(Checks, Effect(Answer)) {
  let checks =
    Checks(
      account: session.account(session),
      server: session.server_address(session),
      own: Loading,
      relays: list.map(settings.relays, fn(address) {
        Relay(address:, server: Loading, account: Loading)
      }),
    )

  #(
    checks,
    effect.batch([
      rsvp.send(
        account_request(checks.server, checks.account),
        rsvp.expect_any_response(ServerReturnedAccount),
      ),
      ..list.flat_map(checks.relays, fn(relay) {
        [
          ask_about_server(checks, relay.address),
          rsvp.send(
            account_request(relay.address, checks.account),
            rsvp.expect_any_response(RelayReturnedAccount(relay.address, _)),
          ),
        ]
      })
    ]),
  )
}

fn ask_about_server(checks: Checks, relay: Request(String)) -> Effect(Answer) {
  rsvp.send(
    server_request(relay, tranquil.server_name(checks.server)),
    rsvp.expect_any_response(RelayReturnedServer(relay, _)),
  )
}

pub fn record(checks: Checks, answer: Answer) -> Checks {
  case answer {
    ServerReturnedAccount(result:) ->
      Checks(..checks, own: read_account(result))

    RelayReturnedServer(relay:, result:) ->
      change(checks, relay, fn(relay) {
        Relay(..relay, server: read_server(result))
      })

    RelayReturnedAccount(relay:, result:) ->
      change(checks, relay, fn(relay) {
        Relay(..relay, account: read_account(result))
      })
  }
}

fn change(
  checks: Checks,
  address: Request(String),
  with: fn(Relay) -> Relay,
) -> Checks {
  Checks(
    ..checks,
    relays: list.map(checks.relays, fn(relay) {
      case relay.address == address {
        True -> with(relay)
        False -> relay
      }
    }),
  )
}

pub fn summary(checks: Checks) -> Remote(Summary) {
  use own <- remote.then(checks.own)
  let findings = list.map(checks.relays, finding(own, _))

  case list.contains(findings, Pending) {
    True -> Loading
    False ->
      Loaded(Summary(
        current: list.count(findings, is_current),
        total: list.length(findings),
      ))
  }
}

pub fn describe(summary: Summary) -> String {
  "up to date on "
  <> int.to_string(summary.current)
  <> " of "
  <> int.to_string(summary.total)
}

fn finding(own: AccountStatus, relay: Relay) -> Finding {
  case relay.server, relay.account {
    Loading, _ | _, Loading -> Pending
    Failed(_), Failed(_) -> Unreached
    Loaded(value: server), Loaded(value: account) ->
      Reached(server: Some(server), standing: Some(standing(own, account)))
    Loaded(value: server), Failed(_) ->
      Reached(server: Some(server), standing: None)
    Failed(_), Loaded(value: account) ->
      Reached(server: None, standing: Some(standing(own, account)))
  }
}

fn is_current(finding: Finding) -> Bool {
  case finding {
    Reached(server: Some(Connected), standing: Some(UpToDate))
    | Reached(server: Some(Idle), standing: Some(UpToDate)) -> True
    Reached(_, _) | Pending | Unreached -> False
  }
}

pub fn server_request(
  relay: Request(String),
  server: String,
) -> Request(String) {
  relay
  |> request.set_path("/xrpc/com.atproto.sync.getHostStatus")
  |> request.set_query([#("hostname", server)])
}

pub fn account_request(host: Request(String), account: Did) -> Request(String) {
  host
  |> request.set_path("/xrpc/com.atproto.sync.getRepoStatus")
  |> request.set_query([#("did", did.to_string(account))])
}

pub fn reconnect_request(
  relay: Request(String),
  server: String,
) -> Request(String) {
  relay
  |> request.set_path("/xrpc/com.atproto.sync.requestCrawl")
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(json.object([#("hostname", json.string(server))])),
  )
}

pub fn read_server(
  result: Result(Response(String), rsvp.Error(String)),
) -> Remote(ServerStatus) {
  let status = {
    use name <- decode.field("status", decode.string)

    decode.success(case name {
      "active" -> Connected
      "idle" -> Idle
      "offline" -> Offline
      "throttled" -> Throttled
      "banned" -> Banned
      name -> OtherServerStatus(name:)
    })
  }

  read(result, status, refused: "HostNotFound", meaning: NotKnown)
}

pub fn read_account(
  result: Result(Response(String), rsvp.Error(String)),
) -> Remote(AccountStatus) {
  let status = {
    use is_active <- decode.field("active", decode.bool)
    use revision <- decode.optional_field(
      "rev",
      None,
      decode.optional(decode.string),
    )
    use reason <- decode.optional_field(
      "status",
      None,
      decode.optional(decode.string),
    )

    decode.success(case is_active {
      True -> Active(revision:)
      False -> Inactive(reason:)
    })
  }

  read(result, status, refused: "RepoNotFound", meaning: NotFound)
}

fn read(
  result: Result(Response(String), rsvp.Error(String)),
  decoder: Decoder(value),
  refused error: String,
  meaning unknown: value,
) -> Remote(value) {
  case result {
    Ok(response) if response.status == 200 ->
      case json.parse(response.body, decoder) {
        Ok(value) -> Loaded(value:)
        Error(_) ->
          Failed(tranquil.Problem(
            service: "the relay",
            reason: tranquil.NotUnderstood,
          ))
      }
    Ok(response) ->
      case json.parse(response.body, decode.at(["error"], decode.string)) {
        Ok(refusal) if refusal == error -> Loaded(value: unknown)
        Ok(_) | Error(_) ->
          Failed(tranquil.Problem(
            service: "the relay",
            reason: tranquil.NotUnderstood,
          ))
      }
    Error(error) -> Failed(tranquil.error_to_problem(error, from: "the relay"))
  }
}

pub fn standing(own: AccountStatus, relay: AccountStatus) -> Standing {
  case own, relay {
    Active(revision: Some(own)), Active(revision: Some(relay)) ->
      case string.compare(relay, own) {
        order.Lt -> Behind
        order.Eq | order.Gt -> UpToDate
      }
    Active(_), Active(_) | Inactive(_), Inactive(_) | NotFound, NotFound ->
      UpToDate
    Active(_), Inactive(reason:) -> Stopped(reason:)
    Active(_), NotFound -> Missing
    Inactive(_), Active(_)
    | Inactive(_), NotFound
    | NotFound, Active(_)
    | NotFound, Inactive(_)
    -> Behind
  }
}

pub opaque type Model {
  Model(
    session: Session,
    settings: Settings,
    checks: Checks,
    reconnects: List(Reconnect),
  )
}

type Reconnect {
  Reconnect(relay: Request(String), state: ReconnectState)
}

type ReconnectState {
  Asking
  Asked
  Refused
  CouldNotAsk
}

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  let #(checks, effect) = check(session, settings)

  #(
    Model(session:, settings:, checks:, reconnects: []),
    effect.map(effect, RelayReturnedAnswer),
  )
}

pub opaque type Message {
  RelayReturnedAnswer(answer: Answer)
  UserClickedCheckAgain
  UserAskedToReconnect(relay: Request(String))
  RelayAnsweredReconnect(
    relay: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
  BrowserWaitedForRelay(relay: Request(String))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    RelayReturnedAnswer(answer:) -> #(
      Model(..model, checks: record(model.checks, answer)),
      effect.none(),
    )

    UserClickedCheckAgain -> init(model.session, model.settings)

    UserAskedToReconnect(relay:) -> #(
      reconnect(model, relay, Asking),
      rsvp.send(
        reconnect_request(relay, tranquil.server_name(model.checks.server)),
        rsvp.expect_any_response(RelayAnsweredReconnect(relay, _)),
      ),
    )

    RelayAnsweredReconnect(relay:, result: Ok(response))
      if response.status == 200
    -> #(
      reconnect(model, relay, Asked),
      browser.after(reconnect_wait_milliseconds, BrowserWaitedForRelay(relay)),
    )

    RelayAnsweredReconnect(relay:, result: Ok(_)) -> #(
      reconnect(model, relay, Refused),
      effect.none(),
    )

    RelayAnsweredReconnect(relay:, result: Error(_)) -> #(
      reconnect(model, relay, CouldNotAsk),
      effect.none(),
    )

    BrowserWaitedForRelay(relay:) -> #(
      Model(
        ..model,
        checks: change(model.checks, relay, fn(relay) {
          Relay(..relay, server: Loading)
        }),
      ),
      ask_about_server(model.checks, relay)
        |> effect.map(RelayReturnedAnswer),
    )
  }
}

fn reconnect(
  model: Model,
  relay: Request(String),
  state: ReconnectState,
) -> Model {
  Model(..model, reconnects: [
    Reconnect(relay:, state:),
    ..list.filter(model.reconnects, fn(reconnect) { reconnect.relay != relay })
  ])
}

pub fn view(model: Model) -> Element(Message) {
  let checks = model.checks

  layout.page([
    layout.title_section_with_actions(
      "relays",
      [
        html.button(
          [
            attribute.class("action"),
            attribute.disabled(summary(checks) == Loading),
            event.on_click(UserClickedCheckAgain),
          ],
          [html.text("Check again")],
        ),
      ],
      [
        html.div([attribute.class("relays")], [
          layout.block(
            layout.rows(
              of: checks.own,
              placeholders: list.length(checks.relays),
              with: fn(own) {
                list.map(checks.relays, fn(relay) {
                  view_relay(
                    relay,
                    finding(own, relay),
                    list.find(model.reconnects, fn(reconnect) {
                      reconnect.relay == relay.address
                    }),
                  )
                })
              },
            ),
          ),
        ]),
      ],
    ),
  ])
}

fn view_relay(
  relay: Relay,
  finding: Finding,
  reconnect: Result(Reconnect, Nil),
) -> Element(Message) {
  let name = tranquil.server_name(relay.address)

  case finding {
    Pending ->
      layout.row(tone: Plain, name:, details: [layout.pending()], actions: [])

    Unreached ->
      layout.row(
        tone: Warning,
        name:,
        details: [html.text("Couldn't reach this relay")],
        actions: [],
      )

    Reached(server:, standing:) -> {
      let server_fact = case server {
        Some(Connected) -> "server connected"
        Some(Idle) -> "server idle"
        Some(Offline) -> "server offline"
        Some(Throttled) -> "server throttled"
        Some(Banned) -> "server banned"
        Some(OtherServerStatus(name:)) -> "server " <> name
        Some(NotKnown) -> "server not known"
        None -> "no answer about the server"
      }
      let account_fact = case standing {
        Some(UpToDate) -> "account up to date"
        Some(Behind) -> "account behind"
        Some(Missing) -> "account not found"
        Some(Stopped(reason: Some("takendown"))) -> "account taken down"
        Some(Stopped(reason: Some("desynchronized"))) -> "account out of sync"
        Some(Stopped(reason: Some(reason))) -> "account " <> reason
        Some(Stopped(reason: None)) -> "account inactive"
        None -> "no answer about the account"
      }
      let reconnect_fact = case reconnect {
        Error(Nil) -> []
        Ok(Reconnect(state: Asking, ..)) -> ["asking to reconnect"]
        Ok(Reconnect(state: Asked, ..)) -> ["asked to reconnect"]
        Ok(Reconnect(state: Refused, ..)) -> ["the relay refused to reconnect"]
        Ok(Reconnect(state: CouldNotAsk, ..)) -> [
          "this relay can't be asked from a browser",
        ]
      }
      let can_reconnect = case server {
        Some(Offline) | Some(Idle) | Some(NotKnown) -> True
        Some(Connected)
        | Some(Throttled)
        | Some(Banned)
        | Some(OtherServerStatus(_))
        | None -> False
      }

      layout.row(
        tone: case is_current(finding) {
          True -> Plain
          False -> Warning
        },
        name:,
        details: [
          html.text(string.join(
            [server_fact, account_fact, ..reconnect_fact],
            " \u{00B7} ",
          )),
        ],
        actions: case can_reconnect, reconnect {
          True, Error(Nil) -> [
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserAskedToReconnect(relay.address)),
              ],
              [html.text("Ask to reconnect")],
            ),
          ]
          True, Ok(_) | False, _ -> []
        },
      )
    }
  }
}
