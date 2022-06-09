module transpiler

const (
	// functions that are in the `strings` module in Go and in the `builtin` module in V
	strings_to_builtin = ['compare', 'contains', 'contains_any', 'count', 'fields', 'index',
		'index_any', 'index_byte', 'last_index', 'last_index_byte', 'repeat', 'split', 'title',
		'to_lower', 'to_upper', 'trim', 'trim_left', 'trim_prefix', 'trim_right', 'trim_space',
		'trim_suffix']
	// function name equivalence (left Go & right V)
	name_equivalence   = {
		'string': 'str'
		'rune':   'runes'
	}
	// methods of the string builder that require a special treatment
	string_builder_diffs  = ['cap', 'grow', 'len', 'reset', 'string', 'write']
	// equivalent of Go's `unicode.utf8.EncodeRune()`
	// fn go2v_utf8_encode_rune(mut p []u8, r rune) int {
	// 	mut bytes := r.bytes()
	// 	p << bytes
	// 	return bytes.len
	// }
	go2v_utf8_encode_rune = FunctionStmt{
		name: 'go2v_utf8_encode_rune'
		args: {
			'p': 'mut []u8'
			'r': 'rune'
		}
		ret_vals: ['int']
		body: [
			VariableStmt{
				names: ['bytes']
				middle: ':='
				values: [CallStmt{
					namespaces: 'r.bytes'
				}]
			},
			PushStmt{BasicValueStmt{'p'}, BasicValueStmt{'bytes'}},
			ReturnStmt{
				values: [BasicValueStmt{'bytes.len'}]
			},
		]
	}
)

// transform a statement valid in Go into a valid one in V
fn (mut v VAST) stmt_transformer(stmt Statement) Statement {
	mut ret_stmt := stmt

	if stmt is CallStmt {
		ns := stmt.namespaces.split('.')
		first_ns := ns.first()
		last_ns := ns.last()
		all_but_last_ns := stmt.namespaces#[..-last_ns.len - 1]

		// common changes
		ret_stmt = match first_ns {
			'len', 'cap', 'rune', 'string' { v.transform_fn_to_decl(stmt, first_ns) }
			'make' { v.transform_make(stmt) }
			'delete' { v.transform_delete(stmt) }
			'strings' { v.transform_strings_module(stmt, last_ns) }
			'fmt' { v.transform_print(stmt, last_ns) }
			'os' { v.transform_exit(stmt, last_ns) }
			'utf8' { v.transform_utf8(stmt, last_ns) }
			else { stmt }
		}
		// string builders
		if v.string_builder_vars.contains(all_but_last_ns)
			&& transpiler.string_builder_diffs.contains(last_ns) {
			ret_stmt = v.transform_string_builder(stmt, all_but_last_ns, last_ns)
		}
	} else if stmt is VariableStmt {
		mut temp_stmt := stmt
		mut multiple_stmt := MultipleStmt{}

		for i, mut value in temp_stmt.values {
			v.current_var_name = stmt.names[i]
			value = v.stmt_transformer(value)

			// `append(array, value)` -> `array << value`
			// `append(array, value1, value2)` -> `array << [value1, value2]`
			if mut value is CallStmt {
				if value.namespaces == 'append' {
					// single
					if value.args.len < 3 {
						mut value_to_append := value.args[1]

						// `append(array, sec_array...)` -> `array << sec_array`
						if mut value_to_append is MultipleStmt {
							if value_to_append.stmts[0] == bv_stmt('...') {
								value_to_append = value_to_append.stmts[1]
							}
						}

						multiple_stmt.stmts << PushStmt{
							stmt: BasicValueStmt{stmt.names[i]}
							value: value_to_append
						}
						// multiple
					} else {
						mut push_stmt := PushStmt{
							stmt: BasicValueStmt{stmt.names[i]}
						}
						mut array := ArrayStmt{}

						for arg in value.args[1..] {
							array.values << arg
						}
						push_stmt.value = array

						multiple_stmt.stmts << push_stmt
					}

					temp_stmt.names.delete(i)
					temp_stmt.values.delete(i)
				}
			} else if mut value is StructStmt {
				v.vars_with_struct_value[v.current_var_name] = value.name
			}
		}

		// clear now empty variable stmts
		if stmt.names.len > 0 {
			multiple_stmt.stmts << temp_stmt
		}

		ret_stmt = multiple_stmt
	} else if stmt is MatchStmt {
		//	switch variable {
		//	case "a", "b", "c", "d":
		//		return true
		//	}
		// ->
		//	if ['a', 'b', 'c', 'd'].includes(variable) {
		//		return true
		//	}
		if stmt.cases.len == 2 && stmt.cases[1].body.len == 0 {
			array := ArrayStmt{
				values: stmt.cases[0].values
			}

			ret_stmt = IfStmt{[], [
				IfElse{
					condition: CallStmt{
						namespaces: '${v.stmt_to_string(array)}.includes'
						args: [stmt.value]
					}
					body: stmt.cases[0].body
				},
			]}
		}
	} else if stmt is ComplexValueStmt {
		// `bytes.Buffer{}` -> `strings.new_builder()`
		// `strings.Buffer{}` -> `strings.new_builder()`
		if stmt.value is StructStmt {
			if stmt.value.name == 'bytes.Buffer' || stmt.value.name == 'strings.Builder' {
				ret_stmt = CallStmt{
					namespaces: 'strings.new_builder'
					args: [bv_stmt('0')]
				}
			}
		}
	}

	return ret_stmt
}

// `fn_name(arg)` -> `arg.fn_name`
fn (mut v VAST) transform_fn_to_decl(stmt CallStmt, left string) Statement {
	right := if left in transpiler.name_equivalence {
		transpiler.name_equivalence[left]
	} else {
		left
	}
	return bv_stmt('${v.stmt_to_string(stmt.args[0])}.$right')
}

// `make(map[string]int)` -> `map[string]int{}`
fn (mut v VAST) transform_make(stmt CallStmt) Statement {
	raw := v.stmt_to_string(stmt.args[0])
	mut out := if raw[raw.len - 2] == `}` { raw#[..-3] } else { raw }

	if stmt.args.len > 1 {
		out += '{len: ${v.stmt_to_string(stmt.args[1])}}'
	} else {
		out += '{}'
	}

	return BasicValueStmt{out}
}

// `delete(map, key)` -> `map.delete(key)`
fn (mut v VAST) transform_delete(stmt CallStmt) Statement {
	return CallStmt{
		namespaces: '${v.stmt_to_string(stmt.args[0])}.delete'
		args: [stmt.args[1]]
	}
}

// `fmt.println(a, b)` -> `println('$a $b')`
fn (mut v VAST) transform_print(stmt CallStmt, right string) Statement {
	if right == 'println' || right == 'print' {
		mut call_stmt := stmt
		call_stmt.namespaces = right

		// `fmt.println("Hi " + name)` -> `println('Hi $name')`
		mut is_plus_syntax := false
		for arg in call_stmt.args {
			if arg is MultipleStmt {
				is_plus_syntax = true
				call_stmt.args.pop()
				call_stmt.args << arg.stmts[0]
				call_stmt.args << arg.stmts[2]
			}
		}

		if call_stmt.args.len > 1 {
			mut out := "'"
			for i, arg in call_stmt.args {
				str_stmt := v.stmt_to_string(arg)#[..-1]

				// strings
				if str_stmt[0] == `'` && str_stmt[str_stmt.len - 1] == `'` {
					out += str_stmt#[1..-1]
					// numbers & booleans
				} else if (`0` <= str_stmt[0] && str_stmt[0] <= `9`)
					|| str_stmt == 'true' || str_stmt == 'false' {
					out += str_stmt
					// anything else
				} else {
					out += '\${$str_stmt}'
				}

				if !is_plus_syntax && i != call_stmt.args.len - 1 {
					out += ' '
				}
			}

			call_stmt.args = [BasicValueStmt{"$out'"}]
		}

		return call_stmt
	} else {
		v.used_imports['fmt'] = true
		return stmt
	}
}

// `os.exit(a)` -> `exit(a)`
fn (mut v VAST) transform_exit(stmt CallStmt, right string) Statement {
	if right == 'exit' {
		return CallStmt{
			namespaces: right
			args: stmt.args
		}
	} else {
		v.used_imports['os'] = true
		return stmt
	}
}

// see `tests/string_builder_bytes` & `tests/string_builder_strings`
fn (v VAST) transform_string_builder(stmt CallStmt, left string, right string) Statement {
	match right {
		'grow' {
			return CallStmt{
				namespaces: '${left}.ensure_cap'
				args: stmt.args
			}
		}
		'cap', 'len' {
			return BasicValueStmt{stmt.namespaces}
		}
		'reset' {
			return UnsafeStmt{[
				CallStmt{
					namespaces: '${left}.free'
				},
				VariableStmt{
					names: ['${left}.offset', '${left}.len']
					middle: '='
					values: [bv_stmt('0'), bv_stmt('0')]
				},
			]}
		}
		'string' {
			return CallStmt{
				namespaces: '${left}.str'
			}
		}
		'write' {
			return OptionalStmt{stmt}
		}
		else {}
	}
	return stmt
}

// transform functions from the `strings` module
fn (mut v VAST) transform_strings_module(stmt CallStmt, right string) Statement {
	if transpiler.strings_to_builtin.contains(right) {
		return CallStmt{
			namespaces: '${v.stmt_to_string(stmt.args[0])}.$right'
			args: if stmt.args.len > 1 { [stmt.args[1]] } else { []Statement{} }
		}
	} else if right == 'new_builder' {
		v.string_builder_vars << v.current_var_name
	} else {
		v.used_imports['strings'] = true
	}
	return stmt
}

fn (mut v VAST) transform_utf8(stmt CallStmt, right string) Statement {
	match right {
		'rune_len' {
			return CallStmt{
				namespaces: '${v.stmt_to_string(stmt.args[0])}.length_in_bytes'
			}
		}
		'encode_rune' {
			if transpiler.go2v_utf8_encode_rune !in v.functions {
				v.functions << transpiler.go2v_utf8_encode_rune
			}
			return CallStmt{
				namespaces: 'go2v_utf8_encode_rune'
				args: [BasicValueStmt{'mut ${v.stmt_to_string(stmt.args[0])}'}, stmt.args[1]]
			}
		}
		'rune_start' {
			return CallStmt{
				namespaces: 'utf8.is_letter'
				args: stmt.args
			}
		}
		'valid' {
			return CallStmt{
				namespaces: 'utf8.validate_str'
				args: [
					CallStmt{
						namespaces: '${v.stmt_to_string(stmt.args[0])}.bytestr'
					},
				]
			}
		}
		else {
			return stmt
		}
	}
}
