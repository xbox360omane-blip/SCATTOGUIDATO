import Foundation
import CoreMotion

/// Livella: inclinazione laterale (orizzonte) e verticale (verticali dritte).
final class MotionLevel: ObservableObject {
    @Published var roll: Double = 0    // gradi, 0 = telefono dritto
    @Published var pitch: Double = 0   // gradi, 0 = telefono perpendicolare al suolo

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            self.roll = atan2(g.x, -g.y) * 180 / .pi
            self.pitch = atan2(-g.z, sqrt(g.x * g.x + g.y * g.y)) * 180 / .pi
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
