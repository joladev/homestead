import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import homestead/repository.{CollectionGroup, NamedCollection}

pub fn only_a_json_object_can_be_saved_as_a_record_test() {
  assert repository.is_json_object("{\"text\": \"Hello\"}")
  assert !repository.is_json_object("[1, 2]")
  assert !repository.is_json_object("{ not json")
}

pub fn collections_are_grouped_by_the_app_that_owns_them_test() {
  assert repository.group_collections([
      "app.bsky.feed.post",
      "org.tangled.feed.star",
      "app.bsky.actor.profile",
      "self",
    ])
    == [
      CollectionGroup(owner: "bsky.app", collections: [
        NamedCollection(
          id: "app.bsky.actor.profile",
          prefix: "app.bsky.",
          name: "actor.profile",
        ),
        NamedCollection(
          id: "app.bsky.feed.post",
          prefix: "app.bsky.",
          name: "feed.post",
        ),
      ]),
      CollectionGroup(owner: "self", collections: [
        NamedCollection(id: "self", prefix: "", name: "self"),
      ]),
      CollectionGroup(owner: "tangled.org", collections: [
        NamedCollection(
          id: "org.tangled.feed.star",
          prefix: "org.tangled.",
          name: "feed.star",
        ),
      ]),
    ]
}

pub fn a_timestamp_key_tells_when_the_record_was_written_test() {
  let assert Ok(written) = repository.written("3n2w2jfxiuc2o")

  assert string.slice(timestamp.to_rfc3339(written, calendar.utc_offset), 0, 19)
    == "2026-11-22T16:39:25"
  assert repository.written("self") == Error(Nil)
}
