import at/did.{type Did}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import homestead/tranquil.{
  Account, ActiveSession, ChannelUsername, ContactPreferences, Discord, Email,
  LinkedAccount, LogEntry, LogPage, MediaPage, OtherChannel, OtherSoftware,
  Passkey, RecordPage, RememberedApp, RepoRecord, SentMessage, Server, Signal,
  Telegram, Tranquil,
}

pub fn a_tranquil_health_answer_gives_its_version_test() {
  assert json.parse(
      "{\"version\":\"tranquil 0.8.0\"}",
      tranquil.health_decoder(),
    )
    == Ok(Tranquil(version: "0.8.0"))
}

pub fn another_servers_health_answer_is_other_software_test() {
  assert json.parse("{\"version\":\"0.4.193\"}", tranquil.health_decoder())
    == Ok(OtherSoftware)
}

pub fn the_account_is_read_from_the_session_answer_test() {
  let body =
    "{\"handle\":\"noor.harbor.example\",\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"active\":true,\"preferredChannel\":\"email\",\"preferredChannelVerified\":false,\"isAdmin\":true,\"email\":\"noor@harbor.example\",\"emailConfirmed\":false}"

  assert tranquil.parse(tranquil.account(), body)
    == Ok(Account(
      handle: "noor.harbor.example",
      email: Some("noor@harbor.example"),
      email_verified: False,
      contact_channel: Email,
      contact_verified: False,
      is_admin: True,
    ))
}

pub fn a_session_through_an_app_names_the_app_test() {
  let body =
    "{\"sessions\":[{\"id\":\"oauth:7\",\"sessionType\":\"oauth\",\"clientName\":\"fieldnotes.example\",\"createdAt\":\"2026-11-20T10:00:00+00:00\",\"expiresAt\":\"2026-12-04T10:00:00+00:00\",\"isCurrent\":true},{\"id\":\"jwt:3\",\"sessionType\":\"legacy\",\"clientName\":null,\"createdAt\":\"2026-11-19T10:00:00+00:00\",\"expiresAt\":\"2027-02-17T10:00:00+00:00\",\"isCurrent\":false}]}"
  let assert Ok(created) = timestamp.parse_rfc3339("2026-11-20T10:00:00Z")
  let assert Ok(expires) = timestamp.parse_rfc3339("2026-12-04T10:00:00Z")

  let assert Ok([through_app, direct]) =
    tranquil.parse(tranquil.sessions(), body)

  assert through_app
    == ActiveSession(
      id: "oauth:7",
      app: Some("fieldnotes.example"),
      created:,
      expires:,
      is_current: True,
    )
  assert direct.app == None
}

pub fn remembered_apps_carry_their_permissions_test() {
  let body =
    "{\"choices\":[{\"clientId\":\"https://fieldnotes.example/client.json\",\"scopes\":[\"atproto\",\"repo:*\"]}]}"

  assert tranquil.parse(tranquil.remembered_apps(), body)
    == Ok([
      RememberedApp(
        client_id: "https://fieldnotes.example/client.json",
        scopes: ["atproto", "repo:*"],
      ),
    ])
}

pub fn a_profile_without_a_display_name_has_none_test() {
  let query = tranquil.display_name(account())

  assert tranquil.parse(
      query,
      "{\"value\":{\"$type\":\"app.bsky.actor.profile\",\"displayName\":\"Noor Halvorsen\"}}",
    )
    == Ok(Some("Noor Halvorsen"))
  assert tranquil.parse(
      query,
      "{\"value\":{\"$type\":\"app.bsky.actor.profile\"}}",
    )
    == Ok(None)
}

pub fn a_server_without_contact_channels_offers_email_test() {
  assert tranquil.parse(
      tranquil.server(),
      "{\"availableUserDomains\":[\"harbor.example\"]}",
    )
    == Ok(Server(
      handle_domains: ["harbor.example"],
      contact_channels: [Email],
      discord_bot: None,
      discord_app_id: None,
      telegram_bot: None,
    ))
}

pub fn a_channel_homestead_does_not_know_keeps_its_name_test() {
  let assert Ok(Server(contact_channels:, ..)) =
    tranquil.parse(
      tranquil.server(),
      "{\"availableCommsChannels\":[\"email\",\"matrix\"]}",
    )

  assert contact_channels == [Email, OtherChannel(name: "matrix")]
}

pub fn contact_preferences_list_each_channels_username_test() {
  assert tranquil.parse(
      tranquil.contact_preferences(),
      "{\"preferredChannel\":\"discord\",\"discordUsername\":\"noor\",
        \"discordVerified\":true,\"telegramUsername\":null,
        \"telegramVerified\":false}",
    )
    == Ok(
      ContactPreferences(preferred: Discord, usernames: [
        ChannelUsername(channel: Discord, username: "noor", verified: True),
        ChannelUsername(channel: Telegram, username: "", verified: False),
        ChannelUsername(channel: Signal, username: "", verified: False),
      ]),
    )
}

pub fn a_sent_message_without_a_subject_has_none_test() {
  let body =
    "{\"notifications\":[{\"createdAt\":\"2026-11-21T19:04:36+00:00\",
      \"channel\":\"discord\",\"commsType\":\"channel_verified\",
      \"status\":\"sent\",\"subject\":null,\"body\":\"Verified\"}]}"

  assert tranquil.parse(tranquil.sent_messages(), body)
    == Ok([
      SentMessage(
        sent: timestamp.from_unix_seconds(1_795_287_876),
        channel: Discord,
        kind: "channel_verified",
        status: "sent",
        subject: None,
        body: "Verified",
      ),
    ])
}

pub fn a_passkey_that_was_never_used_has_no_last_use_test() {
  let body =
    "{\"passkeys\":[{\"id\":\"6cfb44c0\",\"credentialId\":\"aG9t\",
      \"friendlyName\":null,\"createdAt\":\"2026-11-21T19:04:36+00:00\",
      \"lastUsed\":null}]}"

  assert tranquil.parse(tranquil.passkeys(), body)
    == Ok([
      Passkey(
        id: "6cfb44c0",
        name: None,
        created: timestamp.from_unix_seconds(1_795_287_876),
        last_used: None,
      ),
    ])
}

pub fn a_linked_account_names_its_provider_test() {
  let body =
    "{\"accounts\":[{\"id\":\"7f1c\",\"provider\":\"github\",
      \"provider_name\":\"GitHub\",\"provider_username\":\"noor-h\",
      \"provider_email\":null,\"created_at\":\"2026-11-21T19:04:36+00:00\",
      \"last_login_at\":null}]}"

  assert tranquil.parse(tranquil.linked_accounts(), body)
    == Ok([
      LinkedAccount(
        id: "7f1c",
        provider: "GitHub",
        username: Some("noor-h"),
        email: None,
        linked: timestamp.from_unix_seconds(1_795_287_876),
      ),
    ])
}

pub fn a_full_page_of_records_names_the_next_page_test() {
  let record =
    "{\"uri\":\"at://did:plc:abc/app.bsky.feed.post/3m5x7c2k4s2a\",
      \"cid\":\"bafyrei\",\"value\":{}}"
  let body =
    "{\"records\":["
    <> string.join(list.repeat(record, 50), ",")
    <> "],\"cursor\":\"3m5x\"}"

  let assert Ok(RecordPage(next:, ..)) =
    tranquil.parse(
      tranquil.records(account(), "app.bsky.feed.post", None),
      body,
    )

  assert next == Some("3m5x")
}

pub fn a_listed_record_takes_its_key_from_its_address_test() {
  let body =
    "{\"records\":[{\"uri\":\"at://did:plc:abc/app.bsky.feed.post/3m5x7c2k4s2a\",
      \"cid\":\"bafyrei\",\"value\":{\"text\":\"Hello\"}}],\"cursor\":\"3m5x\"}"

  assert tranquil.parse(
      tranquil.records(account(), "app.bsky.feed.post", None),
      body,
    )
    == Ok(RecordPage(
      records: [
        RepoRecord(
          key: "3m5x7c2k4s2a",
          address: "at://did:plc:abc/app.bsky.feed.post/3m5x7c2k4s2a",
          content_id: "bafyrei",
          json: "{\n  \"text\": \"Hello\"\n}",
          preview: "{\"text\":\"Hello\"}",
        ),
      ],
      next: None,
    ))
}

pub fn a_delegation_log_page_carries_its_total_test() {
  let body =
    "{\"entries\":[{\"id\":\"e1\",\"delegatedDid\":\"did:plc:shop\",
      \"actorDid\":\"did:plc:noor\",\"controllerDid\":null,
      \"actionType\":\"TokenIssued\",\"actionDetails\":null,
      \"createdAt\":\"2026-11-21T19:04:36Z\"}],\"total\":23}"

  assert tranquil.parse(tranquil.delegation_log(0), body)
    == Ok(LogPage(
      entries: [
        LogEntry(
          id: "e1",
          actor: "did:plc:noor",
          action: "TokenIssued",
          at: timestamp.from_unix_seconds(1_795_287_876),
        ),
      ],
      total: 23,
    ))
}

pub fn a_page_of_media_names_the_next_page_test() {
  assert tranquil.parse(
      tranquil.media(account(), None),
      "{\"cids\":[\"bafkreiaaa\",\"bafkreibbb\"],\"cursor\":\"bafkreibbb\"}",
    )
    == Ok(MediaPage(
      media: ["bafkreiaaa", "bafkreibbb"],
      next: Some("bafkreibbb"),
    ))
}

fn account() -> Did {
  let assert Ok(account) = did.from_string("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs")

  account
}
