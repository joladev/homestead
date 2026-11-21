import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/result
import gleam/uri.{type Uri}

pub type Software {
  Tranquil(version: String)
  OtherSoftware
}

pub fn health_request(server: Uri) -> Result(Request(String), Nil) {
  request.from_uri(server)
  |> result.map(request.set_path(_, "/xrpc/_health"))
}

pub fn health_decoder() -> Decoder(Software) {
  use version <- decode.field("version", decode.string)

  case version {
    "tranquil " <> version -> decode.success(Tranquil(version:))
    _ -> decode.success(OtherSoftware)
  }
}
