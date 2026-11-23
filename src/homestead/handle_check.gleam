import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import rsvp

const text_record = 16

pub type Finding {
  PointsHere
  PointsElsewhere
  Malformed
  Absent
  Unreadable
}

pub fn verified_handle(
  result: Result(String, rsvp.Error(String)),
) -> Result(Option(String), Nil) {
  case result {
    Ok(handle) -> Ok(Some(handle))
    Error(rsvp.HttpError(response)) if response.status == 400 -> Ok(None)
    Error(rsvp.HttpError(_))
    | Error(rsvp.BadBody)
    | Error(rsvp.BadUrl(_))
    | Error(rsvp.JsonError(_))
    | Error(rsvp.NetworkError)
    | Error(rsvp.UnhandledResponse(_)) -> Error(Nil)
  }
}

pub fn record_request(handle: Handle) -> Request(String) {
  request.new()
  |> request.set_host("cloudflare-dns.com")
  |> request.set_path("/dns-query")
  |> request.set_query([
    #("name", "_atproto." <> handle.to_string(handle)),
    #("type", "TXT"),
  ])
  |> request.set_header("accept", "application/dns-json")
}

fn records_decoder() -> Decoder(List(String)) {
  let answer = {
    use kind <- decode.field("type", decode.int)
    use data <- decode.field("data", decode.string)

    decode.success(#(kind, data))
  }

  use answers <- decode.optional_field("Answer", [], decode.list(answer))

  decode.success(
    list.filter_map(answers, fn(answer) {
      let #(kind, data) = answer

      case kind == text_record {
        True -> Ok(string.replace(data, each: "\"", with: ""))
        False -> Error(Nil)
      }
    }),
  )
}

pub fn record_finding(
  result: Result(Response(String), rsvp.Error(String)),
  account: Did,
) -> Result(Finding, Nil) {
  use response <- result.try(result.replace_error(result, Nil))
  use records <- result.map(
    json.parse(response.body, records_decoder()) |> result.replace_error(Nil),
  )

  case did.from_txt_records(records) {
    Ok(named) if named == account -> PointsHere
    Ok(_) -> PointsElsewhere
    Error(Nil) -> Absent
  }
}

pub fn file_finding(
  result: Result(Response(String), rsvp.Error(String)),
  account: Did,
) -> Finding {
  case result {
    Ok(response) ->
      case did.from_string(string.trim(response.body)) {
        Ok(named) if named == account -> PointsHere
        Ok(_) -> PointsElsewhere
        Error(Nil) -> Malformed
      }
    Error(rsvp.HttpError(_)) -> Absent
    Error(rsvp.BadBody)
    | Error(rsvp.BadUrl(_))
    | Error(rsvp.JsonError(_))
    | Error(rsvp.NetworkError)
    | Error(rsvp.UnhandledResponse(_)) -> Unreadable
  }
}
