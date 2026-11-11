// TEMPORARY AUDIT INSTRUMENTATION — delete this file and every `MicDiag.` call after the audit.
import Foundation

public final class MicDiag: @unchecked Sendable {
    public static let shared = MicDiag()

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.audiosync.diag", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let t0 = DispatchTime.now().uptimeNanoseconds

    // Stage 1 — AVAudioEngine tap thread
    private var tapCalls = 0, tapFramesMin = Int.max, tapFramesMax = 0, gatedTaps = 0
    private var tapIatMaxUs: UInt64 = 0, lastTapNs: UInt64 = 0
    // Stage 2 — audioQueue hand-off + 10ms framing
    private var queueLatMaxUs: UInt64 = 0, raceMismatches = 0, fifoHighWater = 0, framesPacked = 0
    // Stage 3 — netQueue send
    private var sendCalls = 0, sendBurstLt2ms = 0, sendErrors = 0, sendNoConn = 0
    private var payloadMin = Int.max, payloadMax = 0
    private var sendIatMaxUs: UInt64 = 0, lastSendNs: UInt64 = 0
    private var issuedTotal: UInt64 = 0, completedTotal: UInt64 = 0

    public static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.report() }
        t.resume()
        timer = t
    }

    public func onTap(frames: Int, gated: Bool) {
        let now = Self.nowNs()
        lock.lock(); defer { lock.unlock() }
        tapCalls += 1
        tapFramesMin = min(tapFramesMin, frames)
        tapFramesMax = max(tapFramesMax, frames)
        if gated { gatedTaps += 1 }
        if lastTapNs != 0 { tapIatMaxUs = max(tapIatMaxUs, (now &- lastTapNs) / 1_000) }
        lastTapNs = now
    }

    public func onHandoff(enqueuedNs: UInt64, bufferChangedAfterTapReturned: Bool) {
        let lat = (Self.nowNs() &- enqueuedNs) / 1_000
        lock.lock(); defer { lock.unlock() }
        queueLatMaxUs = max(queueLatMaxUs, lat)
        if bufferChangedAfterTapReturned { raceMismatches += 1 }
    }

    public func onFramePacked(fifoCount: Int) {
        lock.lock(); defer { lock.unlock() }
        framesPacked += 1
        fifoHighWater = max(fifoHighWater, fifoCount)
    }

    public func onMicSend(payloadBytes: Int) {
        let now = Self.nowNs()
        lock.lock(); defer { lock.unlock() }
        sendCalls += 1
        payloadMin = min(payloadMin, payloadBytes)
        payloadMax = max(payloadMax, payloadBytes)
        if lastSendNs != 0 {
            let iat = (now &- lastSendNs) / 1_000
            sendIatMaxUs = max(sendIatMaxUs, iat)
            if iat < 2_000 { sendBurstLt2ms += 1 }
        }
        lastSendNs = now
    }

    public func onSendIssued() { lock.lock(); issuedTotal &+= 1; lock.unlock() }
    public func onSendNoConnection() { lock.lock(); sendNoConn += 1; lock.unlock() }
    public func onSendCompleted(error: Error?) {
        lock.lock()
        completedTotal &+= 1
        let isFirstError = (error != nil && sendErrors == 0)
        if error != nil { sendErrors += 1 }
        lock.unlock()
        if isFirstError, let error { print("[DIAG iOS] first send error: \(error)") }
    }

    private func report() {
        func f1(_ us: UInt64) -> String { String(format: "%.1f", Double(us) / 1000.0) }
        func mn(_ v: Int) -> String { v == Int.max ? "-" : String(v) }
        lock.lock()
        let t = String(format: "%.1f", Double(Self.nowNs() &- t0) / 1e9)
        let line = "[DIAG iOS \(t)s] TAP calls=\(tapCalls) frames=\(mn(tapFramesMin))..\(tapFramesMax) iat_max=\(f1(tapIatMaxUs))ms gated=\(gatedTaps)"
            + " | HANDOFF q_lat_max=\(f1(queueLatMaxUs))ms RACE=\(raceMismatches) fifo_hw=\(fifoHighWater) packed=\(framesPacked)"
            + " | SEND calls=\(sendCalls) bytes=\(mn(payloadMin))..\(payloadMax) iat_max=\(f1(sendIatMaxUs))ms burst<2ms=\(sendBurstLt2ms)"
            + " err=\(sendErrors) noconn=\(sendNoConn) inflight=\(issuedTotal &- completedTotal)"
        tapCalls = 0; tapFramesMin = Int.max; tapFramesMax = 0; gatedTaps = 0; tapIatMaxUs = 0
        queueLatMaxUs = 0; raceMismatches = 0; fifoHighWater = 0; framesPacked = 0
        sendCalls = 0; sendBurstLt2ms = 0; sendErrors = 0; sendNoConn = 0
        payloadMin = Int.max; payloadMax = 0; sendIatMaxUs = 0
        lock.unlock()
        print(line)
    }
}
