import gleam/list
import homestead/sign_up

pub fn a_handle_name_follows_the_servers_rule_test() {
  assert sign_up.is_valid_name("noor")
  assert sign_up.is_valid_name("Noor-01")
  assert !sign_up.is_valid_name("no")
  assert !sign_up.is_valid_name("-noor")
  assert !sign_up.is_valid_name("noor.example")
  assert !sign_up.is_valid_name("nineteen-characters")
}

pub fn a_password_is_judged_rule_by_rule_test() {
  let unmet = fn(password) {
    sign_up.password_rules(password)
    |> list.filter(fn(rule) { !rule.is_met })
    |> list.map(fn(rule) { rule.requirement })
  }

  assert unmet("Harbor-Lantern-42") == []
  assert unmet("harbor42") == ["An uppercase letter"]
  assert unmet("Password123") == ["Not a common password"]
}
