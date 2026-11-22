import gleam/dynamic/decode.{type Decoder}
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

pub fn describe_day(timestamp: Timestamp, offset: Duration) -> String {
  let #(date, _) = timestamp.to_calendar(timestamp, offset)

  describe(timestamp, offset) <> " " <> int.to_string(date.year)
}

pub fn describe_moment(timestamp: Timestamp, offset: Duration) -> String {
  describe(timestamp, offset) <> " " <> time_of_day(timestamp, offset)
}

pub fn describe_moment_with_year(
  timestamp: Timestamp,
  offset: Duration,
) -> String {
  let #(date, _) = timestamp.to_calendar(timestamp, offset)

  describe(timestamp, offset)
  <> " "
  <> int.to_string(date.year)
  <> " "
  <> time_of_day(timestamp, offset)
}

pub fn decoder() -> Decoder(Timestamp) {
  use text <- decode.then(decode.string)

  case timestamp.parse_rfc3339(text) {
    Ok(timestamp) -> decode.success(timestamp)
    Error(Nil) -> decode.failure(timestamp.from_unix_seconds(0), "Timestamp")
  }
}

fn time_of_day(timestamp: Timestamp, offset: Duration) -> String {
  let #(_, time) = timestamp.to_calendar(timestamp, offset)

  two_digits(time.hours) <> ":" <> two_digits(time.minutes)
}

fn two_digits(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}
