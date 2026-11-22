import at/did.{type Did}
import at/did_document.{type DidDocument}
import at/handle.{type Handle}
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
  let subjects = label.subjects(account)

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
  RelayReturnedLabelers(subject: String, result: Result(label.Page, Problem))
  RelayTookTooLong(opened: Timestamp)
  AppViewReturnedLabels(
    labelers: List(Did),
    result: Result(label.Page, Problem),
  )
  AppViewReturnedServices(result: Result(List(label.Service), Problem))
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
      let assert [subject, ..rest] = label.subjects(model.account)
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

      case label.server(document) {
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
          label.services_request(unknown),
          rsvp.expect_ok_response(fn(response) {
            AppViewReturnedServices(
              result.replace_error(response, tranquil.Unreachable)
              |> result.try(fn(response) {
                label.read_services(response.body)
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
    label.relay_request(subject, after),
    expect_labels(RelayReturnedLabelers(subject, _)),
  )
}

fn ask_appview(
  model: Model,
  labelers: List(Did),
  after: Option(String),
) -> Effect(Message) {
  rsvp.send(
    label.appview_request(model.account, labelers, after),
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

pub fn view(model: Model) -> Element(Message) {
  let labelers = dict.values(model.labelers)
  let labels =
    list.flat_map(labelers, fn(labeler) {
      case labeler.own {
        Loaded(value: found) -> found.events
        Loading | Failed(_) -> labeler.active
      }
    })
    |> label.history(model.opened)
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
