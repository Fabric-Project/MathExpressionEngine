//
//  Tape.swift
//  MathExpressionEngine
//
//  The bytecode: a register machine over `EngineValue` registers. Scalars/vectors
//  are trivial; `.array` values are heap-backed, so the register file is a normal
//  `[EngineValue]` (one allocation per eval) and comprehensions run a nested
//  sub-tape recursively.
//

enum EngineLimits {
    static let maxArrayElements = 1 << 20   // guardrail against runaway comprehensions
}

/// A single instruction. Scalar/vector ops carry only indices/ids; array ops
/// carry small arrays (built once at compile — not on the per-eval path).
enum Instr: Sendable {
    case loadConst(dst: Int, constIndex: Int)
    case loadInput(dst: Int, inputIndex: Int)
    case negate(dst: Int, src: Int)
    case binary(BinaryOp, dst: Int, lhs: Int, rhs: Int)
    case call0(FnID, dst: Int)
    case call1(FnID, dst: Int, a: Int)
    case call2(FnID, dst: Int, a: Int, b: Int)
    case call3(FnID, dst: Int, a: Int, b: Int, c: Int)
    case construct2(dst: Int, a: Int, b: Int)
    case construct3(dst: Int, a: Int, b: Int, c: Int)
    case construct4(dst: Int, a: Int, b: Int, c: Int, d: Int)
    case splat(dst: Int, src: Int, width: Int)
    case swizzle(dst: Int, src: Int, i0: Int, i1: Int, i2: Int, i3: Int, count: Int)
    case makeArray(dst: Int, srcs: [Int])
    case index(dst: Int, base: Int, idx: Int)
    case comprehension(dst: Int, loopVar: Int, lo: Int, hi: Int, inclusive: Bool, body: [Instr], result: Int)
    case mapComprehension(dst: Int, indexVar: Int?, elemVar: Int, source: Int, body: [Instr], result: Int)
}

struct Tape: Sendable {
    let instructions: [Instr]
    let constants: [Float]
    let inputOrder: [String]
    let registerCount: Int
    let outputRegisters: [(name: String, register: Int)]
}

private struct Lowerer {
    var instructions: [Instr] = []
    var constants: [Float] = []
    var inputIndex: [String: Int] = [:]
    var inputOrder: [String] = []
    var localRegister: [String: Int] = [:]
    var nextRegister = 0

    mutating func newRegister() -> Int {
        defer { nextRegister += 1 }
        return nextRegister
    }

    mutating func constSlot(_ v: Float) -> Int {
        constants.append(v)
        return constants.count - 1
    }

    mutating func inputSlot(_ name: String) -> Int {
        if let i = inputIndex[name] { return i }
        let i = inputOrder.count
        inputIndex[name] = i
        inputOrder.append(name)
        return i
    }

    mutating func lowerBody(_ body: Body) -> [(name: String, register: Int)] {
        var outputs: [(name: String, register: Int)] = []
        for stmt in body.statements {
            switch stmt {
            case .input:
                break   // declared inputs carry no code; loaded by name at eval
            case .local(let name, let value, _):
                localRegister[name] = lower(value)
            case .output(let name, let value, _):
                outputs.append((name: name, register: lower(value)))
            }
        }
        return outputs
    }

    mutating func lower(_ e: Expr) -> Int {
        switch e {
        case .number(let value, _):
            let dst = newRegister()
            instructions.append(.loadConst(dst: dst, constIndex: constSlot(value)))
            return dst

        case .variable(let name, _), .typedVariable(let name, _, _):
            if let reg = localRegister[name] { return reg }
            let dst = newRegister()
            if let constant = Builtins.constants[name] {
                instructions.append(.loadConst(dst: dst, constIndex: constSlot(constant)))
            } else {
                instructions.append(.loadInput(dst: dst, inputIndex: inputSlot(name)))
            }
            return dst

        case .negate(let x, _):
            let src = lower(x)
            let dst = newRegister()
            instructions.append(.negate(dst: dst, src: src))
            return dst

        case .binary(let op, let l, let r, _):
            let lhs = lower(l)
            let rhs = lower(r)
            let dst = newRegister()
            instructions.append(.binary(op, dst: dst, lhs: lhs, rhs: rhs))
            return dst

        case .swizzle(let base, let chars, _):
            let src = lower(base)
            let idx = swizzleIndices(chars) ?? [0]
            let i0 = idx[0]
            let i1 = idx.count > 1 ? idx[1] : 0
            let i2 = idx.count > 2 ? idx[2] : 0
            let i3 = idx.count > 3 ? idx[3] : 0
            let dst = newRegister()
            instructions.append(.swizzle(dst: dst, src: src, i0: i0, i1: i1, i2: i2, i3: i3, count: idx.count))
            return dst

        case .arrayLiteral(let elements, _):
            let regs = elements.map { lower($0) }
            let dst = newRegister()
            instructions.append(.makeArray(dst: dst, srcs: regs))
            return dst

        case .index(let base, let idx, _):
            let baseReg = lower(base)
            let idxReg = lower(idx)
            let dst = newRegister()
            instructions.append(.index(dst: dst, base: baseReg, idx: idxReg))
            return dst

        case .comprehension(let bodyExpr, let loopVar, let lo, let hi, let inclusive, _):
            let loReg = lower(lo)
            let hiReg = lower(hi)
            let loopVarReg = newRegister()

            // Lower the body into a separate instruction list (executed per
            // iteration). Registers are shared (unique indices), so the body
            // can reference outer inputs/locals and allocate its own temporaries.
            let prev = localRegister[loopVar]
            localRegister[loopVar] = loopVarReg
            let saved = instructions
            instructions = []
            let resultReg = lower(bodyExpr)
            let bodyInstructions = instructions
            instructions = saved
            localRegister[loopVar] = prev

            let dst = newRegister()
            instructions.append(.comprehension(dst: dst, loopVar: loopVarReg, lo: loReg, hi: hiReg,
                                               inclusive: inclusive, body: bodyInstructions, result: resultReg))
            return dst

        case .mapComprehension(let bodyExpr, let indexVar, let elemVar, let source, _):
            let sourceReg = lower(source)
            let elemReg = newRegister()
            let indexReg: Int? = indexVar != nil ? newRegister() : nil

            let prevElem = localRegister[elemVar]
            localRegister[elemVar] = elemReg
            var prevIndex: Int? = nil
            if let indexVar { prevIndex = localRegister[indexVar]; localRegister[indexVar] = indexReg! }

            let saved = instructions
            instructions = []
            let resultReg = lower(bodyExpr)
            let bodyInstructions = instructions
            instructions = saved

            localRegister[elemVar] = prevElem
            if let indexVar { localRegister[indexVar] = prevIndex }

            let dst = newRegister()
            instructions.append(.mapComprehension(dst: dst, indexVar: indexReg, elemVar: elemReg, source: sourceReg,
                                                  body: bodyInstructions, result: resultReg))
            return dst

        case .call(let name, let args, _):
            if let constructed = ValueType.Base.constructed(name) {
                let width = constructed.width
                let regs = args.map { lower($0) }
                let dst = newRegister()
                if regs.count == 1 {
                    instructions.append(.splat(dst: dst, src: regs[0], width: width))
                } else {
                    switch width {
                    case 2:  instructions.append(.construct2(dst: dst, a: regs[0], b: regs[1]))
                    case 3:  instructions.append(.construct3(dst: dst, a: regs[0], b: regs[1], c: regs[2]))
                    default: instructions.append(.construct4(dst: dst, a: regs[0], b: regs[1], c: regs[2], d: regs[3]))
                    }
                }
                return dst
            }

            guard let id = Builtins.id(forName: name) else {
                let dst = newRegister()
                instructions.append(.loadConst(dst: dst, constIndex: constSlot(.nan)))
                return dst
            }
            let regs = args.map { lower($0) }
            let dst = newRegister()
            switch regs.count {
            case 0:  instructions.append(.call0(id, dst: dst))
            case 1:  instructions.append(.call1(id, dst: dst, a: regs[0]))
            case 2:  instructions.append(.call2(id, dst: dst, a: regs[0], b: regs[1]))
            default: instructions.append(.call3(id, dst: dst, a: regs[0], b: regs[1], c: regs[2]))
            }
            return dst
        }
    }
}

func lower(_ body: Body) -> Tape {
    var lowerer = Lowerer()
    let outputs = lowerer.lowerBody(body)
    return Tape(
        instructions: lowerer.instructions,
        constants: lowerer.constants,
        inputOrder: lowerer.inputOrder,
        registerCount: lowerer.nextRegister,
        outputRegisters: outputs
    )
}

// MARK: - Execution

private func executeInstrs(_ instructions: [Instr], _ r: inout [EngineValue], base: Int, constants: [Float]) throws(EvalError) {
    for ins in instructions {
        switch ins {
        case .loadConst(let dst, let ci):
            r[base + dst] = .float(constants[ci])
        case .loadInput(let dst, let ii):
            r[base + dst] = r[ii]
        case .negate(let dst, let src):
            r[base + dst] = EngineValue.negate(r[base + src])
        case .binary(let op, let dst, let lhs, let rhs):
            r[base + dst] = EngineValue.binary(op, r[base + lhs], r[base + rhs])
        case .call0(let id, let dst):
            r[base + dst] = Builtins.evaluateValue(id, .float(0), .float(0), .float(0))
        case .call1(let id, let dst, let a):
            r[base + dst] = Builtins.evaluateValue(id, r[base + a], .float(0), .float(0))
        case .call2(let id, let dst, let a, let b):
            r[base + dst] = Builtins.evaluateValue(id, r[base + a], r[base + b], .float(0))
        case .call3(let id, let dst, let a, let b, let c):
            r[base + dst] = Builtins.evaluateValue(id, r[base + a], r[base + b], r[base + c])
        case .construct2(let dst, let a, let b):
            r[base + dst] = EngineValue.construct2(r[base + a].scalar, r[base + b].scalar)
        case .construct3(let dst, let a, let b, let c):
            r[base + dst] = EngineValue.construct3(r[base + a].scalar, r[base + b].scalar, r[base + c].scalar)
        case .construct4(let dst, let a, let b, let c, let d):
            r[base + dst] = EngineValue.construct4(r[base + a].scalar, r[base + b].scalar, r[base + c].scalar, r[base + d].scalar)
        case .splat(let dst, let src, let width):
            r[base + dst] = EngineValue.splat(width, r[base + src].scalar)
        case .swizzle(let dst, let src, let i0, let i1, let i2, let i3, let count):
            r[base + dst] = EngineValue.swizzle(r[base + src], i0, i1, i2, i3, count: count)

        case .makeArray(let dst, let srcs):
            var els: [EngineValue] = []
            els.reserveCapacity(srcs.count)
            for s in srcs { els.append(r[base + s]) }
            r[base + dst] = .array(els)

        case .index(let dst, let baseReg, let idxReg):
            let els = r[base + baseReg].arrayElements ?? []
            let k = Int(r[base + idxReg].scalar.rounded(.down))
            guard k >= 0, k < els.count else { throw EvalError.indexOutOfBounds(index: k, count: els.count) }
            r[base + dst] = els[k]

        case .comprehension(let dst, let loopVar, let lo, let hi, let inclusive, let body, let result):
            let loV = r[base + lo].scalar
            let hiV = r[base + hi].scalar
            let start = Int(loV.rounded(.down))
            let endExclusive = inclusive ? Int(hiV.rounded(.down)) + 1 : Int(hiV.rounded(.down))
            let count = endExclusive - start
            if count <= 0 {
                r[base + dst] = .array([])
            } else {
                guard count <= EngineLimits.maxArrayElements else {
                    throw EvalError.limitExceeded("comprehension produced \(count) elements (max \(EngineLimits.maxArrayElements))")
                }
                var els: [EngineValue] = []
                els.reserveCapacity(count)
                var k = start
                while k < endExclusive {
                    r[base + loopVar] = .float(Float(k))
                    try executeInstrs(body, &r, base: base, constants: constants)
                    els.append(r[base + result])
                    k += 1
                }
                r[base + dst] = .array(els)
            }

        case .mapComprehension(let dst, let indexVar, let elemVar, let source, let body, let result):
            let els = r[base + source].arrayElements ?? []
            var out: [EngineValue] = []
            out.reserveCapacity(els.count)
            for (k, el) in els.enumerated() {
                if let indexVar { r[base + indexVar] = .float(Float(k)) }
                r[base + elemVar] = el
                try executeInstrs(body, &r, base: base, constants: constants)
                out.append(r[base + result])
            }
            r[base + dst] = .array(out)
        }
    }
}

/// Evaluate all outputs, in source order.
func runTapeValues(_ tape: Tape, _ inputs: [String: EngineValue]) throws(EvalError) -> [EngineValue] {
    let inputCount = tape.inputOrder.count
    var registers = [EngineValue](repeating: .float(0), count: inputCount + tape.registerCount)

    var i = 0
    while i < inputCount {
        let name = tape.inputOrder[i]
        guard let value = inputs[name] else { throw EvalError.missingInput(name) }
        registers[i] = value
        i += 1
    }

    try executeInstrs(tape.instructions, &registers, base: inputCount, constants: tape.constants)

    return tape.outputRegisters.map { registers[inputCount + $0.register] }
}
