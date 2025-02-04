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

public class MIDIObject: NSObject, CoreMIDIObjectWrapper, CoreMIDIPropertyChangeHandling {

    unowned var midiContext: CoreMIDIContext    // Future: Should arguably be public, but with what type? CoreMIDIContext is internal, MIDIContext would be more useful.
    private(set) var midiObjectRef: MIDIObjectRef

    required init(context: CoreMIDIContext, objectRef: MIDIObjectRef) {
        precondition(objectRef != 0)

        self.midiContext = context
        self.midiObjectRef = objectRef
        super.init()

        // Immediately cache the object's uniqueID, since it could become
        // inaccessible later, if the object is removed from CoreMIDI
        _ = uniqueID
    }

    // MARK: Property value cache

    // To use the cache:
    //
    // 1. Create a CachedProperty with the MIDI property name and the type of its value.
    //
    // private lazy var cachedWhatever: CachedProperty =
    //     cacheProperty(kMIDIPropertyWhatever, String.self)
    //
    // 2. Access the cache via self[cachedWhatever]. Typically you would do this
    //    in the implementation of a computed property:
    //
    // public var whatever: String? {
    //    get { self[cachedWhatever] }
    //    set { self[cachedWhatever] = newValue }
    // }
    //
    // The cache will automatically be invalidated when CoreMIDI notifies us
    // that this object's kMIDIPropertyWhatever has changed.

    typealias CacheableValue = CoreMIDIPropertyValue & Equatable

    struct CachedProperty: Hashable {
        let property: CFString  // e.g. kMIDIPropertyUniqueID

        init(_ property: CFString) {
            self.property = property
        }
    }

    private var cachedValues: [CachedProperty: AnyCache] = [:]

    func cacheProperty<T: CacheableValue>(_ property: CFString, _ type: T.Type) -> CachedProperty {
        let cachedProperty = CachedProperty(property)
        guard cachedValues[cachedProperty] == nil else { fatalError("Trying to cache the same property twice: \(property)") }

        cachedValues[cachedProperty] = TypedCache<T>(
            getter: { self[property] },
            setter: { self[property] = $0 }
        ).asAnyCache

        return cachedProperty
    }

    private func withTypedCache<T: CacheableValue, Result>(_ cachedProperty: CachedProperty, _ perform: ((inout TypedCache<T>) -> Result)) -> Result {
        guard cachedValues[cachedProperty] != nil else { fatalError("Cache is missing for key \(cachedProperty.property)") }

        return cachedValues[cachedProperty]!.withTypedCache(perform)

        // NOTE: Calling withTypedCache() may cause the AnyCache to be mutated,
        // but since we're calling it on a value directly from a Dictionary subscript,
        // we can modify it in place.
        ///
        // If you ever introduce an intermediate variable, like
        // `if var anyCache = cachedValues[cachedProperty]`, it causes a local
        // copy of the AnyCache to be made. Any mutation only applies to it,
        // not the AnyCache in the dictionary, so you'd need to write it back
        // to cachedValues[] afterwards.
    }

    // Read and write through the cache with self[cachedProperty]
    subscript<T: CacheableValue>(cachedProperty: CachedProperty) -> T? {
        get {
            withTypedCache(cachedProperty) { $0.value }
        }
        set {
            withTypedCache(cachedProperty) { $0.value = newValue }
        }
    }

    private func invalidateCachedProperty(_ property: CFString) {
        cachedValues[CachedProperty(property)]?.base.invalidate()
        // NOTE: That didn't need to manually write back to the cache, it modified the value in place.

        // Always refetch the uniqueID immediately, since we might need it
        // in order to do lookups, and I don't trust that we will always
        // be notified of changes.
        if property == kMIDIPropertyUniqueID {
            _ = uniqueID
        }
    }

    // MARK: Specific properties

    private lazy var cachedUniqueID = cacheProperty(kMIDIPropertyUniqueID, MIDIUniqueID.self)
    private let fallbackUniqueID: MIDIUniqueID = 0
    public var uniqueID: MIDIUniqueID {
        get { self[cachedUniqueID] ?? fallbackUniqueID }
        set { self[cachedUniqueID] = newValue }
    }

    private lazy var cachedName = cacheProperty(kMIDIPropertyName, String.self)
    public var name: String? {
        get { self[cachedName] }
        set { self[cachedName] = newValue }
    }

    private lazy var cachedMaxSysExSpeed = cacheProperty(kMIDIPropertyMaxSysExSpeed, Int32.self)
    private let fallbackMaxSysExSpeed: Int32 = 3125 // bytes/sec for MIDI 1.0
    public var maxSysExSpeed: Int32 {
        get { self[cachedMaxSysExSpeed] ?? fallbackMaxSysExSpeed }
        set { self[cachedMaxSysExSpeed] = newValue }
    }

    // MARK: Property changes

    func midiPropertyChanged(_ property: CFString) {
        invalidateCachedProperty(property)
    }

    // MARK: Internal functions for rare uses

    func invalidateCachedProperties() {
        for cachedProperty in cachedValues.keys {
            invalidateCachedProperty(cachedProperty.property)
        }
    }

    func clearMIDIObjectRef() {
        // Called when this object has been removed from CoreMIDI
        // and it should no longer be used.
        midiObjectRef = 0
    }

}
