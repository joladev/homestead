import gleam/option.{None, Some}
import homestead/permission.{PostOnly, ReadOnly}

pub fn granted_permissions_are_named_by_their_preset_test() {
  assert permission.describe(None) == "Full access"
  assert permission.describe(Some("transition:generic transition:chat.bsky"))
    == "Full access"
  assert permission.describe(Some(
      "atproto transition:generic transition:chat.bsky",
    ))
    == "Full access"
  assert permission.describe(permission.scopes(ReadOnly)) == "Read only"
  assert permission.describe(Some(
      "blob:*/* atproto repo:app.bsky.feed.post?action=create",
    ))
    == permission.label(PostOnly)
}

pub fn other_permissions_are_custom_test() {
  assert permission.describe(Some("atproto repo:*")) == "Custom"
}
