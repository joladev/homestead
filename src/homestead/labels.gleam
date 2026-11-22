import at/did.{type Did}
import at/did_document.{type DidDocument}
import at/handle.{type Handle}
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import homestead/browser
import homestead/date
import homestead/identity
import homestead/label.{type Event, type Label, Active, Expired, Removed}
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

const patience_milliseconds = 5000

pub opaque type Model {
  Model(
    account: Did,
    directory: Uri,
    local_offset: Duration,
    opened: Timestamp,
    relay: Remote(Nil),
    labelers: Dict(Did, Labeler),
  )
}

type Labeler {
  Labeler(
    handle: Option(Handle),
    names: Dict(String, String),
    labels: Remote(Found),
  )
}

type Found {
  Found(events: List(Event), unreadable: Int)
}

pub fn init(session: Session, directory: Uri) -> #(Model, Effect(Message)) {
  let account = session.account(session)
  let opened = timestamp.system_time()
  let assert [subject, ..rest] = label.subjects(account)

  #(
    Model(
      account:,
      directory:,
      local_offset: calendar.local_offset(),
      opened:,
      relay: Loading,
      labelers: dict.new(),
    ),
    effect.batch([
      ask_relay(subject, None, rest),
      browser.after(patience_milliseconds, RelayTookTooLong(opened)),
    ]),
  )
}

pub opaque type Message {
  RelayReturnedLabelers(
    subject: String,
    rest: List(String),
    result: Result(label.Page, Problem),
  )
  RelayTookTooLong(opened: Timestamp)
  DirectoryReturnedLabeler(labeler: Did, result: Result(DidDocument, Problem))
  LabelerReturnedLabels(
    labeler: Did,
    server: Uri,
    subject: String,
    rest: List(String),
    earlier: Found,
    result: Result(label.Page, Problem),
  )
  LabelersTookTooLong(opened: Timestamp, labelers: List(Did))
  LabelerReturnedNames(labeler: Did, result: Result(Dict(String, String), Nil))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    RelayReturnedLabelers(subject:, rest:, result: Ok(page)) -> {
      let #(model, meeting) = meet_labelers(model, page.events)

      case page.next, rest {
        Some(after), _ -> #(
          model,
          effect.batch([meeting, ask_relay(subject, Some(after), rest)]),
        )
        None, [subject, ..rest] -> #(
          model,
          effect.batch([meeting, ask_relay(subject, None, rest)]),
        )
        None, [] -> #(Model(..model, relay: Loaded(Nil)), meeting)
      }
    }

    RelayReturnedLabelers(result: Error(problem), ..) -> #(
      Model(..model, relay: Failed(problem:)),
      effect.none(),
    )

    RelayTookTooLong(opened:) if opened == model.opened -> #(
      Model(..model, relay: give_up(model.relay)),
      effect.none(),
    )

    DirectoryReturnedLabeler(labeler:, result: Ok(document)) -> {
      let model =
        change(model, labeler, fn(known) {
          Labeler(
            ..known,
            handle: did_document.also_known_as(document) |> option.from_result,
          )
        })
      let assert [subject, ..rest] = label.subjects(model.account)
      let found = Found(events: [], unreadable: 0)

      case label.server(document) {
        Ok(server) -> #(
          model,
          effect.batch([
            ask_labeler(labeler, server, subject, None, rest, found),
            ask_names(labeler, document),
          ]),
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
            Labeler(..known, labels: Loaded(found))
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
          Labeler(..known, labels: give_up(known.labels))
        })
      }),
      effect.none(),
    )

    LabelerReturnedNames(labeler:, result: Ok(names)) -> #(
      change(model, labeler, fn(known) { Labeler(..known, names:) }),
      effect.none(),
    )

    RelayTookTooLong(_)
    | LabelersTookTooLong(..)
    | LabelerReturnedNames(result: Error(Nil), ..) -> #(model, effect.none())
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

  #(
    Model(
      ..model,
      labelers: list.fold(unknown, model.labelers, fn(labelers, labeler) {
        dict.insert(
          labelers,
          labeler,
          Labeler(handle: None, names: dict.new(), labels: Loading),
        )
      }),
    ),
    case unknown {
      [] -> effect.none()
      [_, ..] ->
        effect.batch([
          browser.after(
            patience_milliseconds,
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
    },
  )
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
  change(model, labeler, fn(known) {
    Labeler(..known, labels: Failed(problem:))
  })
}

fn give_up(waiting: Remote(value)) -> Remote(value) {
  case waiting {
    Loading -> Failed(tranquil.Unreachable)
    Loaded(_) | Failed(_) -> waiting
  }
}

fn ask_relay(
  subject: String,
  after: Option(String),
  rest: List(String),
) -> Effect(Message) {
  rsvp.send(
    label.relay_request(subject, after),
    expect_labels(RelayReturnedLabelers(subject, rest, _)),
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

  case label.labeler_request(server, subject, after) {
    Ok(request) -> rsvp.send(request, expect_labels(to_message))
    Error(Nil) ->
      effect.from(fn(dispatch) {
        dispatch(to_message(Error(tranquil.NotUnderstood)))
      })
  }
}

fn expect_labels(
  to_message: fn(Result(label.Page, Problem)) -> Message,
) -> rsvp.Handler(String, Message) {
  rsvp.expect_ok_response(fn(response) {
    to_message(
      result.replace_error(response, tranquil.Unreachable)
      |> result.try(fn(response) {
        label.read(response.body)
        |> result.replace_error(tranquil.NotUnderstood)
      }),
    )
  })
}

fn ask_names(labeler: Did, document: DidDocument) -> Effect(Message) {
  case
    did_document.pds(document)
    |> result.try(label.names_request(_, labeler))
  {
    Ok(request) ->
      rsvp.send(
        request,
        rsvp.expect_ok_response(fn(response) {
          LabelerReturnedNames(
            labeler,
            result.replace_error(response, Nil)
              |> result.try(fn(response) { label.read_names(response.body) }),
          )
        }),
      )
    Error(Nil) -> effect.none()
  }
}

pub fn view(model: Model) -> Element(Message) {
  let labelers = dict.to_list(model.labelers)
  let is_waiting =
    list.any(labelers, fn(labeler) { { labeler.1 }.labels == Loading })

  layout.page([
    layout.title_section("labels", [
      layout.block(case model.relay, is_waiting {
        Failed(_), _ -> [layout.problem("Couldn't load labels")]
        Loading, _ | Loaded(_), True -> [layout.loading(3)]
        Loaded(_), False -> view_labels(model, labelers)
      }),
    ]),
  ])
}

fn view_labels(
  model: Model,
  labelers: List(#(Did, Labeler)),
) -> List(Element(Message)) {
  let found =
    list.filter_map(labelers, fn(labeler) {
      case { labeler.1 }.labels {
        Loaded(value:) -> Ok(value)
        Loading | Failed(_) -> Error(Nil)
      }
    })
  let events = list.flat_map(found, fn(found) { found.events })
  let unanswered =
    list.filter_map(labelers, fn(labeler) {
      case { labeler.1 }.labels {
        Failed(_) ->
          Ok(layout.problem(
            "Couldn't load labels from " <> name(model, labeler.0),
          ))
        Loading | Loaded(_) -> Error(Nil)
      }
    })

  list.append(
    layout.listing(
      empty: "No labels",
      rows: label.history(events, model.opened)
        |> list.map(view_label(model, _))
        |> list.append(unanswered),
      actions: [],
    ),
    case int.sum(list.map(found, fn(found) { found.unreadable })) {
      0 -> []
      1 -> [layout.note("1 label couldn't be read", [])]
      count -> [
        layout.note(int.to_string(count) <> " labels couldn't be read", []),
      ]
    },
  )
}

fn view_label(model: Model, found: Label) -> Element(Message) {
  let day = date.describe_day(_, model.local_offset)
  let #(tone, when) = case found.state {
    Active(since:, expires: None) -> #(layout.Plain, "added " <> day(since))
    Active(since:, expires: Some(expires)) -> #(
      layout.Plain,
      "added " <> day(since) <> " \u{00B7} expires " <> day(expires),
    )
    Expired(since:, at:) -> #(
      layout.Past,
      "added " <> day(since) <> " \u{00B7} expired " <> day(at),
    )
    Removed(at:) -> #(layout.Past, "removed " <> day(at))
  }

  layout.row(
    tone:,
    name: dict.get(model.labelers, found.labeler)
      |> result.try(fn(labeler) { dict.get(labeler.names, found.value) })
      |> result.unwrap(found.value),
    details: [
      html.text("by " <> name(model, found.labeler) <> " \u{00B7} " <> when),
    ],
    actions: [],
  )
}

fn name(model: Model, labeler: Did) -> String {
  case dict.get(model.labelers, labeler) {
    Ok(Labeler(handle: Some(handle), ..)) -> "@" <> handle.to_string(handle)
    Ok(Labeler(handle: None, ..)) | Error(Nil) -> did.to_string(labeler)
  }
}
