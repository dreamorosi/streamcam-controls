import Foundation

// Diagnostics never save pixels or change hardware settings. The optional
// cycle action is honored only by an explicitly launched inspection build.
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.dreamorosi.streamcam-controls.inspect"),
    object: CommandLine.arguments.dropFirst().first, userInfo: nil, deliverImmediately: true)
