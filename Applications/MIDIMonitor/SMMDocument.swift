/*
 Copyright (c) 2001-2014, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa

class SMMDocument: NSDocument {

    // TODO Reorganize, make things private, etc.

    private let midiMonitorFileType = "com.snoize.midimonitor"
    private let midiMonitorErrorDomain = "com.snoize.midimonitor"

    private(set) var windowSettings: [String: Any]?

    // MIDI processing
    private let stream = SMMCombinationInputStream()
    private let messageFilter = SMMessageFilter()
    private let history = SMMessageHistory()

    // Transient data
    private var isSysExUpdateQueued = false

    override class var autosavesInPlace: Bool {
        return true
    }

    override init() {
        super.init()

        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(self.readingSysEx(_:)), name: .SMInputStreamReadingSysEx, object: stream)
        center.addObserver(self, selector: #selector(self.doneReadingSysEx(_:)), name: .SMInputStreamDoneReadingSysEx, object: stream)
        center.addObserver(self, selector: #selector(self.sourceListDidChange(_:)), name: .SMInputStreamSourceListChanged, object: stream)
        updateVirtualEndpointName()

        stream.messageDestination = messageFilter
        messageFilter.filterMask = SMMessageTypeAllMask
        messageFilter.channelMask = SMChannelMaskAll

        messageFilter.messageDestination = history
        center.addObserver(self, selector: #selector(self.historyDidChange(_:)), name: .SMMessageHistoryChanged, object: history)

        // If the user changed the value of this old obsolete preference, bring its value forward to our new preference
        // (the default value was YES)
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: SMMPreferenceKeys.selectFirstSourceInNewDocument) {
            defaults.setValue(false, forKey: SMMPreferenceKeys.selectOrdinarySourcesInNewDocument)
            defaults.setValue(true, forKey: SMMPreferenceKeys.selectFirstSourceInNewDocument)
        }

        autoselectSources()

        updateChangeCount(.changeCleared)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeWindowControllers() {
        addWindowController(SMMMonitorWindowController())
    }

    override func data(ofType typeName: String) throws -> Data {
        guard typeName == midiMonitorFileType else { throw badFileTypeError }

        var dict: [String: Any] = [:]
        dict["version"] = 2

        if let streamSettings = stream.persistentSettings {
            dict["streamSettings"] = streamSettings
        }

        let historySize = history.historySize()
        if historySize != SMMessageHistory.defaultHistorySize() {
            dict["maxMessageCount"] = historySize
        }

        let filterMask = messageFilter.filterMask
        if filterMask != SMMessageTypeAllMask {
            dict["filterMask"] = filterMask.rawValue
        }

        let channelMask = messageFilter.channelMask
        if channelMask != SMChannelMaskAll {
            dict["channelMask"] = channelMask.rawValue
        }

        if let savedMessages = history.savedMessages(),
           savedMessages.count > 0 {
            dict["messageData"] = NSKeyedArchiver.archivedData(withRootObject: savedMessages)
        }

        if let windowSettings = monitorWindowController?.windowSettings {
            dict.merge(windowSettings) { (_, new) in new }
        }

        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard typeName == midiMonitorFileType else { throw badFileTypeError }

        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let dict = propertyList as? [String: Any] else { throw badFileContentsError }

        var streamSettings: [String: Any]?

        let version = dict["version"] as? Int ?? 0
        switch version {
        case 1:
            if let number = dict["sourceEndpointUniqueID"] as? NSNumber {
                var settings: [String: Any] = ["portEndpointUniqueID": number]
                if let endpointName = dict["sourceEndpointName"] {
                    settings["portEndpointName"] = endpointName
                }
                streamSettings = settings
            }
            else if let number = dict["virtualDestinationEndpointUniqueID"] as? NSNumber {
                streamSettings = ["virtualEndpointUniqueID": number]
            }

        case 2:
            streamSettings = dict["streamSettings"] as? [String: Any]

        default:
            throw badFileContentsError
        }

        if let settings = streamSettings {
            _ = stream.takePersistentSettings(settings)
            monitorWindowController?.updateSources()
        }
        else {
            selectedInputSources = []
        }

        maxMessageCount = (dict["maxMessageCount"] as? NSNumber)?.uintValue ?? SMMessageHistory.defaultHistorySize()

        if let number = dict["filterMask"] as? NSNumber {
            filterMask = SMMessageType(rawValue: number.uint32Value)
        }
        else {
            filterMask = SMMessageTypeAllMask
        }

        if let number = dict["channelMask"] as? NSNumber {
            channelMask = SMChannelMask(rawValue: number.uint32Value)
        }
        else {
            channelMask = SMChannelMaskAll
        }

        if let messageData = dict["messageData"] as? Data,
           let messages = NSKeyedUnarchiver.unarchiveObject(with: messageData) as? [Any] {
            history.setSavedMessages(messages)
        }

        var readWindowSettings: [String: Any] = [:]
        for key in SMMMonitorWindowController.windowSettingsKeys {
            if let obj = dict[key] {
                readWindowSettings[key] = obj
            }
        }
        windowSettings = readWindowSettings

        // Doing the above caused undo actions to be remembered, but we don't want the user to see them
        updateChangeCount(.changeCleared)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        // Clear the undo stack whenever we load or save.
        super.updateChangeCount(change)
        if change == .changeCleared {
            self.undoManager?.removeAllActions()
        }
    }

    override var fileURL: URL? {
        didSet {
            updateVirtualEndpointName()
        }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        // It's easy for us to dirty the document, but the user may not generally care to save the documents.
        // Pay attention to the user's preference for whether or not to warn when closing a dirty document.

        var mayCloseWithoutSaving = false

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "NSCloseAlwaysConfirmsChanges") {
            // The system preference for "Ask to keep changes when closing documents" is turned ON.
            // Therefore, our documents are not automatically saved. It makes sense to apply our
            // preference to all documents.
            mayCloseWithoutSaving = true
        }
        else {
            // The system preference for "Ask to keep changes when closing documents" is turned OFF.
            // Documents are automatically saved. However, if they are untitled (never saved anywhere),
            // then closing the window will ask to save.
            if self.fileURL == nil {
                // This is an untitled document.
                mayCloseWithoutSaving = true
            }
        }

        if mayCloseWithoutSaving && !defaults.bool(forKey: SMMPreferenceKeys.askBeforeClosingModifiedWindow) {
            // Tell the delegate to close now, regardless of what the document's dirty flag may be.
            // Unfortunately this is not easy in Objective-C:
            // void (*objc_msgSendTyped)(id self, SEL _cmd, NSDocument *document, BOOL shouldClose, void *contextInfo) = (void*)objc_msgSend;
            // objc_msgSendTyped(delegate, shouldCloseSelector, self, YES /* close now */, contextInfo);
            // and it's not nice in Swift either. https://stackoverflow.com/a/43553386
            let delegateObject = delegate as AnyObject
            if let selector = shouldCloseSelector,
               let imp = class_getMethodImplementation(type(of: delegateObject), selector) {
                unsafeBitCast(imp, to: (@convention(c)(Any?, Selector, Any?, Bool, Any?)->Void).self)(delegateObject, selector, self, true /*close now */, contextInfo)
            }
        }
        else {
            // Do the same as normal: ask if the user wants to save.
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    var inputSourceGroups: [SMMCombinationInputStreamSourceGroup] {
        return stream.sourceGroups
    }

    @objc var selectedInputSources: Set<AnyHashable> /* TODO Should become Set<SMInputStreamSource> */ {
        get {
            return stream.selectedInputSources
        }
        set {
            guard selectedInputSources != newValue else { return }

            // let oldValue = selectedInputSources
            stream.selectedInputSources = newValue

            /* TODO Work this out
            if let undoManager = undoManager {
                // TODO: Safer to use block-based undo registration, but it requires newer macOS. When we do that, remove @objc on this variable.
                let proxy: AnyObject = undoManager.prepare(withInvocationTarget: self) as AnyObject
                proxy.setSelectedInputSources(oldValue)
                undoManager.setActionName(NSLocalizedString("Change Selected Sources", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "change source undo action"))
            }
 */

            monitorWindowController?.updateSources()
        }
    }

    @objc var maxMessageCount: UInt {
        get {
            return history.historySize()
        }
        set {
            guard newValue != maxMessageCount else { return }

            /* TODO Work this out
            if let undoManager = undoManager {
                // TODO: Safer to use block-based undo registration, but it requires newer macOS. When we do that, remove @objc on this variable.
                var proxy: AnyObject = undoManager.prepare(withInvocationTarget: self) as AnyObject
//                proxy.maxMessageCount = newValue
//                proxy.setMaxMessageCount(newValue)
                undoManager.setActionName(NSLocalizedString("Change Selected Sources", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "change source undo action"))
            }
 */

            history.setHistorySize(newValue)

            monitorWindowController?.updateMaxMessageCount()
        }
    }

    @objc var filterMask: SMMessageType {
        get {
            return messageFilter.filterMask
        }
        set {
            let oldValue = filterMask
            guard newValue != oldValue else { return }

            /* TODO Work this out
            if let undoManager = undoManager {
                let proxy: AnyObject = undoManager.prepare(withInvocationTarget: self) as AnyObject
                proxy.setFilterMask(oldValue)
                undoManager.setActionName(NSLocalizedString("Change Filter", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "change filter undo action"))
            }
 */

            messageFilter.filterMask = newValue
            monitorWindowController?.updateFilterControls()
        }
    }

    func changeFilterMask(_ maskToChange: SMMessageType, turnBitsOn: Bool) {
        var newMask = messageFilter.filterMask.rawValue
        if turnBitsOn {
            newMask |= maskToChange.rawValue
        }
        else {
            newMask &= ~maskToChange.rawValue
        }

        filterMask = SMMessageType(rawValue: newMask)
    }

    @objc var channelMask: SMChannelMask {
        get {
            return messageFilter.channelMask
        }
        set {
            let oldValue = channelMask
            guard newValue != oldValue else { return }

            /* TODO Work this out
            if let undoManager = undoManager {
                let proxy: AnyObject = undoManager.prepare(withInvocationTarget: self) as AnyObject
                proxy.setChannelMask(oldValue)
                undoManager.setActionName(NSLocalizedString("Change Channel", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "change channel undo action"))
            }
 */

            messageFilter.channelMask = newValue
            monitorWindowController?.updateFilterControls()
        }
    }

    var isShowingAllChannels: Bool {
        return messageFilter.channelMask == SMChannelMaskAll
    }

    var oneChannelToShow: UInt {
        // It is possible that something else could have set the mask to show more than one, or zero, channels.
        // We'll just return the lowest enabled channel (1-16), or 0 if no channel is enabled.

        guard !isShowingAllChannels else { fatalError() }

        var mask = messageFilter.channelMask.rawValue
        for channel: UInt in 0..<16 {
            if mask & 1 == 1 {
                return channel + 1
            }
            else {
                mask >>= 1
            }
        }

        return 0
    }

    func showAllChannels() {
        channelMask = SMChannelMaskAll
    }

    func showOnlyOneChannel(_ channel: UInt) {
        guard (1...16).contains(channel) else { fatalError() }
        channelMask = SMChannelMask(rawValue: UInt32(1) << (channel - 1))
    }

    func clearSavedMessages() {
        if history.savedMessages().count > 0 {
            history.clearSavedMessages()
        }
    }

    var savedMessages: [SMMessage] {
        return history.savedMessages() as? [SMMessage] ?? []  // TODO History type should match
    }

    var monitorWindowController: SMMMonitorWindowController? {
        return windowControllers.first { $0 is SMMMonitorWindowController } as? SMMMonitorWindowController
    }

    var detailsWindowsControllers: [SMMDetailsWindowController] {
        return windowControllers.filter { $0 is SMMDetailsWindowController } as? [SMMDetailsWindowController] ?? []
    }

    func detailsWindowController(for message: SMMessage) -> SMMDetailsWindowController {
        if let match = detailsWindowsControllers.first(where: { $0.message == message}) {
            return match
        }

        let detailsWindowController: SMMDetailsWindowController
        if message is SMSystemExclusiveMessage {
            detailsWindowController = SMMSysExWindowController(message: message)
        }
        else {
            detailsWindowController = SMMDetailsWindowController(message: message)
        }
        addWindowController(detailsWindowController)
        return detailsWindowController
    }

    func encodeRestorableState(_ state: NSCoder, for detailsWindowController: SMMDetailsWindowController) {
        if let messageIndex = savedMessages.firstIndex(of: detailsWindowController.message) {
            state.encode(messageIndex, forKey: "messageIndex")
        }
    }

    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        if identifier.rawValue == "monitor" {
            super.restoreWindow(withIdentifier: identifier, state: state, completionHandler: completionHandler)
        }
        else {
            var window: NSWindow?

            if let messageIndexNumber = state.decodeObject(forKey: "messageIndex") as? NSNumber {
                let messageIndex = messageIndexNumber.intValue
                if messageIndex < savedMessages.count {
                    window = detailsWindowController(for: savedMessages[messageIndex]).window
                }
            }

            completionHandler(window, nil)
        }
    }

    private var badFileTypeError: Error {
        let reason = NSLocalizedString("Unknown file type.", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "error reason for unknown file type read or write")
        return NSError(domain: midiMonitorErrorDomain, code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }

    private var badFileContentsError: Error {
        let reason = NSLocalizedString("Can't read the contents of the file.", tableName: "MIDIMonitor", bundle: SMBundleForObject(self), comment: "error reason for unknown file contents")
        return NSError(domain: midiMonitorErrorDomain, code: 2, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }

    @objc private func sourceListDidChange(_ notification: Notification?) {
        monitorWindowController?.updateSources()

        // Also, it's possible that the endpoint names went from being unique to non-unique, so we need
        // to refresh the messages displayed.
        updateMessages(scrollingToBottom: false)
    }

    private func updateVirtualEndpointName() {
        let applicationName = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
        var virtualEndpointName = applicationName
        if let documentName = displayName { // should always be non-nil, but just in case
            virtualEndpointName += " (\(documentName))"
        }
        stream.virtualEndpointName = virtualEndpointName
    }

    private func autoselectSources() {
        let groups = inputSourceGroups
        var sourcesSet: Set<AnyHashable> = []  // TODO Should become Set<SMInputStreamSource>

        let defaults = UserDefaults.standard

        if defaults.bool(forKey: SMMPreferenceKeys.selectOrdinarySourcesInNewDocument) {
            if groups.count > 0,
               let sources = groups[0].sources as? [AnyHashable] {
                sourcesSet.formUnion(sources)
            }
        }

        if defaults.bool(forKey: SMMPreferenceKeys.selectVirtualDestinationInNewDocument) {
            if groups.count > 1,
               let sources = groups[1].sources as? [AnyHashable] {
                sourcesSet.formUnion(sources)
            }
        }

        if defaults.bool(forKey: SMMPreferenceKeys.selectSpyingDestinationsInNewDocument) {
            if groups.count > 2,
               let sources = groups[2].sources as? [AnyHashable] {
                sourcesSet.formUnion(sources)
            }
        }

        selectedInputSources = sourcesSet
    }

    @objc private func historyDidChange(_ notification: Notification?) {
        updateChangeCount(.changeDone)

        if let number = notification?.userInfo?[SMMessageHistoryWereMessagesAdded] as? NSNumber {
            updateMessages(scrollingToBottom: number.boolValue)
        }
    }

    private func updateMessages(scrollingToBottom: Bool) {
        monitorWindowController?.updateMessages(scrollingToBottom: scrollingToBottom)
    }

    @objc private func readingSysEx(_ notification: Notification?) {
        // We want multiple updates to get coalesced, so only queue it once
        if !isSysExUpdateQueued {
            isSysExUpdateQueued = true
            self.perform(#selector(self.updateSysExReadIndicators), with: nil, afterDelay: 0)
        }
    }

    @objc private func updateSysExReadIndicators() {
        isSysExUpdateQueued = false
        monitorWindowController?.updateSysExReadIndicator()
    }

    @objc private func doneReadingSysEx(_ notification: Notification?) {
        if isSysExUpdateQueued {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.updateSysExReadIndicators), object: nil)
            isSysExUpdateQueued = false
        }

        monitorWindowController?.stopSysExReadIndicator()
    }

}
