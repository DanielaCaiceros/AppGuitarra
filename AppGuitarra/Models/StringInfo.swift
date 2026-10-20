//
//  StringInfo.swift
//  AppGuitarra
//

import Foundation

/// Beginner-friendly facts about each open string. Index 0 = low E (6th string).
nonisolated struct StringInfo: Identifiable, Sendable {
    let index: Int
    /// Guitar numbering: 6 = thickest, 1 = thinnest.
    let number: Int
    let shortName: String
    let fullName: String
    let scientificName: String

    var id: Int { index }
    var ordinal: String {
        switch number {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(number)th"
        }
    }

    static let all: [StringInfo] = [
        StringInfo(index: 0, number: 6, shortName: "E", fullName: "Low E", scientificName: "E2"),
        StringInfo(index: 1, number: 5, shortName: "A", fullName: "A", scientificName: "A2"),
        StringInfo(index: 2, number: 4, shortName: "D", fullName: "D", scientificName: "D3"),
        StringInfo(index: 3, number: 3, shortName: "G", fullName: "G", scientificName: "G3"),
        StringInfo(index: 4, number: 2, shortName: "B", fullName: "B", scientificName: "B3"),
        StringInfo(index: 5, number: 1, shortName: "e", fullName: "High E", scientificName: "E4"),
    ]
}
