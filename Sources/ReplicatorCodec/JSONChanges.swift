import Foundation

enum JSONPath {
    private static func isIdentifier(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
        if scalar == "_" || scalar == "$" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
            return true
        case .nonspacingMark, .spacingMark, .decimalNumber, .connectorPunctuation: return !first
        default: return !first && (scalar.value == 0x200c || scalar.value == 0x200d)
        }
    }
    enum Leg { case member(Data), index(Int, fromEnd: Bool) }
    static func parse(_ text: String) throws -> [Leg] {
        var p = JSONDocumentParser(bytes: Array(text.utf8))
        try jsonRequire(p.take(36), "JSON path must start with $")
        var legs: [Leg] = []
        while true {
            p.space()
            if p.index == p.bytes.count { return legs }
            try jsonRequire(legs.count < 100, "JSON path depth exceeds 100")
            if p.take(46) {
                p.space()
                try jsonRequire(p.index < p.bytes.count, "missing JSON path member")
                let key: String
                if p.bytes[p.index] == 34 {
                    key = try p.string()
                } else {
                    let start = p.index
                    while p.index < p.bytes.count && ![46, 91, 9, 10, 13, 32].contains(p.bytes[p.index]) {
                        p.index += 1
                    }
                    guard let value = String(bytes: p.bytes[start..<p.index], encoding: .utf8), !value.isEmpty else {
                        throw DecoderError(code: 2, offset: 0, reason: "invalid JSON path member")
                    }
                    try jsonRequire(
                        value.unicodeScalars.enumerated().allSatisfy { i, c in isIdentifier(c, first: i == 0) },
                        "invalid or wildcard JSON path member")
                    key = value
                }
                legs.append(.member(Data(key.utf8)))
            } else if p.take(91) {
                p.space()
                let fromEnd = p.bytes.dropFirst(p.index).starts(with: "last".utf8)
                if fromEnd {
                    p.index += 4
                    if !p.take(45) {
                        try jsonRequire(p.take(93), "invalid JSON array index")
                        legs.append(.index(0, fromEnd: true))
                        continue
                    }
                }
                p.space()
                let start = p.index
                while p.index < p.bytes.count && (48...57).contains(p.bytes[p.index]) { p.index += 1 }
                let digits = String(decoding: p.bytes[start..<p.index], as: UTF8.self)
                guard let n = UInt32(digits) else {
                    throw DecoderError(code: 2, offset: 0, reason: "invalid JSON array index")
                }
                try jsonRequire(p.take(93), "invalid JSON array index")
                legs.append(.index(Int(n), fromEnd: fromEnd))
            } else {
                throw DecoderError(code: 2, offset: 0, reason: "invalid JSON path leg")
            }
        }
    }
}
extension JSONNode {
    mutating func change(_ legs: ArraySlice<JSONPath.Leg>, operation: Int, value: JSONNode?, requireNull: Bool = false)
        throws
    {
        guard let first = legs.first else {
            try jsonRequire(operation == 0 && value != nil, "invalid JSON root operation")
            if requireNull {
                guard case .null = self else {
                    throw DecoderError(code: 2, offset: 0, reason: "typed JSON path is not a null slot")
                }
            }
            self = value!
            return
        }
        let last = legs.count == 1
        switch (self, first) {
        case (.object(var object), .member(let key)):
            if last && !requireNull {
                if operation == 1 {
                    try jsonRequire(object[key] == nil, "JSON INSERT member already exists")
                    object[key] = value
                } else {
                    try jsonRequire(object[key] != nil, "JSON change member is absent")
                    object[key] = operation == 2 ? nil : value
                }
            } else {
                guard var child = object[key] else {
                    throw DecoderError(code: 2, offset: 0, reason: "JSON change parent is absent")
                }
                try child.change(legs.dropFirst(), operation: operation, value: value, requireNull: requireNull)
                object[key] = child
            }
            self = .object(object)
        case (.array(var array), .index(let number, let fromEnd)):
            let position = fromEnd ? array.count - 1 - number : number
            if last && operation == 1 && !requireNull {
                guard let value else { throw DecoderError(code: 2, offset: 0, reason: "JSON INSERT lacks a value") }
                array.insert(value, at: min(max(position, 0), array.count))
            } else {
                try jsonRequire(position >= 0 && position < array.count, "JSON change array index is absent")
                if last && operation == 2 && !requireNull {
                    array.remove(at: position)
                } else {
                    try array[position].change(
                        legs.dropFirst(), operation: operation, value: value, requireNull: requireNull)
                }
            }
            self = .array(array)
        default: throw DecoderError(code: 2, offset: 0, reason: "JSON change parent has the wrong type")
        }
    }
}
extension JSONDocument {
    private struct Change: Decodable {
        let operation: Int
        let path: String
        let value: JSONEnvelope?
    }
    func applying(delta: Data, maximumBytes: Int) throws -> JSONDocument {
        let changes = try JSONDecoder().decode([Change].self, from: delta)
        var root = self.root
        for change in changes {
            let path = try JSONPath.parse(change.path)
            try jsonRequire(
                !path.isEmpty && (0...2).contains(change.operation), "invalid JSON diff operation or root path")
            try jsonRequire((change.operation == 2) == (change.value == nil), "invalid JSON diff value")
            let value = try change.value.map { try JSONDocument(envelope: $0).root }
            try root.change(path[...], operation: change.operation, value: value)
            // Check each intermediate document, including changes later removed.
            let intermediate = try JSONDocument(root: root)
            guard intermediate.retainedByteCost <= maximumBytes else {
                throw DecoderError(code: 5, offset: 0, reason: "JSON partial-update output limit exceeded")
            }
        }
        return try JSONDocument(root: root)
    }
}
