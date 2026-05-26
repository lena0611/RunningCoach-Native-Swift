import Foundation
import CoreLocation

struct RunContextWeatherSnapshot: Codable {
    let locationName: String?
    let observedAt: String
    let current: RunContextCurrentWeather
    let hourly: [RunContextHourlyWeather]
    let daily: [RunContextDailyWeather]
}

struct RunContextCurrentWeather: Codable {
    let temperatureC: Double?
    let apparentTemperatureC: Double?
    let humidity: Double?
    let windMps: Double?
    let precipitationIntensityMmPerHour: Double?
    let condition: String
    let symbolName: String
    let isDaylight: Bool
}

struct RunContextHourlyWeather: Codable {
    let time: String
    let temperatureC: Double?
    let apparentTemperatureC: Double?
    let precipitationChance: Double?
    let precipitationAmountMm: Double?
    let precipitationIntensityMmPerHour: Double?
    let condition: String
    let symbolName: String
    let isDaylight: Bool
}

struct RunContextDailyWeather: Codable {
    let date: String
    let minTemperatureC: Double?
    let maxTemperatureC: Double?
    let precipitationChance: Double?
    let precipitationAmountMm: Double?
    let symbolName: String
    let condition: String
}

final class OpenMeteoWeatherImporter: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationCompletion: ((Result<CLLocation, Error>) -> Void)?
    private var locationTimeout: DispatchWorkItem?
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func fetchForecast(completion: @escaping (Result<RunContextWeatherSnapshot, Error>) -> Void) {
        requestLocation { result in
            switch result {
            case .success(let location):
                Task {
                    do {
                        let snapshot = try await self.fetchOpenMeteoForecast(for: location)
                        completion(.success(snapshot))
                    } catch {
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func requestLocation(completion: @escaping (Result<CLLocation, Error>) -> Void) {
        guard CLLocationManager.locationServicesEnabled() else {
            completion(.failure(OpenMeteoWeatherError.locationUnavailable))
            return
        }

        if let cached = lastLocation, abs(cached.timestamp.timeIntervalSinceNow) < 30 * 60 {
            completion(.success(cached))
            return
        }

        locationCompletion = completion
        startLocationTimeout()

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if let cached = locationManager.location, abs(cached.timestamp.timeIntervalSinceNow) < 30 * 60 {
                finishLocation(.success(cached))
            } else {
                locationManager.requestLocation()
            }
        case .denied, .restricted:
            finishLocation(.failure(OpenMeteoWeatherError.authorizationDenied))
        @unknown default:
            finishLocation(.failure(OpenMeteoWeatherError.authorizationDenied))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) < 30 * 60 {
                finishLocation(.success(cached))
            } else {
                manager.requestLocation()
            }
        case .denied, .restricted:
            finishLocation(.failure(OpenMeteoWeatherError.authorizationDenied))
        case .notDetermined:
            break
        @unknown default:
            finishLocation(.failure(OpenMeteoWeatherError.authorizationDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishLocation(.failure(OpenMeteoWeatherError.locationUnavailable))
            return
        }
        lastLocation = location
        finishLocation(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) < 24 * 60 * 60 {
            finishLocation(.success(cached))
            return
        }
        finishLocation(.failure(error))
    }

    private func startLocationTimeout() {
        locationTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.locationCompletion != nil else { return }
            if let cached = self.locationManager.location, abs(cached.timestamp.timeIntervalSinceNow) < 24 * 60 * 60 {
                self.finishLocation(.success(cached))
                return
            }
            self.finishLocation(.failure(OpenMeteoWeatherError.locationTimeout))
        }
        locationTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: item)
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        guard let completion = locationCompletion else { return }
        locationTimeout?.cancel()
        locationTimeout = nil
        locationCompletion = nil
        completion(result)
    }

    private func fetchOpenMeteoForecast(for location: CLLocation) async throws -> RunContextWeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(roundCoordinate(location.coordinate.latitude))),
            URLQueryItem(name: "longitude", value: String(roundCoordinate(location.coordinate.longitude))),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,precipitation,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_min,temperature_2m_max,precipitation_probability_max,precipitation_sum,weather_code"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto")
        ]

        guard let url = components.url else {
            throw OpenMeteoWeatherError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenMeteoWeatherError.requestFailed
        }

        let decoded = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
        return buildSnapshot(from: decoded)
    }

    private func buildSnapshot(from data: OpenMeteoForecastResponse) -> RunContextWeatherSnapshot {
        let currentCode = data.current?.weatherCode
        return RunContextWeatherSnapshot(
            locationName: "현재 위치",
            observedAt: toIso(data.current?.time) ?? Self.isoFormatter.string(from: Date()),
            current: RunContextCurrentWeather(
                temperatureC: rounded(data.current?.temperature),
                apparentTemperatureC: rounded(data.current?.apparentTemperature),
                humidity: percentFromWhole(data.current?.humidity),
                windMps: kmhToMps(data.current?.windSpeed),
                precipitationIntensityMmPerHour: rounded(data.current?.precipitation),
                condition: weatherCodeToCondition(currentCode),
                symbolName: weatherCodeToSymbol(currentCode, isDaylight: data.current?.isDay != 0),
                isDaylight: data.current?.isDay != 0
            ),
            hourly: buildHourly(from: data.hourly),
            daily: buildDaily(from: data.daily)
        )
    }

    private func buildHourly(from hourly: OpenMeteoHourly?) -> [RunContextHourlyWeather] {
        guard let times = hourly?.time else { return [] }
        return times.indices.map { index in
            let code = hourly?.weatherCode?.value(at: index)
            let precipitation = rounded(hourly?.precipitation?.value(at: index))
            return RunContextHourlyWeather(
                time: toIso(times[index]) ?? times[index],
                temperatureC: rounded(hourly?.temperature?.value(at: index)),
                apparentTemperatureC: rounded(hourly?.apparentTemperature?.value(at: index)),
                precipitationChance: percentFromWhole(hourly?.precipitationProbability?.value(at: index)),
                precipitationAmountMm: precipitation,
                precipitationIntensityMmPerHour: precipitation,
                condition: weatherCodeToCondition(code),
                symbolName: weatherCodeToSymbol(code, isDaylight: hourly?.isDay?.value(at: index) != 0),
                isDaylight: hourly?.isDay?.value(at: index) != 0
            )
        }
    }

    private func buildDaily(from daily: OpenMeteoDaily?) -> [RunContextDailyWeather] {
        guard let dates = daily?.time else { return [] }
        return dates.indices.map { index in
            let code = daily?.weatherCode?.value(at: index)
            return RunContextDailyWeather(
                date: dates[index],
                minTemperatureC: rounded(daily?.minTemperature?.value(at: index)),
                maxTemperatureC: rounded(daily?.maxTemperature?.value(at: index)),
                precipitationChance: percentFromWhole(daily?.precipitationProbabilityMax?.value(at: index)),
                precipitationAmountMm: rounded(daily?.precipitationSum?.value(at: index)),
                symbolName: weatherCodeToSymbol(code, isDaylight: true),
                condition: weatherCodeToCondition(code)
            )
        }
    }

    private func roundCoordinate(_ value: CLLocationDegrees) -> Double {
        (value * 100).rounded() / 100
    }

    private func rounded(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 100).rounded() / 100
    }

    private func percentFromWhole(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, min(1, value / 100))
    }

    private func kmhToMps(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value / 3.6 * 10).rounded() / 10
    }

    private func toIso(_ value: String?) -> String? {
        guard let value else { return nil }
        if let date = Self.localHourFormatter.date(from: value) {
            return Self.isoFormatter.string(from: date)
        }
        if let date = Self.dayFormatter.date(from: value) {
            return Self.isoFormatter.string(from: date)
        }
        return value
    }

    private func weatherCodeToCondition(_ code: Int?) -> String {
        guard let code else { return "정보 없음" }
        if code == 0 { return "맑음" }
        if [1, 2].contains(code) { return "대체로 맑음" }
        if code == 3 { return "흐림" }
        if [45, 48].contains(code) { return "안개" }
        if [51, 53, 55, 56, 57].contains(code) { return "이슬비" }
        if [61, 63, 65, 66, 67, 80, 81, 82].contains(code) { return "비" }
        if [71, 73, 75, 77, 85, 86].contains(code) { return "눈" }
        if [95, 96, 99].contains(code) { return "뇌우" }
        return "날씨 변화"
    }

    private func weatherCodeToSymbol(_ code: Int?, isDaylight: Bool) -> String {
        guard let code else { return "cloud" }
        if code == 0 { return isDaylight ? "sun.max" : "moon" }
        if [1, 2].contains(code) { return isDaylight ? "cloud.sun" : "cloud.moon" }
        if code == 3 { return "cloud" }
        if [45, 48].contains(code) { return "cloud.fog" }
        if [51, 53, 55, 56, 57].contains(code) { return "cloud.drizzle" }
        if [61, 63, 65, 66, 67, 80, 81, 82].contains(code) { return "cloud.rain" }
        if [71, 73, 75, 77, 85, 86].contains(code) { return "cloud.snow" }
        if [95, 96, 99].contains(code) { return "cloud.bolt.rain" }
        return "cloud"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct OpenMeteoForecastResponse: Decodable {
    let current: OpenMeteoCurrent?
    let hourly: OpenMeteoHourly?
    let daily: OpenMeteoDaily?
}

private struct OpenMeteoCurrent: Decodable {
    let time: String?
    let temperature: Double?
    let apparentTemperature: Double?
    let humidity: Double?
    let windSpeed: Double?
    let precipitation: Double?
    let weatherCode: Int?
    let isDay: Int?

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case apparentTemperature = "apparent_temperature"
        case humidity = "relative_humidity_2m"
        case windSpeed = "wind_speed_10m"
        case precipitation
        case weatherCode = "weather_code"
        case isDay = "is_day"
    }
}

private struct OpenMeteoHourly: Decodable {
    let time: [String]?
    let temperature: [Double]?
    let apparentTemperature: [Double]?
    let precipitationProbability: [Double]?
    let precipitation: [Double]?
    let weatherCode: [Int]?
    let isDay: [Int]?

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case apparentTemperature = "apparent_temperature"
        case precipitationProbability = "precipitation_probability"
        case precipitation
        case weatherCode = "weather_code"
        case isDay = "is_day"
    }
}

private struct OpenMeteoDaily: Decodable {
    let time: [String]?
    let minTemperature: [Double]?
    let maxTemperature: [Double]?
    let precipitationProbabilityMax: [Double]?
    let precipitationSum: [Double]?
    let weatherCode: [Int]?

    enum CodingKeys: String, CodingKey {
        case time
        case minTemperature = "temperature_2m_min"
        case maxTemperature = "temperature_2m_max"
        case precipitationProbabilityMax = "precipitation_probability_max"
        case precipitationSum = "precipitation_sum"
        case weatherCode = "weather_code"
    }
}

private extension Array {
    func value(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum OpenMeteoWeatherError: LocalizedError {
    case authorizationDenied
    case invalidURL
    case locationTimeout
    case locationUnavailable
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "위치 권한이 허용되지 않아 날씨를 가져올 수 없습니다."
        case .invalidURL:
            return "날씨 요청 주소를 만들지 못했습니다."
        case .locationTimeout:
            return "위치 확인이 지연되고 있습니다. 잠시 후 새로고침해 주세요."
        case .locationUnavailable:
            return "현재 위치를 확인할 수 없어 날씨를 가져올 수 없습니다."
        case .requestFailed:
            return "무료 날씨 예보를 가져오지 못했습니다."
        }
    }
}
