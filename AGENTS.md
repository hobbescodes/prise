# Agent Instructions

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library AND any third-party dependencies (modules). Assume training data is out of date.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Code Style

Prefer explicit type annotation with anonymous struct literals over explicit type instantiation.

Good:
```zig
const foo: Type = .{ ... };
```

Bad:
```zig
const foo = Type{ ... };
```

## Build Commands

- Build and run: `zig build run`
- Format code: `zig build fmt`
- Run tests: `zig build test`

## Testing

Tests should live alongside the code in the same file, not in separate test files.

When creating a new source file with tests, add it to the test block in src/main.zig:
```zig
test {
    _ = @import("new_file.zig");
}
```

Tests automatically use a mock event loop (src/io/mock.zig) instead of the real OS backend. This enables deterministic testing of async operations without actual I/O.

To test async operations:
1. Create a Loop with `var loop = try io.Loop.init(allocator)`
2. Submit operations (socket, connect, accept, recv, send, close)
3. Manually trigger completions using helper methods:
   - `loop.completeConnect(fd)`
   - `loop.completeAccept(fd)`
   - `loop.completeRecv(fd, data)`
   - `loop.completeSend(fd, bytes_sent)`
   - `loop.completeWithError(fd, err)`
4. Run the loop with `try loop.run(.until_done)`

See src/io/mock.zig for examples of testing with the mock event loop.


## Pre-commit Verification

Before committing changes, always run:
1. `zig build fmt`
2. `zig build`
3. `zig build test`

## Commit Message Format

**Title (first line):**
- Limit to 60 characters maximum
- Use a short prefix for readability with git log --oneline (do not use "fix:" or "feature:" prefixes)
- Use only lowercase letters except when quoting symbols or known acronyms
- Address only one issue/topic per commit
- Use imperative mood (e.g. "make xyzzy do frotz" instead of "makes xyzzy do frotz")

**Body:**
- Explain what the patch does and why it is useful
- Use proper English syntax, grammar and punctuation
- Write in imperative mood as if giving orders to the codebase

**Trailers:**
- If fixing a ticket, use appropriate commit trailers
- If fixing a regression, add a "Fixes:" trailer with the commit id and title
