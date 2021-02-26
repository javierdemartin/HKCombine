![platforms](https://img.shields.io/badge/platforms-iOS-lightgrey)
![code-size](https://img.shields.io/github/languages/code-size/javierdemartin/HKCombine?style=plastic)


# HKCombine

Combine-based wrapper to perform related queries.

### Installation

### Usage

This [package](https://github.com/apple/swift-package-manager/blob/main/Documentation/Usage.md) makes extensive use of the [Combine](https://developer.apple.com/documentation/combine#) framework.


<details>
 <summary>Check if the device needs to request HealthKit authorization.</summary>

```swift
HKHealthStore()
    .needsToAuthorize(types: TYPES_TO_QUERY, toShare: false, toRead: true)
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
HKHealthStore().authorize(types: TYPES_TO_QUERY, toShare: false, toRead: true)
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
HKHealthStore().authorize(types: TYPES_TO_QUERY, toShare: false, toRead: true)
    .replaceError(with: false)
    .sink(receiveValue: { finished in
        
        /// Finish the authorization process
        presentMainScreen = true
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
