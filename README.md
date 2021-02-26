![platforms](https://img.shields.io/badge/platforms-iOS-lightgrey)
![platforms](https://img.shields.io/badge/platforms-watchOS-lightgrey)
![code-size](https://img.shields.io/github/languages/code-size/javierdemartin/HKCombine?style=plastic)


# HKCombine

Combine-based wrapper to perform HealthKit related queries.

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
