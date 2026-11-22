import Foundation

/// 极简测试框架（替代 XCTest —— 没 Xcode 时用不了 XCTest）
final class Harness {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []
    private var currentSuite = ""
    private var currentCase = ""

    func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n▶ \(name)")
        body()
    }

    func test(_ name: String, _ body: () -> Void) {
        currentCase = name
        let before = failed
        body()
        if failed == before {
            passed += 1
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            let location = "\(currentSuite) / \(currentCase) (line \(line))"
            let msg = "\(location): \(message())"
            failures.append(msg)
            print("      ✗ \(message())  [line \(line)]")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "",
                                   file: StaticString = #file, line: UInt = #line) {
        expect(actual == expected,
               "\(label.isEmpty ? "" : label + ": ")期望 \(expected)，实际 \(actual)",
               file: file, line: line)
    }

    func expectNil<T>(_ value: T?, _ label: String = "", file: StaticString = #file, line: UInt = #line) {
        expect(value == nil, "\(label) 期望 nil，实际 \(String(describing: value))", file: file, line: line)
    }

    func expectNotNil<T>(_ value: T?, _ label: String = "", file: StaticString = #file, line: UInt = #line) {
        expect(value != nil, "\(label) 期望非 nil", file: file, line: line)
    }

    func report() -> Never {
        print("\n" + String(repeating: "─", count: 56))
        print("通过 \(passed) 项，失败 \(failed) 项")
        if !failures.isEmpty {
            print("\n失败明细：")
            for f in failures { print("  • \(f)") }
            exit(1)
        }
        print("全部通过 ✅")
        exit(0)
    }
}
