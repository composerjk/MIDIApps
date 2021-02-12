/*
 Copyright (c) 2002-2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa

class GeneralWindowController: NSWindowController {

    override init(window: NSWindow?) {
        super.init(window: window)

        windowFrameAutosaveName = self.windowNibName ?? ""
        shouldCascadeWindows = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willUndoOrRedo(_:)), name: .NSUndoManagerWillUndoChange, object: undoManager)
        center.addObserver(self, selector: #selector(willUndoOrRedo(_:)), name: .NSUndoManagerWillRedoChange, object: undoManager)
        center.addObserver(self, selector: #selector(didUndoOrRedo(_:)), name: .NSUndoManagerDidUndoChange, object: undoManager)
        center.addObserver(self, selector: #selector(didUndoOrRedo(_:)), name: .NSUndoManagerDidRedoChange, object: undoManager)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        if let nibName = windowNibName {
            window?.setFrameAutosaveName(nibName)
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        // Make sure that we are the window's delegate (it might not have been set in the nib)
        window?.delegate = self

        // The new Unified toolbar style doesn't leave much room for items, so use the old Expanded version
        // with the toolbar items under the title
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .expanded
        }

        loadToolbar(name: windowNibName) // Might fail, that's OK
    }

    func speciallyInitializeToolbarItem(_ toolbarItem: NSToolbarItem) {
        // Subclasses should override to do something special to this item (like set up a view).
    }

    // Window utility methods

    func finishEditingInWindow() {
        guard let window = window else { return }
        if window.makeFirstResponder(firstResponderWhenNotEditing) {
            // Validation turned out OK
        }
        else {
            // Validation of the field didn't work, but we need to end editing NOW regardless
            window.endEditing(for: nil)
        }
    }

    var firstResponderWhenNotEditing: NSResponder? {
        window
    }

    // Undo-related

    override var undoManager: UndoManager? {
        // Override NSResponder method
        privateUndoManager
    }

    @objc func willUndoOrRedo(_ notification: Notification) {
        // If we're going to undo, anything can happen, and we really need to stop editing first
        finishEditingInWindow()

        // More can be done by subclasses
    }

    @objc func didUndoOrRedo(_ notification: Notification) {
        // Can be overridden by subclasses if they want to.
        // You definitely want to resynchronize your UI here. Just about anything could have happened.
    }

    // MARK: Private

    let privateUndoManager = UndoManager()
    var toolbarItemInfo: [NSToolbarItem.Identifier: Any]?
    var defaultToolbarItemIdentifiers: [NSToolbarItem.Identifier]?
    var allowedToolbarItemIdentifiers: [NSToolbarItem.Identifier]?

}

extension GeneralWindowController: NSUserInterfaceValidations {

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Override in subclasses as necessary
        true
    }

}

extension GeneralWindowController: NSWindowDelegate {

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        // Make sure our undo manager gets used, not the window's default one.
        privateUndoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finishEditingInWindow()

        // It is possible that something caused by -finishEditingInWindow has caused a sheet to open; we shouldn't close the window in that case, because it really confuses the app (and makes it impossible to quit).
        // (Also: As of 10.1.3, we can get here if someone option-clicks on the close button of a different window, even if this window has a sheet up at the time.)
        if window?.attachedSheet != nil {
            return false
        }

        return true
    }

    func windowDidResize(_ notification: Notification) {
        autosaveCurrentWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        autosaveCurrentWindowFrame()
    }

}

extension GeneralWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultToolbarItemIdentifiers ?? []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        allowedToolbarItemIdentifiers ?? []
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        toolbarItem.label = itemIdentifier.rawValue
        toolbarItem.isEnabled = true

        if let itemInfo = toolbarItemInfo?[itemIdentifier] as? [String: Any] {
            toolbarItem.takeValues(itemInfo: itemInfo, target: self)

            if itemInfo["needsSpecialInitialization"] != nil {
                speciallyInitializeToolbarItem(toolbarItem)
            }
        }

        return toolbarItem
    }

}

extension NSToolbarItem {

    fileprivate func takeValues(itemInfo: [String: Any], target: AnyObject?) {
        if let string = itemInfo["label"] as? String {
            self.label = string
        }

        if let string = itemInfo["toolTip"] as? String {
            self.toolTip = string
        }

        if let string = itemInfo["paletteLabel"] as? String {
            self.paletteLabel = string
        }

        self.target = {
            if let string = itemInfo["target"] as? String {
                if string == "FirstResponder" {
                    return nil
                }
                else {
                    let selector = Selector(string)
                    if let nonNilTarget = target, nonNilTarget.responds(to: selector) {
                        return nonNilTarget.perform(selector)?.takeUnretainedValue()
                    }
                    else {
                        return nil
                    }
                }
            }

            return target   // default if not otherwise specified
        }()

        if let string = itemInfo["action"] as? String {
            self.action = Selector(string)
        }

        if let string = itemInfo["imageName"] as? String {
            self.image = NSImage(named: string)
        }
    }

}

extension GeneralWindowController /* Private */ {

    // Window stuff

    private func autosaveCurrentWindowFrame() {
        // Work around an AppKit bug: the frame that gets saved in NSUserDefaults is the window's old position, not the new one.
        // We get notified after the window has been moved/resized and the defaults changed.
        if let window = window {
            window.saveFrame(usingName: window.frameAutosaveName)
        }
    }

    // Toolbars

    private func loadToolbar(name toolbarName: String?) {
        // If we have a plist specifying a toolbar, then add one to the window.
        guard let toolbarName = toolbarName,
              let toolbarFilePath = Bundle.main.path(forResource: toolbarName, ofType: "toolbar"),
              let toolbarPropertyList = NSDictionary(contentsOfFile: toolbarFilePath)
              else { return }

        toolbarItemInfo = toolbarPropertyList["itemInfoByIdentifier"] as? [NSToolbarItem.Identifier: Any]
        defaultToolbarItemIdentifiers = toolbarPropertyList["defaultItemIdentifiers"] as? [NSToolbarItem.Identifier]
        allowedToolbarItemIdentifiers = toolbarPropertyList["allowedItemIdentifiers"] as? [NSToolbarItem.Identifier]

        let toolbar = NSToolbar(identifier: toolbarName)
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = true
        toolbar.delegate = self
        window?.toolbar = toolbar
    }

}
