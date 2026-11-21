import gleam/uri.{type Uri}
import lustre/attribute.{type Attribute}

pub type Route {
  Overview
  Account(AccountPage)
  Access(AccessPage)
  Data(DataPage)
  Advanced(AdvancedPage)
  NotFound(uri: Uri)
}

pub type AccountPage {
  Profile
  Notifications
}

pub type AccessPage {
  SignInMethods
  Sessions
  ConnectedApps
  AppPasswords
}

pub type DataPage {
  Export
  Repository
}

pub type AdvancedPage {
  Delegation
  IdentityDocument
}

pub fn from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> Overview
    ["account", "profile"] -> Account(Profile)
    ["account", "notifications"] -> Account(Notifications)
    ["access", "sign-in"] -> Access(SignInMethods)
    ["access", "sessions"] -> Access(Sessions)
    ["access", "apps"] -> Access(ConnectedApps)
    ["access", "app-passwords"] -> Access(AppPasswords)
    ["data", "export"] -> Data(Export)
    ["data", "repository"] -> Data(Repository)
    ["advanced", "delegation"] -> Advanced(Delegation)
    ["advanced", "identity"] -> Advanced(IdentityDocument)
    _ -> NotFound(uri:)
  }
}

pub fn to_path(route: Route) -> String {
  case route {
    Overview -> "/"
    Account(Profile) -> "/account/profile"
    Account(Notifications) -> "/account/notifications"
    Access(SignInMethods) -> "/access/sign-in"
    Access(Sessions) -> "/access/sessions"
    Access(ConnectedApps) -> "/access/apps"
    Access(AppPasswords) -> "/access/app-passwords"
    Data(Export) -> "/data/export"
    Data(Repository) -> "/data/repository"
    Advanced(Delegation) -> "/advanced/delegation"
    Advanced(IdentityDocument) -> "/advanced/identity"
    NotFound(uri:) -> uri.path
  }
}

pub fn href(route: Route) -> Attribute(message) {
  attribute.href(to_path(route))
}
