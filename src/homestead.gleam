import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn main() -> Nil {
  let app = lustre.element(view())
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

fn view() -> Element(message) {
  html.main([attribute.class("page")], [
    html.h1([], [html.text("Homestead")]),
    html.p([], [
      html.text("An account dashboard for Tranquil servers. Sign in as "),
      html.code([], [html.text("@you.example.com")]),
      html.text("."),
    ]),
  ])
}
