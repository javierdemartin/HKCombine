import HealthKit
import Combine
import CoreLocation

public enum HKCombineError: Error {
    case noWorkoutEvents
    case errorHKQuantityTypeIdentifier
    case noSamples
    case noHKAvailable(error: Error?)
    case noRoutePointsFound
    case noWorkoutsFound
    case noPermission
}

extension HKWorkout {
    
    public var workoutWithDetails: AnyPublisher<HKWorkoutCombineDetails, Error> {
        
        let locationsSamplesPublisher = workoutRouteSubject.flatMap({ workoutRoute -> PassthroughSubject<[CLLocation], Error> in
            workoutRoute.locationsSubject
        })
//        .replaceEmpty(with: [])
        .scan([], { (locations, newLocations) -> [CLLocation] in
            locations + newLocations
        }).last()
        .map({ locationSamples -> [CLLocation] in
            locationSamples.sorted(by: { (loc1, loc2) -> Bool in
                loc1.timestamp <= loc2.timestamp
            })
        })
        
        /// Combine the
        return Publishers.CombineLatest(locationsSamplesPublisher, workoutHeartRateSubject)
            .map({ (locationSamples, heartRateSamples) -> HKWorkoutCombineDetails in
                HKWorkoutCombineDetails(workout: self, locations: locationSamples, heartRate: heartRateSamples)
            }).eraseToAnyPublisher()
    }
    
    /// Query a workout together with workout route samples
    private var workoutRouteSubject:  PassthroughSubject<HKWorkoutRoute, Error> {
        
        let subject = PassthroughSubject<HKWorkoutRoute, Error>()
        
        let workoutPredicate = HKQuery.predicateForObjects(from: self)
        
        let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: workoutPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { (query, routes, error) in
            
            guard let routes = routes as? [HKWorkoutRoute], error == nil else {
                subject.send(completion: .failure(error!))
                return
            }
            
            routes.forEach({ subject.send($0) })
            
            subject.send(completion: .finished)
        }
        
        HKHealthStore().execute(query)
        
        return subject
    }
    
    private var workoutHeartRateSubject: AnyPublisher<[HKQuantitySample], Error> {
        
        let subject = PassthroughSubject<[HKQuantitySample], Error>()
        
        let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        
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
    public var appleWatchPaces: AnyPublisher<[HKWorkoutEvent], Never> {
        
        guard let events = self.workoutEvents else {
            return [].publisher.eraseToAnyPublisher()
        }
        
        let filtered = events.filter({ $0.type == .segment })
        
        return Publishers.MergeMany(filtered.publisher).collect().eraseToAnyPublisher()
    }
    
    /// TODO: Do calculation of non apple watch paces
    /// https://stackoverflow.com/questions/33826972/healthkit-running-splits-in-kilometres-code-inaccurate-why
}

/// Relevant data from a HKWorkout including samples
public struct HKWorkoutCombineDetails: Hashable {
    
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
    var locationsSubject: PassthroughSubject<[CLLocation], Error> {
        
        let subject = PassthroughSubject<[CLLocation], Error>()

        var workoutLocations: [CLLocation] = []
        
        let query = HKWorkoutRouteQuery(route: self) { (query, locations, done, error) in
            
            guard error == nil else {
                subject.send(completion: .failure(error!))
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

private protocol HKHealthStoreCombine {
    
    func needsToAuthorize(types: Set<HKSampleType>, toShare: Bool, toRead: Bool) -> AnyPublisher<Bool, HKCombineError>
    
    func authorize(types: Set<HKSampleType>, toShare: Bool, toRead: Bool) -> AnyPublisher<Bool, HKCombineError>
    
    func workouts(type: HKWorkoutActivityType, _ limit: Int) -> AnyPublisher<[HKWorkout], Error>
    
    func workouts(type: HKWorkoutActivityType, from startDate: Date, to endDate: Date) -> AnyPublisher<[HKWorkout], Error>
    
    func workoutDetails(_ workout: HKWorkout) -> AnyPublisher<HKWorkoutCombineDetails, Error>
    
    func get<T>(sample: T, start: Date, end: Date, limit: Int) -> AnyPublisher<[HKQuantitySample], HKCombineError> where T: HKObjectType
}

extension HKHealthStore: HKHealthStoreCombine {
    
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
        
        let sampleQuery = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: limit, sortDescriptors: nil, resultsHandler: { (query, samples, error) in
            
            let samples = samples as? [HKQuantitySample] ?? []
            
            subject.send(samples)
            subject.send(completion: .finished)
        })
        
        HKHealthStore().execute(sampleQuery)
        
        return subject.eraseToAnyPublisher()
    }
    
    /// Requests permission to save and read the specified data types
    /// - Parameters:
    ///   - types: A set containing the data types to share or read.
    ///   - toShare: A `Bool` indicating if the `types` `Set` can create and save these data types to the HealthKit store.
    ///   - toRead: A `Bool` indicating if the `types` `Set` can read these data types to the HealthKit store.
    /// - Returns: A publisher that emits a `Bool` when the authorization process finishes
    public func authorize(types: Set<HKSampleType>, toShare: Bool = true, toRead: Bool = true) -> AnyPublisher<Bool, HKCombineError> {
        
        let subject = PassthroughSubject<Bool, HKCombineError>()
        
        let callback: (Bool, Error?) -> () = { result, error in
            
            guard error == nil else {
                return subject.send(completion: .failure(.noHKAvailable(error: error)))
            }
            
            subject.send(result)
            subject.send(completion: .finished)
        }
        
        guard HKHealthStore.isHealthDataAvailable() else {
            callback(false, nil)
            return subject.eraseToAnyPublisher()
        }
        
        HKHealthStore().requestAuthorization(toShare: toShare ? types : nil, read: toRead ? types : nil) { (result, error) in
            callback(result, error)
        }
        
        return subject.eraseToAnyPublisher()
    }
    
    public func workouts(type: HKWorkoutActivityType, from startDate: Date, to endDate: Date) -> AnyPublisher<[HKWorkout], Error> {
        
        let subject = PassthroughSubject<[HKWorkout], Error>()
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let workoutPredicate = HKQuery.predicateForWorkouts(with: type)
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        
        let compound = NSCompoundPredicate(andPredicateWithSubpredicates: [workoutPredicate, predicate])
        
        let query = HKSampleQuery(sampleType: .workoutType(),
                                  predicate: compound,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            guard error == nil else {
                return subject.send(completion: .failure(error!))
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
    
    
    fileprivate func workoutDetails(_ workout: HKWorkout) -> AnyPublisher<HKWorkoutCombineDetails, Error> {
        return workout.workoutWithDetails
    }
      
    /// Query workout samples
    /// - Parameters:
    ///   - type: `HKWorkoutActivityType` to query workouts for
    ///   - limit: `Int` to limit the number of workouts to be returned, defaults to `HKObjectQueryNoLimit
    /// - Returns: Publisher that emits an array of `HWorkout`
    public func workouts(type: HKWorkoutActivityType, _ limit: Int = HKObjectQueryNoLimit) -> AnyPublisher<[HKWorkout], Error> {
        let subject = PassthroughSubject<[HKWorkout], Error>()
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                              ascending: false)
        
        let workoutPredicate = HKQuery.predicateForWorkouts(with: type)
        
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                  predicate: workoutPredicate,
                                  limit: limit,
                                  sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            
            guard error == nil else {
                subject.send(completion: .failure(error!))
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
    
    
    /// <#Description#>
    /// - Parameters:
    ///   - types: <#types description#>
    ///   - toShare: <#toShare description#>
    ///   - toRead: <#toRead description#>
    /// - Returns: <#description#>
    public func needsToAuthorize(types: Set<HKSampleType>, toShare: Bool, toRead: Bool) -> AnyPublisher<Bool, HKCombineError> {
        
        let subject = PassthroughSubject<Bool, HKCombineError>()
        
        let callback: (HKAuthorizationRequestStatus, Error?) -> () = {
            result, error in
            
            guard error == nil else {
                subject.send(completion: .failure(HKCombineError.noHKAvailable(error: error)))
                return
            }
            
            subject.send(result == .shouldRequest)
            subject.send(completion: .finished)
        }
        
        guard HKHealthStore.isHealthDataAvailable() else {
            return Fail(error: HKCombineError.noHKAvailable(error: nil)).eraseToAnyPublisher()
        }
        
        getRequestStatusForAuthorization(toShare: toShare ? types : [] , read: toRead ? types : []) { (result, error) in
            callback(result, error)
        }
        
        return subject.eraseToAnyPublisher()
    }
}
