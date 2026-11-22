import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub const path = "/about"

pub fn view() -> Element(message) {
  element.fragment([
    html.header([attribute.class("top-bar")], [
      html.a([attribute.class("brand"), attribute.href("/")], [
        html.text("Homestead"),
      ]),
    ]),
    html.main([attribute.class("page")], [
      element.unsafe_raw_html(
        "",
        "article",
        [attribute.class("prose")],
        content(),
      ),
    ]),
  ])
}

@external(javascript, "./about_ffi.mjs", "html")
fn content() -> String
