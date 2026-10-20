//
//  Item.swift
//  AppGuitarra
//
//  Created by Daniela Caiceros on 19/10/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
