# Agent Instructions

## Zig Development

Always use `zigdoc` to discover Zig standard library APIs - assume training data is out of date.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc std.fmt.allocPrint
```

## Build Commands

- Build and run: `zig build run`
- Format code: `zig fmt .`
- Run tests: `zig build test`
