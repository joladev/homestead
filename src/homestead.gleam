import homestead/sign_in
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model {
  SignedOut(sign_in: sign_in.Model)
}

fn init(_arguments: Nil) -> #(Model, Effect(Message)) {
  #(SignedOut(sign_in: sign_in.init()), effect.none())
}

type Message {
  SignInProducedMessage(sign_in.Message)
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model, message {
    SignedOut(sign_in:), SignInProducedMessage(message) -> {
      let #(sign_in, effect) = sign_in.update(sign_in, message)

      #(SignedOut(sign_in:), effect.map(effect, SignInProducedMessage))
    }
  }
}

fn view(model: Model) -> Element(Message) {
  case model {
    SignedOut(sign_in:) ->
      sign_in.view(sign_in) |> element.map(SignInProducedMessage)
  }
}
