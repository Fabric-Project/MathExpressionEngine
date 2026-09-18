# MathExpressionEngine

A standalone typed-expression engine for Fabric's Math Expression node. Per the node: _Write an expression — free names become input ports, results become output ports. Beyond numbers, values can be vectors, transforms or arrays, and a single expression can drive several named inputs and outputs at once._

Example — a procedural array of transforms for an instanced mesh:

```
[ translate(vec3(i, 0, 0)) * rotateY(i * spacing) for i in 0..<n ]
```

- **[GUIDE.md](GUIDE.md)** — the expression language for end-users (tutorial + function reference).

## What it is

A small compiler for a statically-typed expression DSL whose primitives are native SIMD functions — it compiles and type-checks the source rather than interpreting it.

- **Front-end (a real compiler):** `lex → parse → type-infer → lower`. Free identifiers become typed input ports, `out name = …` become typed outputs, and every type is inferred, with real diagnostics (arity, type mismatch, bad swizzle, "did you mean…"). The expression _is_ the schema — the ports fall out of the compile.
- **Back-end (a tiny VM):** it lowers to a flat register-machine bytecode tape, compiled once as a pure function off the render thread and executed cheaply per frame. A tree-walking interpreter exists only as a differential test oracle.
- **Native primitives:** leaves and builtins are native Swift / Apple `simd` (`Float`, `simd_float3`, `simd_float4x4`, `simd_quatf`, arrays; trig, vector algebra, transform/quat ops) dispatched by opcode, mapping onto Fabric's port types as a zero-copy reinterpret.

It has no package dependencies and doesn't touch Fabric, Metal, or Satin, so the correctness suite runs without a GPU or the app — just a Swift toolchain. Its transform / quaternion types are Apple `simd` (a zero-copy port boundary), so it targets Apple platforms (macOS/iOS/visionOS):

```sh
cd MathExpressionEngine
swift test
```

- **[DESIGN.md](DESIGN.md)** — goal, present reality, and future steps (for contributors).

## Layout

```
Sources/MathExpressionEngine/
  PublicAPI.swift            // Span, Diagnostic, Interface, EngineValue, ValueType, EvalError, CompileResult
  Lexer.swift  AST.swift  Parser.swift  Sema.swift  Builtins.swift  Value.swift  Transform.swift  Suggestions.swift
  Vocabulary.swift           // the names an editor colours and completes
  ReferenceInterpreter.swift // tree-walk oracle
  Tape.swift                 // register-machine bytecode (production)
  Engine.swift               // compile(_:)
Tests/MathExpressionEngineTests/
  Evaluation · Interface · Diagnostics · Property · Differential · Stress · Block · Vector · Array · Transform · Input · InlineTypedInput · Hardening · HostBoundary · Vocabulary
```
