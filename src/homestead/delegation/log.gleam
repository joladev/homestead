import at/did.{type Did}
import at/handle.{type Handle}
import gleam/list
import gleam/option
import gleam/result
import gleam/time/duration.{type Duration}
import homestead/date
import homestead/identity
import homestead/layout
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type LogEntry, type LogPage, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    entries: Remote(List(LogEntry)),
    total: Int,
    more: More,
  )
}

type More {
  NotLoadingMore
  LoadingMore
  MoreRefused(problem: Problem)
}

pub fn init(
  session: Session,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset:,
      entries: Loading,
      total: 0,
      more: NotLoadingMore,
    ),
    tranquil.load(session, tranquil.delegation_log(0), ServerReturnedLog),
  )
}

pub opaque type Message {
  ServerReturnedLog(result: Result(LogPage, Problem))
  UserClickedMore(offset: Int)
  ServerReturnedMore(result: Result(LogPage, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedLog(result:) -> #(
      Model(
        ..model,
        entries: remote.from_result(result)
          |> remote.map(fn(page) { page.entries }),
        total: result.map(result, fn(page) { page.total }) |> result.unwrap(0),
      ),
      effect.none(),
    )

    UserClickedMore(offset:) -> #(
      Model(..model, more: LoadingMore),
      tranquil.load(
        model.session,
        tranquil.delegation_log(offset),
        ServerReturnedMore,
      ),
    )

    ServerReturnedMore(result: Ok(page)) -> #(
      Model(
        ..model,
        entries: remote.map(model.entries, list.append(_, page.entries)),
        total: page.total,
        more: NotLoadingMore,
      ),
      effect.none(),
    )

    ServerReturnedMore(result: Error(problem)) -> #(
      Model(..model, more: MoreRefused(problem:)),
      effect.none(),
    )
  }
}

pub fn describe_action(action: String) -> String {
  case action {
    "GrantCreated" -> "Access granted"
    "GrantRevoked" -> "Access removed"
    "ScopesModified" -> "Access changed"
    "TokenIssued" -> "Signed in"
    "RepoWrite" -> "Record written"
    "BlobUpload" -> "Media uploaded"
    "AccountAction" -> "Account action"
    action -> action
  }
}

pub fn view(
  model: Model,
  names: List(#(Did, Handle)),
) -> List(Element(Message)) {
  [
    layout.block({
      use entries <- layout.rows(model.entries, placeholders: 3)

      list.flatten([
        layout.listing(
          empty: "No entries",
          rows: list.map(entries, fn(entry) {
            #(
              entry.id,
              layout.row(
                tone: layout.Plain,
                name: date.describe_moment(entry.at, model.local_offset),
                details: [
                  html.text(describe_action(entry.action) <> " "),
                  layout.dim(
                    "\u{00B7} by "
                    <> identity.name(
                      entry.actor,
                      list.key_find(names, entry.actor) |> option.from_result,
                    ),
                  ),
                ],
                actions: [],
              ),
            )
          }),
          actions: [],
        ),
        case model.more {
          MoreRefused(_) -> [layout.problem("Couldn't load more")]
          NotLoadingMore | LoadingMore -> []
        },
        case list.length(entries) < model.total {
          True -> [
            layout.actions_row([
              html.button(
                [
                  attribute.class("action"),
                  attribute.disabled(model.more == LoadingMore),
                  event.on_click(UserClickedMore(list.length(entries))),
                ],
                [html.text("More")],
              ),
            ]),
          ]
          False -> []
        },
      ])
    }),
  ]
}
