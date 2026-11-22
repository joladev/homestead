import homestead/tranquil.{type Problem}

pub type Remote(value) {
  Loading
  Loaded(value: value)
  Failed(problem: Problem)
}

pub type Submission {
  Idle
  Sending
  Refused(problem: Problem)
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
