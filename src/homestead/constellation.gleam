import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list

pub type Link {
  Link(collection: String, path: String, records: Int)
}

pub fn links_request(target: String) -> Request(String) {
  request.new()
  |> request.set_host("constellation.microcosm.blue")
  |> request.set_path("/links/all")
  |> request.set_query([#("target", target)])
  |> request.set_header("accept", "application/json")
}

pub fn links_decoder() -> Decoder(List(Link)) {
  let records = decode.at(["records"], decode.int)
  let paths = decode.dict(decode.string, records)

  use collections <- decode.field("links", decode.dict(decode.string, paths))

  decode.success(
    dict.to_list(collections)
    |> list.flat_map(fn(collection) {
      dict.to_list(collection.1)
      |> list.map(fn(path) {
        Link(collection: collection.0, path: path.0, records: path.1)
      })
    })
    |> list.sort(fn(one, other) { int.compare(other.records, one.records) }),
  )
}
