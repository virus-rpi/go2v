module main

fn main() {
	if true {
	}
	if 3 < 4 {
	}
	if 3 != 4 {
	}
	if 3 == 4 {
	}
	if 3 <= 4 {
	}
	if 3 <= 4 && true {
	}
	if 3 <= 4 && true || false {
	}
	mut c := u8(`X`)
	if !(c == `(` || c == `B` || c == `C` || c == `D` || c == `F` || c == `I` || c == `J`
		|| c == `L` || c == `S` || c == `Z` || c == `[`) {
		println('Invalid')
	}
}
