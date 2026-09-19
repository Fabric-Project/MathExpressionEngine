//
//  PublicAPI.swift
//  MathExpressionEngine
//
//  The public surface consumed by the Fabric Math Expression node.
//

import Foundation

/// A source range: a start offset (in characters) and a length.
public struct Span: Equatable, Sendable {
    public let start: Int
    public let length: Int
    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

public enum Severity: Sendable, Equatable {
    case error, warning, info
}

/// Stable diagnostic codes emitted by the compiler.
public enum DiagnosticCode: String, Sendable, Equatable {
    case unexpectedToken
    case unmatchedParen
    case incompleteExpression
    case emptyBody
    case unknownName
    case argumentCount
    case typeMismatch          // operator / function argument type error
    case badSwizzle            // invalid swizzle (bad component, or swizzling a scalar)
    case mixedOutput           // mixing a bare expression with named `out` outputs
    case duplicateOutput       // two outputs with the same name
    case noOutput              // body declares no output at all
    case duplicateBinding
    case useBeforeDefinition
    case expectedName
    case expectedEquals
    case expectedColon         // missing `:` in an `in name: Type` declaration
    case unknownType           // a type annotation names a type that doesn't exist
    case emptyArray            // `[]` with no elements (element type can't be inferred)
    case heterogeneousArray    // array literal with mixed element types
    case notAnArray            // indexing / reducing a non-array
    case expectedRange         // comprehension range malformed
    case divisionByZero        // literal `/ 0` (warning)
    case unusedBinding         // a `let` never referenced (warning)
    case expressionTooDeep     // nesting-depth guard
}

public struct Diagnostic: Sendable, Equatable {
    public let code: DiagnosticCode
    public let severity: Severity
    public let message: String
    public let span: Span
    public init(code: DiagnosticCode, severity: Severity, message: String, span: Span) {
        self.code = code
        self.severity = severity
        self.message = message
        self.span = span
    }
}

/// The value/port types the engine can produce.
public indirect enum ValueType: Sendable, Equatable {
    case float, vec2, vec3, vec4
    case transform, quat
    case array(ValueType)

    /// The types a declaration can name, spelled by their raw values. An array
    /// is not among them: it is spelled by suffixing one of these with `[]`
    /// rather than by a name of its own.
    ///
    /// Every type name the engine reads or reports is spelled here and nowhere
    /// else. The parser reads a declaration through it, `name` reports through
    /// it, constructors are recognised through it, and `Vocabulary` publishes
    /// it for an editor to colour.
    public enum Base: String, CaseIterable, Sendable {
        case float, vec2, vec3, vec4, transform, quat

        /// The type a call to `name` constructs, if that name constructs one.
        /// The vector types are exactly the ones that do, and each constructs at
        /// its own width.
        static func constructed(_ name: String) -> ValueType? {
            guard let base = Self(rawValue: name), base.type.isVector else { return nil }
            return base.type
        }

        public var type: ValueType {
            switch self {
            case .float:     .float
            case .vec2:      .vec2
            case .vec3:      .vec3
            case .vec4:      .vec4
            case .transform: .transform
            case .quat:      .quat
            }
        }
    }

    public var width: Int {
        switch self {
        case .float: return 1
        case .vec2:  return 2
        case .vec3:  return 3
        case .vec4:  return 4
        case .transform, .quat, .array: return 0
        }
    }

    public var isVector: Bool {
        switch self { case .vec2, .vec3, .vec4: return true; default: return false }
    }

    public var elementType: ValueType? {
        if case .array(let t) = self { return t } else { return nil }
    }
    public var isArray: Bool { elementType != nil }

    public var name: String {
        switch self {
        case .float:        return Base.float.rawValue
        case .vec2:         return Base.vec2.rawValue
        case .vec3:         return Base.vec3.rawValue
        case .vec4:         return Base.vec4.rawValue
        case .transform:    return Base.transform.rawValue
        case .quat:         return Base.quat.rawValue
        case .array(let t): return "\(t.name)[]"
        }
    }

    static func ofWidth(_ w: Int) -> ValueType? {
        switch w {
        case 1: return .float
        case 2: return .vec2
        case 3: return .vec3
        case 4: return .vec4
        default: return nil
        }
    }
}

/// A typed value the engine produces. Scalars/vectors are trivial (SIMD
/// payloads); `.array` is heap-backed.
public enum EngineValue: Sendable, Equatable {
    case float(Float)
    case vec2(SIMD2<Float>)
    case vec3(SIMD3<Float>)
    case vec4(SIMD4<Float>)
    case transform(Mat4)
    case quat(Quat)
    case array([EngineValue])

    public var type: ValueType {
        switch self {
        case .float: return .float
        case .vec2:  return .vec2
        case .vec3:  return .vec3
        case .vec4:  return .vec4
        case .transform: return .transform
        case .quat: return .quat
        case .array(let els): return .array(els.first?.type ?? .float)
        }
    }

    /// The scalar value (float), the first component (vectors), or the first
    /// element's scalar (arrays).
    public var scalar: Float {
        switch self {
        case .float(let x): return x
        case .vec2(let v):  return v.x
        case .vec3(let v):  return v.x
        case .vec4(let v):  return v.x
        case .transform(let m): return m.columns.0.x
        case .quat(let q): return q.vector.x
        case .array(let els): return els.first?.scalar ?? 0
        }
    }

    /// Components as a `[Float]` (vectors), `[x]` (float), the 16 column-major
    /// entries (transform), (x,y,z,w) (quat), or per-element scalars (arrays).
    public var components: [Float] {
        switch self {
        case .float(let x): return [x]
        case .vec2(let v):  return [v.x, v.y]
        case .vec3(let v):  return [v.x, v.y, v.z]
        case .vec4(let v):  return [v.x, v.y, v.z, v.w]
        case .transform(let m):
            let c = m.columns
            return [c.0.x, c.0.y, c.0.z, c.0.w,
                    c.1.x, c.1.y, c.1.z, c.1.w,
                    c.2.x, c.2.y, c.2.z, c.2.w,
                    c.3.x, c.3.y, c.3.z, c.3.w]
        case .quat(let q): return [q.vector.x, q.vector.y, q.vector.z, q.vector.w]
        case .array(let els): return els.map(\.scalar)
        }
    }

    /// The elements of an array value (nil for scalars/vectors).
    public var arrayElements: [EngineValue]? {
        if case .array(let els) = self { return els } else { return nil }
    }
}

/// A named, typed input port derived from the expression. Free identifiers are
/// `float`; an `in name: Type` declaration gives the named port that type.
public struct InputPort: Sendable, Equatable {
    public let name: String
    public let type: ValueType
    public init(name: String, type: ValueType) {
        self.name = name
        self.type = type
    }
}

/// A named, typed output port derived from the expression.
public struct OutputPort: Sendable, Equatable {
    public let name: String
    public let type: ValueType
    public init(name: String, type: ValueType) {
        self.name = name
        self.type = type
    }
}

/// The node interface *derived from the expression*. `inputs` are the ports the
/// expression consumes: every `in name: Type` declaration (in declaration order),
/// followed by the remaining free identifiers in first-appearance order (typed
/// `float`; deduplicated, constants and locals excluded). `outputs` are the `out`
/// declarations in source order (types inferred), or a single implicit `result`.
public struct Interface: Sendable, Equatable {
    public let inputs: [InputPort]
    public let outputs: [OutputPort]

    public init(inputs: [InputPort], outputs: [OutputPort]) {
        self.inputs = inputs
        self.outputs = outputs
    }

    public var inputNames: [String] { inputs.map(\.name) }
    public var outputType: ValueType { outputs.first?.type ?? .float }
    public var outputNames: [String] { outputs.map(\.name) }
}

public enum EvalError: Error, Equatable, Sendable {
    case notCompiled
    case missingInput(String)
    case indexOutOfBounds(index: Int, count: Int)
    case limitExceeded(String)
}

extension EvalError: LocalizedError {
    /// Every case carries a description. Without one, `localizedDescription`
    /// falls back to "The operation couldn't be completed. (…EvalError error
    /// 0.)", which names neither the case nor its payload — callers reporting
    /// an evaluation failure to a user have nothing to show, and any that try
    /// to classify the failure from its text get no stable string to work
    /// with. Switch over the case for that; the text is for reading.
    public var errorDescription: String? {
        switch self {
        case .notCompiled:
            return "The expression has not compiled, so it cannot be evaluated."
        case .missingInput(let name):
            return "No value supplied for input `\(name)`."
        case .indexOutOfBounds(let index, let count):
            return "Index \(index) is out of bounds for \(count) element\(count == 1 ? "" : "s")."
        case .limitExceeded(let detail):
            return "Limit exceeded: \(detail)."
        }
    }
}

/// A compiled program: its derived interface, any diagnostics, and — when it
/// compiled cleanly — evaluators.
public struct CompileResult: Sendable {
    public let interface: Interface
    public let diagnostics: [Diagnostic]

    let program: Program?

    init(interface: Interface, diagnostics: [Diagnostic], program: Program?) {
        self.interface = interface
        self.diagnostics = diagnostics
        self.program = program
    }

    public var isValid: Bool { program != nil }

    // MARK: Typed inputs (the general surface)

    /// All outputs as typed values, in `interface.outputs` order. Inputs are
    /// keyed by port name; supply the type each `InputPort` declares (free
    /// identifiers are `float`).
    public func evaluateValues(with inputs: [String: EngineValue]) throws(EvalError) -> [EngineValue] {
        guard let program else { throw EvalError.notCompiled }
        return try program.runValues(inputs)
    }

    /// The first output as a typed value, with typed inputs.
    public func evaluateValue(with inputs: [String: EngineValue]) throws(EvalError) -> EngineValue {
        try evaluateValues(with: inputs).first ?? .float(.nan)
    }

    // MARK: Float-input conveniences (all inputs are scalars)

    /// The first output as a typed value.
    public func evaluateValue(_ inputs: [String: Float]) throws(EvalError) -> EngineValue {
        if let program, let runScalarFirst = program.runScalarFirst {
            return .float(try runScalarFirst(inputs))
        }
        return try evaluateValue(with: inputs.mapValues { EngineValue.float($0) })
    }

    /// All outputs as typed values, in `interface.outputs` order.
    public func evaluateValues(_ inputs: [String: Float]) throws(EvalError) -> [EngineValue] {
        if let program, let runScalarAll = program.runScalarAll {
            return try runScalarAll(inputs).map { .float($0) }
        }
        return try evaluateValues(with: inputs.mapValues { EngineValue.float($0) })
    }

    /// The first output as a `Float` (its scalar / first component). Convenience.
    public func evaluate(_ inputs: [String: Float]) throws(EvalError) -> Float {
        if let program, let runScalarFirst = program.runScalarFirst {
            return try runScalarFirst(inputs)
        }
        return try evaluateValue(inputs).scalar
    }

    /// All outputs as `Float` (scalar / first component each). Convenience.
    public func evaluateAll(_ inputs: [String: Float]) throws(EvalError) -> [Float] {
        if let program, let runScalarAll = program.runScalarAll {
            return try runScalarAll(inputs)
        }
        return try evaluateValues(inputs).map(\.scalar)
    }
}

/// An evaluable program (tape-backed in production, reference-backed as the
/// test oracle). Produces all outputs as typed values in source order.
struct Program: Sendable {
    let outputCount: Int
    let hasScalarFastPath: Bool
    let runValues: @Sendable ([String: EngineValue]) throws(EvalError) -> [EngineValue]
    let runScalarFirst: (@Sendable ([String: Float]) throws(EvalError) -> Float)?
    let runScalarAll: (@Sendable ([String: Float]) throws(EvalError) -> [Float])?
}
