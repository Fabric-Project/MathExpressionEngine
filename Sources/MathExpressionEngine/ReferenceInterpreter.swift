//
//  ReferenceInterpreter.swift
//  MathExpressionEngine
//
//  Tree-walking evaluator over the function body, producing typed `EngineValue`s.
//  Uses the shared value-math in Value.swift / Builtins, and stays on as the
//  differential oracle for the tape (validating lowering & sequencing).
//

enum ReferenceInterpreter {

    static func evalBody(_ body: Body, _ inputs: [String: EngineValue]) throws(EvalError) -> [EngineValue] {
        var locals: [String: EngineValue] = [:]
        var outputs: [EngineValue] = []
        for stmt in body.statements {
            switch stmt {
            case .input:
                break   // declared inputs are supplied by name in `inputs`
            case .local(let name, let value, _):
                locals[name] = try eval(value, inputs, locals)
            case .output(_, let value, _):
                outputs.append(try eval(value, inputs, locals))
            }
        }
        return outputs
    }

    static func eval(_ e: Expr, _ inputs: [String: EngineValue], _ locals: [String: EngineValue]) throws(EvalError) -> EngineValue {
        switch e {
        case .number(let value, _):
            return .float(value)

        case .variable(let name, _), .typedVariable(let name, _, _):
            if let local = locals[name] { return local }
            if let constant = Builtins.constants[name] { return .float(constant) }
            guard let value = inputs[name] else { throw EvalError.missingInput(name) }
            return value

        case .negate(let operand, _):
            return EngineValue.negate(try eval(operand, inputs, locals))

        case .binary(let op, let l, let r, _):
            let a = try eval(l, inputs, locals)
            let b = try eval(r, inputs, locals)
            return EngineValue.binary(op, a, b)

        case .swizzle(let base, let chars, _):
            let v = try eval(base, inputs, locals)
            let idx = swizzleIndices(chars) ?? [0]
            let i0 = idx[0]
            let i1 = idx.count > 1 ? idx[1] : 0
            let i2 = idx.count > 2 ? idx[2] : 0
            let i3 = idx.count > 3 ? idx[3] : 0
            return EngineValue.swizzle(v, i0, i1, i2, i3, count: idx.count)

        case .arrayLiteral(let elements, _):
            var els: [EngineValue] = []
            els.reserveCapacity(elements.count)
            for el in elements { els.append(try eval(el, inputs, locals)) }
            return .array(els)

        case .index(let base, let idx, _):
            let b = try eval(base, inputs, locals)
            let iVal = try eval(idx, inputs, locals)
            let els = b.arrayElements ?? []
            let k = Int(iVal.scalar.rounded(.down))
            guard k >= 0, k < els.count else { throw EvalError.indexOutOfBounds(index: k, count: els.count) }
            return els[k]

        case .comprehension(let bodyExpr, let loopVar, let lo, let hi, let inclusive, _):
            let loV = try eval(lo, inputs, locals).scalar
            let hiV = try eval(hi, inputs, locals).scalar
            let start = Int(loV.rounded(.down))
            let endExclusive = inclusive ? Int(hiV.rounded(.down)) + 1 : Int(hiV.rounded(.down))
            let count = endExclusive - start
            if count <= 0 { return .array([]) }
            guard count <= EngineLimits.maxArrayElements else {
                throw EvalError.limitExceeded("comprehension produced \(count) elements (max \(EngineLimits.maxArrayElements))")
            }
            var els: [EngineValue] = []
            els.reserveCapacity(count)
            var scoped = locals
            var k = start
            while k < endExclusive {
                scoped[loopVar] = .float(Float(k))
                els.append(try eval(bodyExpr, inputs, scoped))
                k += 1
            }
            return .array(els)

        case .mapComprehension(let bodyExpr, let indexVar, let elemVar, let source, _):
            let s = try eval(source, inputs, locals)
            let els = s.arrayElements ?? []
            var out: [EngineValue] = []
            out.reserveCapacity(els.count)
            var scoped = locals
            for (k, el) in els.enumerated() {
                if let indexVar { scoped[indexVar] = .float(Float(k)) }
                scoped[elemVar] = el
                out.append(try eval(bodyExpr, inputs, scoped))
            }
            return .array(out)

        case .call(let name, let args, _):
            var vs: [EngineValue] = []
            vs.reserveCapacity(args.count)
            for arg in args { vs.append(try eval(arg, inputs, locals)) }

            if let constructed = ValueType.Base.constructed(name) {
                let width = constructed.width
                if vs.count == 1 { return EngineValue.splat(width, vs[0].scalar) }
                switch width {
                case 2:  return EngineValue.construct2(vs[0].scalar, vs[1].scalar)
                case 3:  return EngineValue.construct3(vs[0].scalar, vs[1].scalar, vs[2].scalar)
                default: return EngineValue.construct4(vs[0].scalar, vs[1].scalar, vs[2].scalar, vs[3].scalar)
                }
            }

            guard let id = Builtins.id(forName: name) else { return .float(.nan) }
            let a0 = vs.count > 0 ? vs[0] : .float(0)
            let a1 = vs.count > 1 ? vs[1] : .float(0)
            let a2 = vs.count > 2 ? vs[2] : .float(0)
            return Builtins.evaluateValue(id, a0, a1, a2)
        }
    }
}
