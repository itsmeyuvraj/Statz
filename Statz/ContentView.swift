//
//  ContentView.swift
//  Statz
//
//  Created by Yuvraj Poudyal on 27/08/26.
//

import SwiftUI
import SwiftData
import CoreLocation
import AppKit
import Darwin

// MARK: - App Screen Time Entry
struct AppUsageInfo: Identifiable {
    let id = UUID()
    let bundleIdentifier: String
    let appName: String
    let icon: NSImage?
    var duration: TimeInterval
}

// MARK: - Open-Meteo Response Model
private struct OpenMeteoResponse: Decodable {
    let currentWeather: CurrentWeatherUnits
    
    enum CodingKeys: String, CodingKey {
        case currentWeather = "current_weather"
    }
    
    struct CurrentWeatherUnits: Decodable {
        let temperature: Double
        let weathercode: Int
    }
}

// MARK: - System Stats Monitor
@Observable
final class SystemStatsMonitor: NSObject, CLLocationManagerDelegate {
    // Time
    var currentTime: Date = Date()
    
    // CPU & RAM
    var cpuUsage: Double = 0.0
    var ramUsagePercentage: Double = 0.0
    var ramUsedGB: Double = 0.0
    var ramTotalGB: Double = 0.0
    
    // Screen Time & App Tracking
    var activeAppName: String = "Unknown"
    var activeAppIcon: NSImage? = nil
    var activeAppSessionDuration: TimeInterval = 0
    var totalDailyScreenTime: TimeInterval = 0
    var appUsages: [String: AppUsageInfo] = [:]
    
    // Weather & Location
    var temperatureString: String = "--"
    var weatherCondition: String = "Fetching..."
    var weatherSymbolName: String = "cloud.sun.fill"
    var locationName: String = "--"
    var isWeatherLoading: Bool = false
    
    private var timer: Timer?
    private var weatherTimer: Timer?
    private var activeAppStartTime: Date = Date()
    private var lastCpuInfo: processor_info_array_t?
    private var lastCpuInfoCount: mach_msg_type_number_t = 0
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var lastDayTracked: Int = Calendar.current.component(.day, from: Date())
    
    private let defaultFallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
    
    override init() {
        super.init()
        setupTracking()
        setupLocationManager()
        startMonitoring()
    }
    
    deinit {
        timer?.invalidate()
        weatherTimer?.invalidate()
        if let lastCpuInfo {
            let size = MemoryLayout<integer_t>.size * Int(lastCpuInfoCount)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: lastCpuInfo)), vm_size_t(size))
        }
    }
    
    // MARK: - Monitoring Loop
    private func startMonitoring() {
        updateStats()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        
        // Refresh weather every 15 minutes
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 900.0, repeats: true) { [weak self] _ in
            self?.refreshWeather()
        }
    }
    
    private func updateStats() {
        let now = Date()
        currentTime = now
        
        // Reset daily stats if day changed
        let currentDay = Calendar.current.component(.day, from: now)
        if currentDay != lastDayTracked {
            lastDayTracked = currentDay
            totalDailyScreenTime = 0
            appUsages.removeAll()
            activeAppStartTime = now
        }
        
        updateActiveAppDuration()
        updateCPUUsage()
        updateRAMUsage()
    }
    
    // MARK: - Active App & Daily Screen Time Tracking
    private func setupTracking() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            switchActiveApp(to: frontmost)
        }
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            switchActiveApp(to: app)
        }
    }
    
    @objc private func systemWillSleep(_ notification: Notification) {
        recordCurrentAppSession()
    }
    
    @objc private func systemDidWake(_ notification: Notification) {
        activeAppStartTime = Date()
    }
    
    private func switchActiveApp(to app: NSRunningApplication) {
        recordCurrentAppSession()
        
        activeAppName = app.localizedName ?? "Unknown App"
        activeAppIcon = app.icon
        activeAppStartTime = Date()
        activeAppSessionDuration = 0
    }
    
    private func recordCurrentAppSession() {
        let elapsed = Date().timeIntervalSince(activeAppStartTime)
        guard elapsed > 0 else { return }
        
        totalDailyScreenTime += elapsed
        
        let bundleId = activeAppName
        if var existing = appUsages[bundleId] {
            existing.duration += elapsed
            appUsages[bundleId] = existing
        } else {
            appUsages[bundleId] = AppUsageInfo(
                bundleIdentifier: bundleId,
                appName: activeAppName,
                icon: activeAppIcon,
                duration: elapsed
            )
        }
    }
    
    private func updateActiveAppDuration() {
        let currentElapsed = Date().timeIntervalSince(activeAppStartTime)
        activeAppSessionDuration = currentElapsed
    }
    
    var currentTotalScreenTime: TimeInterval {
        return totalDailyScreenTime + activeAppSessionDuration
    }
    
    var topAppsList: [AppUsageInfo] {
        var copy = appUsages
        if var current = copy[activeAppName] {
            current.duration += activeAppSessionDuration
            copy[activeAppName] = current
        } else {
            copy[activeAppName] = AppUsageInfo(
                bundleIdentifier: activeAppName,
                appName: activeAppName,
                icon: activeAppIcon,
                duration: activeAppSessionDuration
            )
        }
        return copy.values.sorted { $0.duration > $1.duration }
    }
    
    // MARK: - CPU Usage Mach API
    private func updateCPUUsage() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )
        
        guard result == KERN_SUCCESS, let cpuInfo else { return }
        
        if let lastCpuInfo {
            var totalInUse: Int32 = 0
            var totalTotal: Int32 = 0
            
            for i in 0..<Int(numCPUs) {
                let baseIndex = i * Int(CPU_STATE_MAX)
                
                let userDelta = cpuInfo[baseIndex + Int(CPU_STATE_USER)] - lastCpuInfo[baseIndex + Int(CPU_STATE_USER)]
                let systemDelta = cpuInfo[baseIndex + Int(CPU_STATE_SYSTEM)] - lastCpuInfo[baseIndex + Int(CPU_STATE_SYSTEM)]
                let idleDelta = cpuInfo[baseIndex + Int(CPU_STATE_IDLE)] - lastCpuInfo[baseIndex + Int(CPU_STATE_IDLE)]
                let niceDelta = cpuInfo[baseIndex + Int(CPU_STATE_NICE)] - lastCpuInfo[baseIndex + Int(CPU_STATE_NICE)]
                
                let inUse = userDelta + systemDelta + niceDelta
                let total = inUse + idleDelta
                
                totalInUse += inUse
                totalTotal += total
            }
            
            if totalTotal > 0 {
                cpuUsage = (Double(totalInUse) / Double(totalTotal)) * 100.0
            }
            
            let size = MemoryLayout<integer_t>.size * Int(lastCpuInfoCount)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: lastCpuInfo)), vm_size_t(size))
        }
        
        lastCpuInfo = cpuInfo
        lastCpuInfoCount = numCpuInfo
    }
    
    // MARK: - RAM Usage Mach API
    private func updateRAMUsage() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return }
        
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        
        let usedBytes = active + wired + compressed
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        
        ramUsedGB = Double(usedBytes) / 1_073_741_824.0
        ramTotalGB = Double(totalBytes) / 1_073_741_824.0
        ramUsagePercentage = (Double(usedBytes) / Double(totalBytes)) * 100.0
    }
    
    // MARK: - Weather & CoreLocation
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            fetchWeather(for: defaultFallbackLocation)
        @unknown default:
            fetchWeather(for: defaultFallbackLocation)
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if currentLocation == nil {
                manager.requestLocation()
            }
        case .denied, .restricted:
            fetchWeather(for: defaultFallbackLocation)
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        fetchWeather(for: location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error.localizedDescription)")
        let locationToUse = currentLocation ?? defaultFallbackLocation
        fetchWeather(for: locationToUse)
    }
    
    func refreshWeather() {
        if let loc = currentLocation {
            fetchWeather(for: loc)
        } else if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.requestLocation()
        } else {
            fetchWeather(for: defaultFallbackLocation)
        }
    }
    
    func fetchWeather(for location: CLLocation) {
        isWeatherLoading = true
        fetchLocationName(for: location)
        
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true") else { return }
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                
                let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                let tempC = decoded.currentWeather.temperature
                let code = decoded.currentWeather.weathercode
                
                let (condition, symbol) = parseWeatherCode(code)
                
                await MainActor.run {
                    self.temperatureString = String(format: "%.1f°C", tempC)
                    self.weatherCondition = condition
                    self.weatherSymbolName = symbol
                    self.isWeatherLoading = false
                }
            } catch {
                print("Weather fetch error: \(error)")
                await MainActor.run {
                    self.weatherCondition = "Offline"
                    self.weatherSymbolName = "cloud.fill"
                    self.isWeatherLoading = false
                }
            }
        }
    }
    
    private func fetchLocationName(for location: CLLocation) {
        Task {
            do {
                let geocoder = CLGeocoder()
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    let city = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name ?? "Current Location"
                    await MainActor.run {
                        self.locationName = city
                    }
                }
            } catch {
                print("Reverse geocoding error: \(error)")
                await MainActor.run {
                    if self.locationName == "--" {
                        self.locationName = "San Francisco"
                    }
                }
            }
        }
    }
    
    private func parseWeatherCode(_ code: Int) -> (String, String) {
        switch code {
        case 0:
            return ("Clear", "sun.max.fill")
        case 1, 2, 3:
            return ("Partly Cloudy", "cloud.sun.fill")
        case 45, 48:
            return ("Foggy", "cloud.fog.fill")
        case 51, 53, 55, 56, 57:
            return ("Drizzle", "cloud.drizzle.fill")
        case 61, 63, 65, 66, 67:
            return ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77:
            return ("Snow", "cloud.snow.fill")
        case 80, 81, 82:
            return ("Showers", "cloud.heavyrain.fill")
        case 95, 96, 99:
            return ("Thunderstorm", "cloud.bolt.rain.fill")
        default:
            return ("Overcast", "cloud.fill")
        }
    }
}

// MARK: - Helper Formatting
extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - Modern Gauge Bar
struct VisualProgressGauge: View {
    let value: Double // 0...100
    let gradientColors: [Color]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat(value / 100.0))))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Main Statz Menu Bar View
struct ContentView: View {
    @State private var stats = SystemStatsMonitor()

    var body: some View {
        VStack(spacing: 14) {
            // MARK: - Header (Clock & Weather Widget)
            HStack(alignment: .center, spacing: 12) {
                // Time & Date Block
                VStack(alignment: .leading, spacing: 0) {
                    Text(stats.currentTime, style: .time)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(stats.currentTime.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Weather Chip
                Button {
                    stats.refreshWeather()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: stats.weatherSymbolName)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 18))
                        
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(stats.temperatureString)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text(stats.weatherCondition)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(stats.locationName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            // MARK: - Active Focus App & Screen Time Card
            VStack(spacing: 12) {
                HStack {
                    Label("Focus & Screen Time", systemImage: "macwindow.on.events.calendar.ticks")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                    
                    Spacer()
                    
                    Text("Today: \(stats.currentTotalScreenTime.formattedDuration)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(.blue)
                }
                
                // Current App Spotlight Card
                HStack(spacing: 12) {
                    Group {
                        if let icon = stats.activeAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        } else {
                            Image(systemName: "app.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.activeAppName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Active for \(stats.activeAppSessionDuration.formattedDuration)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                )
                
                // Top Screen Time Apps Breakdown
                if !stats.topAppsList.isEmpty {
                    VStack(spacing: 6) {
                        let total = max(1, stats.currentTotalScreenTime)
                        ForEach(stats.topAppsList.prefix(3)) { appInfo in
                            HStack(spacing: 8) {
                                if let icon = appInfo.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "square.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                
                                Text(appInfo.appName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.06))
                                        Capsule()
                                            .fill(Color.blue.opacity(0.7))
                                            .frame(width: geo.size.width * CGFloat(appInfo.duration / total))
                                    }
                                }
                                .frame(width: 45, height: 4)
                                
                                Text(appInfo.duration.formattedDuration)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 65, alignment: .trailing)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )

            // MARK: - System Hardware Performance Metrics
            VStack(spacing: 12) {
                HStack {
                    Label("System Metrics", systemImage: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple)
                    Spacer()
                }
                
                // CPU Metric Card
                VStack(spacing: 6) {
                    HStack {
                        Text("CPU Usage")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", stats.cpuUsage))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    VisualProgressGauge(
                        value: stats.cpuUsage,
                        gradientColors: stats.cpuUsage > 80 ? [.orange, .red] : [.teal, .green]
                    )
                }
                
                // RAM Metric Card
                VStack(spacing: 6) {
                    HStack {
                        Text("RAM Memory")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f / %.1f GB", stats.ramUsedGB, stats.ramTotalGB))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    VisualProgressGauge(
                        value: stats.ramUsagePercentage,
                        gradientColors: stats.ramUsagePercentage > 85 ? [.orange, .red] : [.purple, .indigo]
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )

            // MARK: - Footer Actions
            HStack {
                Text("Statz Monitor")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                
                Spacer()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 330)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
