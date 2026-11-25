import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}

pub fn tags_request(
  tangled: Request(String),
  repository: String,
) -> Request(String) {
  tangled
  |> request.set_path("/xrpc/org.tangled.temp.git.listTags")
  |> request.set_query([#("repo", repository), #("limit", "100")])
}

pub fn tags_decoder() -> Decoder(List(String)) {
  decode.at(["tags"], decode.list(decode.at(["name"], decode.string)))
}
