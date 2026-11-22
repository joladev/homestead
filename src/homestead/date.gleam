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

pub fn describe_moment(timestamp: Timestamp, offset: Duration) -> String {
  let #(_, time) = timestamp.to_calendar(timestamp, offset)

  describe(timestamp, offset)
  <> " "
  <> two_digits(time.hours)
  <> ":"
  <> two_digits(time.minutes)
}

fn two_digits(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}
