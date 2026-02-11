//
//  EchoApp.swift
//  Echo
//
//  Created by Alexander Gabrysiak on 01/02/2026.
//
import SwiftUI
import FirebaseCore


@main
struct EchoApp: App {
    
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
