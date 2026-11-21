import gleam/option.{type Option, None, Some}
import gleam/time/timestamp
import homestead/overview
import homestead/tranquil.{type ActiveSession, ActiveSession, Authenticator}

pub fn sign_in_methods_are_listed_with_the_backup_codes_left_test() {
  assert overview.describe_sign_in_methods(
      2,
      Authenticator(enabled: True, backup_codes_remaining: 6),
      True,
    )
    == "2 passkeys \u{00B7} authenticator on \u{00B7} password set \u{00B7} 6 backup codes"
}

pub fn missing_sign_in_methods_are_named_test() {
  assert overview.describe_sign_in_methods(
      0,
      Authenticator(enabled: False, backup_codes_remaining: 0),
      True,
    )
    == "no passkeys \u{00B7} authenticator off \u{00B7} password set"
}

pub fn apps_beyond_the_third_are_counted_test() {
  let sessions = [
    session("oauth:1", Some("Fieldnotes")),
    session("oauth:2", Some("Corkboard")),
    session("oauth:3", Some("Longhand")),
    session("oauth:4", Some("Ledger")),
    session("oauth:5", Some("Fieldnotes")),
    session("jwt:1", None),
  ]

  assert overview.describe_apps(sessions)
    == "4 with access: Fieldnotes, Corkboard, Longhand, 1 more"
  assert overview.describe_sessions(sessions) == "6 open"
}

fn session(id: String, app: Option(String)) -> ActiveSession {
  ActiveSession(
    id:,
    app:,
    created: timestamp.from_unix_seconds(0),
    expires: timestamp.from_unix_seconds(0),
    is_current: False,
  )
}
