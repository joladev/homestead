import at/did.{type Did}
import at/did_document.{type DidDocument, ServiceEndpoint}
import at/handle.{type Handle}
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import homestead/browser
import homestead/date
import homestead/identity
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

const relay_patience_milliseconds = 5000

const labeler_patience_milliseconds = 2500

pub opaque type Model {
  Model(
    account: Did,
    directory: Uri,
    local_offset: Duration,
    opened: Timestamp,
    relay: Relay,
    labelers: Dict(Did, Labeler),
  )
}

type Relay {
  Asking(subjects: Int)
  Answered
  Unanswered
}

type Labeler {
  Labeler(
    handle: Option(Handle),
    image: Option(String),
    names: Dict(String, String),
    active: List(Event),
    own: Remote(Found),
  )
}

type Found {
  Found(events: List(Event), unreadable: Int)
}

pub fn init(session: Session, directory: Uri) -> #(Model, Effect(Message)) {
  let account = session.account(session)
  let opened = timestamp.system_time()
  let subjects = subjects(account)

  #(
    Model(
      account:,
      directory:,
      local_offset: calendar.local_offset(),
      opened:,
      relay: Asking(subjects: list.length(subjects)),
      labelers: dict.new(),
    ),
    effect.batch([
      browser.after(relay_patience_milliseconds, RelayTookTooLong(opened)),
      ..list.map(subjects, ask_relay(_, None))
    ]),
  )
}

pub opaque type Message {
  RelayReturnedLabelers(subject: String, result: Result(Page, Problem))
  RelayTookTooLong(opened: Timestamp)
  AppViewReturnedLabels(labelers: List(Did), result: Result(Page, Problem))
  AppViewReturnedServices(result: Result(List(Service), Problem))
  DirectoryReturnedLabeler(labeler: Did, result: Result(DidDocument, Problem))
  LabelerReturnedLabels(
    labeler: Did,
    server: Uri,
    subject: String,
    rest: List(String),
    earlier: Found,
    result: Result(Page, Problem),
  )
  LabelersTookTooLong(opened: Timestamp, labelers: List(Did))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    RelayReturnedLabelers(subject:, result: Ok(page)) -> {
      let #(model, meeting) = meet_labelers(model, page.events)

      case page.next, model.relay {
        Some(after), _ -> #(
          model,
          effect.batch([meeting, ask_relay(subject, Some(after))]),
        )
        None, Asking(subjects: 1) -> #(Model(..model, relay: Answered), meeting)
        None, Asking(subjects:) -> #(
          Model(..model, relay: Asking(subjects: subjects - 1)),
          meeting,
        )
        None, Answered | None, Unanswered -> #(model, meeting)
      }
    }

    RelayReturnedLabelers(result: Error(_), ..) -> #(
      Model(..model, relay: Unanswered),
      effect.none(),
    )

    RelayTookTooLong(opened:) if opened == model.opened -> #(
      Model(..model, relay: case model.relay {
        Asking(_) -> Unanswered
        Answered | Unanswered -> model.relay
      }),
      effect.none(),
    )

    AppViewReturnedLabels(labelers:, result: Ok(page)) -> #(
      list.fold(page.events, model, fn(model, event) {
        change(model, event.labeler, fn(known) {
          Labeler(..known, active: [event, ..known.active])
        })
      }),
      case page.next {
        Some(after) -> ask_appview(model, labelers, Some(after))
        None -> effect.none()
      },
    )

    AppViewReturnedServices(result: Ok(services)) -> #(
      list.fold(services, model, fn(model, service) {
        change(model, service.labeler, fn(known) {
          Labeler(
            ..known,
            handle: Some(service.handle),
            image: service.image,
            names: service.names,
          )
        })
      }),
      effect.none(),
    )

    DirectoryReturnedLabeler(labeler:, result: Ok(document)) -> {
      let assert [subject, ..rest] = subjects(model.account)
      let model =
        change(model, labeler, fn(known) {
          Labeler(
            ..known,
            handle: option.or(
              known.handle,
              did_document.also_known_as(document) |> option.from_result,
            ),
          )
        })

      case server(document) {
        Ok(server) -> #(
          model,
          ask_labeler(
            labeler,
            server,
            subject,
            None,
            rest,
            Found(events: [], unreadable: 0),
          ),
        )
        Error(Nil) -> #(
          fail(model, labeler, tranquil.NotUnderstood),
          effect.none(),
        )
      }
    }

    DirectoryReturnedLabeler(labeler:, result: Error(problem)) -> #(
      fail(model, labeler, problem),
      effect.none(),
    )

    LabelerReturnedLabels(
      labeler:,
      server:,
      subject:,
      rest:,
      earlier:,
      result: Ok(page),
    ) -> {
      let found =
        Found(
          events: list.filter(page.events, fn(event) {
            event.labeler == labeler
          })
            |> list.append(earlier.events, _),
          unreadable: earlier.unreadable + page.unreadable,
        )

      case page.next, rest {
        Some(after), _ -> #(
          model,
          ask_labeler(labeler, server, subject, Some(after), rest, found),
        )
        None, [subject, ..rest] -> #(
          model,
          ask_labeler(labeler, server, subject, None, rest, found),
        )
        None, [] -> #(
          change(model, labeler, fn(known) {
            Labeler(..known, own: Loaded(found))
          }),
          effect.none(),
        )
      }
    }

    LabelerReturnedLabels(labeler:, result: Error(problem), ..) -> #(
      fail(model, labeler, problem),
      effect.none(),
    )

    LabelersTookTooLong(opened:, labelers:) if opened == model.opened -> #(
      list.fold(labelers, model, fn(model, labeler) {
        change(model, labeler, fn(known) {
          case known.own {
            Loading -> Labeler(..known, own: Failed(tranquil.Unreachable))
            Loaded(_) | Failed(_) -> known
          }
        })
      }),
      effect.none(),
    )

    RelayTookTooLong(_)
    | LabelersTookTooLong(..)
    | AppViewReturnedLabels(result: Error(_), ..)
    | AppViewReturnedServices(result: Error(_)) -> #(model, effect.none())
  }
}

fn meet_labelers(
  model: Model,
  events: List(Event),
) -> #(Model, Effect(Message)) {
  let unknown =
    list.map(events, fn(event) { event.labeler })
    |> list.unique
    |> list.filter(fn(labeler) { !dict.has_key(model.labelers, labeler) })
  let model =
    Model(
      ..model,
      labelers: list.fold(unknown, model.labelers, fn(labelers, labeler) {
        dict.insert(
          labelers,
          labeler,
          Labeler(
            handle: None,
            image: None,
            names: dict.new(),
            active: [],
            own: Loading,
          ),
        )
      }),
    )

  #(model, case unknown {
    [] -> effect.none()
    [_, ..] ->
      effect.batch([
        ask_appview(model, unknown, None),
        rsvp.send(
          services_request(unknown),
          rsvp.expect_ok_response(fn(response) {
            AppViewReturnedServices(
              result.replace_error(response, tranquil.Unreachable)
              |> result.try(fn(response) {
                read_services(response.body)
                |> result.replace_error(tranquil.NotUnderstood)
              }),
            )
          }),
        ),
        browser.after(
          labeler_patience_milliseconds,
          LabelersTookTooLong(model.opened, unknown),
        ),
        ..list.map(unknown, fn(labeler) {
          rsvp.send(
            identity.document_request(model.directory, labeler),
            rsvp.expect_ok_response(fn(response) {
              DirectoryReturnedLabeler(
                labeler,
                result.replace_error(response, tranquil.Unreachable)
                  |> result.try(fn(response) {
                    json.parse(response.body, did_document.decoder())
                    |> result.replace_error(tranquil.NotUnderstood)
                  }),
              )
            }),
          )
        })
      ])
  })
}

fn change(model: Model, labeler: Did, with: fn(Labeler) -> Labeler) -> Model {
  case dict.get(model.labelers, labeler) {
    Ok(known) ->
      Model(
        ..model,
        labelers: dict.insert(model.labelers, labeler, with(known)),
      )
    Error(Nil) -> model
  }
}

fn fail(model: Model, labeler: Did, problem: Problem) -> Model {
  change(model, labeler, fn(known) { Labeler(..known, own: Failed(problem:)) })
}

fn ask_relay(subject: String, after: Option(String)) -> Effect(Message) {
  rsvp.send(
    relay_request(subject, after),
    expect_labels(RelayReturnedLabelers(subject, _)),
  )
}

fn ask_appview(
  model: Model,
  labelers: List(Did),
  after: Option(String),
) -> Effect(Message) {
  rsvp.send(
    appview_request(model.account, labelers, after),
    expect_labels(AppViewReturnedLabels(labelers, _)),
  )
}

fn ask_labeler(
  labeler: Did,
  server: Uri,
  subject: String,
  after: Option(String),
  rest: List(String),
  earlier: Found,
) -> Effect(Message) {
  let to_message = LabelerReturnedLabels(
    labeler,
    server,
    subject,
    rest,
    earlier,
    _,
  )

  case labeler_request(server, subject, after) {
    Ok(request) -> rsvp.send(request, expect_labels(to_message))
    Error(Nil) ->
      effect.from(fn(dispatch) {
        dispatch(to_message(Error(tranquil.NotUnderstood)))
      })
  }
}

fn expect_labels(
  to_message: fn(Result(Page, Problem)) -> Message,
) -> rsvp.Handler(String, Message) {
  rsvp.expect_ok_response(fn(response) {
    to_message(
      result.replace_error(response, tranquil.Unreachable)
      |> result.try(fn(response) {
        read(response.body)
        |> result.replace_error(tranquil.NotUnderstood)
      }),
    )
  })
}

pub fn view(model: Model) -> Element(Message) {
  let labelers = dict.values(model.labelers)
  let labels =
    list.flat_map(labelers, fn(labeler) {
      case labeler.own {
        Loaded(value: found) -> found.events
        Loading | Failed(_) -> labeler.active
      }
    })
    |> history(model.opened)
  let is_waiting =
    list.any(labelers, fn(labeler) { labeler.own == Loading })
    || model.relay != Answered

  layout.page([
    layout.title_section("labels", [
      layout.block(case model.relay, labels {
        Unanswered, _ -> [layout.problem("Couldn't load labels")]
        Asking(_), [] | Answered, [] if is_waiting -> [layout.loading(3)]
        Asking(_), _ | Answered, _ ->
          list.flatten([
            list.map(labels, view_label(model, _)),
            case is_waiting {
              True -> [layout.loading(1)]
              False -> view_gaps(model, labels)
            },
          ])
      }),
    ]),
  ])
}

fn view_gaps(model: Model, labels: List(Label)) -> List(Element(Message)) {
  let unanswered =
    dict.to_list(model.labelers)
    |> list.filter_map(fn(labeler) {
      case { labeler.1 }.own {
        Failed(_) -> Ok(name(model, labeler.0))
        Loading | Loaded(_) -> Error(Nil)
      }
    })
  let unreadable =
    dict.values(model.labelers)
    |> list.map(fn(labeler) {
      case labeler.own {
        Loaded(value: found) -> found.unreadable
        Loading | Failed(_) -> 0
      }
    })
    |> int.sum

  list.flatten([
    case labels, unanswered {
      [], [] -> [layout.note("No labels", [])]
      _, _ -> []
    },
    case unanswered {
      [] -> []
      [_, ..] -> [
        layout.note("No answer from " <> string.join(unanswered, ", "), []),
      ]
    },
    case unreadable {
      0 -> []
      1 -> [layout.note("1 label couldn't be read", [])]
      count -> [
        layout.note(int.to_string(count) <> " labels couldn't be read", []),
      ]
    },
  ])
}

fn view_label(model: Model, found: Label) -> Element(Message) {
  let day = date.describe_day(_, model.local_offset)
  let labeler = dict.get(model.labelers, found.labeler)
  let #(state, is_past, when) = case found.state {
    Active(since:, expires: None) -> #("active", False, [
      "added " <> day(since),
    ])
    Active(since:, expires: Some(expires)) -> #("active", False, [
      "added " <> day(since),
      "expires " <> day(expires),
    ])
    Expired(since:, at:) -> #("expired", True, [
      "added " <> day(since),
      "expired " <> day(at),
    ])
    Removed(at:) -> #("removed", True, ["removed " <> day(at)])
  }

  html.div(
    [
      attribute.classes([
        #("row label-row", True),
        #("past", is_past),
      ]),
    ],
    [
      html.div([attribute.class("what")], [
        html.span([attribute.class("title")], [
          html.strong([], [
            html.text(
              result.try(labeler, fn(labeler) {
                dict.get(labeler.names, found.value)
              })
              |> result.unwrap(found.value),
            ),
          ]),
          html.span([attribute.class("state")], [html.text(state)]),
        ]),
        html.span([attribute.class("labeler")], [
          case labeler {
            Ok(Labeler(image: Some(url), ..)) ->
              html.img([
                attribute.src(url),
                attribute.alt(""),
                attribute.width(20),
                attribute.height(20),
                attribute.loading("lazy"),
              ])
            Ok(Labeler(image: None, ..)) | Error(Nil) ->
              html.span([attribute.class("no-avatar")], [])
          },
          html.text(name(model, found.labeler)),
        ]),
      ]),
      html.div(
        [attribute.class("when")],
        list.map(when, fn(line) { html.span([], [html.text(line)]) }),
      ),
    ],
  )
}

fn name(model: Model, labeler: Did) -> String {
  case dict.get(model.labelers, labeler) {
    Ok(Labeler(handle: Some(handle), ..)) -> "@" <> handle.to_string(handle)
    Ok(Labeler(handle: None, ..)) | Error(Nil) -> did.to_string(labeler)
  }
}

const relay = "https://labelers.firehose.stream"

const appview = "https://public.api.bsky.app"

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

pub type Service {
  Service(
    labeler: Did,
    handle: Handle,
    image: Option(String),
    names: Dict(String, String),
  )
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

  query(request, [subject], [], after)
}

pub fn appview_request(
  account: Did,
  labelers: List(Did),
  after: Option(String),
) -> Request(String) {
  let assert Ok(request) = request.to(appview)

  query(request, subjects(account), labelers, after)
}

pub fn labeler_request(
  server: Uri,
  subject: String,
  after: Option(String),
) -> Result(Request(String), Nil) {
  request.from_uri(server)
  |> result.map(query(_, [subject], [], after))
}

fn query(
  request: Request(String),
  subjects: List(String),
  labelers: List(Did),
  after: Option(String),
) -> Request(String) {
  let page =
    list.flatten([
      list.map(subjects, fn(subject) { #("uriPatterns", subject) }),
      list.map(labelers, fn(labeler) { #("sources", did.to_string(labeler)) }),
      [#("limit", int.to_string(page_size))],
    ])

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

pub fn services_request(labelers: List(Did)) -> Request(String) {
  let assert Ok(request) = request.to(appview)

  request
  |> request.set_path("/xrpc/app.bsky.labeler.getServices")
  |> request.set_query([
    #("detailed", "true"),
    ..list.map(labelers, fn(labeler) { #("dids", did.to_string(labeler)) })
  ])
  |> request.set_header("accept", "application/json")
}

pub fn read_services(body: String) -> Result(List(Service), Nil) {
  json.parse(body, decode.at(["views"], decode.list(service_decoder())))
  |> result.replace_error(Nil)
}

fn service_decoder() -> Decoder(Service) {
  let name = {
    use language <- decode.field("lang", decode.string)
    use name <- decode.field("name", decode.string)

    decode.success(#(language, name))
  }
  let definition = {
    use value <- decode.field("identifier", decode.string)
    use names <- decode.field("locales", decode.list(name))

    decode.success(#(value, names))
  }

  use labeler <- decode.subfield(["creator", "did"], did.decoder())
  use handle <- decode.subfield(["creator", "handle"], handle.decoder())
  use image <- decode.then(decode.optionally_at(
    ["creator", "avatar"],
    None,
    decode.optional(decode.string),
  ))
  use definitions <- decode.then(decode.optionally_at(
    ["policies", "labelValueDefinitions"],
    [],
    decode.list(definition),
  ))

  decode.success(Service(
    labeler:,
    handle:,
    image:,
    names: list.filter_map(definitions, fn(definition) {
      let #(value, names) = definition

      case list.key_find(names, "en"), names {
        Ok(name), _ -> Ok(#(value, name))
        Error(Nil), [#(_, name), ..] -> Ok(#(value, name))
        Error(Nil), [] -> Error(Nil)
      }
    })
      |> dict.from_list,
  ))
}
