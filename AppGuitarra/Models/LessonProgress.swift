//
//  LessonProgress.swift
//  AppGuitarra
//
//  Which lessons are done, stored on the device.
//

import Foundation
import Observation

@Observable
final class LessonProgress {
    private static let key = "completedLessons"
    private let defaults: UserDefaults

    private(set) var completed: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isCompleted(_ lesson: Lesson) -> Bool { completed.contains(lesson.id) }

    func markCompleted(_ lesson: Lesson) {
        completed.insert(lesson.id)
        defaults.set(completed.sorted(), forKey: Self.key)
    }
}
