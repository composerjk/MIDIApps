/*
 Copyright (c) 2001-2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import CoreMIDI

protocol CoreMIDIContext: AnyObject {

    // This protocol is used by CoreMIDIObjectWrappers to interact with
    // the rest of the MIDI system.

    // Basic functionality

    var interface: CoreMIDIInterface { get }
    var client: MIDIClientRef { get }

    func forcePropertyChanged(_ type: MIDIObjectType, _ objectRef: MIDIObjectRef, _ property: CFString)

    func generateNewUniqueID() -> MIDIUniqueID

    func allowMIDIObject(ref: MIDIObjectRef, type: MIDIObjectType) -> Bool

    // Interaction with other MIDIObject subclasses

    func postObjectsAddedNotification<T: CoreMIDIObjectListable & CoreMIDIPropertyChangeHandling>(_ objects: [T])

    func postObjectListChangedNotification(_ type: MIDIObjectType)

    func updateEndpointsForDevice(_ device: Device)

    func findObject(midiObjectRef: MIDIObjectRef) -> Device?
    func findObject(midiObjectRef: MIDIObjectRef) -> ExternalDevice?
    func findObject(midiObjectRef: MIDIObjectRef) -> Source?
    func findObject(midiObjectRef: MIDIObjectRef) -> Destination?

    func findObject(uniqueID: MIDIUniqueID) -> Source?
    func findObject(uniqueID: MIDIUniqueID) -> Destination?

    func addedVirtualSource(midiObjectRef: MIDIObjectRef) -> Source?
    func removedVirtualSource(_ source: Source)
    func addedVirtualDestination(midiObjectRef: MIDIObjectRef) -> Destination?
    func removedVirtualDestination(_ destination: Destination)

}
