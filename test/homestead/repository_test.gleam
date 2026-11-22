import homestead/repository

pub fn only_a_json_object_can_be_saved_as_a_record_test() {
  assert repository.is_json_object("{\"text\": \"Hello\"}")
  assert !repository.is_json_object("[1, 2]")
  assert !repository.is_json_object("{ not json")
}
