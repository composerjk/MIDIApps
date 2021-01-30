/*
 Copyright (c) 2001-2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import CoreAudio

@objc public class SMOutputStream: NSObject, SMMessageDestination {

    @objc public var ignoresTimeStamps = false

    init(midiContext: MIDIContext) {
        self.midiContext = midiContext
        super.init()
    }

    let midiContext: MIDIContext

    // MARK: SMMessageDestination

    public func takeMIDIMessages(_ messages: [Message]) {
        sendMessagesWithLimitedPacketListSize(messages)
    }

    // MARK: Framework internal

    internal func send(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        // Must be overridden by subclasses
        fatalError()
    }

    // MARK: Private

    // CoreMIDI's MIDIPacketList struct is variable-size, consisting of a small
    // header followed by one or more variable-size MIDIPacket structs.
    // The types limit MIDIPacket to holding at most 2^16 - 1 = 65535 bytes,
    // and the MIDIPacketList to holding 2^32 - 1 packets.
    //
    // It's plausible that a large sysex message could exceed the max packet size,
    // but we should be able to split it across multiple packets. The packet
    // count is (almost) unlimited, so we should be able to use a single packet list.
    //
    // HOWEVER. It's not clear we can rely on that, in practice.
    // `MIDIPacketListAdd` has this comment:
    // > The maximum size of a packet list is 65536 bytes.
    // > Large sysex messages must be sent in smaller packet lists.
    // That seems dumb, and maybe they just meant "packet" instead of "packet list",
    // but why risk it? Just send as many packet lists as are necessary.
    //
    // (Back in Mac OS X 10.1, the MIDIServer would crash if you exceeded
    // 1024 bytes in a packet list. So it's not inconceivable that the implementation
    // could have similar limits even today.)
    //
    // Switch to newer CoreMIDI API (introduced in 10.15 or 11.0) when we can.

    private let maxPacketListSize = 65536

    private func sendMessagesWithLimitedPacketListSize(_ messages: [Message]) {
        guard messages.count > 0 else { return }

        var packetListData = Data(count: maxPacketListSize)
        packetListData.withUnsafeMutableBytes { (packetListRawBufferPtr: UnsafeMutableRawBufferPointer) in
            let packetListPtr = packetListRawBufferPtr.bindMemory(to: MIDIPacketList.self).baseAddress!

            func attemptToAddPacket(_ packetPtr: UnsafeMutablePointer<MIDIPacket>, _ message: Message, _ data: Data) -> UnsafeMutablePointer<MIDIPacket>? {
                // Try to add a packet to the packet list, for the given message,
                // with this data (either the message's fullData or a subrange).
                // If successful, returns a non-nil pointer for the next packet.
                // If unsuccessful, returns nil.
                let packetTimeStamp = ignoresTimeStamps ? AudioGetCurrentHostTime() : message.timeStamp
                return data.withUnsafeBytes {
                    return SMWorkaroundMIDIPacketListAdd(packetListPtr, maxPacketListSize, packetPtr, packetTimeStamp, data.count, $0.bindMemory(to: UInt8.self).baseAddress!)
                }
            }

            func sendPacketList() -> UnsafeMutablePointer<MIDIPacket> {
                // Send the current packet list, empty it, and return the next packet to fill in
                send(packetListPtr)
                return MIDIPacketListInit(packetListPtr)
            }

            var curPacketPtr = MIDIPacketListInit(packetListPtr)

            for message in messages {
                // Get the full data for the message (including first status byte)
                let messageData = message.fullData
                guard messageData.count > 0 else { continue }
                var isOverlarge = false

                // Attempt to add a packet with the full data into the current packet list
                if let nextPacketPtr = attemptToAddPacket(curPacketPtr, message, messageData) {
                    // There was enough room in the packet list
                    curPacketPtr = nextPacketPtr
                }
                else if packetListPtr.pointee.numPackets > 0 {
                    // There was not enough room in the packet list.
                    // Send the outstanding packet list, clear it, and try again.
                    curPacketPtr = sendPacketList()

                    if let nextPacketPtr = attemptToAddPacket(curPacketPtr, message, messageData) {
                        // There was enough room in the packet list
                        curPacketPtr = nextPacketPtr
                    }
                    else {
                        isOverlarge = true  // This message will never fit
                    }
                }
                else {
                    isOverlarge = true  // This message will never fit
                }

                if isOverlarge {
                    // This is a large message (in practice, it's sysex, but we don't assume that here).
                    // We send it by filling in the packet list with one packet with as much data as possible,
                    // sending that packet list, then repeating with the remaining data.
                    let chunkSize = maxPacketListSize - MemoryLayout.offset(of: \MIDIPacketList.packet.data)!
                    for chunkStart in stride(from: messageData.startIndex, to: messageData.endIndex, by: chunkSize) {
                        let chunkData = messageData[chunkStart ..< min(chunkStart + chunkSize, messageData.endIndex)]

                        if attemptToAddPacket(curPacketPtr, message, chunkData) == nil {
                            fatalError("Couldn't add packet for overlarge message -- logic error")
                        }
                        curPacketPtr = sendPacketList()
                    }
                }
            }

            // All messages have been processed. Send the last remaining packet list.
            if packetListPtr.pointee.numPackets > 0 {
                send(packetListPtr)
            }
        }
    }

}
