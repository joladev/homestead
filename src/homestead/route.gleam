import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri.{type Uri}
import lustre/attribute.{type Attribute}

pub type Route {
  Overview
  Account(AccountPage)
  Access(AccessPage)
  Data(DataPage)
  Advanced(AdvancedPage)
  Admin
  NotFound(uri: Uri)
}

pub type AccountPage {
  Profile
  Notifications
  DeleteAccount
}

pub type AccessPage {
  SignInMethods
  Sessions
  ConnectedApps
  AppPasswords
}

pub type DataPage {
  Export
  Repository(location: RepositoryLocation)
}

pub type RepositoryLocation {
  Collections
  Records(collection: String)
  Record(collection: String, key: String)
  NewRecord(collection: String)
}

pub type AdvancedPage {
  Delegation
  IdentityDocument
}

pub type Section {
  Section(label: String, first: Route, rest: List(Route))
}

pub const sections = [
  Section(label: "Overview", first: Overview, rest: []),
  Section(
    label: "Account",
    first: Account(Profile),
    rest: [
      Account(Notifications),
      Account(DeleteAccount),
    ],
  ),
  Section(
    label: "Access",
    first: Access(SignInMethods),
    rest: [
      Access(Sessions),
      Access(ConnectedApps),
      Access(AppPasswords),
    ],
  ),
  Section(
    label: "Data",
    first: Data(Export),
    rest: [
      Data(Repository(Collections)),
    ],
  ),
  Section(
    label: "Advanced",
    first: Advanced(Delegation),
    rest: [
      Advanced(IdentityDocument),
    ],
  ),
]

pub fn section_pages(section: Section) -> List(Route) {
  [section.first, ..section.rest]
}

pub fn from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> Overview
    ["account", "profile"] -> Account(Profile)
    ["account", "notifications"] -> Account(Notifications)
    ["account", "delete"] -> Account(DeleteAccount)
    ["access", "sign-in"] -> Access(SignInMethods)
    ["access", "sessions"] -> Access(Sessions)
    ["access", "apps"] -> Access(ConnectedApps)
    ["access", "app-passwords"] -> Access(AppPasswords)
    ["data", "export"] -> Data(Export)
    ["data", "repository"] ->
      Data(
        Repository(case query(uri, "collection"), query(uri, "key") {
          Some(collection), Some(key) -> Record(collection:, key:)
          Some(collection), None -> Records(collection:)
          None, _ -> Collections
        }),
      )
    ["data", "repository", "new"] ->
      Data(
        Repository(
          NewRecord(collection: option.unwrap(query(uri, "collection"), "")),
        ),
      )
    ["advanced", "delegation"] -> Advanced(Delegation)
    ["advanced", "identity"] -> Advanced(IdentityDocument)
    ["admin"] -> Admin
    _ -> NotFound(uri:)
  }
}

pub fn to_path(route: Route) -> String {
  case route {
    Overview -> "/"
    Account(Profile) -> "/account/profile"
    Account(Notifications) -> "/account/notifications"
    Account(DeleteAccount) -> "/account/delete"
    Access(SignInMethods) -> "/access/sign-in"
    Access(Sessions) -> "/access/sessions"
    Access(ConnectedApps) -> "/access/apps"
    Access(AppPasswords) -> "/access/app-passwords"
    Data(Export) -> "/data/export"
    Data(Repository(Collections)) -> "/data/repository"
    Data(Repository(Records(collection:))) ->
      "/data/repository?" <> uri.query_to_string([#("collection", collection)])
    Data(Repository(Record(collection:, key:))) ->
      "/data/repository?"
      <> uri.query_to_string([#("collection", collection), #("key", key)])
    Data(Repository(NewRecord(collection: ""))) -> "/data/repository/new"
    Data(Repository(NewRecord(collection:))) ->
      "/data/repository/new?"
      <> uri.query_to_string([#("collection", collection)])
    Advanced(Delegation) -> "/advanced/delegation"
    Advanced(IdentityDocument) -> "/advanced/identity"
    Admin -> "/admin"
    NotFound(uri:) -> uri.path
  }
}

pub fn label(route: Route) -> String {
  case route {
    Overview -> "Overview"
    Account(Profile) -> "Profile and contact"
    Account(Notifications) -> "Notifications"
    Account(DeleteAccount) -> "Delete account"
    Access(SignInMethods) -> "Sign-in methods"
    Access(Sessions) -> "Sessions"
    Access(ConnectedApps) -> "Connected apps"
    Access(AppPasswords) -> "App passwords"
    Data(Export) -> "Export"
    Data(Repository(_)) -> "Repository"
    Advanced(Delegation) -> "Delegation"
    Advanced(IdentityDocument) -> "Identity document"
    Admin -> "Admin"
    NotFound(_) -> "Page not found"
  }
}

fn query(uri: Uri, name: String) -> Option(String) {
  option.to_result(uri.query, Nil)
  |> result.try(uri.parse_query)
  |> result.try(list.key_find(_, name))
  |> option.from_result
}

pub fn page(route: Route) -> Route {
  case route {
    Data(Repository(_)) -> Data(Repository(Collections))
    Overview
    | Account(_)
    | Access(_)
    | Data(Export)
    | Advanced(_)
    | Admin
    | NotFound(_) -> route
  }
}

pub fn href(route: Route) -> Attribute(message) {
  attribute.href(to_path(route))
}
