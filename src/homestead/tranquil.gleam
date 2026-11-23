import at/did.{type Did}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import homestead/browser.{type File}
import homestead/date
import homestead/json_text
import homestead/session.{type Session}
import lustre/effect.{type Effect}
import rsvp

pub type Software {
  Tranquil(version: String)
  OtherSoftware
}

pub fn health_request(server: Uri) -> Result(Request(String), Nil) {
  request.from_uri(server)
  |> result.map(request.set_path(_, "/xrpc/_health"))
}

pub fn health_decoder() -> Decoder(Software) {
  use version <- decode.field("version", decode.string)

  case version {
    "tranquil " <> version -> decode.success(Tranquil(version:))
    _ -> decode.success(OtherSoftware)
  }
}

pub type Problem {
  Unreachable
  Refused(error: String, message: String)
  NotUnderstood
}

type Failure {
  Expired
  Failed(problem: Problem)
}

pub fn describe_failed_load(problem: Problem) -> String {
  case problem {
    Unreachable -> "Couldn't reach the server"
    Refused("RateLimitExceeded", _) -> "Too many requests. Try again later"
    Refused(error:, message: "") -> "The server refused: " <> error
    Refused(message:, ..) -> message
    NotUnderstood -> "Couldn't read the server's answer"
  }
}

pub fn describe(problem: Problem) -> String {
  case problem {
    Refused("RateLimitExceeded", _) -> "Too many attempts. Try again later"
    Unreachable -> "Couldn't reach the server"
    Refused(_, _) | NotUnderstood -> "The server didn't accept that"
  }
}

pub opaque type Query(answer) {
  Query(path: String, decoder: Decoder(answer))
}

pub type Channel {
  Email
  Discord
  Telegram
  Signal
  OtherChannel(name: String)
}

pub fn channel_name(channel: Channel) -> String {
  case channel {
    Email -> "email"
    Discord -> "discord"
    Telegram -> "telegram"
    Signal -> "signal"
    OtherChannel(name:) -> name
  }
}

pub fn channel_label(channel: Channel) -> String {
  string.capitalise(channel_name(channel))
}

fn channel_decoder() -> Decoder(Channel) {
  use name <- decode.map(decode.string)

  case name {
    "email" -> Email
    "discord" -> Discord
    "telegram" -> Telegram
    "signal" -> Signal
    name -> OtherChannel(name:)
  }
}

pub type Account {
  Account(
    handle: String,
    email: Option(String),
    email_verified: Bool,
    contact_channel: Channel,
    contact_verified: Bool,
    is_admin: Bool,
  )
}

pub type Server {
  Server(
    handle_domains: List(String),
    contact_channels: List(Channel),
    discord_bot: Option(String),
    discord_app_id: Option(String),
    telegram_bot: Option(String),
  )
}

pub type SentMessage {
  SentMessage(
    sent: Timestamp,
    channel: Channel,
    kind: String,
    status: String,
    subject: Option(String),
    body: String,
  )
}

pub type ContactPreferences {
  ContactPreferences(preferred: Channel, usernames: List(ChannelUsername))
}

pub type ChannelUsername {
  ChannelUsername(channel: Channel, username: String, verified: Bool)
}

pub type Passkey {
  Passkey(
    id: String,
    name: Option(String),
    created: Timestamp,
    last_used: Option(Timestamp),
  )
}

pub type LinkedAccount {
  LinkedAccount(
    id: String,
    provider: String,
    username: Option(String),
    email: Option(String),
    linked: Timestamp,
  )
}

pub type OlderApps {
  OlderApps(allowed: Bool, has_second_step: Bool)
}

pub type RememberedDevice {
  RememberedDevice(
    id: String,
    name: Option(String),
    user_agent: Option(String),
    remembered_until: Timestamp,
    last_seen: Timestamp,
  )
}

pub type RepoRecord {
  RepoRecord(
    key: String,
    address: String,
    content_id: String,
    json: String,
    preview: String,
  )
}

pub type RecordPage {
  RecordPage(records: List(RepoRecord), next: Option(String))
}

pub type Controller {
  Controller(
    did: String,
    handle: Option(String),
    access: String,
    since: Timestamp,
    is_active: Bool,
    is_local: Bool,
  )
}

pub type ControlledAccount {
  ControlledAccount(
    did: String,
    handle: Option(String),
    access: String,
    since: Timestamp,
  )
}

pub type AccessLevel {
  AccessLevel(name: String, label: String, scopes: String)
}

pub type FoundController {
  FoundController(
    did: String,
    handle: Option(String),
    server: Option(String),
    is_local: Bool,
  )
}

pub type LogEntry {
  LogEntry(id: String, actor: String, action: String, at: Timestamp)
}

pub type LogPage {
  LogPage(entries: List(LogEntry), total: Int)
}

pub type ServerTotals {
  ServerTotals(accounts: Int, repositories: Int, records: Int, media_bytes: Int)
}

pub type ListedAccount {
  ListedAccount(
    did: String,
    handle: String,
    email: Option(String),
    since: Timestamp,
    is_verified: Bool,
    is_deactivated: Bool,
    has_invites: Bool,
  )
}

pub type AccountPage {
  AccountPage(accounts: List(ListedAccount), next: Option(String))
}

pub type InviteCode {
  InviteCode(
    code: String,
    available: Int,
    is_disabled: Bool,
    created: Timestamp,
    used_by: List(String),
  )
}

pub type ServerPage {
  ServerPage(
    name: String,
    primary: String,
    primary_dark: String,
    secondary: String,
    secondary_dark: String,
    logo: Option(String),
  )
}

pub type MediaPage {
  MediaPage(media: List(String), next: Option(String))
}

pub type AuthenticatorSetup {
  AuthenticatorSetup(secret: String, qr_image: String)
}

pub type Authenticator {
  Authenticator(enabled: Bool, backup_codes_remaining: Int)
}

pub type ActiveSession {
  ActiveSession(
    id: String,
    app: Option(String),
    created: Timestamp,
    expires: Timestamp,
    is_current: Bool,
  )
}

pub type RememberedApp {
  RememberedApp(client_id: String, scopes: List(String))
}

pub type AppPassword {
  AppPassword(name: String, created: Timestamp, scopes: Option(String))
}

pub opaque type Command(answer) {
  Command(
    path: String,
    body: String,
    read: fn(String) -> Result(answer, Problem),
  )
}

pub fn account() -> Query(Account) {
  query("com.atproto.server.getSession", [], {
    use handle <- decode.field("handle", decode.string)
    use email <- decode.optional_field(
      "email",
      None,
      decode.optional(decode.string),
    )
    use email_verified <- decode.optional_field(
      "emailConfirmed",
      False,
      decode.bool,
    )
    use contact_channel <- decode.field("preferredChannel", channel_decoder())
    use contact_verified <- decode.field(
      "preferredChannelVerified",
      decode.bool,
    )
    use is_admin <- decode.field("isAdmin", decode.bool)

    decode.success(Account(
      handle:,
      email:,
      email_verified:,
      contact_channel:,
      contact_verified:,
      is_admin:,
    ))
  })
}

pub fn server() -> Query(Server) {
  query("com.atproto.server.describeServer", [], {
    use handle_domains <- decode.optional_field(
      "availableUserDomains",
      [],
      decode.list(decode.string),
    )
    use contact_channels <- decode.optional_field(
      "availableCommsChannels",
      [Email],
      decode.list(channel_decoder()),
    )
    use discord_bot <- optional_text("discordBotUsername")
    use discord_app_id <- optional_text("discordAppId")
    use telegram_bot <- optional_text("telegramBotUsername")

    decode.success(Server(
      handle_domains:,
      contact_channels:,
      discord_bot:,
      discord_app_id:,
      telegram_bot:,
    ))
  })
}

pub fn language() -> Query(Option(String)) {
  query(
    "com.atproto.server.getSession",
    [],
    optional_text("preferredLocale", decode.success),
  )
}

pub fn login_alerts() -> Query(Bool) {
  query(
    "_account.getNotificationPrefs",
    [],
    decode.at(["legacyLoginAlerts"], decode.bool),
  )
}

pub fn sent_messages() -> Query(List(SentMessage)) {
  query(
    "_account.getNotificationHistory",
    [],
    decode.at(
      ["notifications"],
      decode.list({
        use sent <- decode.field("createdAt", date.decoder())
        use channel <- decode.field("channel", channel_decoder())
        use kind <- decode.field("commsType", decode.string)
        use status <- decode.field("status", decode.string)
        use subject <- optional_text("subject")
        use body <- decode.field("body", decode.string)

        decode.success(SentMessage(
          sent:,
          channel:,
          kind:,
          status:,
          subject:,
          body:,
        ))
      }),
    ),
  )
}

pub fn contact_preferences() -> Query(ContactPreferences) {
  let username = fn(channel: Channel, next) {
    use username <- decode.optional_field(
      channel_name(channel) <> "Username",
      None,
      decode.optional(decode.string),
    )
    use verified <- decode.optional_field(
      channel_name(channel) <> "Verified",
      False,
      decode.bool,
    )

    next(ChannelUsername(
      channel:,
      username: option.unwrap(username, ""),
      verified:,
    ))
  }

  query("_account.getNotificationPrefs", [], {
    use preferred <- decode.field("preferredChannel", channel_decoder())
    use discord <- username(Discord)
    use telegram <- username(Telegram)
    use signal <- username(Signal)

    decode.success(
      ContactPreferences(preferred:, usernames: [discord, telegram, signal]),
    )
  })
}

pub fn display_name(account: Did) -> Query(Option(String)) {
  let account = did.to_string(account)

  query(
    "com.atproto.repo.getRecord",
    [
      #("repo", account),
      #("collection", "app.bsky.actor.profile"),
      #("rkey", "self"),
    ],
    {
      use name <- decode.then(decode.optionally_at(
        ["value", "displayName"],
        "",
        decode.string,
      ))

      case string.trim(name) {
        "" -> decode.success(None)
        name -> decode.success(Some(name))
      }
    },
  )
}

pub fn server_totals() -> Query(ServerTotals) {
  query("_admin.getServerStats", [], {
    use accounts <- decode.field("userCount", decode.int)
    use repositories <- decode.field("repoCount", decode.int)
    use records <- decode.field("recordCount", decode.int)
    use media_bytes <- decode.field("blobStorageBytes", decode.int)

    decode.success(ServerTotals(
      accounts:,
      repositories:,
      records:,
      media_bytes:,
    ))
  })
}

pub fn find_accounts(
  handle: String,
  after: Option(String),
) -> Query(AccountPage) {
  let page = case handle {
    "" -> [#("limit", "25")]
    handle -> [#("limit", "25"), #("handle", handle)]
  }

  query(
    "com.atproto.admin.searchAccounts",
    case after {
      Some(cursor) -> list.append(page, [#("cursor", cursor)])
      None -> page
    },
    {
      use accounts <- decode.field(
        "accounts",
        decode.list({
          use did <- decode.field("did", decode.string)
          use handle <- decode.field("handle", decode.string)
          use email <- optional_text("email")
          use since <- decode.field("indexedAt", date.decoder())
          use verified <- optional_text("emailConfirmedAt")
          use deactivated <- optional_text("deactivatedAt")
          use invites_disabled <- decode.optional_field(
            "invitesDisabled",
            False,
            decode.bool,
          )

          decode.success(ListedAccount(
            did:,
            handle:,
            email:,
            since:,
            is_verified: option.is_some(verified),
            is_deactivated: option.is_some(deactivated),
            has_invites: !invites_disabled,
          ))
        }),
      )
      use next <- optional_text("cursor")

      decode.success(AccountPage(accounts:, next:))
    },
  )
}

pub fn invite_codes_required() -> Query(Bool) {
  query(
    "com.atproto.server.describeServer",
    [],
    decode.optional_field(
      "inviteCodeRequired",
      False,
      decode.bool,
      decode.success,
    ),
  )
}

pub fn invite_codes() -> Query(List(InviteCode)) {
  query(
    "com.atproto.server.getAccountInviteCodes",
    [],
    decode.at(
      ["codes"],
      decode.list({
        use code <- decode.field("code", decode.string)
        use available <- decode.field("available", decode.int)
        use is_disabled <- decode.field("disabled", decode.bool)
        use created <- decode.field("createdAt", date.decoder())
        use used_by <- decode.field(
          "uses",
          decode.list({
            use did <- decode.field("usedBy", decode.string)
            use handle <- optional_text("usedByHandle")

            decode.success(option.unwrap(handle, did))
          }),
        )

        decode.success(InviteCode(
          code:,
          available:,
          is_disabled:,
          created:,
          used_by:,
        ))
      }),
    ),
  )
}

pub fn server_page() -> Query(ServerPage) {
  let colour = fn(name: String, next) {
    use colour <- optional_text(name)

    next(option.unwrap(colour, ""))
  }

  query("_server.getConfig", [], {
    use name <- decode.field("serverName", decode.string)
    use primary <- colour("primaryColor")
    use primary_dark <- colour("primaryColorDark")
    use secondary <- colour("secondaryColor")
    use secondary_dark <- colour("secondaryColorDark")
    use logo <- optional_text("logoCid")

    decode.success(ServerPage(
      name:,
      primary:,
      primary_dark:,
      secondary:,
      secondary_dark:,
      logo:,
    ))
  })
}

pub fn signal_linked() -> Query(Bool) {
  query("_admin.getSignalStatus", [], decode.at(["linked"], decode.bool))
}

pub fn media(account: Did, after: Option(String)) -> Query(MediaPage) {
  let account = did.to_string(account)

  let page = [#("did", account), #("limit", "1000")]

  query(
    "com.atproto.sync.listBlobs",
    case after {
      Some(cursor) -> list.append(page, [#("cursor", cursor)])
      None -> page
    },
    {
      use media <- decode.field("cids", decode.list(decode.string))
      use next <- optional_text("cursor")

      decode.success(MediaPage(media:, next:))
    },
  )
}

pub fn controllers() -> Query(List(Controller)) {
  query(
    "_delegation.listControllers",
    [],
    decode.at(
      ["controllers"],
      decode.list({
        use did <- decode.field("did", decode.string)
        use handle <- optional_text("handle")
        use access <- decode.field("grantedScopes", decode.string)
        use since <- decode.field("grantedAt", date.decoder())
        use is_active <- decode.field("isActive", decode.bool)
        use is_local <- decode.field("isLocal", decode.bool)

        decode.success(Controller(
          did:,
          handle:,
          access:,
          since:,
          is_active:,
          is_local:,
        ))
      }),
    ),
  )
}

pub fn controlled_accounts() -> Query(List(ControlledAccount)) {
  query(
    "_delegation.listControlledAccounts",
    [],
    decode.at(
      ["accounts"],
      decode.list({
        use did <- decode.field("did", decode.string)
        use handle <- optional_text("handle")
        use access <- decode.field("grantedScopes", decode.string)
        use since <- decode.field("grantedAt", date.decoder())

        decode.success(ControlledAccount(did:, handle:, access:, since:))
      }),
    ),
  )
}

pub fn access_levels() -> Query(List(AccessLevel)) {
  query(
    "_delegation.getScopePresets",
    [],
    decode.at(
      ["presets"],
      decode.list({
        use name <- decode.field("name", decode.string)
        use label <- decode.field("label", decode.string)
        use scopes <- decode.field("scopes", decode.string)

        decode.success(AccessLevel(name:, label:, scopes:))
      }),
    ),
  )
}

pub fn find_controller(identifier: String) -> Query(FoundController) {
  query("_delegation.resolveController", [#("identifier", identifier)], {
    use did <- decode.field("did", decode.string)
    use handle <- optional_text("handle")
    use server <- optional_text("pdsUrl")
    use is_local <- decode.field("isLocal", decode.bool)

    decode.success(FoundController(did:, handle:, server:, is_local:))
  })
}

pub fn delegation_log(offset: Int) -> Query(LogPage) {
  query(
    "_delegation.getAuditLog",
    [#("limit", "20"), #("offset", int.to_string(offset))],
    {
      use entries <- decode.field(
        "entries",
        decode.list({
          use id <- decode.field("id", decode.string)
          use actor <- decode.field("actorDid", decode.string)
          use action <- decode.field("actionType", decode.string)
          use at <- decode.field("createdAt", date.decoder())

          decode.success(LogEntry(id:, actor:, action:, at:))
        }),
      )
      use total <- decode.field("total", decode.int)

      decode.success(LogPage(entries:, total:))
    },
  )
}

pub fn collections(account: Did) -> Query(List(String)) {
  let account = did.to_string(account)

  query(
    "com.atproto.repo.describeRepo",
    [#("repo", account)],
    decode.at(["collections"], decode.list(decode.string)),
  )
}

const records_per_page = 50

pub fn records(
  account: Did,
  collection: String,
  after: Option(String),
) -> Query(RecordPage) {
  let account = did.to_string(account)

  let page = [
    #("repo", account),
    #("collection", collection),
    #("limit", int.to_string(records_per_page)),
  ]

  query(
    "com.atproto.repo.listRecords",
    case after {
      Some(cursor) -> list.append(page, [#("cursor", cursor)])
      None -> page
    },
    {
      use records <- decode.field("records", decode.list(record_decoder()))
      use cursor <- optional_text("cursor")

      decode.success(
        RecordPage(
          records:,
          next: case list.length(records) < records_per_page {
            True -> None
            False -> cursor
          },
        ),
      )
    },
  )
}

pub fn record(
  account: Did,
  collection: String,
  key: String,
) -> Query(RepoRecord) {
  let account = did.to_string(account)

  query(
    "com.atproto.repo.getRecord",
    [#("repo", account), #("collection", collection), #("rkey", key)],
    record_decoder(),
  )
}

fn record_decoder() -> Decoder(RepoRecord) {
  use address <- decode.field("uri", decode.string)
  use content_id <- decode.field("cid", decode.string)
  use value <- decode.field("value", decode.dynamic)

  decode.success(RepoRecord(
    key: string.split(address, "/") |> list.last |> result.unwrap(""),
    address:,
    content_id:,
    json: json_text.pretty(value),
    preview: json_text.compact(value),
  ))
}

pub fn passkeys() -> Query(List(Passkey)) {
  query(
    "com.atproto.server.listPasskeys",
    [],
    decode.at(["passkeys"], {
      decode.list({
        use id <- decode.field("id", decode.string)
        use name <- decode.field("friendlyName", decode.optional(decode.string))
        use created <- decode.field("createdAt", date.decoder())
        use last_used <- decode.field(
          "lastUsed",
          decode.optional(date.decoder()),
        )

        decode.success(Passkey(id:, name:, created:, last_used:))
      })
    }),
  )
}

pub fn authenticator() -> Query(Authenticator) {
  query("com.atproto.server.getTotpStatus", [], {
    use enabled <- decode.field("enabled", decode.bool)
    use backup_codes_remaining <- decode.field(
      "backupCodesRemaining",
      decode.int,
    )

    decode.success(Authenticator(enabled:, backup_codes_remaining:))
  })
}

pub fn has_password() -> Query(Bool) {
  query(
    "_account.getPasswordStatus",
    [],
    decode.at(["hasPassword"], decode.bool),
  )
}

pub fn linked_account_providers() -> Query(List(String)) {
  Query(
    path: "/oauth/sso/providers",
    decoder: decode.at(
      ["providers"],
      decode.list(decode.at(["name"], decode.string)),
    ),
  )
}

pub fn linked_accounts() -> Query(List(LinkedAccount)) {
  Query(
    path: "/oauth/sso/linked",
    decoder: decode.at(
      ["accounts"],
      decode.list({
        use id <- decode.field("id", decode.string)
        use provider <- decode.field("provider_name", decode.string)
        use username <- optional_text("provider_username")
        use email <- optional_text("provider_email")
        use linked <- decode.field("created_at", date.decoder())

        decode.success(LinkedAccount(id:, provider:, username:, email:, linked:))
      }),
    ),
  )
}

pub fn older_apps() -> Query(OlderApps) {
  query("_account.getLegacyLoginPreference", [], {
    use allowed <- decode.field("allowLegacyLogin", decode.bool)
    use has_second_step <- decode.field("hasMfa", decode.bool)

    decode.success(OlderApps(allowed:, has_second_step:))
  })
}

pub fn remembered_devices() -> Query(List(RememberedDevice)) {
  query(
    "_account.listTrustedDevices",
    [],
    decode.at(
      ["devices"],
      decode.list({
        use id <- decode.field("id", decode.string)
        use name <- optional_text("friendlyName")
        use user_agent <- optional_text("userAgent")
        use remembered_until <- decode.field("trustedUntil", date.decoder())
        use last_seen <- decode.field("lastSeenAt", date.decoder())

        decode.success(RememberedDevice(
          id:,
          name:,
          user_agent:,
          remembered_until:,
          last_seen:,
        ))
      }),
    ),
  )
}

pub fn sign_in_again_methods() -> Query(List(String)) {
  query(
    "_account.getReauthStatus",
    [],
    decode.at(["availableMethods"], decode.list(decode.string)),
  )
}

pub fn sessions() -> Query(List(ActiveSession)) {
  query(
    "_account.listSessions",
    [],
    decode.at(["sessions"], {
      decode.list({
        use id <- decode.field("id", decode.string)
        use app <- decode.field("clientName", decode.optional(decode.string))
        use created <- decode.field("createdAt", date.decoder())
        use expires <- decode.field("expiresAt", date.decoder())
        use is_current <- decode.field("isCurrent", decode.bool)

        decode.success(ActiveSession(id:, app:, created:, expires:, is_current:))
      })
    }),
  )
}

pub fn remembered_apps() -> Query(List(RememberedApp)) {
  query(
    "_account.listRememberedAppChoices",
    [],
    decode.at(["choices"], {
      decode.list({
        use client_id <- decode.field("clientId", decode.string)
        use scopes <- decode.field("scopes", decode.list(decode.string))

        decode.success(RememberedApp(client_id:, scopes:))
      })
    }),
  )
}

pub fn app_passwords() -> Query(List(AppPassword)) {
  query(
    "com.atproto.server.listAppPasswords",
    [],
    decode.at(["passwords"], {
      decode.list({
        use name <- decode.field("name", decode.string)
        use created <- decode.field("createdAt", date.decoder())
        use scopes <- decode.optional_field(
          "scopes",
          None,
          decode.optional(decode.string),
        )

        decode.success(AppPassword(name:, created:, scopes:))
      })
    }),
  )
}

pub fn create_app_password(
  name: String,
  scopes: Option(String),
) -> Command(String) {
  let body = case scopes {
    Some(scopes) -> [
      #("name", json.string(name)),
      #("scopes", json.string(scopes)),
    ]
    None -> [#("name", json.string(name))]
  }

  command_returning(
    "com.atproto.server.createAppPassword",
    json.object(body),
    decode.at(["password"], decode.string),
  )
}

pub fn save_record(
  account: Did,
  collection: String,
  key: String,
  record: String,
) -> Command(Nil) {
  let account = did.to_string(account)

  Command(
    path: "/xrpc/com.atproto.repo.putRecord",
    body: record_body(
      [
        #("repo", json.string(account)),
        #("collection", json.string(collection)),
        #("rkey", json.string(key)),
      ],
      record,
    ),
    read: fn(_) { Ok(Nil) },
  )
}

pub fn create_record(
  account: Did,
  collection: String,
  key: Option(String),
  record: String,
) -> Command(String) {
  let account = did.to_string(account)

  let place = [
    #("repo", json.string(account)),
    #("collection", json.string(collection)),
  ]

  Command(
    path: "/xrpc/com.atproto.repo.createRecord",
    body: record_body(
      case key {
        Some(key) -> list.append(place, [#("rkey", json.string(key))])
        None -> place
      },
      record,
    ),
    read: fn(answer) {
      json.parse(answer, decode.at(["uri"], decode.string))
      |> result.replace_error(NotUnderstood)
      |> result.try(fn(address) {
        string.split(address, "/")
        |> list.last
        |> result.replace_error(NotUnderstood)
      })
    },
  )
}

pub fn delete_record(
  account: Did,
  collection: String,
  key: String,
) -> Command(Nil) {
  let account = did.to_string(account)

  command(
    "com.atproto.repo.deleteRecord",
    json.object([
      #("repo", json.string(account)),
      #("collection", json.string(collection)),
      #("rkey", json.string(key)),
    ]),
  )
}

fn record_body(place: List(#(String, Json)), record: String) -> String {
  string.drop_end(json.to_string(json.object(place)), 1)
  <> ",\"record\":"
  <> record
  <> "}"
}

pub fn set_account_invites(did: String, enabled: Bool) -> Command(Nil) {
  command(
    case enabled {
      True -> "com.atproto.admin.enableAccountInvites"
      False -> "com.atproto.admin.disableAccountInvites"
    },
    json.object([#("account", json.string(did))]),
  )
}

pub fn delete_account_as_admin(did: String) -> Command(Nil) {
  command(
    "com.atproto.admin.deleteAccount",
    json.object([#("did", json.string(did))]),
  )
}

pub fn create_invite_code() -> Command(String) {
  command_returning(
    "com.atproto.server.createInviteCode",
    json.object([#("useCount", json.int(1))]),
    decode.at(["code"], decode.string),
  )
}

pub fn disable_invite_code(code: String) -> Command(Nil) {
  command(
    "com.atproto.admin.disableInviteCodes",
    json.object([#("codes", json.array([code], json.string))]),
  )
}

pub fn save_server_page(page: ServerPage) -> Command(Nil) {
  command(
    "_admin.updateServerConfig",
    json.object([
      #("serverName", json.string(page.name)),
      #("primaryColor", json.string(page.primary)),
      #("primaryColorDark", json.string(page.primary_dark)),
      #("secondaryColor", json.string(page.secondary)),
      #("secondaryColorDark", json.string(page.secondary_dark)),
      #("logoCid", json.string(option.unwrap(page.logo, ""))),
    ]),
  )
}

pub fn link_signal() -> Command(String) {
  command_returning(
    "_admin.linkSignalDevice",
    json.object([]),
    decode.at(["qrBase64"], decode.string),
  )
}

pub fn unlink_signal() -> Command(Nil) {
  command("_admin.unlinkSignalDevice", json.object([]))
}

pub fn add_controller(did: String, access: String) -> Command(Nil) {
  command(
    "_delegation.addController",
    json.object([
      #("controller_did", json.string(did)),
      #("granted_scopes", json.string(access)),
    ]),
  )
}

pub fn remove_controller(did: String) -> Command(Nil) {
  command(
    "_delegation.removeController",
    json.object([#("controller_did", json.string(did))]),
  )
}

pub fn create_controlled_account(
  handle: String,
  email: Option(String),
  access: String,
) -> Command(Nil) {
  let account = [
    #("handle", json.string(handle)),
    #("controllerScopes", json.string(access)),
  ]

  command(
    "_delegation.createDelegatedAccount",
    json.object(case email {
      Some(email) -> [#("email", json.string(email)), ..account]
      None -> account
    }),
  )
}

pub fn delete_controlled_account(did: String) -> Command(Nil) {
  command(
    "_delegation.deleteControlledAccount",
    json.object([#("did", json.string(did))]),
  )
}

pub fn rename_passkey(id: String, name: String) -> Command(Nil) {
  command(
    "com.atproto.server.updatePasskey",
    json.object([
      #("id", json.string(id)),
      #("friendlyName", json.string(name)),
    ]),
  )
}

pub fn delete_passkey(id: String) -> Command(Nil) {
  command(
    "com.atproto.server.deletePasskey",
    json.object([#("id", json.string(id))]),
  )
}

pub fn prepare_authenticator() -> Command(AuthenticatorSetup) {
  command_returning("com.atproto.server.createTotpSecret", json.object([]), {
    use secret <- decode.field("secret", decode.string)
    use qr_image <- decode.field("qrBase64", decode.string)

    decode.success(AuthenticatorSetup(secret:, qr_image:))
  })
}

pub fn enable_authenticator(code: String) -> Command(List(String)) {
  command_returning(
    "com.atproto.server.enableTotp",
    json.object([#("code", json.string(code))]),
    backup_codes_decoder(),
  )
}

pub fn disable_authenticator(password: String, code: String) -> Command(Nil) {
  command(
    "com.atproto.server.disableTotp",
    json.object([
      #("password", json.string(password)),
      #("code", json.string(code)),
    ]),
  )
}

pub fn replace_backup_codes(
  password: String,
  code: String,
) -> Command(List(String)) {
  command_returning(
    "com.atproto.server.regenerateBackupCodes",
    json.object([
      #("password", json.string(password)),
      #("code", json.string(code)),
    ]),
    backup_codes_decoder(),
  )
}

pub fn change_password(current: String, new: String) -> Command(Nil) {
  command(
    "_account.changePassword",
    json.object([
      #("currentPassword", json.string(current)),
      #("newPassword", json.string(new)),
    ]),
  )
}

pub fn set_password(new: String) -> Command(Nil) {
  command(
    "_account.setPassword",
    json.object([#("newPassword", json.string(new))]),
  )
}

pub fn remove_password() -> Command(Nil) {
  command("_account.removePassword", json.object([]))
}

pub fn unlink_account(id: String) -> Command(Nil) {
  Command(
    path: "/oauth/sso/unlink",
    body: json.to_string(json.object([#("id", json.string(id))])),
    read: fn(_) { Ok(Nil) },
  )
}

pub fn allow_older_apps(allowed: Bool) -> Command(Nil) {
  command(
    "_account.updateLegacyLoginPreference",
    json.object([#("allowLegacyLogin", json.bool(allowed))]),
  )
}

pub fn rename_device(id: String, name: String) -> Command(Nil) {
  command(
    "_account.updateTrustedDevice",
    json.object([
      #("deviceId", json.string(id)),
      #("friendlyName", json.string(name)),
    ]),
  )
}

pub fn forget_device(id: String) -> Command(Nil) {
  command(
    "_account.revokeTrustedDevice",
    json.object([#("deviceId", json.string(id))]),
  )
}

pub fn sign_in_again_with_password(password: String) -> Command(Nil) {
  command(
    "_account.reauthPassword",
    json.object([#("password", json.string(password))]),
  )
}

pub fn sign_in_again_with_code(code: String) -> Command(Nil) {
  command("_account.reauthTotp", json.object([#("code", json.string(code))]))
}

pub fn revoke_app_password(name: String) -> Command(Nil) {
  command(
    "com.atproto.server.revokeAppPassword",
    json.object([#("name", json.string(name))]),
  )
}

pub fn change_handle(handle: String) -> Command(Nil) {
  command(
    "com.atproto.identity.updateHandle",
    json.object([#("handle", json.string(handle))]),
  )
}

pub fn resend_verification(account: Did) -> Command(Nil) {
  let account = did.to_string(account)

  command(
    "com.atproto.server.resendVerification",
    json.object([#("did", json.string(account))]),
  )
}

pub fn confirm_email(email: String, code: String) -> Command(Nil) {
  command(
    "com.atproto.server.confirmEmail",
    json.object([#("email", json.string(email)), #("token", json.string(code))]),
  )
}

pub fn request_email_change(new_email: String) -> Command(Bool) {
  command_returning(
    "com.atproto.server.requestEmailUpdate",
    json.object([#("newEmail", json.string(new_email))]),
    decode.at(["tokenRequired"], decode.bool),
  )
}

pub fn change_email(email: String, code: Option(String)) -> Command(Nil) {
  command(
    "com.atproto.server.updateEmail",
    json.object(case code {
      Some(code) -> [
        #("email", json.string(email)),
        #("token", json.string(code)),
      ]
      None -> [#("email", json.string(email))]
    }),
  )
}

pub fn update_contact(
  preferred: Channel,
  usernames: List(#(Channel, String)),
) -> Command(Nil) {
  let usernames =
    list.map(usernames, fn(entry) {
      #(channel_name(entry.0) <> "Username", json.string(entry.1))
    })

  command(
    "_account.updateNotificationPrefs",
    json.object([
      #("preferredChannel", json.string(channel_name(preferred))),
      ..usernames
    ]),
  )
}

pub fn set_language(code: String) -> Command(Nil) {
  command(
    "_account.updateLocale",
    json.object([#("preferredLocale", json.string(code))]),
  )
}

pub fn request_account_deletion() -> Command(Nil) {
  command("com.atproto.server.requestAccountDelete", json.object([]))
}

pub fn set_login_alerts(enabled: Bool) -> Command(Nil) {
  command(
    "_account.updateNotificationPrefs",
    json.object([#("legacyLoginAlerts", json.bool(enabled))]),
  )
}

pub fn confirm_channel(
  channel: Channel,
  username: String,
  code: String,
) -> Command(Nil) {
  command(
    "_account.confirmChannelVerification",
    json.object([
      #("channel", json.string(channel_name(channel))),
      #("identifier", json.string(username)),
      #("code", json.string(code)),
    ]),
  )
}

pub fn end_session(id: String) -> Command(Nil) {
  command(
    "_account.revokeSession",
    json.object([#("sessionId", json.string(id))]),
  )
}

pub fn end_other_sessions() -> Command(Nil) {
  command("_account.revokeAllSessions", json.object([]))
}

pub fn forget_remembered_app(client_id: String) -> Command(Nil) {
  command(
    "_account.forgetRememberedAppChoice",
    json.object([#("clientId", json.string(client_id))]),
  )
}

pub fn parse(query: Query(answer), body: String) -> Result(answer, Problem) {
  json.parse(body, query.decoder) |> result.replace_error(NotUnderstood)
}

fn fetch(
  session: Session,
  query: Query(answer),
) -> Promise(Result(answer, Failure)) {
  use response <- promise.map(session.get(session, query.path))
  use body <- result.try(accepted(response))

  parse(query, body) |> result.map_error(Failed)
}

fn run(
  session: Session,
  command: Command(answer),
) -> Promise(Result(answer, Failure)) {
  let body = command.body
  use response <- promise.map(session.post(session, command.path, body))
  use answer <- result.try(accepted(response))

  command.read(answer) |> result.map_error(Failed)
}

fn report(
  session: Session,
  start: fn() -> Promise(Result(answer, Failure)),
  to_message: fn(Result(answer, Problem)) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  start()
  |> promise.tap(fn(outcome) {
    case outcome {
      Ok(answer) -> dispatch(to_message(Ok(answer)))
      Error(Failed(problem:)) -> dispatch(to_message(Error(problem)))
      Error(Expired) -> session.expire(session)
    }
  })

  Nil
}

pub fn load(
  session: Session,
  query: Query(answer),
  to_message: fn(Result(answer, Problem)) -> message,
) -> Effect(message) {
  report(session, fn() { fetch(session, query) }, to_message)
}

pub fn perform(
  session: Session,
  command: Command(answer),
  to_message: fn(Result(answer, Problem)) -> message,
) -> Effect(message) {
  report(session, fn() { run(session, command) }, to_message)
}

pub fn upload_media(
  session: Session,
  file: File,
  to_message: fn(Result(String, Problem)) -> message,
) -> Effect(message) {
  report(
    session,
    fn() {
      use response <- promise.map(session.upload(
        session,
        "/xrpc/com.atproto.repo.uploadBlob",
        file,
      ))
      use answer <- result.try(accepted(response))

      json.parse(answer, decode.at(["blob", "ref", "$link"], decode.string))
      |> result.replace_error(Failed(NotUnderstood))
    },
    to_message,
  )
}

pub fn save_repository(
  session: Session,
  filename: String,
  to_message: fn(Result(Nil, Problem)) -> message,
) -> Effect(message) {
  let path =
    "/xrpc/com.atproto.sync.getRepo?"
    <> uri.query_to_string([
      #("did", did.to_string(session.account(session))),
    ])

  report(
    session,
    fn() {
      use response <- promise.map(session.save(session, path, filename))

      accepted(response) |> result.replace(Nil)
    },
    to_message,
  )
}

pub fn delete_account(
  session: Session,
  password: String,
  code: String,
  to_message: fn(Result(Nil, Problem)) -> message,
) -> Effect(message) {
  rsvp.post(
    session.origin(session) <> "/xrpc/com.atproto.server.deleteAccount",
    json.object([
      #("did", json.string(did.to_string(session.account(session)))),
      #("password", json.string(password)),
      #("token", json.string(code)),
    ]),
    rsvp.expect_any_response(fn(response) {
      to_message(case response {
        Ok(response) if response.status == 200 -> {
          session.forget(session)

          Ok(Nil)
        }
        Ok(response) -> Error(refusal(response.body))
        Error(_) -> Error(Unreachable)
      })
    }),
  )
}

fn refusal(body: String) -> Problem {
  let decoder = {
    use error <- decode.field("error", decode.string)
    use message <- decode.optional_field("message", "", decode.string)

    decode.success(Refused(error:, message:))
  }

  case json.parse(body, decoder) {
    Ok(refused) -> refused
    Error(_) -> NotUnderstood
  }
}

fn accepted(
  response: Result(#(Int, String), session.Problem),
) -> Result(String, Failure) {
  case response {
    Ok(#(200, body)) -> Ok(body)

    Error(session.SessionEnded) -> Error(Expired)

    Ok(#(status, body)) ->
      case status, refusal(body) {
        401, Refused(error: "AuthenticationFailed", ..)
        | 401, Refused(error: "ExpiredToken", ..)
        -> Error(Expired)
        _, problem -> Error(Failed(problem:))
      }

    Error(session.SignInRejected)
    | Error(session.NothingStored)
    | Error(session.Failed(_)) -> Error(Failed(Unreachable))
  }
}

fn optional_text(
  name: String,
  next: fn(Option(String)) -> Decoder(answer),
) -> Decoder(answer) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

fn backup_codes_decoder() -> Decoder(List(String)) {
  decode.at(["backupCodes"], decode.list(decode.string))
}

fn command_returning(
  name: String,
  body: Json,
  decoder: Decoder(answer),
) -> Command(answer) {
  Command(path: "/xrpc/" <> name, body: json.to_string(body), read: fn(answer) {
    json.parse(answer, decoder) |> result.replace_error(NotUnderstood)
  })
}

fn command(name: String, body: Json) -> Command(Nil) {
  Command(path: "/xrpc/" <> name, body: json.to_string(body), read: fn(_) {
    Ok(Nil)
  })
}

fn query(
  name: String,
  parameters: List(#(String, String)),
  decoder: Decoder(answer),
) -> Query(answer) {
  let path = case parameters {
    [] -> "/xrpc/" <> name
    [_, ..] -> "/xrpc/" <> name <> "?" <> uri.query_to_string(parameters)
  }

  Query(path:, decoder:)
}
