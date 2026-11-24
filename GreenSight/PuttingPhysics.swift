import Foundation
import simd

struct PuttingPhysics: Sendable {
    struct Simulation {
        let path: [TrajectoryPoint]
        let minimumDistance: Double
        let arrivalSpeed: Double
        let holed: Bool
        let stayedOnSurface: Bool
    }

    let surface: GreenSurface
    let cup: SIMD2<Double>
    let stimpFeet: Double
    var timeStep = 0.008
    var maximumTime = 10.0

    var rollingDeceleration: Double {
        // USGA Stimpmeter release speed is approximately 6 ft/s. This converts
        // measured roll distance into a constant effective deceleration.
        let releaseSpeed = feetToMetres(6.0)
        return releaseSpeed * releaseSpeed / (2 * feetToMetres(stimpFeet))
    }

    func simulate(angle: Double, speed: Double, retainPath: Bool) -> Simulation {
        let direction = SIMD2<Double>(sin(angle), cos(angle))
        var position = SIMD2<Double>.zero
        var velocity = direction * speed
        var path: [TrajectoryPoint] = []
        var closest = simd_distance(position, cup)
        var closestSpeed = speed
        var holed = false
        var stayedOnSurface = true
        let cupRadius = 0.054
        let gravity = 9.80665
        var step = 0

        while Double(step) * timeStep < maximumTime, velocity.length > 0.025 {
            if retainPath, step.isMultiple(of: 5) {
                path.append(TrajectoryPoint(x: Float(position.x), y: Float(position.y), speed: Float(velocity.length)))
            }
            guard let grade = surface.gradientIfAvailable(at: position) else {
                stayedOnSurface = false
                break
            }
            let acceleration = -(5.0 / 7.0) * gravity * grade - rollingDeceleration * velocity.normalized
            let nextVelocity = velocity + acceleration * timeStep
            if simd_dot(nextVelocity, velocity) <= 0 { velocity = .zero } else { velocity = nextVelocity }
            position += velocity * timeStep

            let distance = simd_distance(position, cup)
            if distance < closest {
                closest = distance
                closestSpeed = velocity.length
            }
            if distance <= cupRadius, velocity.length <= 1.4 {
                holed = true
                closest = distance
                closestSpeed = velocity.length
                if retainPath {
                    path.append(TrajectoryPoint(x: Float(position.x), y: Float(position.y), speed: Float(velocity.length)))
                }
                break
            }
            if position.y > cup.y + 2 || abs(position.x) > max(3, cup.y) { break }
            step += 1
        }
        return Simulation(path: path, minimumDistance: closest, arrivalSpeed: closestSpeed,
                          holed: holed, stayedOnSurface: stayedOnSurface)
    }
}

struct TrajectoryOptimizer: Sendable {
    let physics: PuttingPhysics

    func solve() -> PuttSolution {
        struct Candidate {
            let angle: Double
            let speed: Double
            let score: Double
            let simulation: PuttingPhysics.Simulation
        }

        let directDistance = physics.cup.length
        let nominalSpeed = sqrt(2 * physics.rollingDeceleration * max(0.1, directDistance)) + 0.3
        var centreAngle = 0.0
        var centreSpeed = nominalSpeed
        var angleSpan = 28.0 * .pi / 180
        var speedSpan = max(0.8, nominalSpeed * 0.55)
        var best: Candidate?

        for pass in 0..<3 {
            let angleSteps = pass == 0 ? 41 : 25
            let speedSteps = pass == 0 ? 31 : 21
            for ai in 0..<angleSteps {
                let aFraction = Double(ai) / Double(angleSteps - 1) - 0.5
                let angle = centreAngle + 2 * angleSpan * aFraction
                for si in 0..<speedSteps {
                    let sFraction = Double(si) / Double(speedSteps - 1) - 0.5
                    let speed = max(0.25, centreSpeed + 2 * speedSpan * sFraction)
                    let simulation = physics.simulate(angle: angle, speed: speed, retainPath: false)
                    let arrivalPenalty = pow(max(0, simulation.arrivalSpeed - 0.9), 2) * 0.05
                    let supportPenalty = simulation.stayedOnSurface ? 0 : 1.0
                    let score = simulation.minimumDistance + arrivalPenalty + supportPenalty - (simulation.holed ? 0.2 : 0)
                    if score < (best?.score ?? .infinity) {
                        best = Candidate(angle: angle, speed: speed, score: score, simulation: simulation)
                    }
                }
            }
            centreAngle = best?.angle ?? centreAngle
            centreSpeed = best?.speed ?? centreSpeed
            angleSpan *= 0.25
            speedSpan *= 0.25
        }

        let selected = best ?? Candidate(angle: 0, speed: nominalSpeed, score: 99,
                                          simulation: physics.simulate(angle: 0, speed: nominalSpeed, retainPath: false))
        let final = physics.simulate(angle: selected.angle, speed: selected.speed, retainPath: true)
        let aimOffset = tan(selected.angle) * directDistance * 100
        let geometricConfidence = exp(-final.minimumDistance / 0.12)
        let supportConfidence = final.stayedOnSurface ? 1.0 : 0.25
        let confidence = (geometricConfidence * physics.surface.snapshot.coverage * supportConfidence).clamped(to: 0...1)
        return PuttSolution(
            launchAngleDegrees: selected.angle * 180 / .pi,
            launchSpeedMetresPerSecond: selected.speed,
            aimOffsetCentimetres: aimOffset,
            arrivalSpeedMetresPerSecond: final.arrivalSpeed,
            closestDistanceMetres: final.minimumDistance,
            holed: final.holed,
            confidence: confidence,
            path: final.path
        )
    }
}
