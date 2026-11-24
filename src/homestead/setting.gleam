import gleam/dynamic/decode.{type Decoder}
import gleam/fetch
import gleam/http/request.{type Request}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import homestead/tranquil

pub type Settings {
  Settings(
    directory: Request(String),
    typeahead: Request(String),
    slingshot: Request(String),
    constellation: Request(String),
    appview: Request(String),
    label_relay: Request(String),
    dns: Request(String),
    sign_up_servers: List(Request(String)),
    password_entry: PasswordEntry,
  )
}

pub type PasswordEntry {
  ServerFirst
  HomesteadFirst
}

pub fn load(location: Uri) -> Promise(Result(Settings, Nil)) {
  let file = Uri(..location, path: "/config.json", query: None, fragment: None)

  case request.from_uri(file) {
    Ok(request) -> {
      use response <- promise.map(
        fetch.send(request) |> promise.try_await(fetch.read_json_body),
      )

      case response {
        Ok(response) if response.status == 200 ->
          decode.run(response.body, decoder()) |> result.replace_error(Nil)
        Ok(_) | Error(_) -> Error(Nil)
      }
    }
    Error(Nil) -> promise.resolve(Error(Nil))
  }
}

pub fn decoder() -> Decoder(Settings) {
  use directory <- service("plc", at("plc.directory"))
  use typeahead <- service("typeahead", at("typeahead.cove.town"))
  use slingshot <- service("slingshot", at("slingshot.cove.town"))
  use constellation <- service(
    "constellation",
    at("constellation.microcosm.blue"),
  )
  use appview <- service("appview", at("public.api.bsky.app"))
  use label_relay <- service("labelRelay", at("labelers.firehose.stream"))
  use dns <- service(
    "dns",
    at("dns10.quad9.net") |> request.set_path("/dns-query"),
  )
  use sign_up_servers <- decode.optional_field(
    "signUpServers",
    [],
    servers_decoder(),
  )
  use password_entry <- decode.optional_field(
    "passwordEntry",
    ServerFirst,
    password_entry_decoder(),
  )

  decode.success(Settings(
    directory:,
    typeahead:,
    slingshot:,
    constellation:,
    appview:,
    label_relay:,
    dns:,
    sign_up_servers:,
    password_entry:,
  ))
}

fn password_entry_decoder() -> Decoder(PasswordEntry) {
  use name <- decode.then(decode.string)

  case name {
    "" | "server" -> decode.success(ServerFirst)
    "homestead" -> decode.success(HomesteadFirst)
    _ -> decode.failure(ServerFirst, "PasswordEntry")
  }
}

fn servers_decoder() -> Decoder(List(Request(String))) {
  use names <- decode.then(decode.string)
  let servers =
    string.split(names, on: ",")
    |> list.map(string.trim)
    |> list.filter(fn(name) { name != "" })
    |> list.try_map(tranquil.server_address)

  case servers {
    Ok(servers) -> decode.success(servers)
    Error(Nil) -> decode.failure([], "Servers")
  }
}

fn at(host: String) -> Request(String) {
  request.new() |> request.set_host(host)
}

fn service(
  name: String,
  default: Request(String),
  next: fn(Request(String)) -> Decoder(final),
) -> Decoder(final) {
  let address = {
    use address <- decode.then(decode.string)

    case address, uri.parse(address) |> result.try(request.from_uri) {
      "", _ -> decode.success(default)
      _, Ok(service) -> decode.success(service)
      _, Error(Nil) -> decode.failure(default, "Address")
    }
  }

  decode.optional_field(name, default, address, next)
}
