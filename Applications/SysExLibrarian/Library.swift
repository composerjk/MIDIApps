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

class Library: NSObject {

    static var shared = Library()

    override init() {
        guard let documentTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { fatalError() }
        guard documentTypes.count > 1 else { fatalError() }

        rawSysExFileTypes = Self.fileTypes(fromDocumentTypeDictionary: documentTypes[0])
        standardMIDIFileTypes = Self.fileTypes(fromDocumentTypeDictionary: documentTypes[1])
        allowedFileTypes = rawSysExFileTypes + standardMIDIFileTypes

        entries = []

        super.init()
    }

    lazy var libraryFilePath: String? = {
        do {
            var libraryFileURL = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

            libraryFileURL.appendPathComponent("Preferences")
            // This path should exist as-is; don't bother trying to resolve symlinks or aliases.

            libraryFileURL.appendPathComponent("SysEx Librarian Library.sXLb")

            return libraryFileURL.path
        }
        catch {
            // TODO Should this do better?
            return nil
        }
    }()

    var fileDirectoryPath: String {
        get {
            rememberedFileDirectoryPath ?? defaultFileDirectoryPath
        }
        set {
            let alias = Alias(path: newValue)!

            let defaults = UserDefaults.standard
            defaults.set(alias.data, forKey: Self.libraryFileDirectoryBookmarkPreferenceKey)
            // Clear anything that might have been in old LibraryFileDirectoryAliasPreferenceKey.
            // If someone runs an old version of the app, let it fall back via the path.
            defaults.removeObject(forKey: Self.libraryFileDirectoryAliasPreferenceKey)
            defaults.set(newValue, forKey: Self.libraryFileDirectoryPathPreferenceKey)
        }
    }

    func isPathInFileDirectory(_ path: String) -> Bool {
        path.hasPrefix(fileDirectoryPath.appending("/"))
    }

    func preflightAndLoadEntries() -> String? {
        // Returns an error message if something critical is wrong
        if let errorMessage = preflightLibrary() {
            // Currently, the only reason this can fail is in the unlikely event that we can't get a URL to ~/Library/
            let header = NSLocalizedString("There is a problem accessing the SysEx Librarian preferences.", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "error message on preflight library")
            return header + "\n" + errorMessage
        }

        preflightFileDirectory()    // can't produce any fatal errors for launch
        loadEntries()
        return nil
    }

    private(set) var entries: [LibraryEntry]

    func addEntry(forFile filePath: String) -> LibraryEntry? {
        // NOTE: This will return nil, and add no entry, if no messages are in the file

        // Setting the entry path and name will cause us to be notified of a change, and we'll autosave.
        // However, the add might not succeed--if it doesn't, make sure our dirty flag isn't set if it shouldn't be.
        let wasDirty = isDirty

        let entry = LibraryEntry(library: self)
        entry.path = filePath

        if entry.messages.count > 0 {
            entry.setNameFromFile()
            entries.append(entry)
            return entry
        }
        else {
            if !wasDirty {
                isDirty = false
            }
            return nil
        }
    }

    func addNewEntry(sysexData: Data) throws -> LibraryEntry? {
        let fileManager = FileManager.default

        // ensure the file directory exists; if not we can't write there
        try fileManager.createDirectory(atPath: fileDirectoryPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let newFileName = NSLocalizedString("Untitled", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "name of new sysex file")
        let newFileNameWithExtension = NSString(string: newFileName).appendingPathExtension(Self.sysExFileExtension)!
        let newFilePath = NSString(string: fileDirectoryPath).appendingPathComponent(newFileNameWithExtension)
        let uniqueNewFilePath = fileManager.uniqueFilename(from: newFilePath)

        try NSData(data: sysexData).write(toFile: uniqueNewFilePath, options: .atomic)

        let fileAttributes: [FileAttributeKey: Any] = [
            .hfsTypeCode: Self.sysExFileTypeCode,
            .hfsCreatorCode: Self.applicationCreatorCode,
            .extensionHidden: true
        ]
        do {
            try fileManager.setAttributes(fileAttributes, ofItemAtPath: uniqueNewFilePath)
        }
        catch {
            // If we fail to set attributes, it doesn't really matter
        }

        let entry = addEntry(forFile: uniqueNewFilePath)
        // Someday: We write out the file, and then soon afterwards will read it again to get the messages. Pretty inefficient.

        return entry
    }

    func removeEntries(_ entriesToRemove: [LibraryEntry]) {
        for entryToRemove in entriesToRemove {
            if let entryIndex = entries.firstIndex(of: entryToRemove) {
                NotificationCenter.default.post(name: .libraryEntryWillBeRemoved, object: entries[entryIndex])
                entries.remove(at: entryIndex)
            }
        }

        noteEntryChanged()
    }

    func noteEntryChanged() {
        isDirty = true
        autosave()

        if !willPostLibraryDidChangeNotification {
            willPostLibraryDidChangeNotification = true
            DispatchQueue.main.async {
                self.willPostLibraryDidChangeNotification = false
                NotificationCenter.default.post(name: .libraryDidChange, object: self)
            }
        }
    }

    func autosave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(save), object: nil)
        perform(#selector(save), with: nil, afterDelay: 0)
    }

    @objc func save() {
        guard isDirty, let libraryFilePath = libraryFilePath else { return }

        let propertyList = ["Entries": entries.compactMap({ $0.dictionaryValues })]

        do {
            let fileData = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
            try NSData(data: fileData).write(toFile: libraryFilePath, options: .atomic)

            let fileAttributes: [FileAttributeKey: Any] = [
                .hfsTypeCode: Self.libraryFileTypeCode,
                .hfsCreatorCode: Self.applicationCreatorCode,
                .extensionHidden: true
            ]
            do {
                try FileManager.default.setAttributes(fileAttributes, ofItemAtPath: libraryFilePath)
            }
            catch {
                // If we fail to set attributes, it doesn't really matter
            }

            isDirty = false
        }
        catch {
            // Present the error, Can't continue saving, but can continue with the app.
            // This is not fantastic UI, but it works.  This should not happen unless the user is trying to provoke us, anyway.
            let messageText = NSLocalizedString("Error", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "title of error alert")
            let informativeTextFormat = NSLocalizedString("The library \"%@\" could not be saved.", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "format of error message if the library file can't be saved")
            let informativeText = String(format: informativeTextFormat, libraryFilePath) + "\n" + error.localizedDescription

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = messageText
            alert.informativeText = informativeText
            alert.runModal()
        }
    }

    let allowedFileTypes: [String]
        // Should be [UTType], someday, when we can require macOS 11.0

    enum FileType {
        case raw
        case standardMIDI
        case unknown
    }

    func typeOfFile(atPath path: String) -> FileType {
        guard !path.isEmpty else { return .unknown }

        var fileType = NSString(string: path).pathExtension
        if fileType.isEmpty {
            fileType = NSHFSTypeOfFile(path)
        }

        if rawSysExFileTypes.contains(fileType) {
            return .raw
        }
        else if standardMIDIFileTypes.contains(fileType) {
            return .standardMIDI
        }
        else {
            return .unknown
        }
    }

    func findEntries(forFilePaths filePaths: [String]) -> ([LibraryEntry], [String]) {
        var entriesByFilePath: [String: LibraryEntry] = [:]
        for entry in entries {
            if let filePath = entry.path {
                entriesByFilePath[filePath] = entry
            }
        }

        var nonMatchingFilePaths: [String] = []
        var matchingEntries: [LibraryEntry] = []

        for filePath in filePaths {
            if let entry = entriesByFilePath[filePath] {
                matchingEntries.append(entry)
            }
            else {
                nonMatchingFilePaths.append(filePath)
            }
        }

        return (matchingEntries, nonMatchingFilePaths)
    }

    func moveFilesInLibraryDirectoryToTrash(forEntries entriesToTrash: [LibraryEntry]) {
        var filesToTrash: [String] = []

        for entry in entriesToTrash {
            if entry.isFileInLibraryFileDirectory,
               let path = entry.path {
                filesToTrash.append(path)
            }
        }

        if !filesToTrash.isEmpty {
            let urls = filesToTrash.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.recycle(urls, completionHandler: nil)
        }
    }

    // MARK: Private

    private var isDirty = false
    private var willPostLibraryDidChangeNotification = false

    private let rawSysExFileTypes: [String]
    private let standardMIDIFileTypes: [String]

}

extension Notification.Name {

    // notification.object is the Library
    static let libraryDidChange = Notification.Name("SSELibraryDidChangeNotification")

    // notification.object is the LibraryEntry
    static let libraryEntryWillBeRemoved = Notification.Name("SSELibraryEntryWillBeRemovedNotification")

}

extension Library /* Preferences keys */ {

    static let libraryFileDirectoryBookmarkPreferenceKey = "SSELibraryFileDirectoryBookmark"
    static let libraryFileDirectoryAliasPreferenceKey = "SSELibraryFileDirectoryAlias"
    static let libraryFileDirectoryPathPreferenceKey = "SSELibraryFileDirectoryPath"

}

extension Library /* Private */ {

    static let sysExFileExtension = "syx"
    static let applicationCreatorCode = NSHFSTypeCodeFromFileType("'SnSX'")
    static let libraryFileTypeCode = NSHFSTypeCodeFromFileType("'sXLb'")
    static let sysExFileTypeCode = NSHFSTypeCodeFromFileType("'sysX'")

    private static func fileTypes(fromDocumentTypeDictionary dict: [String: Any]) -> [String] {
        var fileTypes: [String] = []

        if let extensions = dict["CFBundleTypeExtensions"] as? [String] {
            fileTypes.append(contentsOf: extensions)
        }

        if let osTypes = dict["CFBundleTypeOSTypes"] as? [String] {
            let osTypesAsFileTypes = osTypes.map { "'\($0)'" }
            fileTypes.append(contentsOf: osTypesAsFileTypes)
        }

        return fileTypes
    }

    private var rememberedFileDirectoryPath: String? {
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.libraryFileDirectoryBookmarkPreferenceKey) {
            return Alias(data: bookmarkData).path
        }
        else if let aliasData = UserDefaults.standard.data(forKey: Self.libraryFileDirectoryAliasPreferenceKey) {
            return Alias(aliasRecordData: aliasData)?.path
        }
        else {
            return UserDefaults.standard.string(forKey: Self.libraryFileDirectoryPathPreferenceKey)
        }
    }

    private func clearRememberedFileDirectoryPath() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.libraryFileDirectoryBookmarkPreferenceKey)
        defaults.removeObject(forKey: Self.libraryFileDirectoryAliasPreferenceKey)
        defaults.removeObject(forKey: Self.libraryFileDirectoryPathPreferenceKey)
    }

    private var defaultFileDirectoryPath: String {
        // Ideally put it in ~/Documents
        let parentPath: String
        do {
            let homeDocumentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            parentPath = homeDocumentsURL.path
        }
        catch {
            parentPath = NSString(string: NSHomeDirectory()).appendingPathComponent("Documents")
        }

        return NSString(string: parentPath).appendingPathComponent("SysEx Librarian")
    }

    private func preflightLibrary() -> String? {
        // This used to do more, but now we only check for absolutely fatal errors.
        do {
            _ = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return nil
        }
        catch {
            // This is really unlikely, but we really can't do much if this fails. Fatal error.
            return error.localizedDescription
        }
    }

    private func preflightFileDirectory() {
        // Note: the fileDirectory only really affects the location of newly added files,
        // and whether we show alerts when removing files. Its value isn't critical, as long
        // as we can find somewhere we can write to.

        // If we have a remembered file directory (either via a bookmark, alias, or path),
        // check whether it still exists. If not, then clear it and go back to the default.
        // (If it doesn't exist, it could be for some user name that doesn't exist, or could be wrong
        //  for some reason that's hard to recover from. Better to just ignore it.)
        if let rememberedFileDirectoryPath = rememberedFileDirectoryPath {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: rememberedFileDirectoryPath, isDirectory: &isDirectory)
            if !(exists && isDirectory.boolValue) {
                clearRememberedFileDirectoryPath()
            }
        }

        // There is no need to do anything else with fileDirectoryPath. When we use it when recording a new sysex file,
        // we will ensure it (and its intermediate directories) exists, and present an error if there are any problems.
    }

    private var resolvedLibraryFilePath: String? {
        guard let libraryFilePath = libraryFilePath else { return nil }

        // Handle the case when someone has replaced our file with a symlink, an alias, or a symlink to an alias.
        // (If you have more symlinks or aliases chained together, well, sorry.)
        // Note that this only affects the data that we read. When we write we will replace the symlink or alias with a plain file.

        let symlinkResolvedLibraryFilePath: String = {
            do {
                let symlinkPath: String = try FileManager.default.destinationOfSymbolicLink(atPath: libraryFilePath)
                if !symlinkPath.hasPrefix("/") {
                    return (((libraryFilePath as NSString).deletingLastPathComponent as NSString) .appendingPathComponent(symlinkPath) as NSString).standardizingPath
                }
                else {
                    return symlinkPath
                }
            }
            catch { // not a symlink
                return libraryFilePath
            }
        }()

        let aliasResolvedLibraryFilePath: String = {
            let url = URL(fileURLWithPath: symlinkResolvedLibraryFilePath, isDirectory: false)
            do {
                let resolvedURL: URL
                if #available(macOS 10.10, *) {
                    resolvedURL = try URL(resolvingAliasFileAt: url, options: .withoutUI)
                }
                else {  // macOS < 10.10
                    let bookmarkData = try URL.bookmarkData(withContentsOf: url)
                    var isStale = false // don't really care
                    resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                }
                if resolvedURL.isFileURL {
                    return resolvedURL.path
                }
            }
            catch { // not an alias
            }

            return symlinkResolvedLibraryFilePath
        }()

        return aliasResolvedLibraryFilePath
    }

    private func loadEntries() {
        // We should only be called once at startup
        precondition(entries.isEmpty)
        guard let libraryFilePath = resolvedLibraryFilePath else { return }

        var errorToReport: Error?
        do {
            let data: NSData = try NSData(contentsOfFile: libraryFilePath, options: [])
            do {
                let propertyList = try PropertyListSerialization.propertyList(from: data as Data, options: [], format: nil)
                if let libraryDict = propertyList as? [String: Any],
                   let entryDicts = libraryDict["Entries"] as? [[String: Any]] {
                    entries = entryDicts.compactMap { LibraryEntry(library: self, dictionary: $0) }
                }
            }
            catch {
                errorToReport = error
            }
        }
        catch {
            // Couldn't load data.
            errorToReport = error
            // Ignore file not found errors. That just means there isn't a file to read from.
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                errorToReport = nil
            }
            else if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                    underlyingError.domain == NSPOSIXErrorDomain && underlyingError.code == ENOENT {
                errorToReport = nil
            }
        }

        if let errorToReport = errorToReport {
            // Report on error, then continue with an empty library.
            let messageText = NSLocalizedString("Error", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "title of error alert")
            let informativeTextFormat = NSLocalizedString("The library \"%@\" could not be read.", tableName: "SysExLibrarian", bundle: Bundle.main, comment: "format of error message if the library file can't be read")
            let informativeText = String(format: informativeTextFormat, libraryFilePath) + "\n" + errorToReport.localizedDescription

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = messageText
            alert.informativeText = informativeText
            alert.runModal()
        }

        // Ignore any changes that came from reading entries
        isDirty = false
    }

}
