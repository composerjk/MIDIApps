/*
 Copyright (c) 2002-2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa
import SnoizeMIDI

@objc class FindMissingController: NSObject {

    @objc init(windowController: MainWindowController, library: Library) {
        self.mainWindowController = windowController
        self.library = library

        super.init()
    }

    // Main window controller sends this to begin the process
    @objc func findMissingFiles(forEntries entries: [LibraryEntry], completion: @escaping () -> Void) {
        // Ask the user to find each missing file.
        // If we go through them all successfully, perform the completion.
        // If we cancel at any point of the process, don't do anything.

        self.entriesWithMissingFiles = entries
        self.completion = completion

        findNextMissingFile()
    }

    // MARK: Private

    private weak var mainWindowController: MainWindowController?
    private weak var library: Library?

    private var entriesWithMissingFiles: [LibraryEntry] = []
    private var completion: (() -> Void)?

}

extension FindMissingController /* Private */ {

    private func findNextMissingFile() {
        if let window = mainWindowController?.window, let entry = entriesWithMissingFiles.first {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Missing File", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of alert for missing file")
            let informativeFormat = NSLocalizedString("The file for the item \"%@\" could not be found. Would you like to locate it?", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "format of message for missing file")
            alert.informativeText = String(format: informativeFormat, entry.name ?? "")
            alert.addButton(withTitle: NSLocalizedString("Yes", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "Yes button in alert"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "Cancel button in alert"))
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn /* Yes */ {
                    // Get this sheet out of the way before we open another one
                    alert.window.orderOut(nil)

                    // Try to locate the file
                    self.runOpenSheetForMissingFile(entry)
                }
                else /* Cancel */ {
                    self.cancelFindMissing()
                }
            }
        }
        else {
            self.completion?()
        }
    }

    private func runOpenSheetForMissingFile(_ entry: LibraryEntry) {
        guard let window = mainWindowController?.window, let library = library else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = library.allowedFileTypes
        openPanel.beginSheetModal(for: window) { response in
            if response == .OK && openPanel.urls.count > 0 {
                let filePath = openPanel.urls.first!.path

                // Is this file in use by any entries?  (It might be in use by *this* entry if the file has gotten put in place again!)
                let (matchingEntries, _) = library.findEntries(forFilePaths: [filePath])
                if !matchingEntries.isEmpty,
                   matchingEntries.firstIndex(of: entry) == nil {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("In Use", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of alert for file already in library")
                    alert.informativeText = NSLocalizedString("That file is already in the library. Please choose another one.", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "message for file already in library")
                    alert.addButton(withTitle: NSLocalizedString("Cancel", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "Cancel button in alert"))

                    let response = alert.runModal()
                    openPanel.orderOut(nil)
                    if response == .alertFirstButtonReturn {
                        // Run the open sheet again
                        self.runOpenSheetForMissingFile(entry)
                    }
                    else {
                        // Cancel out of the whole process
                        self.cancelFindMissing()
                    }
                }
                else { // File is not in use by any entries
                    openPanel.orderOut(nil)

                    entry.path = filePath
                    entry.setNameFromFile()

                    self.entriesWithMissingFiles.removeFirst()

                    // Go on to the next file (if any)
                    self.findNextMissingFile()
                }
            }
            else {
                self.cancelFindMissing()
            }
        }
    }

    private func cancelFindMissing() {
        // Cancel the whole process
        self.entriesWithMissingFiles = []
    }

}
