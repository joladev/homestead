import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import homestead/browser
import homestead/confirmation
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{
  type RepositoryLocation, Collections, Data, NewRecord, Record, Records,
  Repository,
}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type Problem, type RecordPage, type RepoRecord}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem

const delete_button_id = "delete-record"

const record_id = "record-json"

const new_record_template = "{\n  \"$type\": \"\"\n}"

pub opaque type Model {
  Model(session: Session, place: Place)
}

type Place {
  AtCollections(collections: Remote(List(String)))
  AtRecords(
    collection: String,
    records: Remote(List(RepoRecord)),
    next: Option(String),
    more: More,
  )
  AtRecord(
    collection: String,
    key: String,
    record: Remote(RepoRecord),
    text: String,
    action: Action,
    copied: Copied,
  )
  AtNewRecord(collection: String, key: String, text: String, creation: Creation)
}

type More {
  NotLoadingMore
  LoadingMore
  MoreRefused(problem: Problem)
}

type Action {
  Editing
  NotJson
  Saving
  Saved
  SaveRefused(problem: Problem)
  ConfirmingDelete
  Deleting
  DeleteRefused(problem: Problem)
}

type Copied {
  NothingCopied
  CopiedAddress
  CopiedContentId
  CopyFailed
}

type Creation {
  Composing
  NewNotJson
  Creating
  CreationRefused(problem: Problem)
}

pub fn init(
  session: Session,
  location: RepositoryLocation,
) -> #(Model, Effect(Message)) {
  let account = session.account(session)

  case location {
    Collections -> #(
      Model(session:, place: AtCollections(collections: Loading)),
      tranquil.load(
        session,
        tranquil.collections(account),
        ServerReturnedCollections,
      ),
    )

    Records(collection:) -> #(
      Model(
        session:,
        place: AtRecords(
          collection:,
          records: Loading,
          next: None,
          more: NotLoadingMore,
        ),
      ),
      tranquil.load(
        session,
        tranquil.records(account, collection, None),
        ServerReturnedRecords,
      ),
    )

    Record(collection:, key:) -> #(
      Model(
        session:,
        place: AtRecord(
          collection:,
          key:,
          record: Loading,
          text: "",
          action: Editing,
          copied: NothingCopied,
        ),
      ),
      load_record(session, collection, key),
    )

    NewRecord(collection:) -> #(
      Model(
        session:,
        place: AtNewRecord(
          collection:,
          key: "",
          text: new_record_template,
          creation: Composing,
        ),
      ),
      effect.none(),
    )
  }
}

pub fn departure(model: Model) -> Option(Departure) {
  let ended = tranquil.SessionEnded
  let has_ended_session = case model.place {
    AtCollections(collections:) -> remote.has_ended_session(collections)
    AtRecords(records:, more:, ..) ->
      remote.has_ended_session(records) || more == MoreRefused(ended)
    AtRecord(record:, action:, ..) ->
      remote.has_ended_session(record)
      || action == SaveRefused(ended)
      || action == DeleteRefused(ended)
    AtNewRecord(creation:, ..) -> creation == CreationRefused(ended)
  }

  case has_ended_session {
    True -> Some(session.Ended)
    False -> None
  }
}

pub opaque type Message {
  ServerReturnedCollections(result: Result(List(String), Problem))
  ServerReturnedRecords(result: Result(RecordPage, Problem))
  UserClickedMore(after: String)
  ServerReturnedMoreRecords(result: Result(RecordPage, Problem))
  ServerReturnedRecord(result: Result(RepoRecord, Problem))
  UserEditedRecord(text: String)
  UserSubmittedRecord
  ServerSavedRecord(result: Result(Nil, Problem))
  UserClickedCopy(text: String, copied: Copied)
  BrowserCopiedText(copied: Copied, result: Result(Nil, Nil))
  UserClickedDelete
  UserCancelledDelete
  UserConfirmedDelete
  ServerDeletedRecord(result: Result(Nil, Problem))
  UserTypedCollection(collection: String)
  UserTypedKey(key: String)
  UserSubmittedNewRecord
  ServerCreatedRecord(collection: String, result: Result(String, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session
  let account = session.account(session)

  case model.place, message {
    AtCollections(_), ServerReturnedCollections(result:) -> #(
      Model(..model, place: AtCollections(remote.from_result(result))),
      effect.none(),
    )

    AtRecords(collection:, ..), ServerReturnedRecords(result:) -> #(
      Model(
        ..model,
        place: AtRecords(
          collection:,
          records: remote.from_result(result)
            |> remote.map(fn(page) { page.records }),
          next: result.map(result, fn(page) { page.next })
            |> result.unwrap(None),
          more: NotLoadingMore,
        ),
      ),
      effect.none(),
    )

    AtRecords(collection:, records:, next:, ..), UserClickedMore(after:) -> #(
      Model(
        ..model,
        place: AtRecords(collection:, records:, next:, more: LoadingMore),
      ),
      tranquil.load(
        session,
        tranquil.records(account, collection, Some(after)),
        ServerReturnedMoreRecords,
      ),
    )

    AtRecords(collection:, records:, ..),
      ServerReturnedMoreRecords(result: Ok(page))
    -> #(
      Model(
        ..model,
        place: AtRecords(
          collection:,
          records: remote.map(records, list.append(_, page.records)),
          next: page.next,
          more: NotLoadingMore,
        ),
      ),
      effect.none(),
    )

    AtRecords(collection:, records:, next:, ..),
      ServerReturnedMoreRecords(result: Error(problem))
    -> #(
      Model(
        ..model,
        place: AtRecords(
          collection:,
          records:,
          next:,
          more: MoreRefused(problem:),
        ),
      ),
      effect.none(),
    )

    AtRecord(collection:, key:, action:, copied:, ..),
      ServerReturnedRecord(result:)
    -> #(
      Model(
        ..model,
        place: AtRecord(
          collection:,
          key:,
          record: remote.from_result(result),
          text: result.map(result, fn(record) { record.json })
            |> result.unwrap(""),
          action:,
          copied:,
        ),
      ),
      effect.none(),
    )

    AtRecord(..) as place, UserEditedRecord(text:) -> #(
      Model(..model, place: AtRecord(..place, text:, action: Editing)),
      effect.none(),
    )

    AtRecord(collection:, key:, text:, ..) as place, UserSubmittedRecord ->
      case is_json_object(text) {
        False -> #(
          Model(..model, place: AtRecord(..place, action: NotJson)),
          effect.none(),
        )
        True -> #(
          Model(..model, place: AtRecord(..place, action: Saving)),
          tranquil.perform(
            session,
            tranquil.save_record(account, collection, key, text),
            ServerSavedRecord,
          ),
        )
      }

    AtRecord(collection:, key:, ..) as place, ServerSavedRecord(result: Ok(Nil))
    -> #(
      Model(..model, place: AtRecord(..place, action: Saved)),
      load_record(session, collection, key),
    )

    AtRecord(..) as place, ServerSavedRecord(result: Error(problem)) -> #(
      Model(..model, place: AtRecord(..place, action: SaveRefused(problem:))),
      effect.none(),
    )

    AtRecord(..), UserClickedCopy(text:, copied:) -> #(
      model,
      browser.copy(text, BrowserCopiedText(copied, _)),
    )

    AtRecord(..) as place, BrowserCopiedText(copied:, result:) -> #(
      Model(
        ..model,
        place: AtRecord(..place, copied: case result {
          Ok(Nil) -> copied
          Error(Nil) -> CopyFailed
        }),
      ),
      effect.none(),
    )

    AtRecord(..) as place, UserClickedDelete -> #(
      Model(..model, place: AtRecord(..place, action: ConfirmingDelete)),
      confirmation.focus_cancel(),
    )

    AtRecord(..) as place, UserCancelledDelete -> #(
      Model(..model, place: AtRecord(..place, action: Editing)),
      browser.focus(delete_button_id),
    )

    AtRecord(collection:, key:, ..) as place, UserConfirmedDelete -> #(
      Model(..model, place: AtRecord(..place, action: Deleting)),
      tranquil.perform(
        session,
        tranquil.delete_record(account, collection, key),
        ServerDeletedRecord,
      ),
    )

    AtRecord(collection:, ..), ServerDeletedRecord(result: Ok(Nil)) -> #(
      model,
      go_to(Records(collection:)),
    )

    AtRecord(..) as place, ServerDeletedRecord(result: Error(problem)) -> #(
      Model(..model, place: AtRecord(..place, action: DeleteRefused(problem:))),
      effect.none(),
    )

    AtNewRecord(..) as place, UserTypedCollection(collection:) -> #(
      Model(
        ..model,
        place: AtNewRecord(..place, collection:, creation: Composing),
      ),
      effect.none(),
    )

    AtNewRecord(..) as place, UserTypedKey(key:) -> #(
      Model(..model, place: AtNewRecord(..place, key:, creation: Composing)),
      effect.none(),
    )

    AtNewRecord(..) as place, UserEditedRecord(text:) -> #(
      Model(..model, place: AtNewRecord(..place, text:, creation: Composing)),
      effect.none(),
    )

    AtNewRecord(collection:, key:, text:, ..) as place, UserSubmittedNewRecord
    ->
      case is_json_object(text) {
        False -> #(
          Model(..model, place: AtNewRecord(..place, creation: NewNotJson)),
          effect.none(),
        )
        True -> {
          let collection = string.trim(collection)

          #(
            Model(..model, place: AtNewRecord(..place, creation: Creating)),
            tranquil.perform(
              session,
              tranquil.create_record(
                account,
                collection,
                case string.trim(key) {
                  "" -> None
                  key -> Some(key)
                },
                text,
              ),
              ServerCreatedRecord(collection, _),
            ),
          )
        }
      }

    AtNewRecord(..), ServerCreatedRecord(collection:, result: Ok(key)) -> #(
      model,
      go_to(Record(collection:, key:)),
    )

    AtNewRecord(..) as place, ServerCreatedRecord(result: Error(problem), ..) -> #(
      Model(
        ..model,
        place: AtNewRecord(..place, creation: CreationRefused(problem:)),
      ),
      effect.none(),
    )

    AtCollections(_), _
    | AtRecords(..), _
    | AtRecord(..), _
    | AtNewRecord(..), _
    -> #(model, effect.none())
  }
}

fn load_record(
  session: Session,
  collection: String,
  key: String,
) -> Effect(Message) {
  tranquil.load(
    session,
    tranquil.record(session.account(session), collection, key),
    ServerReturnedRecord,
  )
}

fn go_to(location: RepositoryLocation) -> Effect(Message) {
  case uri.parse(route.to_path(Data(Repository(location)))) {
    Ok(address) -> modem.push(address.path, address.query, None)
    Error(Nil) -> effect.none()
  }
}

pub fn is_json_object(text: String) -> Bool {
  json.parse(text, decode.dict(decode.string, decode.dynamic))
  |> result.is_ok
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused(_, message) if message != "" -> message
    tranquil.Unreachable -> "Couldn't reach the server"
    tranquil.Refused(_, _) | tranquil.NotUnderstood | tranquil.SessionEnded ->
      "The server didn't accept that"
  }
}

pub fn view(model: Model) -> Element(Message) {
  let top = link(Collections, "repository")

  layout.page([
    case model.place {
      AtCollections(collections:) ->
        layout.path_section_with_actions(
          [html.text("repository")],
          [view_new_link("")],
          [view_collections(collections)],
        )

      AtRecords(collection:, records:, next:, more:) ->
        layout.path_section_with_actions(
          [top, html.text(collection)],
          [view_new_link(collection)],
          [view_records(collection, records, next, more)],
        )

      AtRecord(collection:, key:, record:, text:, action:, copied:) ->
        layout.path_section_with_actions(
          [top, link(Records(collection:), collection), html.text(key)],
          case record, action {
            Loading, _ | Failed(_), _ | Loaded(_), ConfirmingDelete -> []
            Loaded(_), Editing
            | Loaded(_), NotJson
            | Loaded(_), Saving
            | Loaded(_), Saved
            | Loaded(_), SaveRefused(_)
            | Loaded(_), Deleting
            | Loaded(_), DeleteRefused(_)
            -> [
              html.button(
                [
                  attribute.id(delete_button_id),
                  attribute.class("action"),
                  attribute.disabled(action == Saving || action == Deleting),
                  event.on_click(UserClickedDelete),
                ],
                [html.text("Delete")],
              ),
            ]
          },
          [view_record(record, text, action, copied)],
        )

      AtNewRecord(collection:, key:, text:, creation:) ->
        layout.path_section([top, html.text("new")], [
          view_new_record(collection, key, text, creation),
        ])
    },
  ])
}

fn link(location: RepositoryLocation, text: String) -> Element(Message) {
  html.a([route.href(Data(Repository(location)))], [html.text(text)])
}

fn view_new_link(collection: String) -> Element(Message) {
  html.a(
    [
      attribute.class("action"),
      route.href(Data(Repository(NewRecord(collection:)))),
    ],
    [html.text("New record")],
  )
}

fn view_collections(collections: Remote(List(String))) -> Element(Message) {
  layout.block(
    list.flatten([
      case collections {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: collections) ->
          layout.listing(
            empty: "No collections",
            rows: list.map(collections, fn(collection) {
              layout.wide_row([link(Records(collection:), collection)])
            }),
            actions: [],
          )
      },
    ]),
  )
}

fn view_records(
  collection: String,
  records: Remote(List(RepoRecord)),
  next: Option(String),
  more: More,
) -> Element(Message) {
  layout.block(
    list.flatten([
      case records {
        Loading -> []
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: records) ->
          layout.listing(
            empty: "No records",
            rows: list.map(records, fn(record) {
              layout.linked_row(
                to: route.href(
                  Data(Repository(Record(collection:, key: record.key))),
                ),
                name: record.key,
                details: [
                  html.span([attribute.class("preview")], [
                    html.text(string.slice(record.preview, 0, 200)),
                  ]),
                ],
              )
            }),
            actions: case next {
              Some(after) -> [
                html.button(
                  [
                    attribute.class("action"),
                    attribute.disabled(more == LoadingMore),
                    event.on_click(UserClickedMore(after)),
                  ],
                  [html.text("More")],
                ),
              ]
              None -> []
            },
          )
      },
      case more {
        MoreRefused(_) -> [layout.problem("Couldn't load more")]
        NotLoadingMore | LoadingMore -> []
      },
    ]),
  )
}

fn view_record(
  record: Remote(RepoRecord),
  text: String,
  action: Action,
  copied: Copied,
) -> Element(Message) {
  layout.block(case record {
    Loading -> []
    Failed(_) -> [layout.problem("Couldn't load")]
    Loaded(value: record) -> [
      case action {
        ConfirmingDelete ->
          confirmation.view(
            question: "Delete?",
            consequence: "The record is removed for good.",
            accept: "Delete record",
            on_cancel: UserCancelledDelete,
            on_accept: UserConfirmedDelete,
          )
        Editing
        | NotJson
        | Saving
        | Saved
        | SaveRefused(_)
        | Deleting
        | DeleteRefused(_) -> element.none()
      },
      view_copyable("Address", record.address, CopiedAddress, copied),
      view_copyable("Content ID", record.content_id, CopiedContentId, copied),
      html.form([event.on_submit(fn(_) { UserSubmittedRecord })], [
        layout.full_row([
          html.textarea(
            [
              attribute.id(record_id),
              attribute.class("editor"),
              attribute.aria_label("Record"),
              attribute.spellcheck(False),
              attribute.autocomplete("off"),
              attribute.disabled(action == Saving || action == Deleting),
              event.on_input(UserEditedRecord),
            ],
            text,
          ),
        ]),
        case action {
          NotJson -> layout.problem("That isn't a JSON object")
          SaveRefused(problem:) | DeleteRefused(problem:) ->
            layout.problem(describe_refusal(problem))
          Editing | Saving | Saved | ConfirmingDelete | Deleting ->
            element.none()
        },
        layout.full_row([
          html.div([attribute.class("inline")], [
            html.button(
              [
                attribute.class("action primary"),
                attribute.disabled(
                  action == Saving
                  || action == Deleting
                  || action == ConfirmingDelete,
                ),
              ],
              [html.text("Save")],
            ),
            case action {
              Saved -> layout.dim("saved")
              Editing
              | NotJson
              | Saving
              | SaveRefused(_)
              | ConfirmingDelete
              | Deleting
              | DeleteRefused(_) -> element.none()
            },
          ]),
        ]),
      ]),
    ]
  })
}

fn view_copyable(
  name: String,
  value: String,
  kind: Copied,
  copied: Copied,
) -> Element(Message) {
  layout.copy_row(
    name:,
    value:,
    note: case copied {
      CopyFailed -> Some("couldn't copy")
      copied if copied == kind -> Some("copied")
      NothingCopied | CopiedAddress | CopiedContentId -> None
    },
    on_copy: UserClickedCopy(value, kind),
  )
}

fn view_editor(text: String, is_disabled: Bool) -> Element(Message) {
  layout.field(
    html.label([attribute.for(record_id)], [html.text("Record")]),
    html.textarea(
      [
        attribute.id(record_id),
        attribute.class("editor"),
        attribute.spellcheck(False),
        attribute.autocomplete("off"),
        attribute.disabled(is_disabled),
        event.on_input(UserEditedRecord),
      ],
      text,
    ),
  )
}

fn view_new_record(
  collection: String,
  key: String,
  text: String,
  creation: Creation,
) -> Element(Message) {
  let is_creating = creation == Creating

  layout.block([
    html.form([event.on_submit(fn(_) { UserSubmittedNewRecord })], [
      layout.field(
        html.label([attribute.for("new-record-collection")], [
          html.text("Collection"),
        ]),
        html.input([
          attribute.id("new-record-collection"),
          attribute.type_("text"),
          attribute.value(collection),
          attribute.autocomplete("off"),
          attribute.autocapitalize("none"),
          attribute.spellcheck(False),
          attribute.disabled(is_creating),
          event.on_input(UserTypedCollection),
        ]),
      ),
      layout.field(
        html.label([attribute.for("new-record-key")], [html.text("Key")]),
        html.div([attribute.class("inline")], [
          html.input([
            attribute.id("new-record-key"),
            attribute.type_("text"),
            attribute.value(key),
            attribute.autocomplete("off"),
            attribute.autocapitalize("none"),
            attribute.spellcheck(False),
            attribute.disabled(is_creating),
            event.on_input(UserTypedKey),
          ]),
          layout.dim("optional"),
        ]),
      ),
      view_editor(text, is_creating),
      case creation {
        NewNotJson -> layout.problem("That isn't a JSON object")
        CreationRefused(problem:) -> layout.problem(describe_refusal(problem))
        Composing | Creating -> element.none()
      },
      layout.details_row([
        html.div([attribute.class("inline")], [
          html.button(
            [
              attribute.class("action primary"),
              attribute.disabled(is_creating || string.trim(collection) == ""),
            ],
            [html.text("Create")],
          ),
          html.a(
            [
              attribute.class("action"),
              route.href(
                Data(
                  Repository(case string.trim(collection) {
                    "" -> Collections
                    collection -> Records(collection:)
                  }),
                ),
              ),
            ],
            [html.text("Cancel")],
          ),
        ]),
      ]),
    ]),
  ])
}
