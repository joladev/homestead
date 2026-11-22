import homestead/json_view.{Name, Number, Plain, Text, Word}

pub fn json_is_split_into_names_texts_and_values_test() {
  assert json_view.tokens("{\"a\": \"b:c\", \"n\": -1.5, \"t\": true}")
    == [
      Plain("{"),
      Name("\"a\""),
      Plain(": "),
      Text("\"b:c\""),
      Plain(", "),
      Name("\"n\""),
      Plain(": "),
      Number("-1.5"),
      Plain(", "),
      Name("\"t\""),
      Plain(": "),
      Word("true"),
      Plain("}"),
    ]
}
