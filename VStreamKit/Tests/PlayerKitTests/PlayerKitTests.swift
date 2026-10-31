import Foundation
import Testing
@testable import PlayerKit

@Suite struct LanguagesTests {
    @Test(arguments: [
        ("eng", "English"), ("en", "English"), ("EN", "English"),
        ("fre", "French"), ("fra", "French"), ("fr", "French"),
        ("ger", "German"), ("deu", "German"),
        ("chi", "Chinese"), ("zho", "Chinese"), ("zh-tw", "Chinese"), ("ZH-CN", "Chinese"), ("chs", "Chinese"),
        ("pob", "Portuguese (Brazil)"), ("pt-br", "Portuguese (Brazil)"), ("pt", "Portuguese"),
        ("spa", "Spanish"), ("es-419", "Spanish"), ("spl", "Spanish"),
        ("nob", "Norwegian"), ("vie", "Vietnamese"), ("vi", "Vietnamese"),
    ])
    func optionByAnyCode(code: String, name: String) {
        #expect(Languages.option(for: code)?.name == name)
    }

    @Test func longerCodesFallBackToTheirFirstThreeLetters() {
        #expect(Languages.option(for: "eng-US")?.name == "English")
        #expect(Languages.option(for: "jpn_jp")?.name == "Japanese")
    }

    @Test func twoLetterRegionCodes() {
        #expect(Languages.option(for: "en-US")?.name == "English")
        #expect(Languages.option(for: "pt-PT")?.name == "Portuguese")
    }

    @Test func unknownAndEmptyCodes() {
        #expect(Languages.option(for: nil) == nil)
        #expect(Languages.option(for: "") == nil)
        #expect(Languages.option(for: "xx") == nil)
        #expect(Languages.option(for: "und") == nil)
    }

    @Test func everyCodeMapsBackToItsOwnOption() {
        var seen: [String: String] = [:]
        for option in Languages.all {
            #expect(option.id == option.codes[0])
            for code in option.codes {
                #expect(code == code.lowercased(), "codes are stored lowercase: \(code)")
                #expect(seen[code] == nil, "\(code) is listed for both \(seen[code] ?? "") and \(option.name)")
                seen[code] = option.name
                #expect(Languages.option(for: code) == option)
            }
        }
        #expect(Set(Languages.all.map(\.id)).count == Languages.all.count)
    }

    @Test func names() {
        #expect(Languages.name(for: nil) == "Unknown")
        #expect(Languages.name(for: "") == "Unknown")
        #expect(Languages.name(for: "jpn") == "Japanese")
        #expect(Languages.name(for: "KO") == "Korean")
        // Not in the table: the system's localisation, else the code itself.
        let welsh = Languages.name(for: "cy")
        #expect(!welsh.isEmpty && welsh != "Unknown")
        #expect(welsh == (Locale.current.localizedString(forLanguageCode: "cy") ?? "cy"))
        let made = Languages.name(for: "qqq-invalid")
        #expect(made == (Locale.current.localizedString(forLanguageCode: "qqq-invalid") ?? "qqq-invalid"))
    }

    @Test func matches() {
        #expect(!Languages.matches(nil, any: ["eng"]))
        #expect(Languages.matches("eng", any: ["eng"]))
        #expect(Languages.matches("en", any: ["eng"]), "639-1 against 639-2")
        #expect(Languages.matches("ENG", any: ["en"]), "case-insensitive track tag")
        #expect(Languages.matches("fre", any: ["fra"]), "B and T forms")
        #expect(Languages.matches("zh-tw", any: ["chi"]))
        #expect(!Languages.matches("jpn", any: ["eng", "vie"]))
        #expect(!Languages.matches("eng", any: []))
        #expect(Languages.matches("xx", any: ["xx"]), "unknown codes still match exactly")
        #expect(!Languages.matches("xx", any: ["yy"]))
        #expect(!Languages.matches("pob", any: ["por"]), "Brazilian Portuguese is its own option")
    }
}

@Suite struct MediaTrackTests {
    func track(
        id: Int = 1, kind: MediaTrack.Kind = .audio, title: String? = nil, language: String? = nil,
        codec: String? = nil, channels: Int? = nil, external: Bool = false
    ) -> MediaTrack {
        MediaTrack(id: id, kind: kind, title: title, language: language, codec: codec, channels: channels, isExternal: external, isDefault: false)
    }

    @Test func fullAudioTrack() {
        #expect(track(title: "Director's Commentary", language: "eng", codec: "eac3", channels: 6).displayName == "English · Director's Commentary · EAC3 · 5.1")
    }

    @Test func channelLayouts() {
        #expect(track(channels: 8).displayName == "7.1")
        #expect(track(channels: 2).displayName == "2ch")
        #expect(track(channels: 1).displayName == "1ch")
        #expect(track(id: 4, channels: 0).displayName == "Track 4", "zero channels are omitted")
    }

    @Test func titleEqualToLanguageIsNotRepeated() {
        #expect(track(title: "jpn", language: "jpn").displayName == "Japanese")
        #expect(track(title: "", language: "vie", codec: "aac").displayName == "Vietnamese · AAC")
    }

    @Test func externalSubtitle() {
        #expect(track(kind: .sub, title: "OpenSubtitles", language: "vie", codec: "subrip", external: true).displayName == "Vietnamese · OpenSubtitles · SUBRIP · External")
        #expect(track(kind: .sub, external: true).displayName == "External")
    }

    @Test func emptyTrackFallsBackToID() {
        #expect(track(id: 12, kind: .video).displayName == "Track 12")
    }

    @Test func kindsMatchMPVTypes() {
        #expect(MediaTrack.Kind(rawValue: "audio") == .audio)
        #expect(MediaTrack.Kind(rawValue: "sub") == .sub)
        #expect(MediaTrack.Kind(rawValue: "video") == .video)
        #expect(MediaTrack.Kind(rawValue: "subtitle") == nil)
    }
}

@Suite struct PlaybackValueTests {
    @Test func playbackRequestDefaults() {
        let request = PlaybackRequest(url: URL(string: "https://cdn.example/v.mkv")!)
        #expect(request.headers.isEmpty)
        #expect(request.startTime == 0)
        #expect(request.subtitles.isEmpty)
        #expect(request.preferredAudioLanguages.isEmpty)
        #expect(request.preferredSubtitleLanguages.isEmpty)
    }

    @Test func playbackRequestKeepsValues() {
        let subtitle = ExternalSubtitle(url: URL(string: "https://subs.example/1.srt")!, language: "eng", title: "English")
        let request = PlaybackRequest(
            url: URL(string: "http://127.0.0.1:1/stream")!,
            headers: ["Referer": "x"],
            startTime: 42.5,
            subtitles: [subtitle],
            preferredAudioLanguages: ["jpn"],
            preferredSubtitleLanguages: ["eng"]
        )
        #expect(request.headers == ["Referer": "x"])
        #expect(request.startTime == 42.5)
        #expect(request.subtitles == [subtitle])
        #expect(subtitle.language == "eng")
        #expect(subtitle.title == "English")
        #expect(request.preferredAudioLanguages == ["jpn"])
        #expect(request.preferredSubtitleLanguages == ["eng"])
    }

    @Test func chapters() {
        #expect(Chapter(title: "Intro", time: 0) != Chapter(title: "Intro", time: 1))
        #expect(Chapter(title: "Intro", time: 0).title == "Intro")
    }
}
