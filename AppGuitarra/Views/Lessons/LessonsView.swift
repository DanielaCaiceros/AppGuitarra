//
//  LessonsView.swift
//  AppGuitarra
//
//  All lessons grouped by module. Every lesson is open: you can jump ahead
//  (for example to the F chord) whenever you want.
//

import SwiftUI

struct LessonsView: View {
    @Environment(LessonProgress.self) private var progress
    @State private var catalog: LessonCatalog?
    @State private var loadError: String?
    @State private var path: [Lesson] = []

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let catalog {
                    list(catalog)
                } else if let loadError {
                    ContentUnavailableView("Lessons unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(loadError))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Lessons")
            .navigationDestination(for: Lesson.self) { lesson in
                if let catalog {
                    LessonPlayerView(lesson: lesson, catalog: catalog) { next in
                        path = [next]
                    }
                    .id(lesson.id)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func list(_ catalog: LessonCatalog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(catalog.modules) { module in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(module.name)
                            .font(.title.weight(.bold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(module.lessons) { lesson in
                                NavigationLink(value: lesson) {
                                    LessonCard(lesson: lesson, isCompleted: progress.isCompleted(lesson))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private func load() {
        guard catalog == nil else { return }
        do {
            let loaded = try LessonCatalog.load()
            #if DEBUG
            let problems = loaded.validationErrors()
            assert(problems.isEmpty, "Lesson content problems:\n" + problems.joined(separator: "\n"))
            #endif
            catalog = loaded
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct LessonCard: View {
    let lesson: Lesson
    let isCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(lesson.number)")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isCompleted ? Color.green : Color.accentColor))
                Spacer()
                if isCompleted {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Text(lesson.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(lesson.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
            HStack(spacing: 6) {
                ForEach(lesson.chords, id: \.self) { chord in
                    Text(chord)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    LessonsView()
        .environment(LessonProgress())
}
