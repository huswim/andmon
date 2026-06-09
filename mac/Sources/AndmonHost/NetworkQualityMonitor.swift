import Foundation

final class NetworkQualityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    
    // Configurable/User limits
    private(set) var maxBitrate: Int = 12_000_000 // default 12 Mbps
    let minBitrate: Int = 4_000_000  // 4 Mbps
    
    // Current state
    private(set) var effectiveBitrate: Int = 12_000_000
    private(set) var fecGroupSize: Int = 5
    private(set) var fecType: Int = 1 // 1 = XOR
    private(set) var packetLossRate: Double = 0.0
    private(set) var rttMs: Double = 0.0
    private(set) var abrMode: String = "Stable"
    
    // Stability tracking
    private var lastBackoffTime = Date()
    private var lastAdjustmentTime = Date()
    private var stablePeriodStart = Date()
    
    var onQueuePurgeTriggered: (() -> Void)?
    var onBitrateChanged: ((Int) -> Void)?
    var onFecGroupSizeChanged: ((Int) -> Void)?
    var onPacingIntervalChanged: ((UInt32) -> Void)?
    
    func updateMetrics(rttMs: Double, packetLossRate: Double, throughputBytesPerSec: Int) {
        lock.withLock {
            self.rttMs = rttMs
            self.packetLossRate = packetLossRate
            
            let now = Date()
            var changedBitrate = false
            var changedFec = false
            
            // 1. Back-off (Aggressive Congestion Avoidance)
            if packetLossRate > 0.15 || rttMs > 100.0 {
                // Severe congestion: Drop bitrate by 50% immediately and lock FEC to high protection
                if now.timeIntervalSince(lastBackoffTime) >= 1.0 {
                    let oldBitrate = effectiveBitrate
                    effectiveBitrate = max(minBitrate, Int(Double(effectiveBitrate) * 0.5))
                    
                    let oldFec = fecGroupSize
                    fecGroupSize = 3
                    
                    abrMode = "Severe Congestion Backoff"
                    lastBackoffTime = now
                    lastAdjustmentTime = now
                    stablePeriodStart = now
                    
                    if oldBitrate != effectiveBitrate { changedBitrate = true }
                    if oldFec != fecGroupSize { changedFec = true }
                    
                    // Trigger immediate queue purge
                    onQueuePurgeTriggered?()
                }
            } else if packetLossRate > 0.03 || rttMs > 30.0 {
                // Moderate congestion: Drop bitrate by 30%
                if now.timeIntervalSince(lastBackoffTime) >= 1.0 {
                    let oldBitrate = effectiveBitrate
                    effectiveBitrate = max(minBitrate, Int(Double(effectiveBitrate) * 0.7))
                    
                    let oldFec = fecGroupSize
                    fecGroupSize = max(3, fecGroupSize - 1)
                    
                    abrMode = "Backing Off"
                    lastBackoffTime = now
                    lastAdjustmentTime = now
                    stablePeriodStart = now
                    
                    if oldBitrate != effectiveBitrate { changedBitrate = true }
                    if oldFec != fecGroupSize { changedFec = true }
                    
                    // Trigger immediate queue purge
                    onQueuePurgeTriggered?()
                }
            }
            // 2. Ramp-up (Two-stage Fast-Ramp)
            else if packetLossRate < 0.005 && rttMs < 15.0 {
                // Check stability period (>= 5 seconds)
                if now.timeIntervalSince(stablePeriodStart) >= 5.0 && now.timeIntervalSince(lastAdjustmentTime) >= 5.0 {
                    let oldBitrate = effectiveBitrate
                    let oldFec = fecGroupSize
                    
                    if effectiveBitrate < Int(Double(maxBitrate) * 0.7) {
                        // Fast-ramp (Slow Start phase)
                        effectiveBitrate = min(maxBitrate, effectiveBitrate + 3_000_000)
                        abrMode = "Ramping Up (Fast)"
                    } else {
                        // Gradual recovery phase
                        effectiveBitrate = min(maxBitrate, effectiveBitrate + 1_000_000)
                        abrMode = "Ramping Up (Gradual)"
                    }
                    
                    fecGroupSize = min(10, fecGroupSize + 1)
                    
                    lastAdjustmentTime = now
                    
                    if oldBitrate != effectiveBitrate { changedBitrate = true }
                    if oldFec != fecGroupSize { changedFec = true }
                    
                    if effectiveBitrate == maxBitrate {
                        abrMode = "Stable"
                    }
                }
            } else {
                // Stable conditions but not yet ready to increase
                stablePeriodStart = now
            }
            
            // Adjust UDP Pacing interval dynamically based on current throughput / bitrate
            // If bitrate is high, pacing should be lower (faster sending).
            // - >= 8Mbps: 100 microseconds
            // - 4Mbps to 8Mbps: 200 microseconds
            // - < 4Mbps: 500 microseconds
            let pacing: UInt32
            if effectiveBitrate >= 8_000_000 {
                pacing = 100
            } else if effectiveBitrate >= 4_000_000 {
                pacing = 200
            } else {
                pacing = 500
            }
            onPacingIntervalChanged?(pacing)
            
            // Trigger callbacks outside the lock
            let newBitrate = effectiveBitrate
            let newFec = fecGroupSize
            
            if changedBitrate {
                DispatchQueue.global().async { [weak self] in
                    self?.onBitrateChanged?(newBitrate)
                }
            }
            if changedFec {
                DispatchQueue.global().async { [weak self] in
                    self?.onFecGroupSizeChanged?(newFec)
                }
            }
        }
    }
    
    func setMaxBitrate(_ newMax: Int) {
        lock.withLock {
            self.maxBitrate = newMax
            if self.effectiveBitrate > newMax {
                self.effectiveBitrate = newMax
                self.abrMode = "Stable"
                let b = self.effectiveBitrate
                DispatchQueue.global().async { [weak self] in
                    self?.onBitrateChanged?(b)
                }
            }
        }
    }
    
    func reset(initialMaxBitrate: Int) {
        lock.withLock {
            self.maxBitrate = initialMaxBitrate
            // Start at a safe initial bitrate (min 10 Mbps, maxBitrate) to avoid flooding the network on start
            self.effectiveBitrate = min(10_000_000, initialMaxBitrate)
            self.fecGroupSize = 5
            self.fecType = 1
            self.packetLossRate = 0.0
            self.rttMs = 0.0
            self.abrMode = "Stable"
            let now = Date()
            self.lastBackoffTime = now
            self.lastAdjustmentTime = now
            self.stablePeriodStart = now
        }
    }
}
