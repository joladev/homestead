import gleam/json
import gleam/option.{None, Some}
import gleam/time/timestamp
import homestead/tranquil.{
  Account, ActiveSession, OtherSoftware, RememberedApp, Tranquil,
}

pub fn a_tranquil_health_answer_gives_its_version_test() {
  assert json.parse(
      "{\"version\":\"tranquil 0.8.0\"}",
      tranquil.health_decoder(),
    )
    == Ok(Tranquil(version: "0.8.0"))
}

pub fn another_servers_health_answer_is_other_software_test() {
  assert json.parse("{\"version\":\"0.4.193\"}", tranquil.health_decoder())
    == Ok(OtherSoftware)
}

pub fn the_account_is_read_from_the_session_answer_test() {
  let body =
    "{\"handle\":\"noor.harbor.example\",\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"active\":true,\"preferredChannel\":\"email\",\"preferredChannelVerified\":false,\"isAdmin\":true,\"email\":\"noor@harbor.example\",\"emailConfirmed\":false}"

  assert tranquil.parse(tranquil.account(), body)
    == Ok(Account(
      handle: "noor.harbor.example",
      contact_channel: "email",
      contact_verified: False,
      is_admin: True,
    ))
}

pub fn a_session_through_an_app_names_the_app_test() {
  let body =
    "{\"sessions\":[{\"id\":\"oauth:7\",\"sessionType\":\"oauth\",\"clientName\":\"fieldnotes.example\",\"createdAt\":\"2026-11-20T10:00:00+00:00\",\"expiresAt\":\"2026-12-04T10:00:00+00:00\",\"isCurrent\":true},{\"id\":\"jwt:3\",\"sessionType\":\"legacy\",\"clientName\":null,\"createdAt\":\"2026-11-19T10:00:00+00:00\",\"expiresAt\":\"2027-02-17T10:00:00+00:00\",\"isCurrent\":false}]}"
  let assert Ok(created) = timestamp.parse_rfc3339("2026-11-20T10:00:00Z")
  let assert Ok(expires) = timestamp.parse_rfc3339("2026-12-04T10:00:00Z")

  let assert Ok([through_app, direct]) =
    tranquil.parse(tranquil.sessions(), body)

  assert through_app
    == ActiveSession(
      id: "oauth:7",
      app: Some("fieldnotes.example"),
      created:,
      expires:,
      is_current: True,
    )
  assert direct.app == None
}

pub fn remembered_apps_carry_their_permissions_test() {
  let body =
    "{\"choices\":[{\"clientId\":\"https://fieldnotes.example/client.json\",\"scopes\":[\"atproto\",\"repo:*\"]}]}"

  assert tranquil.parse(tranquil.remembered_apps(), body)
    == Ok([
      RememberedApp(
        client_id: "https://fieldnotes.example/client.json",
        scopes: ["atproto", "repo:*"],
      ),
    ])
}

pub fn a_profile_without_a_display_name_has_none_test() {
  let query = tranquil.display_name("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs")

  assert tranquil.parse(
      query,
      "{\"value\":{\"$type\":\"app.bsky.actor.profile\",\"displayName\":\"Noor Halvorsen\"}}",
    )
    == Ok(Some("Noor Halvorsen"))
  assert tranquil.parse(
      query,
      "{\"value\":{\"$type\":\"app.bsky.actor.profile\"}}",
    )
    == Ok(None)
}
