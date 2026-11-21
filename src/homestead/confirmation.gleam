import gleam/dynamic/decode
import homestead/browser
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const cancel_id = "confirmation-cancel"

pub fn focus_cancel() -> Effect(message) {
  browser.focus(cancel_id)
}

pub fn view(
  question question: String,
  consequence consequence: String,
  accept accept: String,
  on_cancel on_cancel: message,
  on_accept on_accept: message,
) -> Element(message) {
  html.div(
    [
      attribute.class("row warning confirming"),
      event.on("keydown", {
        use key <- decode.field("key", decode.string)

        case key {
          "Escape" -> decode.success(on_cancel)
          _ -> decode.failure(on_cancel, "Escape")
        }
      }),
    ],
    [
      html.strong([], [html.text(question)]),
      html.span([attribute.class("details")], [html.text(consequence)]),
      html.div([attribute.class("actions")], [
        html.button(
          [
            attribute.id(cancel_id),
            attribute.class("action"),
            event.on_click(on_cancel),
          ],
          [html.text("Cancel")],
        ),
        html.button(
          [attribute.class("action accept"), event.on_click(on_accept)],
          [html.text(accept)],
        ),
      ]),
    ],
  )
}
