import CoreAudio

/// AudioObject 프로퍼티 변경 알림을 클로저로 받는 작은 래퍼.
/// 인스턴스가 해제되면 리스너도 자동으로 제거된다.
final class PropertyListener {
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws {
        self.objectID = objectID
        self.address = PropertyAddress(selector, scope: scope, element: element)
        self.queue = queue
        self.block = { _, _ in handler() }

        var address = self.address
        let err = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard err == noErr else { throw AudioHardwareError(err) }
    }

    deinit {
        var address = self.address
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
