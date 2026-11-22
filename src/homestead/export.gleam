import gleam/option.{type Option, None, Some}
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Account, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(session: Session, account: Remote(Account), download: Download)
}

type Download {
  NotDownloading
  Downloading
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(session:, account: Loading, download: NotDownloading),
    tranquil.load(session, tranquil.account(), ServerReturnedAccount),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    remote.has_ended_session(model.account)
    || model.download == Refused(tranquil.SessionEnded)

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedAccount(result: Result(Account, Problem))
  UserClickedDownload(handle: String)
  BrowserSavedRepository(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedAccount(result:) -> #(
      Model(..model, account: remote.from_result(result)),
      effect.none(),
    )

    UserClickedDownload(handle:) -> #(
      Model(..model, download: Downloading),
      tranquil.save_repository(
        model.session,
        filename(handle),
        BrowserSavedRepository,
      ),
    )

    BrowserSavedRepository(result: Ok(Nil)) -> #(
      Model(..model, download: NotDownloading),
      effect.none(),
    )

    BrowserSavedRepository(result: Error(problem)) -> #(
      Model(..model, download: Refused(problem:)),
      effect.none(),
    )
  }
}

pub fn filename(handle: String) -> String {
  handle <> "-repo.car"
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section("export", [
      layout.block(case model.account {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: account) -> [
          layout.row(
            tone: layout.Plain,
            name: "Records",
            details: [
              html.text("Every record in one file "),
              layout.dim("\u{00B7} media not included"),
            ],
            actions: [
              html.button(
                [
                  attribute.class("action"),
                  attribute.disabled(model.download == Downloading),
                  event.on_click(UserClickedDownload(account.handle)),
                ],
                [
                  html.text(case model.download {
                    Downloading -> "Downloading"
                    NotDownloading | Refused(_) -> "Download"
                  }),
                ],
              ),
            ],
          ),
          case model.download {
            Refused(_) -> layout.problem("Couldn't download")
            NotDownloading | Downloading -> element.none()
          },
        ]
      }),
    ]),
  ])
}
