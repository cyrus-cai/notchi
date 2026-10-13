import CoreLocation
import CoreWLAN
import Foundation

/// Where this Mac is, for `weather` and `wifi_status`. Asks for Location access
/// the first time either tool needs it; macOS also hides the Wi-Fi network name
/// until an app has that access. A fix is reused for 30 minutes.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var lastFix: (location: CLLocation, at: Date)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    /// Raises the system prompt when the user has not answered it yet, and
    /// returns once they have (or right away when they already did). Gives up
    /// after a minute, so a prompt left unanswered never holds an answer open.
    func requestAccess() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { cont in
            authWaiters.append(cont)
            guard authWaiters.count == 1 else { return }
            manager.requestWhenInUseAuthorization()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.finishAuth()
            }
        }
    }

    private func finishAuth() {
        let waiters = authWaiters
        authWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The current location, or nil when access is denied or no fix arrives
    /// within 10 seconds.
    func current() async -> CLLocation? {
        if let lastFix, Date().timeIntervalSince(lastFix.at) < 30 * 60 { return lastFix.location }
        await requestAccess()
        guard isAuthorized else { return nil }
        let location: CLLocation? = await withCheckedContinuation { cont in
            fixWaiters.append(cont)
            guard fixWaiters.count == 1 else { return }
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishFix(nil)
            }
        }
        if let location { lastFix = (location, Date()) }
        return location
    }

    private func finishFix(_ location: CLLocation?) {
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            self.finishAuth()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finishFix(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFix(nil) }
    }
}

/// The city `weather` uses when Location access is off. Set in Settings →
/// Advanced or through `manage_app_settings` (`weather_city`).
enum WeatherCity {
    private static let key = "weather.city"

    static var value: String {
        get { (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(trimmed, forKey: key) }
        }
    }
}

/// `weather`: current conditions and the daily forecast from Open-Meteo (free,
/// no key). Uses the place the user named, else this Mac's location, else the
/// city set in Settings. Coordinates are sent, never the user's IP location —
/// through a proxy that lands in another country.
struct WeatherTool: NotchTool {
    static let toolName = "weather"
    let name = toolName
    let description = """
    Current weather and the daily forecast for up to 7 days: conditions, high \
    and low, chance and amount of rain, wind. Call for any weather question \
    ("明天要带伞吗", "周末杭州冷不冷", "weather in Tokyo"). Leave place empty for \
    where the user is; pass a city when they name one. Use this, not web_search \
    or run_shell, for weather.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "place": ["type": "string", "description": "City or place the user named. Omit for their current location."],
            "days": ["type": "integer", "minimum": 1, "maximum": 7, "description": "Days of forecast from today. Default 3."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let named = (input["place"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let days = min(max((input["days"] as? NSNumber)?.intValue ?? 3, 1), 7)
        let place: Place
        if !named.isEmpty {
            guard let found = try await Self.geocode(named) else { return "No place called \"\(named)\" was found." }
            place = found
        } else if let location = await LocationService.shared.current() {
            place = Place(name: await Self.placeName(location), latitude: location.coordinate.latitude,
                          longitude: location.coordinate.longitude)
        } else if !WeatherCity.value.isEmpty, let found = try await Self.geocode(WeatherCity.value) {
            place = found
        } else {
            return "The user's location is unknown: Location access for Notchi is off and no weather city is set. "
                + "Ask which city, then call again with place. They can turn on Location for Notchi in "
                + "System Settings → Privacy & Security → Location Services, or set a default city "
                + "(manage_app_settings weather_city)."
        }
        return try await Self.forecast(place, days: days)
    }

    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private static func geocode(_ name: String) async throws -> Place? {
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        let language = Localization.shared.language.resolved == .zhHans
            || Localization.shared.language.resolved == .zhHant ? "zh" : "en"
        url.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1"),
                          .init(name: "language", value: language)]
        let json = try await fetch(url.url!)
        guard let first = (json["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        let parts = [first["name"], first["admin1"], first["country"]].compactMap { $0 as? String }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return Place(name: unique.joined(separator: ", "), latitude: lat, longitude: lon)
    }

    private static func placeName(_ location: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        let mark = marks?.first
        let parts = [mark?.locality, mark?.administrativeArea, mark?.country].compactMap { $0 }
        return parts.isEmpty ? String(format: "%.2f, %.2f", location.coordinate.latitude, location.coordinate.longitude)
            : parts.joined(separator: ", ")
    }

    private static func forecast(_ place: Place, days: Int) async throws -> String {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: String(days)),
        ]
        let json = try await fetch(url.url!)
        var lines = ["Weather for \(place.name) (Open-Meteo):"]
        if let now = json["current"] as? [String: Any] {
            lines.append("Now (\(now["time"] as? String ?? "")): \(condition(now["weather_code"])), "
                + "\(number(now["temperature_2m"]))°C, feels like \(number(now["apparent_temperature"]))°C, "
                + "rain \(number(now["precipitation"])) mm, wind \(number(now["wind_speed_10m"])) km/h")
        }
        if let daily = json["daily"] as? [String: Any], let dates = daily["time"] as? [String] {
            func at(_ key: String, _ i: Int) -> Any? { (daily[key] as? [Any]).flatMap { i < $0.count ? $0[i] : nil } }
            for (i, date) in dates.enumerated() {
                lines.append("\(date): \(condition(at("weather_code", i))), "
                    + "\(number(at("temperature_2m_min", i)))–\(number(at("temperature_2m_max", i)))°C, "
                    + "rain chance \(number(at("precipitation_probability_max", i)))%, "
                    + "\(number(at("precipitation_sum", i))) mm, wind up to \(number(at("wind_speed_10m_max", i))) km/h")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func fetch(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    private static func number(_ value: Any?) -> String {
        guard let n = (value as? NSNumber)?.doubleValue else { return "?" }
        return n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }

    /// WMO weather interpretation codes, as Open-Meteo returns them.
    private static func condition(_ code: Any?) -> String {
        switch (code as? NSNumber)?.intValue ?? -1 {
        case 0: return "clear"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80: return "light showers"
        case 81: return "showers"
        case 82: return "violent showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "unknown"
        }
    }
}

/// `wifi_status`: the Wi-Fi network this Mac is on, read with CoreWLAN.
/// macOS returns the network name only to an app with Location access, so the
/// first call asks for it.
struct WiFiStatusTool: NotchTool {
    static let toolName = "wifi_status"
    let name = toolName
    let description = """
    Which Wi-Fi network this Mac is connected to, with signal strength, speed \
    and channel, or whether Wi-Fi is off. Call for "现在连的是哪个 Wi-Fi", \
    "is my Wi-Fi signal good". Use this, not run_shell: shell commands cannot \
    read the network name on current macOS.
    """
    let schema: [String: Any] = ["type": "object", "properties": [String: Any]()]

    func execute(_ input: [String: Any]) async throws -> String {
        await LocationService.shared.requestAccess()
        let authorized = await LocationService.shared.isAuthorized
        guard let wifi = CWWiFiClient.shared().interface() else { return "This Mac has no Wi-Fi interface." }
        guard wifi.powerOn() else { return "Wi-Fi is turned off." }
        let rssi = wifi.rssiValue()
        guard rssi != 0 else { return "Wi-Fi is on but not connected to a network." }
        var lines: [String] = []
        if let ssid = wifi.ssid() {
            lines.append("Connected to \"\(ssid)\".")
        } else {
            lines.append(authorized
                ? "Connected to a Wi-Fi network; macOS did not return its name."
                : "Connected to a Wi-Fi network. macOS hides its name until Notchi has Location access: "
                    + "System Settings → Privacy & Security → Location Services.")
        }
        let quality = rssi >= -60 ? "strong" : rssi >= -70 ? "fair" : "weak"
        lines.append("Signal \(rssi) dBm (\(quality)), noise \(wifi.noiseMeasurement()) dBm, "
            + "transmit rate \(Int(wifi.transmitRate())) Mbps.")
        if let channel = wifi.wlanChannel() {
            let band: String
            switch channel.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default: band = "unknown band"
            }
            lines.append("Channel \(channel.channelNumber), \(band).")
        }
        return lines.joined(separator: " ")
    }
}
