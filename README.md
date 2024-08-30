### Go2V

Uses JSON Go AST generated by go/parser.

Early stage.

## Requirements:
Go v1.20 or later.

Make sure `go/bin` is in your path.

The latest version of [asty](https://github.com/asty-org/asty), but
the code will install it for you the first time you run `go2v`, _if_
it can find `go` in your path.

## Testing

To run the existing tests, do `v run .`

To attempt a new test, specify the path to the directory as well as
the name of the test:

```bash
v .
./go2v untested/block
```

When a test passes, move it from `untested` to `tests`.
