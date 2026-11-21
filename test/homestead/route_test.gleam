import gleam/list
import gleam/uri
import homestead/route.{
  Access, Account, Admin, Advanced, AppPasswords, ConnectedApps, Data,
  Delegation, Export, IdentityDocument, NotFound, Notifications, Overview,
  Profile, Repository, Sessions, SignInMethods,
}

pub fn every_page_survives_the_round_trip_through_its_path_test() {
  let pages = [
    Overview,
    Account(Profile),
    Account(Notifications),
    Access(SignInMethods),
    Access(Sessions),
    Access(ConnectedApps),
    Access(AppPasswords),
    Data(Export),
    Data(Repository),
    Advanced(Delegation),
    Advanced(IdentityDocument),
    Admin,
  ]

  list.each(pages, fn(page) {
    let assert Ok(uri) = uri.parse(route.to_path(page))

    assert route.from_uri(uri) == page
  })
}

pub fn an_unknown_path_is_not_found_test() {
  let assert Ok(uri) = uri.parse("/nowhere")

  assert route.from_uri(uri) == NotFound(uri:)
}
