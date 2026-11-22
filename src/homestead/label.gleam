import at/did.{type Did}
import at/did_document.{type DidDocument, ServiceEndpoint}
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import homestead/date

const relay = "https://labelers.firehose.stream"

const page_size = 250

pub type Event {
  Event(
    labeler: Did,
    subject: String,
    value: String,
    at: Timestamp,
    expires: Option(Timestamp),
    is_removal: Bool,
  )
}

pub type Page {
  Page(events: List(Event), unreadable: Int, next: Option(String))
}

pub type Label {
  Label(labeler: Did, value: String, state: State)
}

pub type State {
  Active(since: Timestamp, expires: Option(Timestamp))
  Expired(since: Timestamp, at: Timestamp)
  Removed(at: Timestamp)
}

pub fn subjects(account: Did) -> List(String) {
  let account = did.to_string(account)

  [account, "at://" <> account <> "/app.bsky.actor.profile/self"]
}

pub fn relay_request(
  subject: String,
  after: Option(String),
) -> Request(String) {
  let assert Ok(request) = request.to(relay)

  query(request, subject, after)
}

pub fn labeler_request(
  server: Uri,
  subject: String,
  after: Option(String),
) -> Result(Request(String), Nil) {
  request.from_uri(server)
  |> result.map(query(_, subject, after))
}

fn query(
  request: Request(String),
  subject: String,
  after: Option(String),
) -> Request(String) {
  let page = [#("uriPatterns", subject), #("limit", int.to_string(page_size))]

  request
  |> request.set_path("/xrpc/com.atproto.label.queryLabels")
  |> request.set_query(case after {
    Some(cursor) -> [#("cursor", cursor), ..page]
    None -> page
  })
  |> request.set_header("accept", "application/json")
}

pub fn server(document: DidDocument) -> Result(Uri, Nil) {
  use service <- list.find_map(document.service)

  case service {
    ServiceEndpoint(
      id: did.Url(fragment: Some("#atproto_labeler"), ..),
      type_: "AtprotoLabeler",
      service_endpoint:,
    ) -> Ok(service_endpoint)
    _ -> Error(Nil)
  }
}

pub fn read(body: String) -> Result(Page, Nil) {
  let label =
    decode.one_of(decode.map(event_decoder(), Ok), [
      decode.success(Error(Nil)),
    ])

  json.parse(body, {
    use labels <- decode.field("labels", decode.list(label))
    use cursor <- decode.optional_field(
      "cursor",
      None,
      decode.optional(decode.string),
    )
    let #(events, unreadable) = result.partition(labels)

    decode.success(
      Page(
        events: list.reverse(events),
        unreadable: list.length(unreadable),
        next: case list.length(labels) < page_size {
          True -> None
          False -> cursor
        },
      ),
    )
  })
  |> result.replace_error(Nil)
}

fn event_decoder() -> Decoder(Event) {
  use labeler <- decode.field("src", did.decoder())
  use subject <- decode.field("uri", decode.string)
  use value <- decode.field("val", decode.string)
  use at <- decode.field("cts", date.decoder())
  use expires <- decode.optional_field(
    "exp",
    None,
    decode.optional(date.decoder()),
  )
  use is_removal <- decode.optional_field("neg", False, decode.bool)

  decode.success(Event(labeler:, subject:, value:, at:, expires:, is_removal:))
}

pub fn history(events: List(Event), now: Timestamp) -> List(Label) {
  list.group(events, fn(event) { #(event.labeler, event.subject, event.value) })
  |> dict.values
  |> list.flat_map(periods(_, now))
  |> list.sort(fn(one, other) {
    timestamp.compare(changed(other), changed(one))
  })
}

fn changed(label: Label) -> Timestamp {
  case label.state {
    Active(since:, ..) -> since
    Expired(at:, ..) -> at
    Removed(at:) -> at
  }
}

fn periods(events: List(Event), now: Timestamp) -> List(Label) {
  let assert [Event(labeler:, value:, ..), ..] = events
  let label = fn(state) { Label(labeler:, value:, state:) }
  let #(open, closed) =
    list.sort(events, fn(one, other) { timestamp.compare(one.at, other.at) })
    |> list.fold(#(None, []), fn(found, event) {
      let #(open, closed) = found

      case event.is_removal, open {
        True, _ -> #(None, [label(Removed(at: event.at)), ..closed])
        False, None -> #(Some(#(event.at, event.expires)), closed)
        False, Some(#(since, _)) -> #(Some(#(since, event.expires)), closed)
      }
    })

  case open {
    None -> closed
    Some(#(since, None)) -> [label(Active(since:, expires: None)), ..closed]
    Some(#(since, Some(expires))) ->
      case timestamp.compare(expires, now) {
        order.Gt -> [label(Active(since:, expires: Some(expires))), ..closed]
        order.Lt | order.Eq -> [label(Expired(since:, at: expires)), ..closed]
      }
  }
}

pub fn names_request(
  server: Uri,
  labeler: Did,
) -> Result(Request(String), Nil) {
  use request <- result.map(request.from_uri(server))

  request
  |> request.set_path("/xrpc/com.atproto.repo.getRecord")
  |> request.set_query([
    #("repo", did.to_string(labeler)),
    #("collection", "app.bsky.labeler.service"),
    #("rkey", "self"),
  ])
  |> request.set_header("accept", "application/json")
}

pub fn read_names(body: String) -> Result(Dict(String, String), Nil) {
  let definition = {
    use value <- decode.field("identifier", decode.string)
    use names <- decode.field(
      "locales",
      decode.list({
        use language <- decode.field("lang", decode.string)
        use name <- decode.field("name", decode.string)

        decode.success(#(language, name))
      }),
    )

    decode.success(#(value, names))
  }

  json.parse(
    body,
    decode.at(
      ["value", "policies", "labelValueDefinitions"],
      decode.list(definition),
    ),
  )
  |> result.replace_error(Nil)
  |> result.map(fn(definitions) {
    list.filter_map(definitions, fn(definition) {
      let #(value, names) = definition

      case list.key_find(names, "en"), names {
        Ok(name), _ -> Ok(#(value, name))
        Error(Nil), [#(_, name), ..] -> Ok(#(value, name))
        Error(Nil), [] -> Error(Nil)
      }
    })
    |> dict.from_list
  })
}
