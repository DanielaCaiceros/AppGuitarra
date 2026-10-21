//
//  Phase3Tests.swift
//  AppGuitarraTests
//
//  Content (12 lessons, song catalog), new strokes (chucks, bass notes,
//  arpeggios), chord-change illustrations, the personalized path and the streak.
//

import XCTest
@testable import AppGuitarra

private func library() throws -> [String: Chord] {
    Dictionary(uniqueKeysWithValues: try ChordLibrary.loadChords().map { ($0.id, $0) })
}

final class StrokeTests: XCTestCase {
    func testNewStrokesParse() {
        let arpeggio = StrumPattern(id: "a", name: "a", strokes: "B3212321")
        XCTAssertTrue(arpeggio.isValid)
        XCTAssertEqual(arpeggio.slots.prefix(4), [.bass, .string(3), .string(2), .string(1)])
        XCTAssertTrue(arpeggio.hasSpecialStrokes)

        let chuck = StrumPattern(id: "c", name: "c", strokes: "D-xUD-xU")
        XCTAssertEqual(chuck.slots[2], .mute)
        XCTAssertTrue(StrumPattern(id: "b", name: "b", strokes: "B-DUA-DU").isValid)
        XCTAssertFalse(StrumPattern(id: "f", name: "f", strokes: "D-DU-UDU").hasSpecialStrokes)
        XCTAssertFalse(StrumPattern(id: "x", name: "x", strokes: "D-D7-UDU").isValid, "7 is not a string")
    }

    func testSixEightCounts() {
        let sixEight = StrumPattern(id: "s", name: "s", strokes: "D-DUDU", beatsPerBar: 2, slotsPerBeat: 3)
        XCTAssertTrue(sixEight.isValid)
        XCTAssertEqual((0..<6).map(sixEight.countLabel), ["1", "la", "li", "2", "la", "li"])
    }

    func testBassStrings() throws {
        let chords = try library()
        XCTAssertEqual(chords["C"]?.bassStringIndex, 1)        // 5th string
        XCTAssertEqual(chords["C"]?.altBassStringIndex, 2)     // 4th string
        XCTAssertEqual(chords["G"]?.bassStringIndex, 0)        // 6th string
        XCTAssertEqual(chords["G"]?.altBassStringIndex, 2)     // jumps to the 4th
        XCTAssertEqual(chords["F"]?.bassStringIndex, 2)        // 4th string, the low two are muted
        XCTAssertEqual(Stroke.string(6).stringIndexes(on: try XCTUnwrap(chords["D"])), [], "Muted string stays silent")
    }

    private func timeline(_ strokes: String, chord: String) throws -> PracticeTimeline {
        let pattern = StrumPattern(id: "p", name: "p", strokes: strokes)
        return PracticeTimeline(config: PracticeConfig(
            pattern: pattern,
            segments: [PracticeSegment(chord: try XCTUnwrap(library()[chord]), bars: 1)],
            bpm: 60
        ))
    }

    func testArpeggioPlaysSingleNotes() throws {
        let notes = try timeline("B3212321", chord: "C").cycleSounds.filter { !$0.isClick }
        // C: bass C3 (A string, fret 3), then G3, C4, E4 …
        XCTAssertEqual(notes.prefix(4).map(\.sound), [.note(48), .note(55), .note(60), .note(64)])
        XCTAssertTrue(notes.allSatisfy { !$0.damps }, "Arpeggio notes ring into each other")
    }

    func testCarterAndChucks() throws {
        let carter = try timeline("B-DUA-DU", chord: "G").cycleSounds.filter { !$0.isClick }
        XCTAssertEqual(carter.first?.sound, .note(43))                      // low G
        XCTAssertEqual(carter.first { $0.slot == 4 }?.sound, .note(50))      // open D
        XCTAssertTrue(carter.first { $0.slot == 2 }?.damps ?? false)

        let chuck = try timeline("D-xUD-xU", chord: "G").cycleSounds.filter { !$0.isClick }
        XCTAssertEqual(chuck.filter { $0.sound == .mute("G") }.map(\.slot), [2, 6])
    }

    func testMutedStringMakesNoSound() throws {
        let sounds = try timeline("6-------", chord: "D").cycleSounds.filter { !$0.isClick }
        XCTAssertTrue(sounds.isEmpty)
    }
}

final class ChordTransitionTests: XCTestCase {
    func testCToAmHasTwoAnchors() throws {
        let chords = try library()
        let change = ChordTransition(from: try XCTUnwrap(chords["C"]), to: try XCTUnwrap(chords["Am"]))
        XCTAssertEqual(change.anchorFingers, [1, 2])
        XCTAssertEqual(change.moves.first { $0.finger == 3 }?.move, .move(fromString: 5, toString: 3, toFret: 2))
        XCTAssertEqual(change.anchoredPlacements(in: try XCTUnwrap(chords["Am"])).count, 2)
    }

    func testGToDHasNoAnchor() throws {
        let chords = try library()
        let change = ChordTransition(from: try XCTUnwrap(chords["G"]), to: try XCTUnwrap(chords["D"]))
        XCTAssertTrue(change.anchorFingers.isEmpty)
        XCTAssertTrue(change.summary.contains("land them as one"))
    }

    func testPivotsAndBarre() throws {
        let chords = try library()
        XCTAssertEqual(ChordTransition(from: try XCTUnwrap(chords["B7"]), to: try XCTUnwrap(chords["E7"])).anchorFingers, [2])
        let cToF = ChordTransition(from: try XCTUnwrap(chords["C"]), to: try XCTUnwrap(chords["F"]))
        XCTAssertEqual(cToF.anchorFingers, [1], "The index stays and flattens into the barre")
        XCTAssertEqual(cToF.moves.first { $0.finger == 4 }, nil)
    }

    func testSlideIsAGuideFinger() {
        let a = Chord(id: "a", name: "a", frets: [-1, -1, 2, -1, -1, -1], fingers: [0, 0, 1, 0, 0, 0], baseFret: 1, barre: nil)
        let b = Chord(id: "b", name: "b", frets: [-1, -1, 4, -1, -1, -1], fingers: [0, 0, 1, 0, 0, 0], baseFret: 1, barre: nil)
        XCTAssertEqual(ChordTransition(from: a, to: b).moves.first?.move, .slide(fromFret: 2, toFret: 4))
    }
}

final class ContentTests: XCTestCase {
    func testTwelveLessonsInThreeModules() throws {
        let catalog = try LessonCatalog.load()
        XCTAssertEqual(catalog.lessons.map(\.number), Array(1...12))
        XCTAssertEqual(catalog.modules.map(\.name), ["Rhythm", "Changes", "Technique"])
        XCTAssertTrue(catalog.modules.allSatisfy { $0.lessons.count == 4 })
        XCTAssertEqual(catalog.validationErrors(), [])
    }

    func testEveryPatternParses() throws {
        for pattern in try LessonCatalog.load().patterns.values {
            XCTAssertTrue(pattern.isValid, pattern.id)
        }
    }

    func testChecksMatchTheirProgressions() throws {
        // A check should play whole passes through its progression.
        let catalog = try LessonCatalog.load()
        for lesson in catalog.lessons {
            for index in lesson.steps.indices {
                guard case .check(let check) = lesson.steps[index], let resolved = lesson.resolvedCheck(at: index) else { continue }
                let cycle = resolved.progression.reduce(0) { $0 + $1.bars }
                XCTAssertEqual(check.bars % cycle, 0, "\(lesson.id): \(check.bars) bars vs a \(cycle)-bar progression")
            }
        }
    }

    func testCatalogIsValid() throws {
        let lessons = try LessonCatalog.load()
        let songs = try SongCatalog.load()
        XCTAssertGreaterThanOrEqual(songs.count, 30)
        XCTAssertEqual(SongCatalog.validationErrors(songs, chords: Set(lessons.chords.keys), patterns: Set(lessons.patterns.keys)), [])
        XCTAssertTrue(songs.contains { $0.id == "why-why-why" })
    }

    func testSectionParsing() {
        let section = CatalogSection(name: "Verse", chords: "Am G C:2")
        XCTAssertEqual(section.progression, [
            ProgressionSegment(chord: "Am", bars: 1), ProgressionSegment(chord: "G", bars: 1), ProgressionSegment(chord: "C", bars: 2),
        ])
        XCTAssertNil(CatalogSection(name: "Bad", chords: "Am G:0").progression)
        XCTAssertNil(CatalogSection(name: "Bad", chords: "Am :2").progression)
    }
}

final class PathRankerTests: XCTestCase {
    private func song(_ id: String, _ chords: [String], artist: String = "A", bpm: Int = 90, pattern: String = "folk") -> PathCandidate {
        PathCandidate(id: id, title: id, artist: artist, chords: chords, bpm: bpm, pattern: pattern)
    }

    private let lessons = [
        PathLesson(id: "L01", number: 1, title: "One", chords: ["Em", "Am"], patterns: ["quarter-downs"]),
        PathLesson(id: "L02", number: 2, title: "Two", chords: ["Em", "Am"], patterns: ["eighths"]),
        PathLesson(id: "L03", number: 3, title: "Three", chords: ["G", "D"], patterns: ["folk"]),
        PathLesson(id: "L10", number: 10, title: "Ten", chords: ["Fmaj7", "F", "C", "G"], patterns: ["quarter-downs"]),
    ]

    func testUnlocksCountSongsThatBecomePlayable() {
        let a = song("a", ["G", "F"]), b = song("b", ["F", "C"]), c = song("c", ["Bm"])
        XCTAssertEqual(PathRanker.unlocks(a, pool: [a, b, c], known: ["C", "G"]), 1)
    }

    func testEasyFMakesTheRealFCheaper() {
        XCTAssertLessThan(PathRanker.effort(of: "F", known: ["Fmaj7"]), PathRanker.effort(of: "F", known: []))
    }

    func testCloserSongsScoreHigher() {
        let known: Set<String> = ["G", "D", "Em", "C"]
        let easy = song("easy", ["G", "D", "Em", "C"])
        let hard = song("hard", ["Bm", "F", "B7"])
        let prefs = PathPreferences()
        let pool = [easy, hard]
        XCTAssertGreaterThan(PathRanker.score(easy, pool: pool, known: known, level: 2, preferences: prefs).total,
                             PathRanker.score(hard, pool: pool, known: known, level: 2, preferences: prefs).total)
    }

    func testWantedSongComesFirstAndItsLessonBeforeIt() {
        var prefs = PathPreferences()
        prefs.wantSongs = ["imagination"]
        let imagination = song("imagination", ["Am", "F", "C", "G"])
        let other = song("other", ["G", "D"], artist: "B")
        let pool = PathRanker.pool(catalog: [imagination, other], imported: [], preferences: prefs)
        XCTAssertEqual(pool.map(\.id), ["imagination"], "With a taste set, only liked songs are on the path")

        let items = PathRanker.buildPath(pool: pool, lessons: lessons, completedLessons: ["L01", "L03"],
                                         known: ["G", "D", "Em", "C", "Am"], level: 2, preferences: prefs)
        XCTAssertEqual(items.map(\.id), ["lesson-L10", "song-imagination"])
        guard case .song(_, let score) = items.last else { return XCTFail() }
        XCTAssertEqual(score.newChords, ["F"])
        XCTAssertTrue(score.reason.hasPrefix("You want this one"), score.reason)
    }

    func testBeginnerStartsWithTheBasics() {
        let items = PathRanker.buildPath(pool: [song("s", ["Em", "Am"], pattern: "quarter-downs")], lessons: lessons,
                                         completedLessons: [], known: [], level: 1, preferences: PathPreferences())
        XCTAssertEqual(items.map(\.id), ["lesson-L01", "lesson-L02", "song-s"])
    }

    func testPathKnowledgeAccumulates() {
        // After learning song a (G, D), song b (G, D, Em) needs only Em.
        let a = song("a", ["G", "D"]), b = song("b", ["G", "D", "Em"])
        let items = PathRanker.buildPath(pool: [a, b], lessons: [], completedLessons: ["L01"],
                                         known: ["C", "Am", "Em"], level: 2, preferences: PathPreferences())
        let songs = items.compactMap { item -> PathScore? in
            if case .song(_, let score) = item { return score } else { return nil }
        }
        XCTAssertEqual(songs.count, 2)
        XCTAssertTrue(songs.last?.newChords.isEmpty ?? false)
    }

    func testLearnedSongsLeaveThePathAndTeachTheirChords() {
        var prefs = PathPreferences()
        prefs.learnedSongs = ["a"]
        let a = song("a", ["Bm", "A"]), b = song("b", ["G"])
        XCTAssertEqual(PathRanker.pool(catalog: [a, b], imported: [], preferences: prefs).map(\.id), ["b"])
        let known = PathRanker.knownChords(preferences: prefs, completedLessons: ["L03"], lessons: lessons, songs: [a, b])
        XCTAssertEqual(known, ["Bm", "A", "G", "D"])
    }
}

final class StreakAndStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testStreakCountsConsecutiveDays() throws {
        let progress = LessonProgress(defaults: defaults())
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        XCTAssertEqual(progress.streak(today: today, calendar: calendar), 0)
        progress.recordPractice(on: day(-1))
        progress.recordPractice(on: day(-2))
        XCTAssertEqual(progress.streak(today: today, calendar: calendar), 2, "Yesterday still counts")
        progress.recordPractice(on: today)
        XCTAssertEqual(progress.streak(today: today, calendar: calendar), 3)
        progress.recordPractice(on: day(-4))
        XCTAssertEqual(progress.streak(today: today, calendar: calendar), 3, "A gap ends the streak")
    }

    func testInterestIsExclusiveAndPersists() {
        let suite = defaults()
        let store = PathStore(defaults: suite)
        store.setInterest(.want, for: "perfect")
        store.setInterest(.halfPlay, for: "perfect")
        XCTAssertEqual(store.interest(for: "perfect"), .halfPlay)
        XCTAssertFalse(store.preferences.wantSongs.contains("perfect"))
        store.toggleArtist("Ed Sheeran")
        XCTAssertEqual(PathStore(defaults: suite).preferences.favoriteArtists, ["Ed Sheeran"])
    }
}
