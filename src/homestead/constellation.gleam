import at/did.{type Did}
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Link {
  Link(collection: String, path: String, records: Int, accounts: Int)
}

pub type Linking {
  Linking(account: Did, key: String)
}

pub type Page {
  Page(records: List(Linking), next: Option(String))
}

pub fn links_request(target: String) -> Request(String) {
  request.new()
  |> request.set_host("constellation.microcosm.blue")
  |> request.set_path("/links/all")
  |> request.set_query([#("target", target)])
  |> request.set_header("accept", "application/json")
}

pub fn links_decoder() -> Decoder(List(Link)) {
  let counts = {
    use records <- decode.field("records", decode.int)
    use accounts <- decode.field("distinct_dids", decode.int)

    decode.success(#(records, accounts))
  }
  let paths = decode.dict(decode.string, counts)

  use collections <- decode.field("links", decode.dict(decode.string, paths))

  decode.success(
    dict.to_list(collections)
    |> list.flat_map(fn(collection) {
      dict.to_list(collection.1)
      |> list.map(fn(path) {
        Link(
          collection: collection.0,
          path: path.0,
          records: path.1.0,
          accounts: path.1.1,
        )
      })
    })
    |> list.sort(fn(one, other) { int.compare(other.records, one.records) }),
  )
}

pub fn linking_request(
  target: String,
  collection: String,
  path: String,
  after: Option(String),
) -> Request(String) {
  let page = [
    #("target", target),
    #("collection", collection),
    #("path", path),
    #("limit", "25"),
  ]

  request.new()
  |> request.set_host("constellation.microcosm.blue")
  |> request.set_path("/links")
  |> request.set_query(case after {
    Some(cursor) -> [#("cursor", cursor), ..page]
    None -> page
  })
  |> request.set_header("accept", "application/json")
}

pub fn linking_decoder() -> Decoder(Page) {
  let linking = {
    use account <- decode.field("did", did.decoder())
    use key <- decode.field("rkey", decode.string)

    decode.success(Linking(account:, key:))
  }

  use records <- decode.field("linking_records", decode.list(linking))
  use next <- decode.optional_field(
    "cursor",
    None,
    decode.optional(decode.string),
  )

  decode.success(Page(records:, next:))
}
