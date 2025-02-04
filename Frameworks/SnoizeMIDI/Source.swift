/*
 Copyright (c) 2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import CoreMIDI

public class Source: Endpoint, CoreMIDIObjectListable {

    // MARK: CoreMIDIObjectListable

    static let midiObjectType = MIDIObjectType.source
    static func midiObjectCount(_ context: CoreMIDIContext) -> Int {
        context.interface.getNumberOfSources()
    }
    static func midiObjectSubscript(_ context: CoreMIDIContext, _ index: Int) -> MIDIObjectRef {
        context.interface.getSource(index)
    }

    override func midiPropertyChanged(_ property: CFString) {
        super.midiPropertyChanged(property)

        if property == kMIDIPropertyConnectionUniqueID || property == kMIDIPropertyName {
            // This may affect our displayName
            midiContext.forcePropertyChanged(Self.midiObjectType, midiObjectRef, kMIDIPropertyDisplayName)
        }

        if property == kMIDIPropertyDisplayName {
            // FUTURE: Something more targeted would be nice.
            midiContext.postObjectListChangedNotification(Self.midiObjectType)
        }
    }

    // MARK: Additional API

    public func remove() {
        // Only possible for virtual endpoints owned by this process
        guard midiObjectRef != 0 && isOwnedByThisProcess else { return }

        _ = midiContext.interface.endpointDispose(endpointRef)

        // This object still hangs around in the endpoint lists until CoreMIDI gets around to posting a notification.
        // We should remove it immediately.
        midiContext.removedVirtualSource(self)

        // Now we can forget the objectRef (not earlier!)
        clearMIDIObjectRef()
    }

}

extension CoreMIDIContext {

    public func createVirtualSource(name: String, uniqueID: MIDIUniqueID) -> Source? {
        // If newUniqueID is 0, we'll use the unique ID that CoreMIDI generates for us

        var newEndpointRef: MIDIEndpointRef = 0
        guard interface.sourceCreate(client, name as CFString, &newEndpointRef) == noErr else { return nil }

        // We want to get at the Source immediately, to configure it.
        // CoreMIDI will send us a notification that something was added,
        // but that won't arrive until later. So manually add the new Source,
        // trusting that we won't add it again later.
        guard let source = addedVirtualSource(midiObjectRef: newEndpointRef) else { return nil }

        source.setOwnedByThisProcess()

        if uniqueID != 0 {
            source.uniqueID = uniqueID
        }
        while source.uniqueID == 0 {
            // CoreMIDI didn't assign a unique ID to this endpoint, so we should generate one ourself
            source.uniqueID = generateNewUniqueID()
        }

        source.manufacturer = "Snoize"
        source.model = name

        return source
    }

}
