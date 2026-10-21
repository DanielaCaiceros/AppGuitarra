//
//  LessonProgress.swift
//  AppGuitarra
//
//  Which lessons are done and on which days you practiced (for the streak),
//  stored on the device.
//

import Foundation
import Observation

@Observable
final class LessonProgress {
    private static let key = "completedLessons"
    private static let daysKey = "practiceDays"
    private let defaults: UserDefaults

    private(set) var completed: Set<String>
    /// Days with practice, as "yyyy-MM-dd" in the device's calendar.
    private(set) var practiceDays: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = Set(defaults.stringArray(forKey: Self.key) ?? [])
        practiceDays = Set(defaults.stringArray(forKey: Self.daysKey) ?? [])
    }

    func isCompleted(_ lesson: Lesson) -> Bool { completed.contains(lesson.id) }

    func markCompleted(_ lesson: Lesson) {
        completed.insert(lesson.id)
        defaults.set(completed.sorted(), forKey: Self.key)
        recordPractice()
    }

    func recordPractice(on date: Date = .now) {
        let day = Self.dayKey(date)
        guard !practiceDays.contains(day) else { return }
        practiceDays.insert(day)
        defaults.set(practiceDays.sorted(), forKey: Self.daysKey)
    }

    /// Days in a row with practice, ending today (or yesterday, if you haven't played yet today).
    func streak(today: Date = .now, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if !practiceDays.contains(Self.dayKey(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while practiceDays.contains(Self.dayKey(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
