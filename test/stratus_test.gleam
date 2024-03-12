import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn hello_world_test() {
  should.equal(1, 1)
}
