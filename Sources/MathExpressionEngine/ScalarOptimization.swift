//
//  ScalarOptimization.swift
//  MathExpressionEngine
//
//  Private execution-policy helpers for scalar-only fast paths. The general VM
//  stays typed over `EngineValue`; these predicates identify the subset that can
//  safely run on raw `Float` registers or parallel scalar comprehension workers.
//

extension FnID {
    var isScalarFastPathEligible: Bool {
        switch self {
        case .sin, .cos, .tan, .asin, .acos, .atan,
             .sqrt, .abs, .exp, .log, .log2,
             .floor, .ceil, .round, .sign, .fract,
             .radians, .degrees, .saturate,
             .atan2, .pow, .min, .max, .mod, .wrap, .step,
             .clamp, .mix, .smoothstep:
            return true
        case .length, .distance, .dot, .cross, .normalize,
             .sum, .product, .mean, .count,
             .identity, .translate, .scale, .rotateX, .rotateY, .rotateZ, .compose,
             .transformPoint, .transformDir, .transpose, .inverse, .lookAt,
             .quatAxisAngle, .quatEuler, .conjugate, .mul, .rotate, .slerp:
            return false
        }
    }
}

extension Instr {
    var supportsScalarFastPath: Bool {
        switch self {
        case .loadConst, .loadInput, .negate, .binary:
            return true
        case .call0(let id, _),
             .call1(let id, _, _),
             .call2(let id, _, _, _),
             .call3(let id, _, _, _, _):
            return id.isScalarFastPathEligible
        case .construct2, .construct3, .construct4, .splat, .swizzle,
             .makeArray, .index, .comprehension, .mapComprehension:
            return false
        }
    }
}

extension Array where Element == Instr {
    var supportsScalarFastPath: Bool {
        allSatisfy(\.supportsScalarFastPath)
    }
}

extension Tape {
    func supportsScalarFastPath(interface: Interface) -> Bool {
        guard interface.inputs.allSatisfy({ $0.type == .float }),
              interface.outputs.allSatisfy({ $0.type == .float })
        else { return false }

        return instructions.supportsScalarFastPath
    }
}
