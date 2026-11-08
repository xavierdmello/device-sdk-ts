// iOS side of LDMKTransportHIDModule: USB Ledgers over CCID, through CryptoTokenKit.
//
// iOS has no HID access for apps, but it does expose USB smart-card readers (CCID) through
// CryptoTokenKit. A Ledger app built with `ENABLE_USB_CCID = 1` shows up as a reader named
// e.g. "Ledger Nano S+", and the reader carries whole APDUs, so there is no HID framing here.
// The JS bridge contract (methods, events, result shapes) is the same as the Android module's.
//
// Notes:
// - Only Ledger apps with CCID enabled are visible. The dashboard has no CCID interface, so a
//   device appears once such an app is open and disappears when it is closed.
// - CryptoTokenKit doesn't expose USB VID/PID, so the model comes from the reader name.

import CryptoTokenKit
import Foundation
import React

@objc(LDMKTransportHIDModule)
final class LDMKTransportHIDModule: RCTEventEmitter {
  private static let discoveredDevicesEvent = "DiscoveredDevices"
  private static let deviceDisconnectedEvent = "DeviceDisconnected"
  private static let transportLogEvent = "TransportLog"
  private static let tag = "TransportHidModule"
  /// Same as the Android module: how long a session survives its card going away.
  private static let reconnectionTimeout: TimeInterval = 5

  private let queue = DispatchQueue(label: "com.ledger.devicesdk.transporthid")
  private var hasListeners = false
  private var activeScanCount = 0
  private var namesObservation: NSKeyValueObservation?
  private var readers: [String: Reader] = [:]
  private var sessions: [String: Session] = [:]
  private var lastEmittedReaders: [String]?

  override var methodQueue: DispatchQueue! { queue }
  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! {
    [Self.discoveredDevicesEvent, Self.deviceDisconnectedEvent, Self.transportLogEvent]
  }

  override func startObserving() { queue.async { self.hasListeners = true } }
  override func stopObserving() { queue.async { self.hasListeners = false } }

  override func invalidate() {
    queue.async {
      for session in Array(self.sessions.values) { self.terminate(session, notify: false) }
      self.namesObservation?.invalidate()
      self.namesObservation = nil
      self.readers.values.forEach { $0.stateObservation?.invalidate() }
      self.readers.removeAll()
    }
    super.invalidate()
  }

  // MARK: - Bridge methods (all run on `queue`)

  @objc(startScan:reject:)
  func startScan(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    log("debug", "[startScan] called")
    activeScanCount += 1
    if activeScanCount > 1 {
      log("debug", "[startScan] already scanning")
      resolve(nil)
      return
    }
    startTrackingReaders()
    lastEmittedReaders = nil
    emitDiscoveredDevices()
    resolve(nil)
  }

  @objc(stopScan:reject:)
  func stopScan(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    log("debug", "[stopScan] called, activeScanCount=\(activeScanCount)")
    // Reader tracking keeps running: open sessions need it to notice disconnections.
    activeScanCount = max(0, activeScanCount - 1)
    resolve(nil)
  }

  @objc(connectDevice:resolve:reject:)
  func connectDevice(
    _ uid: String,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    startTrackingReaders()
    guard let reader = readers[uid], let slot = reader.slot, slot.state == .validCard,
          let model = Self.model(forReaderName: uid) else {
      log("error", "[connectDevice] no Ledger app with CCID open on \(uid)")
      resolve(["success": false, "error": "DeviceNotFound"])
      return
    }
    openCard(on: slot) { card in
      guard let card else {
        self.log("error", "[connectDevice] session refused by \(uid)")
        resolve(["success": false, "error": "UnknownError: the Ledger refused the session"])
        return
      }
      let session = Session(id: UUID().uuidString, readerName: uid, card: card)
      self.sessions[session.id] = session
      self.log("info", "[connectDevice] connected to \(uid), session \(session.id)")
      resolve([
        "success": true,
        "sessionId": session.id,
        "ledgerDevice": ["name": model.name, "usbProductIdMask": model.usbProductIdMask],
        "deviceName": uid,
      ])
    }
  }

  @objc(disconnectDevice:resolve:reject:)
  func disconnectDevice(
    _ sessionId: String,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    if let session = sessions[sessionId] { terminate(session, notify: false) }
    resolve(nil)
  }

  @objc(sendApdu:apdu:triggersDisconnection:abortTimeout:resolve:reject:)
  func sendApdu(
    _ sessionId: String,
    apdu apduBase64: String,
    triggersDisconnection: Bool,
    abortTimeout: NSNumber,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    guard let session = sessions[sessionId] else {
      resolve(Self.failure("DeviceNotFound"))
      return
    }
    guard let apdu = Data(base64Encoded: apduBase64), apdu.count >= 4 else {
      resolve(Self.failure("ApduNotWellFormatted"))
      return
    }
    let request = Request(
      apdu: apdu,
      triggersDisconnection: triggersDisconnection,
      abortTimeoutMs: abortTimeout.doubleValue,
      resolve: resolve
    )
    if session.inFlight != nil || session.queued != nil {
      resolve(Self.failure("DeviceBusy"))
    } else if session.card == nil {
      // Waiting for the reader to come back: send once it does, like the Android module.
      session.queued = request
    } else {
      transmit(request, on: session)
    }
  }

  // MARK: - Readers

  private final class Reader {
    let name: String
    var slot: TKSmartCardSlot?
    var stateObservation: NSKeyValueObservation?
    init(name: String) { self.name = name }
  }

  private func startTrackingReaders() {
    guard namesObservation == nil else { return }
    guard let manager = TKSmartCardSlotManager.default else {
      log("error", "TKSmartCardSlotManager.default is nil: smart-card access isn't available")
      return
    }
    namesObservation = manager.observe(\.slotNames, options: [.initial, .new]) { [weak self] manager, _ in
      let names = manager.slotNames
      self?.queue.async { self?.readerNamesChanged(names, manager: manager) }
    }
  }

  private func readerNamesChanged(_ names: [String], manager: TKSmartCardSlotManager) {
    let ledgerNames = Set(names.filter { $0.hasPrefix("Ledger") })
    for name in readers.keys where !ledgerNames.contains(name) {
      log("info", "reader removed: \(name)")
      readers.removeValue(forKey: name)?.stateObservation?.invalidate()
      cardWentAway(readerName: name)
    }
    for name in ledgerNames where readers[name] == nil {
      log("info", "reader added: \(name)")
      let reader = Reader(name: name)
      readers[name] = reader
      manager.getSlot(withName: name) { [weak self] slot in
        self?.queue.async {
          guard let self, self.readers[name] === reader, let slot else { return }
          reader.slot = slot
          reader.stateObservation = slot.observe(\.state, options: [.initial, .new]) { [weak self] slot, _ in
            let state = slot.state
            self?.queue.async { self?.readerStateChanged(name, state: state) }
          }
        }
      }
    }
    emitDiscoveredDevices()
  }

  private func readerStateChanged(_ name: String, state: TKSmartCardSlot.State) {
    log("debug", "reader \(name) state \(state.rawValue)")
    if state == .validCard {
      cardCameBack(readerName: name)
    } else if state != .probing {
      cardWentAway(readerName: name)
    }
    emitDiscoveredDevices()
  }

  /// A reader counts as a device only while a CCID-enabled Ledger app is open on it.
  private func emitDiscoveredDevices() {
    guard activeScanCount > 0 else { return }
    let names = readers.values
      .filter { $0.slot?.state == .validCard && Self.model(forReaderName: $0.name) != nil }
      .map(\.name)
      .sorted()
    guard names != lastEmittedReaders else { return }
    lastEmittedReaders = names
    let devices: [[String: Any]] = names.compactMap { name in
      guard let model = Self.model(forReaderName: name) else { return nil }
      return [
        "uid": name,
        "name": name,
        "ledgerDevice": ["name": model.name, "usbProductIdMask": model.usbProductIdMask],
      ]
    }
    send(Self.discoveredDevicesEvent, devices)
  }

  /// Reader names look like "Ledger Nano S+". USB product ID masks match the Android module's.
  static func model(forReaderName readerName: String) -> (name: String, usbProductIdMask: String)? {
    let name = readerName.lowercased()
    guard name.hasPrefix("ledger") else { return nil }
    if name.contains("nano s+") || name.contains("nano s plus") || name.contains("nano sp") {
      return ("Nano S Plus", "0x50")
    }
    if name.contains("nano x") { return ("Nano X", "0x40") }
    if name.contains("stax") { return ("Ledger Stax", "0x60") }
    if name.contains("flex") { return ("Ledger Flex", "0x70") }
    if name.contains("apex") { return ("Ledger Apex", "0x80") }
    if name.contains("nano s") { return ("Nano S", "0x10") }
    return nil
  }

  // MARK: - Sessions

  private struct Request {
    let apdu: Data
    let triggersDisconnection: Bool
    let abortTimeoutMs: Double
    let resolve: RCTPromiseResolveBlock
  }

  private final class Session {
    let id: String
    let readerName: String
    /// nil while waiting for the reader to come back.
    var card: TKSmartCard?
    var inFlight: InFlight?
    var queued: Request?
    var reconnectionTimer: DispatchWorkItem?
    init(id: String, readerName: String, card: TKSmartCard) {
      self.id = id
      self.readerName = readerName
      self.card = card
    }
  }

  /// A transmit the card hasn't answered yet. The promise can be answered earlier (abort
  /// timeout, disconnection); the card stays busy until it really replies.
  private final class InFlight {
    private var resolve: RCTPromiseResolveBlock?
    init(_ resolve: @escaping RCTPromiseResolveBlock) { self.resolve = resolve }
    func answer(_ result: [String: Any]) {
      resolve?(result)
      resolve = nil
    }
  }

  private func openCard(on slot: TKSmartCardSlot, completion: @escaping (TKSmartCard?) -> Void) {
    guard let card = slot.makeSmartCard() else {
      completion(nil)
      return
    }
    card.beginSession { [weak self] ok, error in
      self?.queue.async {
        if let error { self?.log("error", "beginSession failed: \(error.localizedDescription)") }
        completion(ok ? card : nil)
      }
    }
  }

  private func transmit(_ request: Request, on session: Session) {
    guard let card = session.card else { return }
    let inFlight = InFlight(request.resolve)
    session.inFlight = inFlight
    if request.abortTimeoutMs > 0 {
      queue.asyncAfter(deadline: .now() + request.abortTimeoutMs / 1000) {
        inFlight.answer(Self.failure("SendApduTimeout"))
      }
    }
    card.transmit(request.apdu) { [weak self] reply, error in
      self?.queue.async {
        guard let self else { return }
        if session.inFlight === inFlight { session.inFlight = nil }
        if let reply {
          if reply.isEmpty {
            inFlight.answer(Self.failure("EmptyResponse"))
            return
          }
          inFlight.answer(["success": true, "apdu": reply.base64EncodedString()])
          let ok = reply.count >= 2 && reply[reply.count - 2] == 0x90 && reply[reply.count - 1] == 0x00
          if request.triggersDisconnection && ok {
            // The Ledger is about to close this app (e.g. open/close app): expect the reader to
            // re-enumerate, and hold the next APDU until it does.
            self.startWaitingForReconnection(session)
          }
        } else {
          let message = error?.localizedDescription ?? "no reply"
          self.log("error", "transmit failed: \(message)")
          let gone = !card.isValid || self.readers[session.readerName]?.slot?.state != .validCard
          inFlight.answer(Self.failure(gone ? "DeviceDisconnected" : "NoResponse: \(message)"))
        }
        if session.inFlight == nil, session.card != nil, let next = session.queued {
          session.queued = nil
          self.transmit(next, on: session)
        }
      }
    }
  }

  private func cardWentAway(readerName: String) {
    for session in sessions.values where session.readerName == readerName && session.card != nil {
      log("info", "session \(session.id): card went away")
      session.inFlight?.answer(Self.failure("DeviceDisconnected"))
      startWaitingForReconnection(session)
    }
  }

  private func startWaitingForReconnection(_ session: Session) {
    session.card?.endSession()
    session.card = nil
    session.reconnectionTimer?.cancel()
    let timer = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session, self.sessions[session.id] === session else { return }
      // A triggersDisconnection APDU may not have re-enumerated the reader after all.
      if let slot = self.readers[session.readerName]?.slot, slot.state == .validCard {
        self.reconnect(session, slot: slot, terminateOnFailure: true)
      } else {
        self.log("info", "session \(session.id): reader didn't come back")
        self.terminate(session, notify: true)
      }
    }
    session.reconnectionTimer = timer
    queue.asyncAfter(deadline: .now() + Self.reconnectionTimeout, execute: timer)
  }

  private func cardCameBack(readerName: String) {
    guard let slot = readers[readerName]?.slot else { return }
    for session in sessions.values where session.readerName == readerName && session.card == nil {
      reconnect(session, slot: slot, terminateOnFailure: false)
    }
  }

  private func reconnect(_ session: Session, slot: TKSmartCardSlot, terminateOnFailure: Bool) {
    openCard(on: slot) { [weak self] card in
      guard let self, self.sessions[session.id] === session, session.card == nil else {
        card?.endSession()
        return
      }
      guard let card else {
        if terminateOnFailure { self.terminate(session, notify: true) }
        return
      }
      self.log("info", "session \(session.id): reconnected")
      session.reconnectionTimer?.cancel()
      session.reconnectionTimer = nil
      session.card = card
      if session.inFlight == nil, let next = session.queued {
        session.queued = nil
        self.transmit(next, on: session)
      }
    }
  }

  private func terminate(_ session: Session, notify: Bool) {
    guard sessions.removeValue(forKey: session.id) != nil else { return }
    session.reconnectionTimer?.cancel()
    session.inFlight?.answer(Self.failure("DeviceDisconnected"))
    session.queued?.resolve(Self.failure("DeviceDisconnected"))
    session.queued = nil
    session.card?.endSession()
    session.card = nil
    if notify { send(Self.deviceDisconnectedEvent, ["id": session.id]) }
  }

  // MARK: - Events and logs

  private static func failure(_ error: String) -> [String: Any] {
    ["success": false, "error": error]
  }

  private func send(_ name: String, _ body: Any) {
    guard hasListeners else { return }
    sendEvent(withName: name, body: body)
  }

  private func log(_ level: String, _ message: String) {
    NSLog("[LDMKTransportHIDModule] %@", message)
    send(Self.transportLogEvent, [
      "level": level,
      "tag": "[\(Self.tag)]",
      "message": message,
      "jsonPayload": [String: String](),
      "timestamp": String(Int64(Date().timeIntervalSince1970 * 1000)),
    ])
  }
}
