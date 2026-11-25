import at/did.{type Did}
import at/handle
import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleam/time/timestamp.{type Timestamp}
import homestead/admin
import homestead/admin/account.{Gathered, Gathering}
import homestead/label.{Active, Event, Label}
import homestead/tangled
import homestead/tranquil.{
  AccountPage, Deactivated, HostedAccount, HostedPage, ListedAccount, OtherState,
  Running, TakenDown,
}

fn at(text: String) -> Timestamp {
  let assert Ok(time) = timestamp.parse_rfc3339(text)

  time
}

fn account(text: String) -> Did {
  let assert Ok(account) = did.from_string(text)

  account
}

pub fn a_newer_release_is_found_among_the_tags_test() {
  let tags = ["v0.9.1", "v0.9.0", "v0.10.0", "nightly", "v0.8.0"]

  assert admin.newer_version("0.8.0 (built 2026-11-22 14:43:23 UTC)", tags)
    == Some("0.10.0")
  assert admin.newer_version("0.10.0", tags) == None
  assert admin.newer_version("unknown", tags) == None
}

pub fn tangled_lists_tags_by_name_test() {
  let body =
    "{\"tags\":[{\"name\":\"v0.9.1\",\"annotation\":{\"message\":\"Version 0.9.1\"}},{\"name\":\"v0.9.0\"}],\"total\":2}"

  assert json.parse(body, tangled.tags_decoder()) == Ok(["v0.9.1", "v0.9.0"])
}

pub fn every_hosted_account_has_a_state_test() {
  let body =
    "{\"repos\":[{\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"head\":\"bafy\",\"rev\":\"3n33m5hioig2f\",\"active\":true},{\"did\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"head\":\"bafy\",\"rev\":\"3n33m5hioig2f\",\"active\":false,\"status\":\"takendown\"},{\"did\":\"did:plc:z72i7hdynmk6r22z27h6tvur\",\"head\":\"bafy\",\"rev\":\"3n33m5hioig2f\",\"active\":false,\"status\":\"deactivated\"},{\"did\":\"did:plc:ar7c4by46qjdydhdevvrndac\",\"head\":\"bafy\",\"rev\":\"3n33m5hioig2f\",\"active\":false,\"status\":\"suspended\"}],\"cursor\":\"next\"}"

  assert tranquil.parse(tranquil.hosted_accounts(None), body)
    == Ok(HostedPage(
      accounts: [
        HostedAccount(
          did: account("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs"),
          state: Running,
        ),
        HostedAccount(
          did: account("did:plc:ewvi7nxzyoun6zhxrhs64oiz"),
          state: TakenDown,
        ),
        HostedAccount(
          did: account("did:plc:z72i7hdynmk6r22z27h6tvur"),
          state: Deactivated,
        ),
        HostedAccount(
          did: account("did:plc:ar7c4by46qjdydhdevvrndac"),
          state: OtherState(name: "suspended"),
        ),
      ],
      next: Some("next"),
    ))
}

pub fn only_labels_in_force_flag_an_account_test() {
  let labeler = account("did:plc:ar7c4by46qjdydhdevvrndac")
  let flagged = account("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs")
  let cleared = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  let event = fn(subject, value, at, is_removal) {
    Event(labeler:, subject:, value:, at:, expires: None, is_removal:)
  }
  let flags =
    account.flags(
      [
        event(
          did.to_string(flagged),
          "!takedown",
          at("2026-11-23T10:00:00Z"),
          False,
        ),
        event(cleared, "spam", at("2026-11-20T10:00:00Z"), False),
        event(cleared, "spam", at("2026-11-21T10:00:00Z"), True),
      ],
      at("2026-11-25T10:00:00Z"),
    )

  assert dict.to_list(flags)
    == [
      #(flagged, [
        Label(
          labeler:,
          value: "!takedown",
          state: Active(since: at("2026-11-23T10:00:00Z"), expires: None),
        ),
      ]),
    ]
}

fn listed(did: String, name: String, since: String) {
  let assert Ok(handle) = handle.from_string(name)

  ListedAccount(
    did: account(did),
    handle:,
    email: None,
    since: at(since),
    is_verified: True,
    is_deactivated: False,
    has_invites: True,
  )
}

pub fn accounts_are_gathered_page_by_page_then_listed_newest_first_test() {
  let oldest =
    listed(
      "did:plc:k4q7m2x3vt5hwz6r2ypbn7cs",
      "noor.harbor.example",
      "2026-08-01T10:00:00Z",
    )
  let newest =
    listed(
      "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      "sami.harbor.example",
      "2026-11-20T10:00:00Z",
    )
  let middle =
    listed(
      "did:plc:z72i7hdynmk6r22z27h6tvur",
      "lena.harbor.example",
      "2026-10-05T10:00:00Z",
    )
  let after_first =
    account.add_accounts(
      Gathering(so_far: []),
      AccountPage(accounts: [oldest, newest], next: Some("page-2")),
    )

  assert after_first == Gathering(so_far: [oldest, newest])
  assert account.add_accounts(
      after_first,
      AccountPage(accounts: [middle], next: None),
    )
    == Gathered(all: [newest, middle, oldest])
}

pub fn account_states_are_gathered_page_by_page_test() {
  let first = account("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs")
  let second = account("did:plc:ewvi7nxzyoun6zhxrhs64oiz")
  let after_first =
    account.add_states(
      Gathering(so_far: dict.new()),
      HostedPage(
        accounts: [HostedAccount(did: first, state: Running)],
        next: Some("page-2"),
      ),
    )

  assert after_first == Gathering(so_far: dict.from_list([#(first, Running)]))
  assert account.add_states(
      after_first,
      HostedPage(
        accounts: [HostedAccount(did: second, state: TakenDown)],
        next: None,
      ),
    )
    == Gathered(all: dict.from_list([#(first, Running), #(second, TakenDown)]))
}
