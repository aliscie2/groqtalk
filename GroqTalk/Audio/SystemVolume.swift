import CoreAudio

enum SystemVolume {
    private static var saved: Float?
    private static let lock = NSLock()

    static func duck(to level: Float) {
        lock.lock(); defer { lock.unlock() }
        guard let device = defaultOutputDevice() else { return }
        if saved == nil { saved = currentVolume(device) }
        setVolume(device, level)
    }

    static func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let device = defaultOutputDevice(), let s = saved else { return }
        setVolume(device, s)
        saved = nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func currentVolume(_ device: AudioObjectID) -> Float {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var volume = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return 1.0
    }

    private static func setVolume(_ device: AudioObjectID, _ volume: Float) {
        var v = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(device, &addr) {
                AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v)
            }
        }
    }
}
