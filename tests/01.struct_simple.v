module main

struct Struct1 {
pub mut:
	a int
	b []string
}

fn main() {
	mut foo := Struct1{
		a: 5
	}
	foo.a = 7
}
