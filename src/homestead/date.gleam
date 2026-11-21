import gleam/int
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

pub fn describe(timestamp: Timestamp, offset: Duration) -> String {
  let #(date, _) = timestamp.to_calendar(timestamp, offset)

  int.to_string(date.day)
  <> " "
  <> string.slice(calendar.month_to_string(date.month), 0, 3)
}
