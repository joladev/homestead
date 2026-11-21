import gleam/uri
import homestead

pub fn main() -> Nil {
  let assert Ok(directory) = uri.parse("http://localhost:2582")

  homestead.start(directory)
}
