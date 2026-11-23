import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}
import rsvp

pub fn resolve_request(handle: Handle) -> Request(String) {
  request.new()
  |> request.set_host("slingshot.cove.town")
  |> request.set_path("/xrpc/com.atproto.identity.resolveHandle")
  |> request.set_query([#("handle", handle.to_string(handle))])
}

pub fn resolve_decoder() -> Decoder(Did) {
  decode.at(["did"], did.decoder())
}

pub fn identity_request(account: Did) -> Request(String) {
  request.new()
  |> request.set_host("slingshot.cove.town")
  |> request.set_path("/xrpc/blue.microcosm.identity.resolveMiniDoc")
  |> request.set_query([#("identifier", did.to_string(account))])
}

pub fn handle_decoder() -> Decoder(String) {
  decode.at(["handle"], decode.string)
}

pub fn verified_handle(
  result: Result(String, rsvp.Error(String)),
) -> Result(Option(String), Nil) {
  case result {
    Ok(handle) -> Ok(Some(handle))
    Error(rsvp.HttpError(response)) if response.status == 400 -> Ok(None)
    Error(rsvp.HttpError(_))
    | Error(rsvp.BadBody)
    | Error(rsvp.BadUrl(_))
    | Error(rsvp.JsonError(_))
    | Error(rsvp.NetworkError)
    | Error(rsvp.UnhandledResponse(_)) -> Error(Nil)
  }
}
