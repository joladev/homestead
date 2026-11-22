import at/did.{type Did}
import at/handle
import gleam/dict
import gleam/option.{None, Some}
import gleam/time/timestamp.{type Timestamp}
import homestead/label.{Active, Expired, Label, Page, Removed, Service}

fn at(text: String) -> Timestamp {
  let assert Ok(time) = timestamp.parse_rfc3339(text)

  time
}

fn labeler() -> Did {
  let assert Ok(labeler) = did.from_string("did:plc:ar7c4by46qjdydhdevvrndac")

  labeler
}

pub fn a_page_of_labels_keeps_count_of_the_ones_it_cannot_read_test() {
  let body =
    "{\"cursor\":\"12\",\"labels\":[
      {\"src\":\"did:plc:ar7c4by46qjdydhdevvrndac\",
       \"uri\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"val\":\"spam\",
       \"cts\":\"2026-04-28T06:48:26.030Z\",\"exp\":\"2026-05-05T06:48:26.030Z\"},
      {\"src\":\"did:plc:ar7c4by46qjdydhdevvrndac\",\"val\":\"no subject\"}]}"

  let assert Ok(Page(events: [event], unreadable:, next:)) = label.read(body)

  assert event.labeler == labeler()
  assert event.value == "spam"
  assert event.expires == Some(at("2026-05-05T06:48:26.030Z"))
  assert !event.is_removal
  assert unreadable == 1
  assert next == None
}

pub fn a_removal_closes_the_label_it_removes_test() {
  let event = fn(value, time, expires, is_removal) {
    label.Event(
      labeler: labeler(),
      subject: "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      value:,
      at: at(time),
      expires:,
      is_removal:,
    )
  }
  let found = fn(value, state) { Label(labeler: labeler(), value:, state:) }

  assert label.history(
      [
        event("spam", "2026-01-01T00:00:00Z", None, False),
        event("spam", "2026-02-01T00:00:00Z", None, True),
        event("elder", "2025-06-01T00:00:00Z", None, False),
        event(
          "event",
          "2026-03-01T00:00:00Z",
          Some(at("2026-04-01T00:00:00Z")),
          False,
        ),
      ],
      at("2026-11-22T00:00:00Z"),
    )
    == [
      found(
        "event",
        Expired(
          since: at("2026-03-01T00:00:00Z"),
          at: at("2026-04-01T00:00:00Z"),
        ),
      ),
      found("spam", Removed(at: at("2026-02-01T00:00:00Z"))),
      found("elder", Active(since: at("2025-06-01T00:00:00Z"), expires: None)),
    ]
}

pub fn a_labeler_service_carries_its_handle_image_and_label_names_test() {
  let body =
    "{\"views\":[
      {\"creator\":{\"did\":\"did:plc:ar7c4by46qjdydhdevvrndac\",
        \"handle\":\"moderation.bsky.app\",\"avatar\":\"https://cdn.test/a\"},
       \"policies\":{\"labelValueDefinitions\":[
        {\"identifier\":\"us-gov-account\",\"locales\":[
          {\"lang\":\"en\",\"name\":\"United States Government Account\"}]}]}},
      {\"creator\":{\"did\":\"did:plc:ar7c4by46qjdydhdevvrndac\",
        \"handle\":\"moderation.bsky.app\"},
       \"policies\":{\"labelValues\":[\"spam\"]}}]}"
  let assert Ok(handle) = handle.from_string("moderation.bsky.app")

  assert label.read_services(body)
    == Ok([
      Service(
        labeler: labeler(),
        handle:,
        image: Some("https://cdn.test/a"),
        names: dict.from_list([
          #("us-gov-account", "United States Government Account"),
        ]),
      ),
      Service(labeler: labeler(), handle:, image: None, names: dict.new()),
    ])
}
