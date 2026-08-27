//
//  Item.swift
//  Statz
//
//  Created by Yuvraj Poudyal on 27/08/26.
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
