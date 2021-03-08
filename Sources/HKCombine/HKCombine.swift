import HealthKit
import Combine
import CoreLocation

private protocol HKHealthStoreCombine {
    
    func needsAuthorization(toShare: Set<HKSampleType>, toRead: Set<HKSampleType>) -> AnyPublisher<Bool, HKCombineError>
    
    func requestAuthorization(toShare: Set<HKSampleType>?, toRead: Set<HKSampleType>?) -> AnyPublisher<Bool, HKCombineError>
    
    func workouts(type: HKWorkoutActivityType, _ limit: Int) -> AnyPublisher<[HKWorkout], HKCombineError>
    
    func workouts(type: HKWorkoutActivityType, from startDate: Date, to endDate: Date, limit: Int) -> AnyPublisher<[HKWorkout], HKCombineError>
    
    func workoutDetails(_ workout: HKWorkout) -> AnyPublisher<HKCWorkoutDetails, HKCombineError>
    
    func get<T>(sample: T, start: Date, end: Date, limit: Int) -> AnyPublisher<[HKQuantitySample], HKCombineError> where T: HKObjectType
    
    func statistic(for type: HKQuantityType, with options: HKStatisticsOptions, from startDate: Date, to endDate: Date, _ limit: Int) -> AnyPublisher<HKStatistics, HKCombineError>
}

public enum HKCombineError: Error {
    /// Current device does not have HealthKit capabilities
    case noHKAvailable
    /// No workouts have been found for the given activity type and/or date range
    case noWorkoutsFound
    /// Given a HKWorkout there are no `HKWorkoutEvents` present
    case missingHKWorkoutEvents
    /// Wrapper around an upstream error from HealthKit
    case upstream(error: Error)
}

extension HKCombineError: Equatable {
    public static func == (lhs: HKCombineError, rhs: HKCombineError) -> Bool {
        switch (lhs, rhs) {
        case (.noWorkoutsFound, .noWorkoutsFound):
            return true
        default:
            return false
        }
    }
}

extension HKWorkout {
    
    public var workoutWithDetails: AnyPublisher<HKCWorkoutDetails, HKCombineError> {
        
        let locationsSamplesPublisher = routeSubject.flatMap({ workoutRoute -> PassthroughSubject<[CLLocation], HKCombineError> in
            workoutRoute.locationsSubject
        })
//        .replaceEmpty(with: [])
        /// Given a start value of an empty array
        .scan([]) { $0 + $1 }
        /// After combining all the values in a final array get the latest item which will have all the locations combined
        .last()
        /// Sort samples in ascending order
        .map({ locationSamples -> [CLLocation] in
            locationSamples.sorted(by: { $0.timestamp <= $1.timestamp })
        })
        /// Subscribe to two publishers, location and heart rate, and producing a tuple upon receiving output from any of the publishers.
        return Publishers.CombineLatest(locationsSamplesPublisher, heartRateSubject)
            .map({ (locationSamples, heartRateSamples) -> HKCWorkoutDetails in
                /// Once both taks have finished publish a HKCWorkoutDetails object downstream
                HKCWorkoutDetails(workout: self, locations: locationSamples, heartRate: heartRateSamples)
            }).eraseToAnyPublisher()
    }
    
    /// Query a workout together with workout route samples
    private var routeSubject:  PassthroughSubject<HKWorkoutRoute, HKCombineError> {
        
        let subject = PassthroughSubject<HKWorkoutRoute, HKCombineError>()
        
        let predicate = HKQuery.predicateForObjects(from: self)
        
        let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { (query, routes, error) in
            
            guard let routes = routes as? [HKWorkoutRoute], error == nil else {
                subject.send(completion: .failure(.upstream(error: error!)))
                return
            }
            
            routes.forEach({ subject.send($0) })
            
            subject.send(completion: .finished)
        }
        
        HKHealthStore().execute(query)
        
        return subject
    }
    
    /// Query the heart rate samples created during the workout start & end `Date` range
    private var heartRateSubject: AnyPublisher<[HKQuantitySample], HKCombineError> {
        
        let subject = PassthroughSubject<[HKQuantitySample], HKCombineError>()
        
        let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        
        let predicate = HKQuery.predicateForObjects(from: self)
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            
            let quantitySamples = samples as? [HKQuantitySample] ?? []
            
            subject.send(quantitySamples)
            subject.send(completion: .finished)
        }
        
        HKHealthStore().execute(query)
        
        return subject.eraseToAnyPublisher()
    }
    
    /// Publisher that emits an array of `HKWorkoutEvent` of type `.segment` which are the ones marked as pace splits on apple watches
    /// https://developer.apple.com/documentation/healthkit/hkworkouteventtype/segment#
    public var appleWatchPaces: AnyPublisher<[HKWorkoutEvent], HKCombineError> {
        
        guard let events = self.workoutEvents else {
            return Fail(error: HKCombineError.missingHKWorkoutEvents).eraseToAnyPublisher()
        }
        
        let filtered = events.filter({ $0.type == .segment })
        
        return Publishers.MergeMany(filtered.publisher).collect().setFailureType(to: HKCombineError.self).eraseToAnyPublisher()
    }
    
    /// TODO: Do calculation of non apple watch paces
    /// https://stackoverflow.com/questions/33826972/healthkit-running-splits-in-kilometres-code-inaccurate-why
    /// Splits by kilometer/mile for workouts not recorded with Apple Watch's Workout application
    public var splits: AnyPublisher<[HKWorkoutEvent], HKCombineError> {
        
        let subject = PassthroughSubject<[HKWorkoutEvent], Never>()
        
        var paces: [HKWorkoutEvent] = []
        
        guard let distanceType = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.distanceWalkingRunning) else {
            return [].publisher.setFailureType(to: HKCombineError.self).eraseToAnyPublisher()
        }

        let workoutPredicate = HKQuery.predicateForObjects(from: self)
        
        let startDateSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        var gpsDrops: TimeInterval = 0

        /// Query HealthKit's store
        let query = HKSampleQuery(sampleType: distanceType, predicate: workoutPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: [startDateSort]) {
            
            (sampleQuery, results, error) -> Void in
            
            guard let distanceSamples = results as? [HKQuantitySample], !distanceSamples.isEmpty else {
                subject.send(paces)
                subject.send(completion: .finished)
                return
            }
            
            /// GPS might take some time to "warm up" and receive a usable connection since the user presses start.
            /// This is calculated by obtaining the difference of the workout's startDate and the startDate of the first location sample
            let initialDrift = distanceSamples[0].startDate.timeIntervalSince(self.startDate)
            
            gpsDrops += initialDrift
            
            /// Values will be added progressively until they fill a whole kilometer
            /// For example, as it reaches 1.004,5 meters there are 4,5 meters that have to be left for the next round.
            var meters = 0.00
            
            /// Left-over duration used when a complete kilometer is reached
            var addedDuration = 0.0
            
            // Time where the current interval has started
            var splitIntervalStart = distanceSamples[0].startDate + initialDrift
            
            /// Iterate through the [HKQuantitySample] array. It will be samples with distances in small meter samples.
            /// Trick is to stack them up progresively until they stack a full kilometre
            for (index, element) in distanceSamples.enumerated() {
                
                if index > 1 {
                    
                    if distanceSamples[index].startDate != distanceSamples[index - 1].endDate {
                        
                        gpsDrops += distanceSamples[index].startDate.timeIntervalSince(distanceSamples[index-1].endDate)
                    }
                }
                
                addedDuration += element.startDate.distance(to: element.endDate)
                meters +=  element.quantity.doubleValue(for: HKUnit.meter())
                
                /// Finished processing a full kilometre
                if meters >= 1000 {

                    addedDuration = Double(element.endDate.timeIntervalSince(splitIntervalStart)) - gpsDrops
                    
                    /// seconds / meters
                    let pace = Double(addedDuration / meters)
                    
                    /// Calculate the excess of meters that are over an exact kilometer
                    let remainder = meters.truncatingRemainder(dividingBy: 1000)
                    
                    let remainerDuration: TimeInterval = remainder * pace
                    
                    /// Removed the extra meters from 100x.x meters
                    addedDuration -= remainerDuration
                    
                    splitIntervalStart = distanceSamples[index].endDate.addingTimeInterval(-1 * remainerDuration)
                    
                    
                    let metadata: [String: Any] = [
                        
                        "_HKPrivateMetadataSplitActiveDurationQuantity": HKQuantity(unit: HKUnit.second(), doubleValue: addedDuration),
                        "_HKPrivateMetadataSplitDistanceQuantity" : HKQuantity(unit: HKUnit.meter(), doubleValue: meters - remainder),
                        "_HKPrivateMetadataSplitMeasuringSystem": 1
                    ]
                    
//                    paces.append(Pace(meters: meters - remainder, duration: addedDuration))
                    paces.append(HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: splitIntervalStart, duration: addedDuration), metadata: metadata))
                    
                    meters = remainder
                    addedDuration = remainerDuration
                    
                    gpsDrops = 0
                }
                
                /// Penultimate sample
                if (distanceSamples.count - 1 ) == index {
                    
                    let metadata: [String: Any] = [
                        
                        "_HKPrivateMetadataSplitActiveDurationQuantity": HKQuantity(unit: HKUnit.second(), doubleValue: addedDuration),
                        "_HKPrivateMetadataSplitDistanceQuantity" : HKQuantity(unit: HKUnit.meter(), doubleValue: meters),
                        "_HKPrivateMetadataSplitMeasuringSystem": 1
                    ]
                    
                    paces.append(HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: splitIntervalStart, duration: addedDuration), metadata: metadata))
                }
            }
            
            subject.send(paces)
            subject.send(completion: .finished)
        }
    
        HKHealthStore().execute(query)
        
        return subject.setFailureType(to: HKCombineError.self).eraseToAnyPublisher()
    }
}

/// Relevant data from a HKWorkout including samples
public struct HKCWorkoutDetails: Hashable, Identifiable {
    
    public let id = UUID()
    /// The actual workout
    public let workout: HKWorkout
    /// A sorted array of location samples, across all HKWorkoutRoutes that are part of the workout
    public let locations: [CLLocation]
    /// A sorted array of heartrate samples taken during the workout
    public let heartRate: [HKQuantitySample]
    
    public init(workout: HKWorkout, locations: [CLLocation], heartRate: [HKQuantitySample]) {
        self.workout = workout
        self.locations = locations
        self.heartRate = heartRate
    }
}

private extension HKWorkoutRoute {
    
    /// Query the `HKWorkoutRoute` associated with an exercise
    /// Emits an array of `[CLLocation]` if it succeeds
    var locationsSubject: PassthroughSubject<[CLLocation], HKCombineError> {
        
        let subject = PassthroughSubject<[CLLocation], HKCombineError>()

        var workoutLocations: [CLLocation] = []
        
        let query = HKWorkoutRouteQuery(route: self) { (query, locations, done, error) in
            
            guard error == nil else {
                subject.send(completion: .failure(.upstream(error: error!)))
                return
            }
            
            /// If more batches of locations are coming add them to the array
            workoutLocations.append(contentsOf: locations ?? [])
            
            /// Once no more location batches have to be returned the publisher
            /// will be terminated after sending the finished array of locations
            if done {
                subject.send(workoutLocations)
                subject.send(completion: .finished)
            }
        }
        
        HKHealthStore().execute(query)
        
        return subject
    }
}

extension HKHealthStore: HKHealthStoreCombine {
    
    /// Perform statistical calculations over a set of samples
    /// - Parameters:
    ///   - type: Type of sample to search for. Must be an instance of `HKQuantityType`
    ///   - options: Options specified for the query
    ///   - startDate: Start date range for the query
    ///   - endDate: End date range for the query
    ///   - limit: Number of samples to be returned, defaults to `HKObjectQueryNoLimit`
    /// - Returns: Returns a publisher that publishes downstream the query result
    public func statistic(for type: HKQuantityType, with options: HKStatisticsOptions, from startDate: Date, to endDate: Date, _ limit: Int = HKObjectQueryNoLimit) -> AnyPublisher<HKStatistics, HKCombineError> {
        
        let subject = PassthroughSubject<HKStatistics, HKCombineError>()
        
        let predicate = HKStatisticsQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options, completionHandler: { (query, statistics, error) in
            
            guard error == nil else {
                subject.send(completion: .failure(HKCombineError.upstream(error: error!)))
                return
            }
            
            subject.send(statistics!)
            subject.send(completion: .finished)
        })
        
        self.execute(query)
        
        return subject.eraseToAnyPublisher()
    }
    
    /// General query that returns a snapshot of all the matching samples in the HealthKit store
    /// - Parameters:
    ///   - sample: HKQuantity sample to query.
    ///   - start: Start range of the sample query.
    ///   - end: End range of the sample query.
    ///   - limit: Integer limiting the number of samples to be returned.
    /// - Returns: A publisher containing an array of the requested samples.
    public func get<T>(sample: T, start: Date, end: Date, limit: Int = HKObjectQueryNoLimit) -> AnyPublisher<[HKQuantitySample], HKCombineError> where T: HKObjectType {
        
        let subject = PassthroughSubject<[HKQuantitySample], HKCombineError>()
        
        let sampleType = HKSampleType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: sample.identifier))!

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        
        let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: limit, sortDescriptors: nil, resultsHandler: { (query, samples, error) in
            
            let samples = samples as? [HKQuantitySample] ?? []
            
            subject.send(samples)
            subject.send(completion: .finished)
        })
        
        self.execute(query)
        
        return subject.eraseToAnyPublisher()
    }
    
    /// Requests permission to save and read the specified data types
    /// - Parameters:
    ///   - toShare: Set containing the data types to share.
    ///   - toRead: Set containing the data types to read.
    /// - Returns: A publisher that emits a `Bool` when the authorization process finishes
    public func requestAuthorization(toShare: Set<HKSampleType>?, toRead: Set<HKSampleType>?) -> AnyPublisher<Bool, HKCombineError> {
        
        let subject = PassthroughSubject<Bool, HKCombineError>()
        
        /// - `Bool`: Indicates whether the request was processed successfully. Doesn't indicate whether the
        ///          permission was actually granted.
        /// - `Error`:  `nil` if an error hasn't ocurred
        let callback: (Bool, Error?) -> () = { result, error in
            
            guard error == nil else {
                return subject.send(completion: .failure(.upstream(error: error!)))
            }
            
            subject.send(result)
            subject.send(completion: .finished)
        }
        
        guard HKHealthStore.isHealthDataAvailable() else {
            callback(false, nil)
            return subject.eraseToAnyPublisher()
        }
        
        self.requestAuthorization(toShare: toShare, read: toRead) { (result, error) in
            /// Won't be called until the system's HealthKit permission has ended
            callback(result, error)
        }
        
        return subject.eraseToAnyPublisher()
    }
    
    /// Checks whether the system presents the user with a permission sheet if your app requests authorization for the provided types.
    /// - Parameters:
    ///   - toShare: Set containing the data types to share.
    ///   - toRead: Set containing the data types to read.
    /// - Returns: `true` if it needs to request permissions for the given `types`, otherwise `false`.
    public func needsAuthorization(toShare: Set<HKSampleType>, toRead: Set<HKSampleType>) -> AnyPublisher<Bool, HKCombineError> {
        
        let subject = PassthroughSubject<Bool, HKCombineError>()
        
        let callback: (HKAuthorizationRequestStatus, Error?) -> () = { result, error in
            
            guard error == nil else {
                subject.send(completion: .failure(HKCombineError.upstream(error: error!)))
                return
            }
            
            subject.send(result == .shouldRequest)
            subject.send(completion: .finished)
        }
        
        guard HKHealthStore.isHealthDataAvailable() else {
            return Fail(error: HKCombineError.noHKAvailable).eraseToAnyPublisher()
        }
        
        getRequestStatusForAuthorization(toShare: toShare , read: toRead) { (result, error) in
            callback(result, error)
        }
        
        return subject.eraseToAnyPublisher()
    }
    
    
    /// Query workouts from a type in a date range
    /// - Parameters:
    ///   - type: Workout activity type to query
    ///   - startDate: Start date range to perform the query
    ///   - endDate: End date range to perform the query
    ///   - limit: Limits the number of values to be returned, defaults to `HKObjectQueryNoLimit`
    /// - Returns: Publisher that emits an array of `HKWorkout`.
    public func workouts(type: HKWorkoutActivityType, from startDate: Date, to endDate: Date, limit: Int = HKObjectQueryNoLimit) -> AnyPublisher<[HKWorkout], HKCombineError> {
        
        let subject = PassthroughSubject<[HKWorkout], HKCombineError>()
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let workoutPredicate = HKQuery.predicateForWorkouts(with: type)
        
        let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictEndDate, .strictStartDate])
        
        let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [workoutPredicate, datePredicate])
        
        let query = HKSampleQuery(sampleType: .workoutType(),
                                  predicate: compoundPredicate,
                                  limit: limit,
                                  sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            
            guard error == nil else {
                return subject.send(completion: .failure(HKCombineError.upstream(error: error!)))
            }
            
            guard let workouts = samples as? [HKWorkout] else {
                subject.send(completion: .failure(HKCombineError.noWorkoutsFound))
                return
            }
            
            subject.send(workouts)
            subject.send(completion: .finished)
        }
        
        self.execute(query)
        
        return subject.eraseToAnyPublisher()
    }
    
    
    /// Given a `HKWorkout` retrieve heart rate and `HKWorkoutRoute` values in a `HKCWorkoutDetails` containing both of them.
    /// - Parameter workout: `HKWorkout` to get the information from
    /// - Returns: Publisher that emits a single `HKCWorkouDetails` object with the associated data
    fileprivate func workoutDetails(_ workout: HKWorkout) -> AnyPublisher<HKCWorkoutDetails, HKCombineError> {
        return workout.workoutWithDetails
    }
      
    /// Query workout samples
    /// - Parameters:
    ///   - type: `HKWorkoutActivityType` to query workouts for
    ///   - limit: `Int` to limit the number of workouts to be returned, defaults to `HKObjectQueryNoLimit
    /// - Returns: Publisher that emits an array of `HWorkout`
    public func workouts(type: HKWorkoutActivityType, _ limit: Int = HKObjectQueryNoLimit) -> AnyPublisher<[HKWorkout], HKCombineError> {
        let subject = PassthroughSubject<[HKWorkout], HKCombineError>()
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                              ascending: false)
        
        let workoutPredicate = HKQuery.predicateForWorkouts(with: type)
        
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                  predicate: workoutPredicate,
                                  limit: limit,
                                  sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            
            guard error == nil else {
                subject.send(completion: .failure(HKCombineError.upstream(error: error!)))
                return
            }
            guard let workouts = samples as? [HKWorkout] else {
                subject.send(completion: .failure(HKCombineError.noWorkoutsFound))
                return
            }
            
            subject.send(workouts)
            subject.send(completion: .finished)
        }
        
        self.execute(query)
        
        return subject.eraseToAnyPublisher()
    }
}
