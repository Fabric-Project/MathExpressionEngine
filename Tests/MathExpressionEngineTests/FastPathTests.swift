import Testing
@testable import MathExpressionEngine

@Suite struct FastPathTests {

    @Test func scalarProgramInstallsFastPath() throws {
        let result = compile("sin(a) + b ^ 2")
        #expect(result.isValid, "\(result.diagnostics)")
        #expect(result.program?.hasScalarFastPath == true)
        #expect(abs(try result.evaluate(["a": 0, "b": 3]) - 9) < 1e-4)
    }

    @Test func multipleScalarOutputsUseFastPath() throws {
        let result = compile("out x = a + 1; out y = a * 2")
        #expect(result.isValid, "\(result.diagnostics)")
        #expect(result.program?.hasScalarFastPath == true)
        #expect(try result.evaluateAll(["a": 4]) == [5, 8])
    }

    @Test func scalarFastPathPreservesMissingInputError() throws {
        let result = compile("a + b")
        #expect(result.isValid, "\(result.diagnostics)")
        #expect(result.program?.hasScalarFastPath == true)
        #expect(throws: EvalError.missingInput("b")) {
            try result.evaluate(["a": 1])
        }
    }

    @Test func typedProgramsStayOnGeneralPath() {
        let vector = compile("vec3(x, y, 0)")
        #expect(vector.isValid, "\(vector.diagnostics)")
        #expect(vector.program?.hasScalarFastPath == false)

        let array = compile("[i * 2 for i in 0..<n]")
        #expect(array.isValid, "\(array.diagnostics)")
        #expect(array.program?.hasScalarFastPath == false)
    }
}
