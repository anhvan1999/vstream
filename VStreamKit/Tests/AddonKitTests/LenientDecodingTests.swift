import Foundation
import Testing
@testable import AddonKit

/// Decodes `{"v": ...}` through every lossy accessor.
private struct Probe: Decodable {
    let string: String?
    let int: Int?
    let bool: Bool?
    let url: URL?
    let strings: [String]
    let ints: [Int]

    enum CodingKeys: String, CodingKey { case v }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        string = container.lossyString(.v)
        int = container.lossyInt(.v)
        bool = container.lossyBool(.v)
        url = container.lossyURL(.v)
        strings = container.lossyStringArray(.v)
        ints = container.lossyArray(.v)
    }

    static func of(_ value: String) throws -> Probe {
        try JSONDecoder().decode(Probe.self, from: Data(#"{"v":\#(value)}"#.utf8))
    }
}

@Suite struct LenientDecodingTests {
    @Test func missingKey() throws {
        let probe = try JSONDecoder().decode(Probe.self, from: Data("{}".utf8))
        #expect(probe.string == nil)
        #expect(probe.int == nil)
        #expect(probe.bool == nil)
        #expect(probe.url == nil)
        #expect(probe.strings.isEmpty)
        #expect(probe.ints.isEmpty)
    }

    @Test func null() throws {
        let probe = try Probe.of("null")
        #expect(probe.string == nil)
        #expect(probe.int == nil)
        #expect(probe.bool == nil)
        #expect(probe.strings.isEmpty)
    }

    @Test func strings() throws {
        #expect(try Probe.of(#""hello""#).string == "hello")
        #expect(try Probe.of(#""""#).string == nil)
        #expect(try Probe.of("42").string == "42")
        #expect(try Probe.of("2.5").string == "2.5")
        #expect(try Probe.of("true").string == nil)
        #expect(try Probe.of("[1]").string == nil)
    }

    @Test func ints() throws {
        #expect(try Probe.of("7").int == 7)
        #expect(try Probe.of("7.9").int == 7)
        #expect(try Probe.of(#""12""#).int == 12)
        #expect(try Probe.of(#""12a""#).int == nil)
        #expect(try Probe.of("{}").int == nil)
    }

    @Test func bools() throws {
        #expect(try Probe.of("true").bool == true)
        #expect(try Probe.of("false").bool == false)
        #expect(try Probe.of("1").bool == true)
        #expect(try Probe.of("0").bool == false)
        #expect(try Probe.of(#""Yes""#).bool == true)
        #expect(try Probe.of(#""TRUE""#).bool == true)
        #expect(try Probe.of(#""1""#).bool == true)
        #expect(try Probe.of(#""no""#).bool == false)
        #expect(try Probe.of("[]").bool == nil)
    }

    @Test func urls() throws {
        #expect(try Probe.of(#""  https://a.example/x.png  ""#).url?.absoluteString == "https://a.example/x.png")
        #expect(try Probe.of(#""""#).url == nil)
        #expect(try Probe.of("5").url?.absoluteString == "5")
    }

    @Test func stringArrays() throws {
        #expect(try Probe.of(#"["a","",3,"b",null]"#).strings == ["a", "b"])
        #expect(try Probe.of(#""a, b,,c ""#).strings == ["a", "b", "c"])
        #expect(try Probe.of(#""single""#).strings == ["single"])
        #expect(try Probe.of("12").strings.isEmpty)
    }

    @Test func lossyArrayDropsBadElements() throws {
        #expect(try Probe.of(#"[1,"x",2,null,3.5,{}]"#).ints == [1, 2])
        #expect(try Probe.of(#""not an array""#).ints.isEmpty)
    }

    @Test func anyCodingKey() {
        let key = AnyCodingKey("name")
        #expect(key.stringValue == "name")
        #expect(key.intValue == nil)
        #expect(AnyCodingKey(stringValue: "x")?.stringValue == "x")
        #expect(AnyCodingKey(intValue: 1) == nil)
        #expect(key == AnyCodingKey("name"))
    }
}

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[null,true,1.5,"s",[2],{"k":false}]"#.utf8))
        #expect(value == .array([.null, .bool(true), .number(1.5), .string("s"), .array([.number(2)]), .object(["k": .bool(false)])]))
    }

    @Test func numbersAreNotBools() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("[0,1]".utf8)) == .array([.number(0), .number(1)]))
    }

    @Test func roundTrips() throws {
        let value: JSONValue = .object([
            "null": .null, "bool": .bool(false), "num": .number(-3), "str": .string("é"),
            "arr": .array([.object([:])]),
        ])
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func subscriptAndStringValue() {
        let value: JSONValue = .object(["a": .string("x")])
        #expect(value["a"] == .string("x"))
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["a"] == nil)
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.number(3).stringValue == "3")
        #expect(JSONValue.number(3.25).stringValue == "3.25")
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.null.stringValue == nil)
        #expect(value.stringValue == nil)
    }
}

@Suite struct StremioDateTests {
    @Test func parsesBothISOForms() {
        #expect(StremioDate.parse("2008-01-20T00:00:00.000Z") == Date(timeIntervalSince1970: 1_200_787_200))
        #expect(StremioDate.parse("2008-01-20T00:00:00Z") == Date(timeIntervalSince1970: 1_200_787_200))
        #expect(StremioDate.parse("2008-01-20T00:00:00.250Z")?.timeIntervalSince1970 == 1_200_787_200.25)
    }

    @Test func rejectsEmptyAndGarbage() {
        #expect(StremioDate.parse(nil) == nil)
        #expect(StremioDate.parse("") == nil)
        #expect(StremioDate.parse("2008") == nil)
        #expect(StremioDate.parse("yesterday") == nil)
    }
}
