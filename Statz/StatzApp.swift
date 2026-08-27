//
//  StatzApp.swift
//  Statz
//
//  Created by Yuvraj Poudyal on 27/08/26.
//

import SwiftUI
import SwiftData

@main
struct StatzApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        MenuBarExtra("Statz", systemImage: "chart.bar.fill") {
            ContentView()
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
    }
}
