import homestead/tranquil.{type Problem, SessionEnded}

pub type Remote(value) {
  Loading
  Loaded(value: value)
  Failed(problem: Problem)
}

pub fn from_result(result: Result(value, Problem)) -> Remote(value) {
  case result {
    Ok(value) -> Loaded(value:)
    Error(problem) -> Failed(problem:)
  }
}

pub fn map(remote: Remote(a), with: fn(a) -> b) -> Remote(b) {
  then(remote, fn(value) { Loaded(with(value)) })
}

pub fn then(remote: Remote(a), with: fn(a) -> Remote(b)) -> Remote(b) {
  case remote {
    Loading -> Loading
    Loaded(value:) -> with(value)
    Failed(problem:) -> Failed(problem:)
  }
}

pub fn has_ended_session(remote: Remote(value)) -> Bool {
  case remote {
    Failed(problem: SessionEnded) -> True
    Loading | Loaded(_) | Failed(_) -> False
  }
}
