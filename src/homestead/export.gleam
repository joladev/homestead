import at/handle.{type Handle}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import homestead/layout
import homestead/media_archive.{type Stopper}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Account, type MediaPage, type Problem, MediaPage}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    account: Remote(Account),
    download: Download,
    media: Remote(List(String)),
    archive: Archive,
    saves_to_disk: Bool,
  )
}

type Download {
  NotDownloading
  Downloading
  Refused(problem: Problem)
}

type Archive {
  NotSaving
  Saving(done: Int, stopper: Option(Stopper))
  SavingFailed
}

pub fn init(
  session: Session,
  saves_to_disk: Bool,
) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      account: Loading,
      download: NotDownloading,
      media: Loading,
      archive: NotSaving,
      saves_to_disk:,
    ),
    effect.batch([
      tranquil.load(session, tranquil.account(), ServerReturnedAccount),
      load_media(session, [], None),
    ]),
  )
}

pub opaque type Message {
  ServerReturnedAccount(result: Result(Account, Problem))
  ServerReturnedMedia(found: List(String), result: Result(MediaPage, Problem))
  UserClickedDownload(handle: Handle)
  BrowserSavedRepository(result: Result(Nil, Problem))
  UserClickedSaveMedia(handle: Handle, media: List(String))
  BrowserStartedSaving(stopper: Stopper)
  BrowserSavedMedia(done: Int)
  UserClickedCancel(stopper: Stopper)
  BrowserFinishedSaving(outcome: media_archive.Outcome)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedAccount(result:) -> #(
      Model(..model, account: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedMedia(
      found:,
      result: Ok(MediaPage(media:, next: Some(cursor))),
    ) -> #(
      model,
      load_media(model.session, list.append(found, media), Some(cursor)),
    )

    ServerReturnedMedia(found:, result: Ok(MediaPage(media:, next: None))) -> #(
      Model(..model, media: Loaded(list.append(found, media))),
      effect.none(),
    )

    ServerReturnedMedia(result: Error(problem), ..) -> #(
      Model(..model, media: Failed(problem)),
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

    UserClickedSaveMedia(handle:, media:) -> #(
      Model(..model, archive: Saving(done: 0, stopper: None)),
      media_archive.save(
        model.session,
        media,
        media_filename(handle),
        started: BrowserStartedSaving,
        progressed: BrowserSavedMedia,
        finished: BrowserFinishedSaving,
      ),
    )

    BrowserStartedSaving(stopper:) ->
      case model.archive {
        Saving(done:, ..) -> #(
          Model(..model, archive: Saving(done:, stopper: Some(stopper))),
          effect.none(),
        )
        NotSaving | SavingFailed -> #(model, effect.none())
      }

    BrowserSavedMedia(done:) ->
      case model.archive {
        Saving(stopper:, ..) -> #(
          Model(..model, archive: Saving(done:, stopper:)),
          effect.none(),
        )
        NotSaving | SavingFailed -> #(model, effect.none())
      }

    UserClickedCancel(stopper:) -> #(model, media_archive.stop(stopper))

    BrowserFinishedSaving(outcome: media_archive.Saved)
    | BrowserFinishedSaving(outcome: media_archive.Cancelled) -> #(
      Model(..model, archive: NotSaving),
      effect.none(),
    )

    BrowserFinishedSaving(outcome: media_archive.Failed) -> #(
      Model(..model, archive: SavingFailed),
      effect.none(),
    )
  }
}

fn load_media(
  session: Session,
  found: List(String),
  after: Option(String),
) -> Effect(Message) {
  tranquil.load(
    session,
    tranquil.media(session.account(session), after),
    ServerReturnedMedia(found, _),
  )
}

pub fn filename(handle: Handle) -> String {
  handle.to_string(handle) <> "-repo.car"
}

pub fn media_filename(handle: Handle) -> String {
  handle.to_string(handle) <> "-media.zip"
}

pub fn view(model: Model) -> Element(Message) {
  let media = {
    use account <- remote.then(model.account)
    use media <- remote.map(model.media)

    #(account.handle, media)
  }

  layout.page([
    layout.title_section("export", [
      layout.block([
        layout.row(
          tone: layout.Plain,
          name: "Records",
          details: [html.text("Every record in one file")],
          actions: [
            {
              use account <- layout.value(model.account)

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
              )
            },
          ],
        ),
        case model.download {
          Refused(_) -> layout.problem("Couldn't download")
          NotDownloading | Downloading -> element.none()
        },
        {
          use #(handle, media) <- layout.awaited_row(name: "Media", of: media)

          view_media(model, handle, media)
        },
        case model.archive {
          SavingFailed -> layout.problem("Couldn't download")
          NotSaving | Saving(..) -> element.none()
        },
      ]),
    ]),
  ])
}

fn view_media(
  model: Model,
  handle: Handle,
  media: List(String),
) -> Element(Message) {
  let #(details, actions) = case media, model.archive {
    [], _ -> #([layout.dim("none")], [])

    [_, ..], Saving(done:, stopper:) -> #(
      [
        html.text(
          int.to_string(done) <> " of " <> int.to_string(list.length(media)),
        ),
      ],
      case stopper {
        Some(stopper) -> [
          html.button(
            [
              attribute.class("action"),
              event.on_click(UserClickedCancel(stopper)),
            ],
            [html.text("Cancel")],
          ),
        ]
        None -> []
      },
    )

    [_, ..], NotSaving | [_, ..], SavingFailed -> #(
      [
        html.text(case list.length(media) {
          1 -> "1 file in one zip"
          count -> int.to_string(count) <> " files in one zip"
        }),
        case model.saves_to_disk {
          True -> element.none()
          False ->
            layout.dim(
              " \u{00B7} very large libraries may not fit in this browser",
            )
        },
      ],
      [
        html.button(
          [
            attribute.class("action"),
            event.on_click(UserClickedSaveMedia(handle, media)),
          ],
          [html.text("Download")],
        ),
      ],
    )
  }

  layout.row(tone: layout.Plain, name: "Media", details:, actions:)
}
