import Foundation
import HealthKit
import CoreLocation

struct HealthKitRunCandidate: Codable {
    let externalId: String
    let sourceName: String?
    let date: String
    let startAt: String
    let endAt: String
    let durationSec: Double?
    let distanceKm: Double?
    let avgPaceSec: Double?
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let cadence: Double?
    let activeEnergyKcal: Double?
    let temperature: Double?
    let humidity: Double?
    let windMps: Double?
    let elevationGainM: Double?
    let elevationLossM: Double?
    let rpe: Double?
    let routeAvailable: Bool
    let laps: [HealthKitLap]
    let fastSegments: [HealthKitFastSegment]
    let rawAvailability: HealthKitAvailability
}

struct HealthKitLap: Codable {
    let index: Int
    let distanceKm: Double?
    let paceSec: Double?
    let avgHeartRate: Double?
    let cadence: Double?
}

struct HealthKitFastSegment: Codable {
    let index: Int
    let startSec: Double?
    let durationSec: Double?
    let distanceKm: Double?
    let avgPaceSec: Double?
    let bestPaceSec: Double?
}

struct HealthKitAvailability: Codable {
    let workout: Bool
    let heartRate: Bool
    let route: Bool
    let cadence: Bool
    let runningDynamics: Bool
}

final class HealthKitRunImporter {
    private let healthStore = HKHealthStore()
    private struct HeartRatePoint {
        let date: Date
        let bpm: Double
    }

    private struct DistancePoint {
        let startDate: Date
        let endDate: Date
        let meter: Double
    }

    private struct StepPoint {
        let startDate: Date
        let endDate: Date
        let count: Double
    }

    func fetchRecentRunningWorkouts(days: Int, completion: @escaping (Result<[HealthKitRunCandidate], Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[RunContext HealthKit] Health data unavailable")
            completion(.failure(HealthKitImportError.healthDataUnavailable))
            return
        }

        requestAuthorization { [weak self] result in
            switch result {
            case .success:
                print("[RunContext HealthKit] authorization success")
                self?.queryRecentRunningWorkouts(days: days, completion: completion)
            case .failure(let error):
                print("[RunContext HealthKit] authorization failed:", error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    func fetchRunningWorkout(externalId: String, completion: @escaping (Result<HealthKitRunCandidate, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[RunContext HealthKit] Health data unavailable")
            completion(.failure(HealthKitImportError.healthDataUnavailable))
            return
        }

        guard let uuid = UUID(uuidString: externalId) else {
            completion(.failure(HealthKitImportError.invalidExternalId))
            return
        }

        requestAuthorization { [weak self] result in
            switch result {
            case .success:
                print("[RunContext HealthKit] authorization success")
                self?.queryRunningWorkout(uuid: uuid, completion: completion)
            case .failure(let error):
                print("[RunContext HealthKit] authorization failed:", error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func requestAuthorization(completion: @escaping (Result<Void, Error>) -> Void) {
        let readTypes = Set(healthTypesToRead())
        healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
            if let error {
                completion(.failure(error))
            } else if success {
                completion(.success(()))
            } else {
                completion(.failure(HealthKitImportError.authorizationDenied))
            }
        }
    }

    private func healthTypesToRead() -> [HKObjectType] {
        var types: [HKObjectType] = [HKObjectType.workoutType()]

        [
            HKQuantityTypeIdentifier.heartRate,
            HKQuantityTypeIdentifier.stepCount,
            HKQuantityTypeIdentifier.distanceWalkingRunning,
            HKQuantityTypeIdentifier.activeEnergyBurned,
            HKQuantityTypeIdentifier.runningSpeed,
            HKQuantityTypeIdentifier.runningPower,
            HKQuantityTypeIdentifier.runningStrideLength,
            HKQuantityTypeIdentifier.runningVerticalOscillation
        ].compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { types.append($0) }

        if #available(iOS 18.0, *),
           let effortType = HKObjectType.quantityType(forIdentifier: .workoutEffortScore) {
            types.append(effortType)
        }

        types.append(HKSeriesType.workoutRoute())

        return types
    }

    private func queryRecentRunningWorkouts(days: Int, completion: @escaping (Result<[HealthKitRunCandidate], Error>) -> Void) {
        let startDate = Calendar.current.date(byAdding: .day, value: -max(days - 1, 0), to: Date()) ?? Date()
        let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: [])
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, runningPredicate])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            if let error {
                completion(.failure(error))
                return
            }

            let workouts = (samples as? [HKWorkout]) ?? []
            print("[RunContext HealthKit] workouts=\(workouts.count)")
            self?.buildCandidates(from: workouts, completion: completion)
        }

        healthStore.execute(query)
    }

    private func queryRunningWorkout(uuid: UUID, completion: @escaping (Result<HealthKitRunCandidate, Error>) -> Void) {
        let objectPredicate = HKQuery.predicateForObject(with: uuid)
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [objectPredicate, runningPredicate])

        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { [weak self] _, samples, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let workout = (samples as? [HKWorkout])?.first else {
                completion(.failure(HealthKitImportError.workoutNotFound))
                return
            }

            self?.buildCandidate(from: workout) { candidate in
                completion(.success(candidate))
            }
        }

        healthStore.execute(query)
    }

    private func buildCandidates(from workouts: [HKWorkout], completion: @escaping (Result<[HealthKitRunCandidate], Error>) -> Void) {
        let group = DispatchGroup()
        var candidates = Array<HealthKitRunCandidate?>(repeating: nil, count: workouts.count)

        for (index, workout) in workouts.enumerated() {
            group.enter()
            buildCandidate(from: workout) { candidate in
                candidates[index] = candidate
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            completion(.success(candidates.compactMap { $0 }))
        }
    }

    private func buildCandidate(from workout: HKWorkout, completion: @escaping (HealthKitRunCandidate) -> Void) {
        let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)
        let distanceKm = workoutDistanceKm(workout)
        let durationSec = workout.duration
        let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
            .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }

        var avgHeartRate: Double?
        var maxHeartRate: Double?
        var heartRatePoints: [HeartRatePoint] = []
        var routeLocations: [CLLocation] = []
        var distancePoints: [DistancePoint] = []
        var stepPoints: [StepPoint] = []
        var rpe: Double?

        let group = DispatchGroup()

        if let heartType {
            group.enter()
            queryHeartRate(for: workout, heartType: heartType) { average, maximum in
                avgHeartRate = average
                maxHeartRate = maximum
                group.leave()
            }

            group.enter()
            queryHeartRateSamples(for: workout, heartType: heartType) { points in
                heartRatePoints = points
                group.leave()
            }
        }

        group.enter()
        queryRouteLocations(for: workout) { locations in
            routeLocations = locations
            group.leave()
        }

        if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            group.enter()
            queryDistanceSamples(for: workout, distanceType: distanceType) { points in
                distancePoints = points
                group.leave()
            }
        }

        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            group.enter()
            queryStepSamples(for: workout, stepType: stepType) { points in
                stepPoints = points
                group.leave()
            }
        }

        if #available(iOS 18.0, *),
           let effortType = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) {
            group.enter()
            queryWorkoutEffortScore(for: workout, effortType: effortType) { score in
                rpe = score
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            let weather = self.workoutWeather(from: workout)
            let elevation = self.routeElevation(from: routeLocations)
            let avgPace = distanceKm.flatMap { distance -> Double? in
                guard distance > 0 else { return nil }
                return durationSec / distance
            }
            let laps = self.buildLaps(
                workout: workout,
                routeLocations: routeLocations,
                distancePoints: distancePoints,
                heartRatePoints: heartRatePoints,
                stepPoints: stepPoints,
                fallbackDistanceKm: distanceKm,
                fallbackDurationSec: durationSec
            )
            let fastSegments = self.buildFastSegments(workout: workout, routeLocations: routeLocations)
            let avgCadence = self.averageCadence(stepPoints, from: workout.startDate, to: workout.endDate)

            completion(
                HealthKitRunCandidate(
                    externalId: workout.uuid.uuidString,
                    sourceName: workout.sourceRevision.source.name,
                    date: Self.dayFormatter.string(from: workout.startDate),
                    startAt: Self.isoFormatter.string(from: workout.startDate),
                    endAt: Self.isoFormatter.string(from: workout.endDate),
                    durationSec: durationSec,
                    distanceKm: distanceKm,
                    avgPaceSec: avgPace,
                    avgHeartRate: avgHeartRate,
                    maxHeartRate: maxHeartRate,
                    cadence: avgCadence,
                    activeEnergyKcal: activeEnergy,
                    temperature: weather.temperature,
                    humidity: weather.humidity,
                    windMps: nil,
                    elevationGainM: elevation.gain,
                    elevationLossM: elevation.loss,
                    rpe: rpe,
                    routeAvailable: !routeLocations.isEmpty,
                    laps: laps,
                    fastSegments: fastSegments,
                    rawAvailability: HealthKitAvailability(
                        workout: true,
                        heartRate: avgHeartRate != nil || maxHeartRate != nil,
                        route: !routeLocations.isEmpty,
                        cadence: avgCadence != nil,
                        runningDynamics: avgCadence != nil || !fastSegments.isEmpty
                    )
                )
            )
        }
    }

    private func workoutDistanceKm(_ workout: HKWorkout) -> Double? {
        if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           let distance = workout.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter()) {
            return rounded(distance / 1000)
        }

        return workout.totalDistance.map { rounded($0.doubleValue(for: .meter()) / 1000) }
    }

    private func queryHeartRate(for workout: HKWorkout, heartType: HKQuantityType, completion: @escaping (Double?, Double?) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let query = HKStatisticsQuery(quantityType: heartType, quantitySamplePredicate: predicate, options: [.discreteAverage, .discreteMax]) { _, statistics, _ in
            let unit = HKUnit.count().unitDivided(by: .minute())
            let average = statistics?.averageQuantity().map { Self.rounded($0.doubleValue(for: unit)) }
            let maximum = statistics?.maximumQuantity().map { Self.rounded($0.doubleValue(for: unit)) }
            completion(average, maximum)
        }
        healthStore.execute(query)
    }

    @available(iOS 18.0, *)
    private func queryWorkoutEffortScore(for workout: HKWorkout, effortType: HKQuantityType, completion: @escaping (Double?) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let query = HKStatisticsQuery(quantityType: effortType, quantitySamplePredicate: predicate, options: [.discreteAverage]) { _, statistics, _ in
            let score = statistics?.averageQuantity().map { Self.rounded($0.doubleValue(for: .appleEffortScore())) }
            completion(score)
        }
        healthStore.execute(query)
    }

    private func queryHeartRateSamples(for workout: HKWorkout, heartType: HKQuantityType, completion: @escaping ([HeartRatePoint]) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: heartType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let unit = HKUnit.count().unitDivided(by: .minute())
            let points = (samples as? [HKQuantitySample] ?? []).map {
                HeartRatePoint(date: $0.startDate, bpm: Self.rounded($0.quantity.doubleValue(for: unit)))
            }
            completion(points)
        }
        healthStore.execute(query)
    }

    private func queryDistanceSamples(for workout: HKWorkout, distanceType: HKQuantityType, completion: @escaping ([DistancePoint]) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: distanceType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let points = (samples as? [HKQuantitySample] ?? []).map {
                DistancePoint(
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    meter: $0.quantity.doubleValue(for: .meter())
                )
            }
            completion(points)
        }
        healthStore.execute(query)
    }

    private func queryStepSamples(for workout: HKWorkout, stepType: HKQuantityType, completion: @escaping ([StepPoint]) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: stepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let points = (samples as? [HKQuantitySample] ?? []).map {
                StepPoint(
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    count: $0.quantity.doubleValue(for: .count())
                )
            }
            completion(points)
        }
        healthStore.execute(query)
    }


    private func queryRouteLocations(for workout: HKWorkout, completion: @escaping ([CLLocation]) -> Void) {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        let query = HKSampleQuery(sampleType: routeType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, _ in
            guard let self else {
                completion([])
                return
            }
            let routes = (samples as? [HKWorkoutRoute]) ?? []
            guard !routes.isEmpty else {
                completion([])
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            var allLocations: [CLLocation] = []

            for route in routes {
                group.enter()
                self.collectLocations(from: route) { locations in
                    lock.lock()
                    allLocations.append(contentsOf: locations)
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .global()) {
                completion(allLocations.sorted { $0.timestamp < $1.timestamp })
            }
        }
        healthStore.execute(query)
    }

    private func collectLocations(from route: HKWorkoutRoute, completion: @escaping ([CLLocation]) -> Void) {
        var locations: [CLLocation] = []
        let query = HKWorkoutRouteQuery(route: route) { _, batch, done, _ in
            if let batch {
                locations.append(contentsOf: batch)
            }
            if done {
                completion(locations)
            }
        }
        healthStore.execute(query)
    }

    private func workoutWeather(from workout: HKWorkout) -> (temperature: Double?, humidity: Double?) {
        let metadata = workout.metadata ?? [:]
        let temperature = (metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity)
            .map { Self.rounded($0.doubleValue(for: .degreeCelsius())) }
        let humidity = (metadata[HKMetadataKeyWeatherHumidity] as? HKQuantity)
            .map { Self.normalizedHumidity($0.doubleValue(for: .percent())) }
        return (temperature, humidity)
    }

    private func routeElevation(from locations: [CLLocation]) -> (gain: Double?, loss: Double?) {
        guard locations.count >= 2 else { return (nil, nil) }

        var gain = 0.0
        var loss = 0.0
        var previous: CLLocation?

        for location in locations where location.verticalAccuracy >= 0 {
            guard let last = previous else {
                previous = location
                continue
            }

            let delta = location.altitude - last.altitude
            previous = location
            guard abs(delta) >= 0.5, abs(delta) <= 80 else { continue }

            if delta > 0 {
                gain += delta
            } else {
                loss += abs(delta)
            }
        }

        guard gain > 0 || loss > 0 else { return (nil, nil) }
        return (Self.rounded(gain), Self.rounded(loss))
    }

    private func buildLaps(
        workout: HKWorkout,
        routeLocations: [CLLocation],
        distancePoints: [DistancePoint],
        heartRatePoints: [HeartRatePoint],
        stepPoints: [StepPoint],
        fallbackDistanceKm: Double?,
        fallbackDurationSec: Double
    ) -> [HealthKitLap] {
        if routeLocations.count >= 2 {
            return buildRouteLaps(locations: routeLocations, heartRatePoints: heartRatePoints, stepPoints: stepPoints)
        }

        if !distancePoints.isEmpty {
            return buildDistanceSampleLaps(distancePoints: distancePoints, heartRatePoints: heartRatePoints, stepPoints: stepPoints)
        }

        guard let fallbackDistanceKm, fallbackDistanceKm > 0 else { return [] }
        return [
            HealthKitLap(
                index: 1,
                distanceKm: Self.rounded(fallbackDistanceKm),
                paceSec: Self.rounded(fallbackDurationSec / fallbackDistanceKm),
                avgHeartRate: averageHeartRate(heartRatePoints, from: workout.startDate, to: workout.endDate),
                cadence: averageCadence(stepPoints, from: workout.startDate, to: workout.endDate)
            )
        ]
    }

    private func buildRouteLaps(locations: [CLLocation], heartRatePoints: [HeartRatePoint], stepPoints: [StepPoint]) -> [HealthKitLap] {
        var laps: [HealthKitLap] = []
        var lapIndex = 1
        var lapStartDate = locations.first?.timestamp
        var lapDistanceMeter = 0.0

        for index in 1..<locations.count {
            let previous = locations[index - 1]
            let current = locations[index]
            let segmentMeter = max(current.distance(from: previous), 0)
            lapDistanceMeter += segmentMeter

            if lapDistanceMeter >= 1000 {
                let start = lapStartDate ?? previous.timestamp
                let end = current.timestamp
                let duration = max(end.timeIntervalSince(start), 1)
                let distanceKm = lapDistanceMeter / 1000
                laps.append(
                    HealthKitLap(
                        index: lapIndex,
                        distanceKm: Self.rounded(distanceKm),
                        paceSec: Self.rounded(duration / distanceKm),
                        avgHeartRate: averageHeartRate(heartRatePoints, from: start, to: end),
                        cadence: averageCadence(stepPoints, from: start, to: end)
                    )
                )
                lapIndex += 1
                lapStartDate = current.timestamp
                lapDistanceMeter = 0
            }
        }

        if lapDistanceMeter >= 100, let start = lapStartDate, let end = locations.last?.timestamp {
            let duration = max(end.timeIntervalSince(start), 1)
            let distanceKm = lapDistanceMeter / 1000
            laps.append(
                HealthKitLap(
                    index: lapIndex,
                    distanceKm: Self.rounded(distanceKm),
                    paceSec: Self.rounded(duration / distanceKm),
                    avgHeartRate: averageHeartRate(heartRatePoints, from: start, to: end),
                    cadence: averageCadence(stepPoints, from: start, to: end)
                )
            )
        }

        return laps
    }

    private func buildDistanceSampleLaps(distancePoints: [DistancePoint], heartRatePoints: [HeartRatePoint], stepPoints: [StepPoint]) -> [HealthKitLap] {
        var laps: [HealthKitLap] = []
        var lapIndex = 1
        var lapStartDate = distancePoints.first?.startDate
        var lapEndDate = distancePoints.first?.endDate
        var lapDistanceMeter = 0.0

        for point in distancePoints {
            lapDistanceMeter += max(point.meter, 0)
            lapEndDate = point.endDate

            if lapDistanceMeter >= 1000, let start = lapStartDate, let end = lapEndDate {
                let duration = max(end.timeIntervalSince(start), 1)
                let distanceKm = lapDistanceMeter / 1000
                laps.append(
                    HealthKitLap(
                        index: lapIndex,
                        distanceKm: Self.rounded(distanceKm),
                        paceSec: Self.rounded(duration / distanceKm),
                        avgHeartRate: averageHeartRate(heartRatePoints, from: start, to: end),
                        cadence: averageCadence(stepPoints, from: start, to: end)
                    )
                )
                lapIndex += 1
                lapStartDate = point.endDate
                lapDistanceMeter = 0
            }
        }

        if lapDistanceMeter >= 100, let start = lapStartDate, let end = lapEndDate {
            let duration = max(end.timeIntervalSince(start), 1)
            let distanceKm = lapDistanceMeter / 1000
            laps.append(
                HealthKitLap(
                    index: lapIndex,
                    distanceKm: Self.rounded(distanceKm),
                    paceSec: Self.rounded(duration / distanceKm),
                    avgHeartRate: averageHeartRate(heartRatePoints, from: start, to: end),
                    cadence: averageCadence(stepPoints, from: start, to: end)
                )
            )
        }

        return laps
    }

    private func buildFastSegments(workout: HKWorkout, routeLocations: [CLLocation]) -> [HealthKitFastSegment] {
        guard routeLocations.count >= 2 else { return [] }

        struct WorkingSegment {
            var startDate: Date
            var endDate: Date
            var distanceMeter: Double
            var durationSec: Double
            var bestPaceSec: Double
        }

        var segments: [HealthKitFastSegment] = []
        var current: WorkingSegment?
        let fastPaceThreshold = 345.0
        let minimumFastSegmentDuration = 6.0
        let minimumFastSegmentDistanceMeter = 20.0

        func closeCurrent() {
            guard let segment = current else { return }
            defer { current = nil }
            guard segment.durationSec >= minimumFastSegmentDuration, segment.distanceMeter >= minimumFastSegmentDistanceMeter else { return }
            let distanceKm = segment.distanceMeter / 1000
            guard distanceKm > 0 else { return }

            segments.append(
                HealthKitFastSegment(
                    index: segments.count + 1,
                    startSec: Self.rounded(max(segment.startDate.timeIntervalSince(workout.startDate), 0)),
                    durationSec: Self.rounded(segment.durationSec),
                    distanceKm: Self.rounded(distanceKm),
                    avgPaceSec: Self.rounded(segment.durationSec / distanceKm),
                    bestPaceSec: Self.rounded(segment.bestPaceSec)
                )
            )
        }

        for index in 1..<routeLocations.count {
            let previous = routeLocations[index - 1]
            let currentLocation = routeLocations[index]
            let duration = currentLocation.timestamp.timeIntervalSince(previous.timestamp)
            guard duration > 0, duration <= 30 else {
                closeCurrent()
                continue
            }

            let distanceMeter = max(currentLocation.distance(from: previous), 0)
            guard distanceMeter >= 5 else { continue }
            let paceSec = duration / (distanceMeter / 1000)
            guard paceSec.isFinite else { continue }

            if paceSec <= fastPaceThreshold {
                if var segment = current {
                    segment.endDate = currentLocation.timestamp
                    segment.distanceMeter += distanceMeter
                    segment.durationSec += duration
                    segment.bestPaceSec = min(segment.bestPaceSec, paceSec)
                    current = segment
                } else {
                    current = WorkingSegment(
                        startDate: previous.timestamp,
                        endDate: currentLocation.timestamp,
                        distanceMeter: distanceMeter,
                        durationSec: duration,
                        bestPaceSec: paceSec
                    )
                }
            } else {
                closeCurrent()
            }
        }

        closeCurrent()
        return Array(segments.prefix(12))
    }

    private func averageHeartRate(_ points: [HeartRatePoint], from start: Date, to end: Date) -> Double? {
        let values = points.filter { $0.date >= start && $0.date <= end }.map(\.bpm)
        guard !values.isEmpty else { return nil }
        return Self.rounded(values.reduce(0, +) / Double(values.count))
    }

    private func averageCadence(_ points: [StepPoint], from start: Date, to end: Date) -> Double? {
        let totalSteps = points
            .filter { $0.endDate >= start && $0.startDate <= end }
            .reduce(0) { $0 + max($1.count, 0) }
        let durationMin = end.timeIntervalSince(start) / 60
        guard totalSteps > 0, durationMin > 0 else { return nil }
        return Self.rounded(totalSteps / durationMin)
    }

    private func rounded(_ value: Double) -> Double {
        Self.rounded(value)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func normalizedHumidity(_ value: Double) -> Double {
        let percent = value <= 1 ? value * 100 : value
        return rounded(percent)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum HealthKitImportError: LocalizedError {
    case healthDataUnavailable
    case authorizationDenied
    case invalidExternalId
    case workoutNotFound

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "이 기기에서 HealthKit을 사용할 수 없습니다."
        case .authorizationDenied:
            return "HealthKit 권한이 허용되지 않았습니다."
        case .invalidExternalId:
            return "HealthKit 원본 ID 형식이 올바르지 않습니다."
        case .workoutNotFound:
            return "HealthKit에서 해당 러닝 세션을 찾지 못했습니다."
        }
    }
}
