import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import homestead/admin/account
import homestead/admin/invite_code
import homestead/admin/server_page
import homestead/admin/server_relay
import homestead/admin/signal
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{type AdminPage}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/tangled
import homestead/tranquil.{
  type Problem, type ServerTotals, type Software, OtherSoftware, Tranquil,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

pub opaque type Model {
  AccountsPage(accounts: account.Model, invite_codes: invite_code.Model)
  FlaggedPage(accounts: account.Model)
  ServerPage(
    totals: Remote(ServerTotals),
    software: Remote(Software),
    tags: Remote(List(String)),
    relays: server_relay.Model,
    signal: signal.Model,
    server_page: server_page.Model,
  )
}

pub fn init(
  session: Session,
  settings: Settings,
  local_offset: Duration,
  origin: String,
  now: Timestamp,
  page: AdminPage,
) -> #(Model, Effect(Message)) {
  case page {
    route.Accounts -> {
      let #(accounts, accounts_effect) =
        account.init(session, settings, local_offset, now, account.Everyone)
      let #(invite_codes, invite_codes_effect) =
        invite_code.init(session, origin, local_offset)

      #(
        AccountsPage(accounts:, invite_codes:),
        effect.batch([
          effect.map(accounts_effect, AccountsProducedMessage),
          effect.map(invite_codes_effect, InviteCodesProducedMessage),
        ]),
      )
    }

    route.Flagged -> {
      let #(accounts, accounts_effect) =
        account.init(session, settings, local_offset, now, account.Flagged)

      #(
        FlaggedPage(accounts:),
        effect.map(accounts_effect, AccountsProducedMessage),
      )
    }

    route.Server -> {
      let #(relays, relays_effect) = server_relay.init(session, settings)
      let #(signal, signal_effect) = signal.init(session)
      let #(server_page, server_page_effect) = server_page.init(session)

      #(
        ServerPage(
          totals: Loading,
          software: Loading,
          tags: Loading,
          relays:,
          signal:,
          server_page:,
        ),
        effect.batch([
          tranquil.load(session, tranquil.server_totals(), ServerReturnedTotals),
          tranquil.load(session, tranquil.software(), ServerReturnedSoftware),
          rsvp.send(
            tangled.tags_request(settings.tangled, tranquil.repository),
            rsvp.expect_json(tangled.tags_decoder(), TangledReturnedTags),
          ),
          effect.map(relays_effect, RelaysProducedMessage),
          effect.map(signal_effect, SignalProducedMessage),
          effect.map(server_page_effect, ServerPageProducedMessage),
        ]),
      )
    }
  }
}

pub opaque type Message {
  ServerReturnedTotals(result: Result(ServerTotals, Problem))
  ServerReturnedSoftware(result: Result(Software, Problem))
  TangledReturnedTags(result: Result(List(String), rsvp.Error(String)))
  AccountsProducedMessage(message: account.Message)
  InviteCodesProducedMessage(message: invite_code.Message)
  RelaysProducedMessage(message: server_relay.Message)
  SignalProducedMessage(message: signal.Message)
  ServerPageProducedMessage(message: server_page.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model, message {
    ServerPage(..), ServerReturnedTotals(result:) -> #(
      ServerPage(..model, totals: remote.from_result(result)),
      effect.none(),
    )

    ServerPage(..), ServerReturnedSoftware(result:) -> #(
      ServerPage(..model, software: remote.from_result(result)),
      effect.none(),
    )

    ServerPage(..), TangledReturnedTags(result:) -> #(
      ServerPage(
        ..model,
        tags: result.replace_error(result, tranquil.Unreachable)
          |> remote.from_result,
      ),
      effect.none(),
    )

    AccountsPage(accounts:, ..), AccountsProducedMessage(message:) -> {
      let #(accounts, effect) = account.update(accounts, message)

      #(
        AccountsPage(..model, accounts:),
        effect.map(effect, AccountsProducedMessage),
      )
    }

    FlaggedPage(accounts:), AccountsProducedMessage(message:) -> {
      let #(accounts, effect) = account.update(accounts, message)

      #(FlaggedPage(accounts:), effect.map(effect, AccountsProducedMessage))
    }

    AccountsPage(invite_codes:, ..), InviteCodesProducedMessage(message:) -> {
      let #(invite_codes, effect) = invite_code.update(invite_codes, message)

      #(
        AccountsPage(..model, invite_codes:),
        effect.map(effect, InviteCodesProducedMessage),
      )
    }

    ServerPage(relays:, ..), RelaysProducedMessage(message:) -> {
      let #(relays, effect) = server_relay.update(relays, message)

      #(ServerPage(..model, relays:), effect.map(effect, RelaysProducedMessage))
    }

    ServerPage(signal:, ..), SignalProducedMessage(message:) -> {
      let #(signal, effect) = signal.update(signal, message)

      #(ServerPage(..model, signal:), effect.map(effect, SignalProducedMessage))
    }

    ServerPage(server_page:, ..), ServerPageProducedMessage(message:) -> {
      let #(server_page, effect) = server_page.update(server_page, message)

      #(
        ServerPage(..model, server_page:),
        effect.map(effect, ServerPageProducedMessage),
      )
    }

    AccountsPage(..), ServerReturnedTotals(_)
    | AccountsPage(..), ServerReturnedSoftware(_)
    | AccountsPage(..), TangledReturnedTags(_)
    | AccountsPage(..), RelaysProducedMessage(_)
    | AccountsPage(..), SignalProducedMessage(_)
    | AccountsPage(..), ServerPageProducedMessage(_)
    | FlaggedPage(_), ServerReturnedTotals(_)
    | FlaggedPage(_), ServerReturnedSoftware(_)
    | FlaggedPage(_), TangledReturnedTags(_)
    | FlaggedPage(_), InviteCodesProducedMessage(_)
    | FlaggedPage(_), RelaysProducedMessage(_)
    | FlaggedPage(_), SignalProducedMessage(_)
    | FlaggedPage(_), ServerPageProducedMessage(_)
    | ServerPage(..), AccountsProducedMessage(_)
    | ServerPage(..), InviteCodesProducedMessage(_)
    -> #(model, effect.none())
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

type Release {
  Release(tag: String, numbers: List(Int))
}

pub fn newer_version(running: String, tags: List(String)) -> Option(String) {
  let newest =
    list.filter_map(tags, fn(tag) {
      version_numbers(tag) |> result.map(Release(tag:, numbers: _))
    })
    |> list.sort(fn(one, other) { compare_versions(other.numbers, one.numbers) })
    |> list.first

  case newest, version_numbers(running) {
    Ok(Release(tag:, numbers:)), Ok(running) ->
      case compare_versions(numbers, running) {
        order.Gt ->
          Some(case tag {
            "v" <> version -> version
            version -> version
          })
        order.Eq | order.Lt -> None
      }
    Ok(_), Error(Nil) | Error(Nil), _ -> None
  }
}

fn version_numbers(text: String) -> Result(List(Int), Nil) {
  let text = case string.trim(text) {
    "v" <> version -> version
    version -> version
  }
  let version = case string.split_once(text, " ") {
    Ok(#(version, _)) -> version
    Error(Nil) -> text
  }

  string.split(version, on: ".") |> list.try_map(int.parse)
}

fn compare_versions(one: List(Int), other: List(Int)) -> Order {
  case one, other {
    [], [] -> order.Eq
    [], [_, ..] -> order.Lt
    [_, ..], [] -> order.Gt
    [first, ..rest], [other_first, ..other_rest] ->
      case int.compare(first, other_first) {
        order.Eq -> compare_versions(rest, other_rest)
        order.Lt -> order.Lt
        order.Gt -> order.Gt
      }
  }
}

pub fn view(model: Model) -> Element(Message) {
  case model {
    AccountsPage(accounts:, invite_codes:) ->
      layout.page([
        layout.title_section("accounts", [
          map(account.view(accounts), AccountsProducedMessage),
        ]),
        case invite_code.is_offered(invite_codes) {
          True ->
            layout.section_with_actions(
              "invite-codes",
              invite_code.view_actions(invite_codes)
                |> list.map(element.map(_, InviteCodesProducedMessage)),
              [map(invite_code.view(invite_codes), InviteCodesProducedMessage)],
            )
          False -> element.none()
        },
      ])

    FlaggedPage(accounts:) ->
      layout.page([
        layout.title_section("flagged-accounts", [
          map(account.view(accounts), AccountsProducedMessage),
        ]),
      ])

    ServerPage(totals:, software:, tags:, relays:, signal:, server_page:) ->
      layout.page([
        layout.title_section("server", [
          layout.block([view_totals(totals), view_version(software, tags)]),
        ]),
        layout.section("relays", [
          map(server_relay.view(relays), RelaysProducedMessage),
        ]),
        layout.section("signal", [
          map(signal.view(signal), SignalProducedMessage),
        ]),
        layout.section("server-page", [
          map(server_page.view(server_page), ServerPageProducedMessage),
        ]),
      ])
  }
}

fn view_totals(totals: Remote(ServerTotals)) -> Element(message) {
  use totals <- layout.awaited_row(name: "Totals", of: totals)

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
  )
}

fn view_version(
  software: Remote(Software),
  tags: Remote(List(String)),
) -> Element(message) {
  use software <- layout.awaited_row(name: "Version", of: software)
  let releases =
    html.a(
      [
        attribute.href(tranquil.releases),
        attribute.target("_blank"),
        attribute.rel("noopener"),
      ],
      [html.text("Releases")],
    )

  case software {
    OtherSoftware ->
      layout.row(
        tone: layout.Warning,
        name: "Version",
        details: [html.text("not a Tranquil server")],
        actions: [],
      )

    Tranquil(version:) -> {
      let newer = remote.map(tags, newer_version(version, _))

      layout.row(
        tone: case newer {
          Loaded(value: Some(_)) -> layout.Warning
          Loaded(value: None) | Loading | Failed(_) -> layout.Plain
        },
        name: "Version",
        details: [
          html.text(
            "Tranquil "
            <> version
            <> case newer {
              Loaded(value: Some(newer)) ->
                " \u{00B7} " <> newer <> " is available"
              Loaded(value: None) -> " \u{00B7} up to date"
              Loading -> ""
              Failed(_) -> " \u{00B7} couldn't read the latest version"
            },
          ),
        ],
        actions: [releases],
      )
    }
  }
}

fn map(
  elements: List(Element(message)),
  to_message: fn(message) -> Message,
) -> Element(Message) {
  element.fragment(elements) |> element.map(to_message)
}
