import SwiftUI

enum MoveAnimation {
    static let duration: TimeInterval = 0.35
    static let animation = Animation.timingCurve(0.2, 0.0, 0.8, 1.0, duration: duration)
}
