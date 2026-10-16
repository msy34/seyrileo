import Foundation

/// Xtream-compatible panels disagree on JSON types: IDs and counters arrive as numbers,
/// numeric strings, empty strings or null depending on the panel version. These helpers
/// accept those variants for known fields and return nil (unknown) instead of failing.
extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           abs(value) < Double(Int32.max) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed), double.isFinite, abs(double) < Double(Int32.max) { return Int(double) }
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let int = lenientInt(key) { return int != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func lenientStringArray(_ key: Key) -> [String] {
        if let values = try? decodeIfPresent([LenientScalar].self, forKey: key) {
            return values.compactMap(\.string)
        }
        return []
    }
}

/// A scalar that may be a string, number, bool or null.
struct LenientScalar: Decodable {
    let string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { string = nil }
        else if let value = try? container.decode(String.self) { string = value }
        else if let value = try? container.decode(Int.self) { string = String(value) }
        else if let value = try? container.decode(Double.self) { string = String(value) }
        else if let value = try? container.decode(Bool.self) { string = value ? "1" : "0" }
        else { string = nil }
    }
}

/// Decodes each array element independently so one bad entry does not discard the list.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                dropped += 1
                // Advance past the undecodable element.
                _ = try? container.decode(SkipValue.self)
            }
        }
        self.elements = elements
        self.droppedCount = dropped
    }
}

private struct SkipValue: Decodable {
    init(from decoder: Decoder) throws {}
}
