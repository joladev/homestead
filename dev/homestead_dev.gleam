import gleam/http/request
import homestead
import homestead/setting.{Settings}

pub fn main() -> Nil {
  let assert Ok(directory) = request.to("http://localhost:2582")
  let assert Ok(server) = request.to("https://pds.test")

  homestead.start(with: fn(settings) {
    Settings(..settings, directory:, sign_up_servers: [server])
  })
}
