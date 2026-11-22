import at/tid
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/json_view
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{
  type RepositoryLocation, Collections, Data, NewRecord, Record, Records,
  Repository,
}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem, type RecordPage, type RepoRecord}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem

const delete_button_id = "delete-record"

const edit_button_id = "edit-record"

const record_id = "record-json"

const new_record_template = "{\n  \"$type\": \"\"\n}"

pub opaque type Model {
  Model(session: Session, local_offset: Duration, place: Place)
}

pub type CollectionGroup {
  CollectionGroup(owner: String, collections: List(NamedCollection))
}

pub type NamedCollection {
  NamedCollection(id: String, prefix: String, name: String)
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
  Reading
  Editing
  NotJson
  Saving
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
  let local_offset = calendar.local_offset()

  case location {
    Collections -> #(
      Model(session:, local_offset:, place: AtCollections(collections: Loading)),
      tranquil.load(
        session,
        tranquil.collections(account),
        ServerReturnedCollections,
      ),
    )

    Records(collection:) -> #(
      Model(
        session:,
        local_offset:,
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
        local_offset:,
        place: AtRecord(
          collection:,
          key:,
          record: Loading,
          text: "",
          action: Reading,
          copied: NothingCopied,
        ),
      ),
      load_record(session, collection, key),
    )

    NewRecord(collection:) -> #(
      Model(
        session:,
        local_offset:,
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
  UserClickedEdit
  UserCancelledEdit
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

    AtRecord(..) as place, UserClickedEdit -> #(
      Model(..model, place: AtRecord(..place, action: Editing)),
      browser.focus(record_id),
    )

    AtRecord(record:, ..) as place, UserCancelledEdit -> #(
      Model(
        ..model,
        place: AtRecord(
          ..place,
          text: case record {
            Loaded(value: record) -> record.json
            Loading | Failed(_) -> ""
          },
          action: Reading,
        ),
      ),
      browser.focus(edit_button_id),
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
      Model(..model, place: AtRecord(..place, action: Reading)),
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
      Model(..model, place: AtRecord(..place, action: Reading)),
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
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
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
          [view_records(collection, records, next, more, model.local_offset)],
        )

      AtRecord(collection:, key:, record:, text:, action:, copied:) ->
        layout.path_section_with_actions(
          [top, link(Records(collection:), collection), html.text(key)],
          case record, action {
            Loaded(_), Reading
            | Loaded(_), Deleting
            | Loaded(_), DeleteRefused(_)
            -> [
              html.button(
                [
                  attribute.id(edit_button_id),
                  attribute.class("action"),
                  attribute.disabled(action == Deleting),
                  event.on_click(UserClickedEdit),
                ],
                [html.text("Edit")],
              ),
              html.button(
                [
                  attribute.id(delete_button_id),
                  attribute.class("action"),
                  attribute.disabled(action == Deleting),
                  event.on_click(UserClickedDelete),
                ],
                [html.text("Delete")],
              ),
            ]
            Loading, _
            | Failed(_), _
            | Loaded(_), ConfirmingDelete
            | Loaded(_), Editing
            | Loaded(_), NotJson
            | Loaded(_), Saving
            | Loaded(_), SaveRefused(_)
            -> []
          },
          [view_record(record, key, text, action, copied, model.local_offset)],
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
  layout.block(case collections {
    Loading -> [layout.loading(3)]
    Failed(_) -> [layout.problem("Couldn't load")]
    Loaded(value: []) -> [layout.note("No collections", [])]
    Loaded(value: collections) ->
      list.map(group_collections(collections), fn(group) {
        layout.row(
          tone: layout.Plain,
          name: group.owner,
          details: [
            html.span(
              [attribute.class("lines collections")],
              list.map(group.collections, fn(collection) {
                html.a(
                  [
                    route.href(
                      Data(Repository(Records(collection: collection.id))),
                    ),
                  ],
                  [layout.dim(collection.prefix), html.text(collection.name)],
                )
              }),
            ),
          ],
          actions: [],
        )
      })
  })
}

pub fn group_collections(ids: List(String)) -> List(CollectionGroup) {
  list.map(ids, name_collection)
  |> list.group(fn(named) { named.0 })
  |> dict.to_list
  |> list.sort(fn(one, other) { string.compare(one.0, other.0) })
  |> list.map(fn(group) {
    CollectionGroup(
      owner: group.0,
      collections: list.map(group.1, fn(named) { named.1 })
        |> list.sort(fn(one, other) { string.compare(one.id, other.id) }),
    )
  })
}

fn name_collection(id: String) -> #(String, NamedCollection) {
  case string.split(id, ".") {
    [top, second, first, ..rest] -> #(
      second <> "." <> top,
      NamedCollection(
        id:,
        prefix: top <> "." <> second <> ".",
        name: string.join([first, ..rest], "."),
      ),
    )
    [] | [_] | [_, _] -> #(id, NamedCollection(id:, prefix: "", name: id))
  }
}

pub fn written(key: String) -> Result(Timestamp, Nil) {
  tid.from_string(key) |> result.map(tid.to_timestamp)
}

fn view_records(
  collection: String,
  records: Remote(List(RepoRecord)),
  next: Option(String),
  more: More,
  local_offset: Duration,
) -> Element(Message) {
  layout.block(
    list.flatten([
      case records {
        Loading -> [layout.loading(3)]
        Failed(_) -> [layout.problem("Couldn't load")]
        Loaded(value: records) ->
          layout.listing(
            empty: "No records",
            rows: list.map(records, fn(record) {
              html.a(
                [
                  attribute.class("row record"),
                  route.href(
                    Data(Repository(Record(collection:, key: record.key))),
                  ),
                ],
                [
                  html.span([attribute.class("name")], [html.text(record.key)]),
                  html.span([attribute.class("details")], [
                    case written(record.key) {
                      Ok(time) ->
                        html.span([attribute.class("dim when")], [
                          html.text(date.describe_moment_with_year(
                            time,
                            local_offset,
                          )),
                        ])
                      Error(Nil) -> element.none()
                    },
                    html.span([attribute.class("preview")], [
                      html.text(string.slice(record.preview, 0, 200)),
                    ]),
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
  key: String,
  text: String,
  action: Action,
  copied: Copied,
  local_offset: Duration,
) -> Element(Message) {
  layout.block(case record {
    Loading -> [layout.loading(3)]
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
        Reading
        | Editing
        | NotJson
        | Saving
        | SaveRefused(_)
        | Deleting
        | DeleteRefused(_) -> element.none()
      },
      case written(key) {
        Ok(time) ->
          layout.row(
            tone: layout.Plain,
            name: "Created",
            details: [
              html.text(date.describe_moment_with_year(time, local_offset)),
            ],
            actions: [],
          )
        Error(Nil) -> element.none()
      },
      view_copyable("Address", record.address, CopiedAddress, copied),
      view_copyable("Content ID", record.content_id, CopiedContentId, copied),
      case action {
        Reading | ConfirmingDelete | Deleting ->
          layout.full_row([json_view.view(record.json)])

        DeleteRefused(problem:) ->
          element.fragment([
            layout.full_row([json_view.view(record.json)]),
            layout.problem(describe_refusal(problem)),
          ])

        Editing | NotJson | Saving | SaveRefused(_) ->
          view_record_editor(text, action)
      },
    ]
  })
}

fn view_record_editor(text: String, action: Action) -> Element(Message) {
  let is_saving = action == Saving

  html.form([event.on_submit(fn(_) { UserSubmittedRecord })], [
    layout.full_row([
      html.textarea(
        [
          attribute.id(record_id),
          attribute.class("editor"),
          attribute.aria_label("Record"),
          attribute.spellcheck(False),
          attribute.autocomplete("off"),
          attribute.disabled(is_saving),
          event.on_input(UserEditedRecord),
        ],
        text,
      ),
    ]),
    case action {
      NotJson -> layout.problem("That isn't a JSON object")
      SaveRefused(problem:) -> layout.problem(describe_refusal(problem))
      Reading
      | Editing
      | Saving
      | ConfirmingDelete
      | Deleting
      | DeleteRefused(_) -> element.none()
    },
    layout.full_row([
      html.div([attribute.class("inline")], [
        html.button(
          [attribute.class("action primary"), attribute.disabled(is_saving)],
          [html.text("Save")],
        ),
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            attribute.disabled(is_saving),
            event.on_click(UserCancelledEdit),
          ],
          [html.text("Cancel")],
        ),
      ]),
    ]),
  ])
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
