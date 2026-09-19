//
//  Engine.swift
//  MathExpressionEngine
//
//  The pipeline. `compile(_:)` lowers to the flat POD tape (fast path);
//  `compileReferenceInterpreter(_:)` wraps the tree-walking interpreter and is
//  used as the differential oracle in tests. Both share the same front end, so
//  they always agree on the interface and diagnostics.
//

private func frontEnd(_ source: String) -> (body: Body?, interface: Interface, diagnostics: [Diagnostic]) {
    var lexer = Lexer(source)
    let (tokens, lexDiagnostics) = lexer.tokenize()

    var parser = Parser(tokens)
    let body = parser.parse()

    var diagnostics = lexDiagnostics + parser.diagnostics
    var interface = Interface(inputs: [], outputs: [])

    if let body {
        let (derived, semaDiagnostics) = analyze(body)
        interface = derived
        diagnostics += semaDiagnostics
    }

    return (body, interface, diagnostics)
}

/// Compile a Math Expression node source to a tape-backed program.
public func compile(_ source: String) -> CompileResult {
    let (body, interface, diagnostics) = frontEnd(source)

    var program: Program? = nil
    if let body, !diagnostics.contains(where: { $0.severity == .error }) {
        let tape = lower(body)
        let hasScalarFastPath = tape.supportsScalarFastPath(interface: interface)
        program = Program(
            outputCount: tape.outputRegisters.count,
            hasScalarFastPath: hasScalarFastPath,
            runValues: { @Sendable (inputs: [String: EngineValue]) throws(EvalError) -> [EngineValue] in
                try runTapeValues(tape, inputs)
            },
            runScalarFirst: hasScalarFastPath ? { @Sendable (inputs: [String: Float]) throws(EvalError) -> Float in
                try runScalarTapeFirst(tape, inputs)
            } : nil,
            runScalarAll: hasScalarFastPath ? { @Sendable (inputs: [String: Float]) throws(EvalError) -> [Float] in
                try runScalarTapeValues(tape, inputs)
            } : nil
        )
    }

    return CompileResult(interface: interface, diagnostics: diagnostics, program: program)
}

/// Compile to a program backed by the tree-walking reference interpreter.
/// Internal: the differential oracle for the tape (see DifferentialTests).
func compileReferenceInterpreter(_ source: String) -> CompileResult {
    let (body, interface, diagnostics) = frontEnd(source)

    var program: Program? = nil
    if let body, !diagnostics.contains(where: { $0.severity == .error }) {
        program = Program(
            outputCount: interface.outputs.count,
            hasScalarFastPath: false,
            runValues: { @Sendable (inputs: [String: EngineValue]) throws(EvalError) -> [EngineValue] in
                try ReferenceInterpreter.evalBody(body, inputs)
            },
            runScalarFirst: nil,
            runScalarAll: nil
        )
    }

    return CompileResult(interface: interface, diagnostics: diagnostics, program: program)
}
