import gleam/json
import homestead/constellation.{Link}

pub fn links_decode_to_one_entry_per_path_with_the_most_linked_first_test() {
  let body =
    "{\"links\":{
      \"app.bsky.feed.post\":{
        \".reply.parent.uri\":{\"records\":2,\"distinct_dids\":2},
        \".embed.record.uri\":{\"records\":1,\"distinct_dids\":1}},
      \"app.bsky.feed.like\":{\".subject.uri\":{\"records\":16,\"distinct_dids\":16}}}}"

  assert json.parse(body, constellation.links_decoder())
    == Ok([
      Link(collection: "app.bsky.feed.like", path: ".subject.uri", records: 16),
      Link(
        collection: "app.bsky.feed.post",
        path: ".reply.parent.uri",
        records: 2,
      ),
      Link(
        collection: "app.bsky.feed.post",
        path: ".embed.record.uri",
        records: 1,
      ),
    ])
}
