import Foundation

// Request only our app's metadata. No pixels, external app inspection, or writes.
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.dreamorosi.streamcam-controls.inspect"),
    object: nil, userInfo: nil, deliverImmediately: true)
