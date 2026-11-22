import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub type Token {
  Name(text: String)
  Text(text: String)
  Number(text: String)
  Word(text: String)
  Plain(text: String)
}

pub fn view(json: String) -> Element(message) {
  html.pre(
    [attribute.class("document")],
    list.map(tokens(json), fn(token) {
      case token {
        Name(text:) -> span("json-name", text)
        Text(text:) -> span("json-text", text)
        Number(text:) | Word(text:) -> span("json-value", text)
        Plain(text:) -> html.text(text)
      }
    }),
  )
}

fn span(class: String, text: String) -> Element(message) {
  html.span([attribute.class(class)], [html.text(text)])
}

pub fn tokens(json: String) -> List(Token) {
  scan(json, [])
}

fn scan(rest: String, found: List(Token)) -> List(Token) {
  case rest {
    "" -> list.reverse(found)

    "\"" <> after -> {
      let #(quoted, after) = take_quoted(after, "\"")
      let token = case string.trim_start(after) {
        ":" <> _ -> Name(text: quoted)
        _ -> Text(text: quoted)
      }

      scan(after, [token, ..found])
    }

    "true" <> after -> scan(after, [Word(text: "true"), ..found])
    "false" <> after -> scan(after, [Word(text: "false"), ..found])
    "null" <> after -> scan(after, [Word(text: "null"), ..found])

    _ ->
      case take_number(rest, "") {
        #("", _) ->
          case string.pop_grapheme(rest), found {
            Ok(#(grapheme, after)), [Plain(text:), ..earlier] ->
              scan(after, [Plain(text: text <> grapheme), ..earlier])
            Ok(#(grapheme, after)), _ ->
              scan(after, [Plain(text: grapheme), ..found])
            Error(Nil), _ -> list.reverse(found)
          }
        #(number, after) -> scan(after, [Number(text: number), ..found])
      }
  }
}

fn take_quoted(rest: String, taken: String) -> #(String, String) {
  case rest {
    "\\" <> after ->
      case string.pop_grapheme(after) {
        Ok(#(escaped, after)) -> take_quoted(after, taken <> "\\" <> escaped)
        Error(Nil) -> #(taken <> "\\", "")
      }
    "\"" <> after -> #(taken <> "\"", after)
    _ ->
      case string.pop_grapheme(rest) {
        Ok(#(grapheme, after)) -> take_quoted(after, taken <> grapheme)
        Error(Nil) -> #(taken, "")
      }
  }
}

fn take_number(rest: String, taken: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Ok(#(grapheme, after)) ->
      case string.contains("0123456789-+.eE", grapheme), taken, grapheme {
        True, "", "e" | True, "", "E" | True, "", "+" | True, "", "." -> #(
          taken,
          rest,
        )
        True, _, _ -> take_number(after, taken <> grapheme)
        False, _, _ -> #(taken, rest)
      }
    Error(Nil) -> #(taken, rest)
  }
}
