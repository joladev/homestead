import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/option.{type Option, None}

pub type Actor {
  Actor(
    did: Did,
    handle: Handle,
    display_name: Option(String),
    avatar: Option(String),
  )
}

pub fn search_request(
  typeahead: Request(String),
  query: String,
) -> Request(String) {
  typeahead
  |> request.set_path("/xrpc/town.cove.actor.searchActorsTypeahead")
  |> request.set_query([#("q", query), #("limit", "6")])
}

pub fn search_decoder() -> Decoder(List(Actor)) {
  decode.at(["actors"], decode.list(actor_decoder()))
}

fn actor_decoder() -> Decoder(Actor) {
  use did <- decode.field("did", did.decoder())
  use handle <- decode.field("handle", handle.decoder())
  use display_name <- decode.optional_field(
    "displayName",
    None,
    decode.optional(decode.string),
  )
  use avatar <- decode.optional_field(
    "avatar",
    None,
    decode.optional(decode.string),
  )

  decode.success(Actor(did:, handle:, display_name:, avatar:))
}
