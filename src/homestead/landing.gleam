import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn view(content: List(Element(message))) -> Element(message) {
  html.div([attribute.class("landing")], [
    html.section([attribute.class("about")], [
      html.span([attribute.class("brand")], [html.text("Homestead")]),
      html.div([], [
        html.h1([], [html.text("A portable Tranquil frontend dashboard.")]),
        html.p([], [
          html.text(
            "Homestead is a fully browser based frontend for the Tranquil PDS, log into any backend safely from your browser, or run your own.",
          ),
        ]),
      ]),
      html.ul([attribute.class("assurances")], [
        html.li([], [html.text("Lorem ipsum dolor sit amet")]),
        html.li([], [html.text("Consectetur adipiscing elit")]),
      ]),
    ]),
    html.main([attribute.class("sign-in")], [html.div([], content)]),
  ])
}
