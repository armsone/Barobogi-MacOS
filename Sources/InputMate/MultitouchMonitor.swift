import Darwin
import Foundation

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTContactCallback = @convention(c) (
    Int32,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private typealias MTDeviceCreateDefaultFunction = @convention(c) () -> UnsafeMutableRawPointer?
private typealias MTRegisterCallbackFunction = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTUnregisterCallbackFunction = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTDeviceStartFunction = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias MTDeviceStopFunction = @convention(c) (UnsafeMutableRawPointer) -> Int32
private typealias MTDeviceReleaseFunction = @convention(c) (UnsafeMutableRawPointer) -> Void

private weak var activeMultitouchMonitor: MultitouchMonitor?

private let multitouchContactCallback: MTContactCallback = { _, touches, count, _, _ in
    guard let touches, count > 0 else {
        activeMultitouchMonitor?.handleFrame([])
        return 0
    }
    let typedTouches = touches.assumingMemoryBound(to: MTTouch.self)
    let values = Array(UnsafeBufferPointer(start: typedTouches, count: Int(count)))
    activeMultitouchMonitor?.handleFrame(values)
    return 0
}

final class MultitouchMonitor {
    enum MonitorError: LocalizedError {
        case frameworkUnavailable
        case missingSymbol(String)
        case trackpadUnavailable
        case startFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:
                "이 macOS 버전에서 멀티터치 프레임워크를 열 수 없습니다."
            case let .missingSymbol(name):
                "필요한 시스템 함수(\(name))를 찾을 수 없습니다."
            case .trackpadUnavailable:
                "내장 트랙패드를 찾을 수 없습니다."
            case let .startFailed(code):
                "트랙패드 감시를 시작하지 못했습니다. (오류 \(code))"
            }
        }
    }

    var onActivationTouch: (() -> Void)?

    private let lock = NSLock()
    private var activationRegion = ActivationRegion.default
    private var ignoredFingerIDs = Set<Int32>()
    private var activeFingerIDs = Set<Int32>()
    private var isArmed = false

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregisterCallback: MTUnregisterCallbackFunction?
    private var stopDevice: MTDeviceStopFunction?
    private var releaseDevice: MTDeviceReleaseFunction?

    var isRunning: Bool { device != nil }

    var hasActiveTouches: Bool {
        lock.withLock { !activeFingerIDs.isEmpty }
    }

    func start() throws {
        guard device == nil else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw MonitorError.frameworkUnavailable
        }

        do {
            let createDevice: MTDeviceCreateDefaultFunction = try loadSymbol("MTDeviceCreateDefault", from: handle)
            let register: MTRegisterCallbackFunction = try loadSymbol("MTRegisterContactFrameCallback", from: handle)
            let startDevice: MTDeviceStartFunction = try loadSymbol("MTDeviceStart", from: handle)
            let unregister: MTUnregisterCallbackFunction? = try? loadSymbol("MTUnregisterContactFrameCallback", from: handle)
            let stop: MTDeviceStopFunction? = try? loadSymbol("MTDeviceStop", from: handle)
            let release: MTDeviceReleaseFunction? = try? loadSymbol("MTDeviceRelease", from: handle)

            guard let device = createDevice() else {
                throw MonitorError.trackpadUnavailable
            }

            activeMultitouchMonitor = self
            register(device, multitouchContactCallback)
            let result = startDevice(device, 0)
            guard result == 0 else {
                unregister?(device, multitouchContactCallback)
                release?(device)
                activeMultitouchMonitor = nil
                throw MonitorError.startFailed(result)
            }

            frameworkHandle = handle
            self.device = device
            unregisterCallback = unregister
            stopDevice = stop
            releaseDevice = release
        } catch {
            dlclose(handle)
            throw error
        }
    }

    func stop() {
        guard let device else { return }
        lock.withLock {
            isArmed = false
            ignoredFingerIDs.removeAll()
            activeFingerIDs.removeAll()
        }
        unregisterCallback?(device, multitouchContactCallback)
        _ = stopDevice?(device)
        releaseDevice?(device)
        self.device = nil
        activeMultitouchMonitor = nil
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
        frameworkHandle = nil
    }

    func setActivationRegion(_ region: ActivationRegion) {
        lock.withLock { activationRegion = region }
    }

    func arm() {
        lock.withLock {
            ignoredFingerIDs = activeFingerIDs
            isArmed = true
        }
    }

    func disarm() {
        lock.withLock {
            isArmed = false
            ignoredFingerIDs.removeAll()
        }
    }

    fileprivate func handleFrame(_ touches: [MTTouch]) {
        var shouldActivate = false

        lock.withLock {
            let currentTouches = touches.filter { $0.state == 3 || $0.state == 4 }
            let currentIDs = Set(currentTouches.map(\.fingerID))
            ignoredFingerIDs.formIntersection(currentIDs)

            if isArmed {
                for touch in currentTouches where touch.state == 3 && !ignoredFingerIDs.contains(touch.fingerID) {
                    let point = NormalizedPoint(
                        x: Double(touch.normalizedVector.position.x),
                        y: Double(touch.normalizedVector.position.y)
                    )
                    if activationRegion.contains(point) {
                        isArmed = false
                        shouldActivate = true
                        break
                    }
                }
            }
            activeFingerIDs = currentIDs
        }

        if shouldActivate {
            DispatchQueue.main.async { [weak self] in
                self?.onActivationTouch?()
            }
        }
    }

    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw MonitorError.missingSymbol(name)
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
