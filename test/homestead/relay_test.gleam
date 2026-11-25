import gleam/http/response
import gleam/option.{None, Some}
import homestead/relay.{
  Active, Behind, Connected, Inactive, Missing, NotFound, NotKnown, Stopped,
  Summary, UpToDate,
}
import homestead/remote.{Failed, Loaded}
import homestead/tranquil
import rsvp

fn answered(status: Int, body: String) {
  Ok(response.new(status) |> response.set_body(body))
}

pub fn a_relay_says_whether_it_is_connected_to_the_server_test() {
  let connected =
    "{\"accountCount\":907,\"hostname\":\"harbor.example\",\"seq\":155844,\"status\":\"active\"}"
  let unknown = "{\"error\":\"HostNotFound\",\"message\":\"host not found\"}"

  assert relay.read_server(answered(200, connected)) == Loaded(Connected)
  assert relay.read_server(answered(404, unknown)) == Loaded(NotKnown)
  assert relay.read_server(answered(502, "")) == Failed(tranquil.NotUnderstood)
  assert relay.read_server(Error(rsvp.NetworkError))
    == Failed(tranquil.Unreachable)
}

pub fn a_relay_says_what_it_holds_for_the_account_test() {
  let active =
    "{\"active\":true,\"did\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"rev\":\"3n33m5hioig2f\"}"
  let deactivated =
    "{\"active\":false,\"did\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"status\":\"deactivated\"}"
  let unknown = "{\"error\":\"RepoNotFound\",\"message\":\"account not found\"}"

  assert relay.read_account(answered(200, active))
    == Loaded(Active(revision: Some("3n33m5hioig2f")))
  assert relay.read_account(answered(200, deactivated))
    == Loaded(Inactive(reason: Some("deactivated")))
  assert relay.read_account(answered(404, unknown)) == Loaded(NotFound)
}

pub fn a_relay_is_judged_against_the_servers_revision_test() {
  let own = Active(revision: Some("3n33m5hioig2f"))

  assert relay.standing(own, own) == UpToDate
  assert relay.standing(own, Active(revision: Some("3mqpz5de7ko2c"))) == Behind
  assert relay.standing(own, NotFound) == Missing
  assert relay.standing(own, Inactive(reason: None)) == Stopped(reason: None)
}

pub fn the_overview_counts_relays_that_are_up_to_date_test() {
  assert relay.describe(Summary(current: 6, total: 7)) == "up to date on 6 of 7"
}
