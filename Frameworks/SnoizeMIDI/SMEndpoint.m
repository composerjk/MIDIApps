//
// Copyright 2001-2002 Kurt Revis. All rights reserved.
//

#import "SMEndpoint.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "SMClient.h"


@interface SMEndpoint (Private)

typedef struct EndpointUniqueNamesFlags {
    unsigned int areNamesUnique:1;
    unsigned int haveNamesAlwaysBeenUnique:1;
} EndpointUniqueNamesFlags;

+ (void)_earlyMIDISetup;
+ (void)_midiClientCreated:(NSNotification *)notification;
+ (void)_midiSetupChanged:(NSNotification *)notification;

+ (NSMapTable **)_endpointMapTablePtr;
+ (ItemCount)_endpointCount;
+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index;
+ (ItemCount)_endpointCountForEntity:(MIDIEntityRef)entity;
+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index forEntity:(MIDIEntityRef)entity;

+ (void)_reloadEndpoints;
+ (NSArray *)_allEndpoints;
+ (NSArray *)_allEndpointsSortedByOrdinal;
+ (SMEndpoint *)_endpointMatchingUniqueID:(SInt32)uniqueID;
+ (SMEndpoint *)_endpointMatchingName:(NSString *)aName;
+ (SMEndpoint *)_endpointForEndpointRef:(MIDIEndpointRef)anEndpointRef;

+ (BOOL)_doEndpointsHaveUniqueNames;
+ (BOOL)_haveEndpointsAlwaysHadUniqueNames;
+ (void)_checkForUniqueNames;

- (void)_updateUniqueID;
- (void)_invalidateCachedProperties;

- (MIDIDeviceRef)_findDevice;
- (MIDIDeviceRef)_device;
- (NSString *)_deviceName;
- (NSString *)_deviceStringForProperty:(CFStringRef)property;

- (SInt32)_ownerPID;
- (void)_setOwnerPID:(SInt32)value;

- (NSString *)_stringForProperty:(CFStringRef)property;
- (void)_setString:(NSString *)value forProperty:(CFStringRef)property;

- (SInt32)_integerForProperty:(CFStringRef)property;
- (void)_setInteger:(SInt32)value forProperty:(CFStringRef)property;

- (void)_setOrdinal:(unsigned int)value;
- (unsigned int)_ordinal;
static int endpointOrdinalComparator(id endpoint1, id endpoint2, void *context);

- (void)_checkIfPropertySetIsAllowed;

- (void)_postRemovedNotification;
- (void)_postReplacedNotificationWithReplacement:(SMEndpoint *)replacement;

@end


@implementation SMEndpoint

DEFINE_NSSTRING(SMEndpointsAppearedNotification);
DEFINE_NSSTRING(SMEndpointDisappearedNotification);
DEFINE_NSSTRING(SMEndpointWasReplacedNotification);
DEFINE_NSSTRING(SMEndpointReplacement);

DEFINE_NSSTRING(SMEndpointPropertyOwnerPID);


+ (SInt32)generateNewUniqueID;
{
    SInt32 proposed;
    static SInt32 sequence = 0;

    while (1) {
        // We could get fancy, but just using the current time is likely to work just fine.
        // Add a sequence number in case this method is called more than once within a second.
        proposed = time(NULL);
        proposed += sequence;
        sequence++;

        // Make sure this uniqueID is not in use, just in case
        if ([SMSourceEndpoint sourceEndpointWithUniqueID:proposed] == nil && [SMDestinationEndpoint destinationEndpointWithUniqueID:proposed] == nil)
            break;
    }

    return proposed;
}

- (id)initWithEndpointRef:(MIDIEndpointRef)anEndpointRef;
{
    if (!(self = [super init]))
        return nil;

    OBPRECONDITION(anEndpointRef);
    endpointRef = anEndpointRef;

    // Save the endpoint's uniqueID, since it could become inaccessible later (if the endpoint goes away).
    [self _updateUniqueID];

    // We start out not knowing the endpoint's device (if it has one). We'll look it up on demand.
    deviceRef = NULL;
    flags.hasLookedForDevice = NO;

    // Nothing has been cached yet 
    flags.hasCachedName = NO;
    flags.hasCachedManufacturerName = NO;
    flags.hasCachedModelName = NO;
    flags.hasCachedDeviceName = NO;

    return self;
}

- (void)dealloc;
{
    [cachedName release];
    cachedName = nil;
    [cachedManufacturerName release];
    cachedManufacturerName = nil;
    [cachedModelName release];
    cachedModelName = nil;
    [cachedDeviceName release];
    cachedDeviceName = nil;

    [super dealloc];
}

- (MIDIEndpointRef)endpointRef;
{
    return endpointRef;
}

- (BOOL)isVirtual;
{
    // We are virtual if we have no device
    return ([self _device] == NULL);
}

- (BOOL)isOwnedByThisProcess;
{
    return ([self isVirtual] && ([self _ownerPID] == getpid()));
}

- (void)setIsOwnedByThisProcess;
{
    // We have sort of a chicken-egg problem here. When setting values of properties, we want
    // to make sure that the endpoint is owned by this process. However, there's no way to
    // tell if the endpoint is owned by this process until it gets a property set on it.
    // So we'll say that this method should be called first, before any other setters are called.
    
    if (![self isVirtual]) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Endpoint is not virtual, so it can't be owned by this process", @"SnoizeMIDI", [self bundle], "exception if someone calls -setIsOwnedByThisProcess on a non-virtual endpoint")];
    }
    
    [self _setOwnerPID:getpid()];
}

- (SInt32)uniqueID;
{
    return uniqueID;
}

- (void)setUniqueID:(SInt32)value;
{
    OSStatus status;

    if (value == uniqueID)
        return;

    [self _checkIfPropertySetIsAllowed];

    status = MIDIObjectSetIntegerProperty(endpointRef, kMIDIPropertyUniqueID, value);
    if (status) {
        // Ignore failure... not sure if this is the right thing to do or not.
    }

    // Refresh our idea of the unique ID since it may or may not have changed
    [self _updateUniqueID];
}

- (NSString *)name;
{
    if (!flags.hasCachedName) {
        [cachedName release];
        cachedName = [[self _stringForProperty:kMIDIPropertyName] retain];
        flags.hasCachedName = YES;
    }
    
    return cachedName;
}

- (void)setName:(NSString *)value;
{
    if (![value isEqualToString:[self name]]) {
        [self _setString:value forProperty:kMIDIPropertyName];
        flags.hasCachedName = NO;
    }
}

- (NSString *)manufacturerName;
{
    if (!flags.hasCachedManufacturerName) {
        [cachedManufacturerName release];

        cachedManufacturerName = [self _stringForProperty:kMIDIPropertyManufacturer];
        // NOTE This fails sometimes on 10.1.3 and earlier (see bug #2865704).
        // So we fall back to asking for the device's manufacturer name if necessary.        
        if (!cachedManufacturerName)
            cachedManufacturerName = [self _deviceStringForProperty:kMIDIPropertyManufacturer];

        [cachedManufacturerName retain];
        flags.hasCachedManufacturerName = YES;        
    }

    return cachedManufacturerName;
}

- (void)setManufacturerName:(NSString *)value;
{
    if (![value isEqualToString:[self manufacturerName]]) {
        [self _setString:value forProperty:kMIDIPropertyManufacturer];
        flags.hasCachedManufacturerName = NO;
    }
}

- (NSString *)modelName;
{
    if (!flags.hasCachedModelName) {
        [cachedModelName release];
        cachedModelName = [[self _stringForProperty:kMIDIPropertyModel] retain];

        flags.hasCachedModelName = YES;
    }

    return cachedModelName;
}

- (void)setModelName:(NSString *)value;
{
    if (![value isEqualToString:[self modelName]]) {
        [self _setString:value forProperty:kMIDIPropertyModel];
        flags.hasCachedModelName = NO;
    }
}

- (NSString *)uniqueName;
{
    if ([[self class] _doEndpointsHaveUniqueNames])
        return [self name];
    else
        return [self longName];
}

- (NSString *)alwaysUniqueName;
{
    if ([[self class] _haveEndpointsAlwaysHadUniqueNames])
        return [self name];
    else
        return [self longName];    
}

- (NSString *)longName;
{
    NSString *endpointName, *modelOrDeviceName;

    endpointName = [self name];

    if ([self isVirtual]) {
        modelOrDeviceName = [self modelName];
    } else {
        modelOrDeviceName = [self _deviceName];
    }
    
    if (modelOrDeviceName && [modelOrDeviceName length] > 0)
        return [[modelOrDeviceName stringByAppendingString:@" "] stringByAppendingString:endpointName];
    else
        return endpointName;
}

- (SInt32)advanceScheduleTime;
{
    return [self _integerForProperty:kMIDIPropertyAdvanceScheduleTimeMuSec];
}

- (void)setAdvanceScheduleTime:(SInt32)newValue;
{
    [self _setInteger:newValue forProperty:kMIDIPropertyAdvanceScheduleTimeMuSec];
}

- (id)allProperties;
{
    OSStatus status;
    id propertyList;

    status = MIDIObjectGetProperties(endpointRef, (CFPropertyListRef *)&propertyList, NO);	// Not deep
    if (status != noErr)
        propertyList = nil;

    return [propertyList autorelease];
}

- (BOOL)needsSysExWorkaround;
{
    // Returns YES if the endpoint is provided by the broken MIDIMAN driver, which can't send more than 3 bytes of sysex at once.
    //
    // Unfortunately we don't have a really good way of identifying this broken driver -- there isn't an obvious version number
    // that we can get through CoreMIDI.
    // (We could use the string property kMIDIPropertyDriverOwner, go through the possible MIDI Drivers directories,
    // track down the bundle, and get the CFBundleVersion out of it...)
    // But these drivers also unnecessarily put "MIDIMAN MIDISPORT " at the beginning of each endpoint name, which got
    // fixed in the next release.

    return ([[self manufacturerName] isEqualToString:@"MIDIMAN"] && [[self name] hasPrefix:@"MIDIMAN "]);
}

@end


@implementation SMEndpoint (Private)

+ (void)_earlyMIDISetup;
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_midiClientCreated:) name:SMClientCreatedInternalNotification object:nil];
}

+ (void)_midiClientCreated:(NSNotification *)notification;
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_midiSetupChanged:) name:SMClientSetupChangedInternalNotification object:[SMClient sharedClient]];
    [self _midiSetupChanged:nil];
}

+ (void)_midiSetupChanged:(NSNotification *)notification
{
    [self _reloadEndpoints];
}

+ (NSMapTable **)_endpointMapTablePtr;
{
    OBRequestConcreteImplementation(self, _cmd);
    return NULL;
}

+ (EndpointUniqueNamesFlags *)_endpointUniqueNamesFlagsPtr;
{
    OBRequestConcreteImplementation(self, _cmd);
    return NULL;
}

+ (ItemCount)_endpointCount;
{
    OBRequestConcreteImplementation(self, _cmd);
    return 0;
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index;
{
    OBRequestConcreteImplementation(self, _cmd);
    return NULL;
}

+ (ItemCount)_endpointCountForEntity:(MIDIEntityRef)entity;
{
    OBRequestConcreteImplementation(self, _cmd);
    return 0;
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index forEntity:(MIDIEntityRef)entity;
{
    OBRequestConcreteImplementation(self, _cmd);
    return NULL;
}

+ (void)_reloadEndpoints;
{
    NSMapTable **mapTablePtr;
    NSMapTable *oldMapTable, *newMapTable;
    ItemCount endpointIndex, endpointCount;
    NSMutableArray *removedEndpoints, *replacedEndpoints, *replacementEndpoints, *addedEndpoints;

    endpointCount = [self _endpointCount];

    mapTablePtr = [self _endpointMapTablePtr];
    OBASSERT(mapTablePtr != NULL);
    oldMapTable = *mapTablePtr;
    newMapTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSObjectMapValueCallBacks, endpointCount);    

    // We start out assuming all endpoints have been removed, none have been replaced.
    // As we find out otherwise, we remove some endpoints from removedEndpoints,
    // and add some to replacedEndpoints.
    removedEndpoints = [NSMutableArray arrayWithArray:[self _allEndpoints]];
    replacedEndpoints = [NSMutableArray array];
    replacementEndpoints = [NSMutableArray array];
    addedEndpoints = [NSMutableArray array];

    // Iterate through the new endpointRefs.
    for (endpointIndex = 0; endpointIndex < endpointCount; endpointIndex++) {
        MIDIEndpointRef anEndpointRef;
        SMEndpoint *endpoint;

        anEndpointRef = [self _endpointAtIndex:endpointIndex];
        if (anEndpointRef == NULL)
            continue;
        
        if ((endpoint = [self _endpointForEndpointRef:anEndpointRef])) {
            // This endpointRef existed previously.
            [removedEndpoints removeObjectIdenticalTo:endpoint];
            // It's possible that its uniqueID changed, though.
            [endpoint _updateUniqueID];
            // And its ordinal may also have changed...
            [endpoint _setOrdinal:endpointIndex];
        } else {
            SMEndpoint *replacedEndpoint;

            // This endpointRef did not previously exist, so create a new endpoint for it.
            endpoint = [[[self alloc] initWithEndpointRef:anEndpointRef] autorelease];
            [endpoint _setOrdinal:endpointIndex];
            
            // If the new endpoint has the same uniqueID as an old endpoint, remember it.
            if ((replacedEndpoint = [self _endpointMatchingUniqueID:[endpoint uniqueID]])) {
                [replacedEndpoints addObject:replacedEndpoint];
                [replacementEndpoints addObject:endpoint];
                [removedEndpoints removeObjectIdenticalTo:replacedEndpoint];
            } else {
                [addedEndpoints addObject:endpoint];
            }
        }

        NSMapInsert(newMapTable, anEndpointRef, endpoint);
    }
    
    if (oldMapTable)
        NSFreeMapTable(oldMapTable);
    *mapTablePtr = newMapTable;

    // Make the new group of endpoints invalidate their cached properties (names and such).
    [[self _allEndpoints] makeObjectsPerformSelector:@selector(_invalidateCachedProperties)];

    // And check if the names are unique or not
    [self _checkForUniqueNames];

    // Now everything is in place for the new regime. Have the endpoints post notifications of their change in status.
    [removedEndpoints makeObjectsPerformSelector:@selector(_postRemovedNotification)];

    endpointIndex = [replacedEndpoints count];
    while (endpointIndex--) {
        [[replacedEndpoints objectAtIndex:endpointIndex] _postReplacedNotificationWithReplacement:[replacementEndpoints objectAtIndex:endpointIndex]];
    }

    if ([addedEndpoints count] > 0)
        [[NSNotificationCenter defaultCenter] postNotificationName:SMEndpointsAppearedNotification object:addedEndpoints];
}

+ (NSArray *)_allEndpoints;
{
    NSMapTable **mapTablePtr;

    mapTablePtr = [self _endpointMapTablePtr];
    OBASSERT(mapTablePtr);

    if (*mapTablePtr)
        return NSAllMapTableValues(*mapTablePtr);
    else
        return nil;
}

+ (NSArray *)_allEndpointsSortedByOrdinal;
{
    return [[self _allEndpoints] sortedArrayUsingFunction:endpointOrdinalComparator context:NULL];
}

+ (SMEndpoint *)_endpointMatchingUniqueID:(SInt32)aUniqueID;
{
    NSArray *allEndpoints;
    unsigned int endpointIndex;

    allEndpoints = [self _allEndpoints];
    endpointIndex = [allEndpoints count];
    while (endpointIndex--) {
        SMEndpoint *endpoint;

        endpoint = [allEndpoints objectAtIndex:endpointIndex];
        if ([endpoint uniqueID] == aUniqueID)
            return endpoint;
    }

    return nil;
}

+ (SMEndpoint *)_endpointMatchingName:(NSString *)aName;
{
    NSArray *allEndpoints;
    unsigned int endpointIndex;

    if (!aName)
        return nil;

    allEndpoints = [self _allEndpoints];
    endpointIndex = [allEndpoints count];
    while (endpointIndex--) {
        SMEndpoint *endpoint;

        endpoint = [allEndpoints objectAtIndex:endpointIndex];
        if ([[endpoint name] isEqualToString:aName])
            return endpoint;
    }

    return nil;
}

+ (SMEndpoint *)_endpointForEndpointRef:(MIDIEndpointRef)anEndpointRef;
{
    NSMapTable **mapTablePtr;

    mapTablePtr = [self _endpointMapTablePtr];
    OBASSERT(mapTablePtr);

    if (*mapTablePtr)
        return NSMapGet(*mapTablePtr, anEndpointRef);
    else
        return nil;        
}

+ (BOOL)_doEndpointsHaveUniqueNames;
{
    return [self _endpointUniqueNamesFlagsPtr]->areNamesUnique;
}

+ (BOOL)_haveEndpointsAlwaysHadUniqueNames;
{
    return [self _endpointUniqueNamesFlagsPtr]->haveNamesAlwaysBeenUnique;
}

+ (void)_checkForUniqueNames;
{
    NSArray *endpoints;
    NSArray *nameArray, *nameSet;
    BOOL areNamesUnique;
    struct EndpointUniqueNamesFlags *flagsPtr;

    endpoints = [self _allEndpoints];
    nameArray = [endpoints arrayByPerformingSelector:@selector(name)];
    nameSet = [NSSet setWithArray:nameArray];

    areNamesUnique = ([nameArray count] == [nameSet count]);

    flagsPtr = [self _endpointUniqueNamesFlagsPtr];
    flagsPtr->areNamesUnique = areNamesUnique;
    flagsPtr->haveNamesAlwaysBeenUnique = flagsPtr->haveNamesAlwaysBeenUnique && areNamesUnique;
}

- (void)_updateUniqueID;
{
    if (noErr != MIDIObjectGetIntegerProperty(endpointRef, kMIDIPropertyUniqueID, &uniqueID))
        uniqueID = 0;
}

- (void)_invalidateCachedProperties;
{
    flags.hasLookedForDevice = NO;
    flags.hasCachedName = NO;
    flags.hasCachedManufacturerName = NO;
    flags.hasCachedModelName = NO;
    flags.hasCachedDeviceName = NO;
}

- (MIDIDeviceRef)_findDevice;
{
    // Walk the device/entity/endpoint tree, looking for the device which has our endpointRef.
    // CoreMIDI should provide an easier way to get at this.
    // Note that if this endpoint is virtual, no device will be found.

    ItemCount deviceCount, deviceIndex;
    
    deviceCount = MIDIGetNumberOfDevices();
    for (deviceIndex = 0; deviceIndex < deviceCount; deviceIndex++) {
        MIDIDeviceRef device;
        ItemCount entityCount, entityIndex;
        
        device = MIDIGetDevice(deviceIndex);
        entityCount = MIDIDeviceGetNumberOfEntities(device);
        
        for (entityIndex = 0; entityIndex < entityCount; entityIndex++) {
            MIDIEntityRef entity;
            ItemCount endpointCount, endpointIndex;
            
            entity = MIDIDeviceGetEntity(device, entityIndex);
            endpointCount = [[self class] _endpointCountForEntity:entity];
            for (endpointIndex = 0; endpointIndex < endpointCount; endpointIndex++) {
                MIDIEndpointRef thisEndpoint;
                
                thisEndpoint = [[self class] _endpointAtIndex:endpointIndex forEntity:entity];
                if (thisEndpoint == endpointRef) {
                    // Found it!
                    return device;
                }
            }
        }
    }
    
    // Nothing was found
    return NULL;
}

- (MIDIDeviceRef)_device;
{
    if (!flags.hasLookedForDevice) {
        deviceRef = [self _findDevice];
        flags.hasLookedForDevice = YES;
    }

    return deviceRef;
}

- (NSString *)_deviceName;
{
    if (!flags.hasCachedDeviceName) {
        [cachedDeviceName release];
        cachedDeviceName = [[self _deviceStringForProperty:kMIDIPropertyName] retain];

        flags.hasCachedDeviceName = YES;        
    }
    
    return cachedDeviceName;
}

- (NSString *)_deviceStringForProperty:(CFStringRef)property;
{
    MIDIDeviceRef device;
    NSString *string;

    device = [self _device];
    if (device && (noErr == MIDIObjectGetStringProperty(device, property, (CFStringRef *)&string)))
        return [string autorelease];
    else
        return nil;
}

- (SInt32)_ownerPID;
{
    OSStatus status;
    SInt32 ownerPID;

    status = MIDIObjectGetIntegerProperty(endpointRef, (CFStringRef)SMEndpointPropertyOwnerPID, &ownerPID);
    if (status)
        return 0;
    else
        return ownerPID;
}

- (void)_setOwnerPID:(SInt32)value;
{
    OSStatus status;
    
    status = MIDIObjectSetIntegerProperty(endpointRef, (CFStringRef)SMEndpointPropertyOwnerPID, value);
    if (status) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Couldn't set owner PID on endpoint: error %ld", @"SnoizeMIDI", [self bundle], "exception with OSStatus if setting endpoint's owner PID fails"), status];
    }
}

- (NSString *)_stringForProperty:(CFStringRef)property;
{
    NSString *string;
    
    if (noErr == MIDIObjectGetStringProperty(endpointRef, property, (CFStringRef *)&string))
        return [string autorelease];
    else
        return nil;
}

- (void)_setString:(NSString *)value forProperty:(CFStringRef)property;
{
    OSStatus status;
    
    [self _checkIfPropertySetIsAllowed];

    status = MIDIObjectSetStringProperty(endpointRef, property, (CFStringRef)value);
    if (status) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Couldn't set endpoint's property %@ (error %ld)", @"SnoizeMIDI", [self bundle], "exception with property and OSStatus if setting endpoint's property fails"), property, status];
    }
}

- (SInt32)_integerForProperty:(CFStringRef)property;
{
    OSStatus status;
    SInt32 value;
    
    status = MIDIObjectGetIntegerProperty(endpointRef, property, &value);
    if (status) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Couldn't get endpoint's property %@ (error %ld)", @"SnoizeMIDI", [self bundle], "exception with property and OSStatus if getting endpoint's property fails"), property, status];
    }
    
    return value;    
}

- (void)_setInteger:(SInt32)value forProperty:(CFStringRef)property;
{
    OSStatus status;

    [self _checkIfPropertySetIsAllowed];
    
    status = MIDIObjectSetIntegerProperty(endpointRef, property, value);
    if (status) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Couldn't set endpoint's property %@ (error %ld)", @"SnoizeMIDI", [self bundle], "exception with property and OSStatus if setting endpoint's property fails"), property, status];
    }
}

- (void)_setOrdinal:(unsigned int)value;
{
    ordinal = value;
}

- (unsigned int)_ordinal;
{
    return ordinal;
}

static int endpointOrdinalComparator(id object1, id object2, void *context)
{
    unsigned int ordinal1, ordinal2;

    ordinal1 = [object1 _ordinal];
    ordinal2 = [object2 _ordinal];
        
    if (ordinal1 > ordinal2)
        return NSOrderedDescending;
    else if (ordinal1 == ordinal2)
        return NSOrderedSame;
    else
        return NSOrderedAscending;
}

- (void)_checkIfPropertySetIsAllowed;
{
    if (![self isOwnedByThisProcess]) {
        [NSException raise:NSGenericException format:NSLocalizedStringFromTableInBundle(@"Can't set a property on an endpoint we don't own", @"SnoizeMIDI", [self bundle], "exception if someone tries to set a property on an endpoint we don't own")];
    }
}

- (void)_postRemovedNotification;
{
    [[NSNotificationCenter defaultCenter] postNotificationName:SMEndpointDisappearedNotification object:self];
}

- (void)_postReplacedNotificationWithReplacement:(SMEndpoint *)replacement;
{
    NSDictionary *userInfo;
    
    OBASSERT(replacement != NULL);
    userInfo = [NSDictionary dictionaryWithObjectsAndKeys:replacement, SMEndpointReplacement, nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:SMEndpointWasReplacedNotification object:self userInfo:userInfo];
}

@end


@implementation SMSourceEndpoint

static NSMapTable *sourceEndpointRefToSMEndpointMapTable = NULL;
static EndpointUniqueNamesFlags sourceEndpointUniqueNamesFlags = { YES, YES };

+ (void)didLoad
{
    [self _earlyMIDISetup];
}

+ (NSMapTable **)_endpointMapTablePtr;
{
    return &sourceEndpointRefToSMEndpointMapTable;
}

+ (EndpointUniqueNamesFlags *)_endpointUniqueNamesFlagsPtr;
{
    return &sourceEndpointUniqueNamesFlags;
}

+ (ItemCount)_endpointCount;
{
    return MIDIGetNumberOfSources();
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index;
{
    return MIDIGetSource(index);
}

+ (ItemCount)_endpointCountForEntity:(MIDIEntityRef)entity;
{
    return MIDIEntityGetNumberOfSources(entity);
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index forEntity:(MIDIEntityRef)entity;
{
    return MIDIEntityGetSource(entity, index);
}


+ (NSArray *)sourceEndpoints;
{
    return [self _allEndpointsSortedByOrdinal];
}

+ (SMSourceEndpoint *)sourceEndpointWithUniqueID:(SInt32)aUniqueID;
{
    return (SMSourceEndpoint *)[self _endpointMatchingUniqueID:aUniqueID];
}

+ (SMSourceEndpoint *)sourceEndpointWithName:(NSString *)aName;
{
    return (SMSourceEndpoint *)[self _endpointMatchingName:aName];
}

+ (SMSourceEndpoint *)sourceEndpointWithEndpointRef:(MIDIEndpointRef)anEndpointRef;
{
    return (SMSourceEndpoint *)[self _endpointForEndpointRef:anEndpointRef];
}


- (NSString *)inputStreamSourceName;
{
    return [self uniqueName];
}

- (NSNumber *)inputStreamSourceUniqueID;
{
    return [NSNumber numberWithInt:[self uniqueID]];
}

@end


@implementation SMDestinationEndpoint

static NSMapTable *destinationEndpointRefToSMEndpointMapTable = NULL;
static EndpointUniqueNamesFlags destinationEndpointUniqueNamesFlags = { YES, YES };

+ (void)didLoad
{
    [self _earlyMIDISetup];
}

+ (NSMapTable **)_endpointMapTablePtr;
{
    return &destinationEndpointRefToSMEndpointMapTable;
}

+ (EndpointUniqueNamesFlags *)_endpointUniqueNamesFlagsPtr;
{
    return &destinationEndpointUniqueNamesFlags;
}

+ (ItemCount)_endpointCount;
{
    return MIDIGetNumberOfDestinations();
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index;
{
    return MIDIGetDestination(index);
}

+ (ItemCount)_endpointCountForEntity:(MIDIEntityRef)entity;
{
    return MIDIEntityGetNumberOfDestinations(entity);
}

+ (MIDIEndpointRef)_endpointAtIndex:(ItemCount)index forEntity:(MIDIEntityRef)entity;
{
    return MIDIEntityGetDestination(entity, index);
}


+ (NSArray *)destinationEndpoints;
{
    return [self _allEndpointsSortedByOrdinal];
}

+ (SMDestinationEndpoint *)destinationEndpointWithUniqueID:(SInt32)aUniqueID;
{
    return (SMDestinationEndpoint *)[self _endpointMatchingUniqueID:aUniqueID];
}

+ (SMDestinationEndpoint *)destinationEndpointWithName:(NSString *)aName;
{
    return (SMDestinationEndpoint *)[self _endpointMatchingName:aName];
}

+ (SMDestinationEndpoint *)destinationEndpointWithEndpointRef:(MIDIEndpointRef)anEndpointRef;
{
    return (SMDestinationEndpoint *)[self _endpointForEndpointRef:anEndpointRef];
}

@end
