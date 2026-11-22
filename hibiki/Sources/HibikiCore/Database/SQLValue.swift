import Foundation

/// SQLite 能存的五种基本值。
///
/// 为什么不用 `Any`：SQLite 只有 5 种类型，用枚举能把"传错类型"
/// 变成编译期问题，而不是运行时崩溃。
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    // 便利构造
    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    public init(_ value: Date, calendar: Calendar = .current) {
        self = .integer(Int64(value.timeIntervalSince1970 * 1000))
    }

    /// 可选值拍平：nil → .null
    /// 便利构造：Int / Bool 直接当整数存，省去调用方手写 Int64(...)
    public static func integer(_ value: Int) -> SQLValue { .integer(Int64(value)) }
    public static func integer(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }

    public static func optional(_ value: String?) -> SQLValue {
        value.map { SQLValue.text($0) } ?? .null
    }

    public static func optional(_ value: Int?) -> SQLValue {
        value.map { SQLValue.integer(Int64($0)) } ?? .null
    }

    public static func optional(_ value: Double?) -> SQLValue {
        value.map { SQLValue.real($0) } ?? .null
    }

    public static func optional(_ value: Data?) -> SQLValue {
        value.map { SQLValue.blob($0) } ?? .null
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var intValue: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        default: return nil
        }
    }

    public var boolValue: Bool? { intValue.map { $0 != 0 } }

    public var dataValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }

    public var dateValue: Date? {
        intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// 一行查询结果。
public struct SQLRow: Equatable, Sendable {
    public let values: [String: SQLValue]

    public init(_ values: [String: SQLValue]) {
        self.values = values
    }

    public subscript(column: String) -> SQLValue {
        values[column] ?? .null
    }

    public func int(_ column: String) -> Int? {
        values[column]?.intValue.map { Int($0) }
    }

    public func int64(_ column: String) -> Int64? {
        values[column]?.intValue
    }

    public func double(_ column: String) -> Double? {
        values[column]?.doubleValue
    }

    public func string(_ column: String) -> String? {
        guard let v = values[column], !v.isNull else { return nil }
        return v.stringValue
    }

    public func bool(_ column: String) -> Bool {
        values[column]?.boolValue ?? false
    }

    public func data(_ column: String) -> Data? {
        values[column]?.dataValue
    }

    public func date(_ column: String) -> Date? {
        values[column]?.dateValue
    }
}
