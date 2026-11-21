import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import homestead/connected_apps
import homestead/sessions

pub fn a_date_is_the_day_and_short_month_test() {
  let assert Ok(late_evening) = timestamp.parse_rfc3339("2026-11-20T23:30:00Z")

  assert sessions.describe_date(late_evening, calendar.utc_offset) == "20 Nov"
  assert sessions.describe_date(late_evening, duration.hours(1)) == "21 Nov"
}

pub fn an_app_is_named_by_its_host_test() {
  assert connected_apps.describe_app("https://fieldnotes.example/client.json")
    == "fieldnotes.example"
  assert connected_apps.describe_app("http://localhost?scope=atproto")
    == "Localhost App"
}
