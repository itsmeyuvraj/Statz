# Statz 📊

**Statz** is a lightweight, modern macOS menu bar application built with SwiftUI that gives you real-time insights into system performance, current focus time, daily screen time, and weather conditions—right from your menu bar.

![macOS Menu Bar App](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Framework-blue.svg)

---

## ✨ Features

- 🌤️ **Live Weather**: Instant weather updates with current temperature and condition icons powered by CoreLocation and Open-Meteo API.
- 🕒 **Date & Clock**: Clean digital time display with weekday and calendar date.
- 🎯 **Active Focus Tracker**: Real-time duration timer tracking how long your frontmost application has been active.
- ⏳ **Daily Screen Time**: Tracks total screen time for the day and visualizes usage across your top 3 most-used applications.
- 💻 **CPU & RAM Metrics**: Live CPU usage percentage and memory consumption (Used vs. Total GB) powered by native Mach kernel APIs.
- 🎨 **Native macOS UI**: Modern, translucent, card-based interface styled specifically for macOS.

---

## 🛠️ Built With

- **SwiftUI** & **@Observable** state management.
- **Mach Kernel APIs** (`host_processor_info`, `host_statistics64`) for low-overhead hardware telemetry.
- **NSWorkspace** observers for active application and sleep/wake events.
- **CoreLocation** & **Open-Meteo API** for location-based weather data.

---

## 🚀 Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Statz.git
   cd Statz
