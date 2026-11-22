import gleam/option.{None, Some}
import homestead/permissions.{PostOnly, ReadOnly}

pub fn granted_permissions_are_named_by_their_preset_test() {
  assert permissions.describe(None) == "Full access"
  assert permissions.describe(Some("transition:generic transition:chat.bsky"))
    == "Full access"
  assert permissions.describe(Some(
      "atproto transition:generic transition:chat.bsky",
    ))
    == "Full access"
  assert permissions.describe(permissions.scopes(ReadOnly)) == "Read only"
  assert permissions.describe(Some(
      "blob:*/* atproto repo:app.bsky.feed.post?action=create",
    ))
    == permissions.label(PostOnly)
}

pub fn other_permissions_are_custom_test() {
  assert permissions.describe(Some("atproto repo:*")) == "Custom"
}
