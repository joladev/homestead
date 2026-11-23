import gleam/http/request
import homestead
import homestead/setting.{Settings}

pub fn main() -> Nil {
  let assert Ok(directory) = request.to("http://localhost:2582")

  homestead.start(with: fn(settings) { Settings(..settings, directory:) })
}
