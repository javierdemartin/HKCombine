![platforms](https://img.shields.io/badge/platforms-iOS-lightgrey)
![platforms](https://img.shields.io/badge/platforms-watchOS-lightgrey)
![code-size](https://img.shields.io/github/languages/code-size/javierdemartin/HKCombine?style=plastic)


# HKCombine

Combine-based wrapper to perform HealthKit related queries.

My app, [Singlet](https://apps.apple.com/app/id1545746941), makes full use of this Swift Package. 

### Installation

Add the repository link as a dependency on Xcode from File, Swift Packages & Add Package Dependency...

### Usage

This [package](https://github.com/apple/swift-package-manager/blob/main/Documentation/Usage.md) makes extensive use of the [Combine](https://developer.apple.com/documentation/combine#) framework.

<details>
 <summary>Check if the device needs to request HealthKit authorization.</summary>

```swift
HKHealthStore()
    .needsAuthorization(for: TYPES_TO_QUERY, toShare: false, toRead: true)
    .replaceError(with: false)
    .sink(receiveValue: { needsAuthorization in
        
        /// Perform an action based on the result
        requestPermissionButtonEnabled = !needsAuthorization
        
    }).store(in: &cancellableBag)
```
</details>

<details>
 <summary>Request permission to HealthKit for the given types. </summary>

```swift
HKHealthStore()
    .requestAuthorization(for: TYPES_TO_QUERY, toShare: false, toRead: true)
    .replaceError(with: false)
    .sink(receiveValue: { finished in
        
        /// Finish the authorization process
        presentMainScreen = true
    }).store(in: &cancellableBag)
```

</details>

<details>
 <summary>Query HealthKit samples.</summary>

```swift
HKHealthStore()
    .get(sample: SAMPLE_TYPE, start: START_RANGE, end: END_RANGE)
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: { subscription in
        /// Do something at the subscriber's end of life or error
    }, receiveValue: { samples in
        /// Save samples or do something with them
    }).store(in: &cancellableBag)
```

</details>

<details>
 <summary>Query HKWorkout with all the associated heart rate and location data.</summary>
 
 You can also query for a number of samples instead of using a `Date` range.
 
 Bear in mind that this is an expensive request as it requests both heart rate data and the workout's route from every requested HKWorkout.

```swift

var samples: [HKCWorkoutDetails] = []

HKHealthStore()
    .workouts(type: .running, from: START_RANGE, to: END_RANGE)
    .flatMap({ $0.publisher })
    .flatMap({ $0.workoutWithDetails })
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: { comp in
        switch comp {
        case .finished:
            /// `samples` contains all the data asked for
        case .failure(_):
            /// Act on the error
        }
    }, receiveValue: { details in
        samples.append(details)
    })
    .store(in: &cancellableBag)
```

</details>

<details>
 <summary>HKStatisticQuery</summary>
 
 The gist of this is to replace the possible error that might surface if the queried sample doesn't have permissions for it with a `nil`, or whatever suits your purpose, before continuing.

```swift

HKHealthStore()
    .statistic(for: HKObjectType.quantityType(forIdentifier: .restingHeartRate)!, with: .discreteAverage, from: Date().startOfMonth!, to: Date())
    .map({ $0.averageQuantity()?.doubleValue(for: UserUnits.shared().heartCountUnits) })
    .replaceError(with: nil)
    .assertNoFailure()
    .receive(on: DispatchQueue.main)
    .assign(to: &$VARIABLE)
```

</details>

<details>
 <summary>Splits/Paces from a HKWorkout</summary>
 
 If the `HKWorkout` you're querying has been recorded from an Apple Watch using the native Workouts.app this is straightforward.

```swift

workout.appleWatchPaces
    .receive(on: DispatchQueue.main)
    .replaceError(with: []) 
    .sink(receiveCompletion: { sub in
        
        switch sub {
        
        case .finished:
            break
        case .failure(_):
            fatalError()
        }
    },receiveValue: { events in
        
        /// Work with the received `HKWorkoutEvents`
        
    }).store(in: &bag)
```

There are other times when you want to query paces from an Apple Watch if it exists and default to manual calculations if it fails or they don't exist. This requires access to query `.distanceWalkingRunning` samples.

**NOTE**: These manual calculations, `splits` might have some errors as this is an algorithm where some issues might appear.

**NOTE 2**: Apps like Strava might not produce reliable calculations by the way the save data on `HealthKit`. As far as I know there is no workaround around this. If you have a better solution for this feel free to open a [pull request](https://github.com/javierdemartin/HKCombine/pulls).

```swift

workout.appleWatchPaces
    .receive(on: DispatchQueue.main)
    .replaceError(with: [])
    .flatMap({ applePaces -> AnyPublisher<[HKWorkoutEvent], Error> in
        
        if applePaces.isEmpty {
            return workout.workout.splits
        } else {
            return Just(applePaces).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
    })
    
    .sink(receiveCompletion: { sub in
        
        switch sub {
        
        case .finished:
            break
        case .failure(_):
            fatalError()
        }
    },receiveValue: { events in
        
        /// Work with the `HKWorkoutEvents`
        
    }).store(in: &bag)
```

</details>


### Disclaimers

Strava
