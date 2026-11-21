import gleam/option.{None, Some}
import homestead/overview
import homestead/tranquil.{ActiveSession, Authenticator}

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
    ActiveSession(id: "oauth:1", app: Some("Fieldnotes"), is_current: True),
    ActiveSession(id: "oauth:2", app: Some("Corkboard"), is_current: False),
    ActiveSession(id: "oauth:3", app: Some("Longhand"), is_current: False),
    ActiveSession(id: "oauth:4", app: Some("Ledger"), is_current: False),
    ActiveSession(id: "oauth:5", app: Some("Fieldnotes"), is_current: False),
    ActiveSession(id: "jwt:1", app: None, is_current: False),
  ]

  assert overview.describe_apps(sessions)
    == "4 with access: Fieldnotes, Corkboard, Longhand, 1 more"
  assert overview.describe_sessions(sessions) == "6 open"
}
