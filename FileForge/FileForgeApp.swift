//
//  FileForgeApp.swift
//  FileForge
//
//  A local file-conversion suite for macOS: PDF, image, Office and text
//  conversions that run entirely on this Mac. No uploads, no accounts, no
//  page limits — the reason to build this rather than use a website.
//
//  Author: Ibrahim Sultan
//

import SwiftUI

@main
struct FileForgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            // The file menu's Open should feed the queue, not open a document
            // window — this app has exactly one window and a queue in it.
            CommandGroup(replacing: .newItem) { }
        }
    }
}
