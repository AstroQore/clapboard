//
//  ClapboardDriver.c
//  Factory, COM plumbing and the IO half of the AudioServerPlugIn.
//
//  Loopback model
//  --------------
//  Each device owns one ring of kClapboard_RingFrames stereo Float32 frames.
//  The HAL hands the driver two operations per cycle and per client:
//
//    WriteMix  — a client's finished output mix. It is *added* into the ring
//                at mOutputTime.mSampleTime, so several apps writing at once
//                sum, exactly as they would into real hardware.
//    ReadInput — the input side. It copies out of the ring at
//                mInputTime.mSampleTime and then zeroes what it copied, so a
//                frame is delivered once and silence follows if nobody writes
//                again.
//
//  The device's zero-timestamp period equals the ring size, so the HAL's
//  sample time and the ring offset agree by construction: offset =
//  sampleTime % kClapboard_RingFrames.
//
//  Nothing in DoIOOperation()/GetZeroTimeStamp() allocates, locks or logs.
//

#include "ClapboardDriver.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <string.h>

static AudioServerPlugInDriverInterface  gClapboard_Interface;
static AudioServerPlugInDriverInterface* gClapboard_InterfacePtr = &gClapboard_Interface;
static AudioServerPlugInDriverRef        gClapboard_DriverRef    = &gClapboard_InterfacePtr;

static os_log_t Clapboard_DriverLog(void)
{
    static os_log_t sLog;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        sLog = os_log_create("com.astroqore.ClapboardDriver", "io");
    });
    return sLog;
}

//  Resolves a device object ID without taking the state mutex. Safe on the IO
//  thread: the device table is built before the driver ref is handed out and
//  torn down only after the last release.
static ClapboardDevice* Clapboard_DeviceForID(AudioObjectID inDeviceObjectID)
{
    ClapboardDevice* theDevice = NULL;
    if (Clapboard_ClassifyObject(inDeviceObjectID, &theDevice) == kClapboardObjectKind_Device) {
        return theDevice;
    }
    return NULL;
}

#pragma mark - COM

static HRESULT Clapboard_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != (void*)gClapboard_DriverRef) {
        return (HRESULT)kAudioHardwareBadObjectError;
    }
    if (outInterface == NULL) {
        return (HRESULT)kAudioHardwareIllegalOperationError;
    }

    HRESULT theResult = (HRESULT)E_NOINTERFACE;
    CFUUIDRef theRequested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (theRequested != NULL) {
        if (CFEqual(theRequested, IUnknownUUID) ||
            CFEqual(theRequested, kAudioServerPlugInDriverInterfaceUUID)) {
            if (Clapboard_StateRetain() > 0) {
                *outInterface = gClapboard_DriverRef;
                theResult = S_OK;
            } else {
                theResult = (HRESULT)kAudioHardwareUnspecifiedError;
            }
        }
        CFRelease(theRequested);
    }
    return theResult;
}

static ULONG Clapboard_AddRef(void* inDriver)
{
    if (inDriver != (void*)gClapboard_DriverRef) {
        return 0;
    }
    return (ULONG)Clapboard_StateRetain();
}

static ULONG Clapboard_Release(void* inDriver)
{
    if (inDriver != (void*)gClapboard_DriverRef) {
        return 0;
    }
    return (ULONG)Clapboard_StateRelease();
}

#pragma mark - Basic operations

static OSStatus Clapboard_Initialize(AudioServerPlugInDriverRef inDriver,
                                     AudioServerPlugInHostRef inHost)
{
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gClapboard_StateMutex);
    gClapboard_Host = inHost;
    const UInt32 theCount = gClapboard_DeviceCount;
    pthread_mutex_unlock(&gClapboard_StateMutex);

    os_log_info(Clapboard_DriverLog(), "Clapboard driver initialized with %u bus(es)",
                (unsigned)theCount);
    return (theCount > 0) ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
}

static OSStatus Clapboard_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                       CFDictionaryRef inDescription,
                                       const AudioServerPlugInClientInfo* inClientInfo,
                                       AudioObjectID* outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    //  The bus list is fixed at load time; the HAL may not add to it.
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Clapboard_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Clapboard_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    //  Nothing per-client to track: every client shares the one ring.
    return (Clapboard_DeviceForID(inDeviceObjectID) != NULL) ? kAudioHardwareNoError
                                                             : kAudioHardwareBadObjectError;
}

static OSStatus Clapboard_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return (Clapboard_DeviceForID(inDeviceObjectID) != NULL) ? kAudioHardwareNoError
                                                             : kAudioHardwareBadObjectError;
}

static OSStatus Clapboard_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID inDeviceObjectID,
                                                           UInt64 inChangeAction,
                                                           void* inChangeInfo)
{
    (void)inChangeInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    const Float64 theRate = (Float64)inChangeAction;
    if (!Clapboard_IsSupportedSampleRate(theRate)) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice == NULL) {
        pthread_mutex_unlock(&gClapboard_StateMutex);
        return kAudioHardwareBadObjectError;
    }

    //  The host has stopped IO for us, so the ring can be cleared here.
    theDevice->sampleRate        = theRate;
    theDevice->pendingSampleRate = 0.0;
    if (theDevice->ring != NULL) {
        memset(theDevice->ring, 0,
               (size_t)kClapboard_RingFrames * kClapboard_ChannelCount * sizeof(Float32));
    }
    Clapboard_ResetTimeline(theDevice);
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return kAudioHardwareNoError;
}

static OSStatus Clapboard_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                         AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction,
                                                         void* inChangeInfo)
{
    (void)inChangeAction;
    (void)inChangeInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice != NULL) {
        theDevice->pendingSampleRate = 0.0;
    }
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return (theDevice != NULL) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

#pragma mark - Property forwarding

static Boolean Clapboard_HasPropertyEntry(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress)
{
    if (inDriver != gClapboard_DriverRef) {
        return false;
    }
    return Clapboard_HasProperty(inObjectID, inClientProcessID, inAddress);
}

static OSStatus Clapboard_IsPropertySettableEntry(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress* inAddress,
                                                  Boolean* outIsSettable)
{
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return Clapboard_IsPropertySettable(inObjectID, inClientProcessID, inAddress, outIsSettable);
}

static OSStatus Clapboard_GetPropertyDataSizeEntry(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inObjectID,
                                                   pid_t inClientProcessID,
                                                   const AudioObjectPropertyAddress* inAddress,
                                                   UInt32 inQualifierDataSize,
                                                   const void* inQualifierData,
                                                   UInt32* outDataSize)
{
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return Clapboard_GetPropertyDataSize(inObjectID, inClientProcessID, inAddress,
                                         inQualifierDataSize, inQualifierData, outDataSize);
}

static OSStatus Clapboard_GetPropertyDataEntry(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress* inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void* inQualifierData,
                                               UInt32 inDataSize,
                                               UInt32* outDataSize,
                                               void* outData)
{
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return Clapboard_GetPropertyData(inObjectID, inClientProcessID, inAddress,
                                     inQualifierDataSize, inQualifierData,
                                     inDataSize, outDataSize, outData);
}

static OSStatus Clapboard_SetPropertyDataEntry(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress* inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void* inQualifierData,
                                               UInt32 inDataSize,
                                               const void* inData)
{
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return Clapboard_SetPropertyData(inObjectID, inClientProcessID, inAddress,
                                     inQualifierDataSize, inQualifierData, inDataSize, inData);
}

#pragma mark - IO

static OSStatus Clapboard_StartIO(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice == NULL) {
        pthread_mutex_unlock(&gClapboard_StateMutex);
        return kAudioHardwareBadObjectError;
    }

    if (theDevice->ioCount == 0) {
        //  First client on this bus: clear the ring and anchor the timeline.
        if (theDevice->ring != NULL) {
            memset(theDevice->ring, 0,
                   (size_t)kClapboard_RingFrames * kClapboard_ChannelCount * sizeof(Float32));
        }
        Clapboard_ResetTimeline(theDevice);
        atomic_store_explicit(&theDevice->running, true, memory_order_release);
    }
    ++theDevice->ioCount;
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return kAudioHardwareNoError;
}

static OSStatus Clapboard_StopIO(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inDeviceObjectID,
                                 UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice == NULL) {
        pthread_mutex_unlock(&gClapboard_StateMutex);
        return kAudioHardwareBadObjectError;
    }

    if (theDevice->ioCount > 0) {
        --theDevice->ioCount;
    }
    if (theDevice->ioCount == 0) {
        atomic_store_explicit(&theDevice->running, false, memory_order_release);
    }
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return kAudioHardwareNoError;
}

static OSStatus Clapboard_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID,
                                           Float64* outSampleTime,
                                           UInt64* outHostTime,
                                           UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice == NULL || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareBadObjectError;
    }

    const UInt64 theTicksPerRing =
        atomic_load_explicit(&theDevice->hostTicksPerRing, memory_order_relaxed);
    if (theTicksPerRing == 0) {
        return kAudioHardwareUnspecifiedError;
    }

    const UInt64 theAnchor =
        atomic_load_explicit(&theDevice->anchorHostTime, memory_order_relaxed);
    UInt64 theCount = atomic_load_explicit(&theDevice->timeStampCount, memory_order_relaxed);

    //  One period per ring. Only this thread advances the counter.
    const UInt64 theNow = mach_absolute_time();
    if (theNow >= theAnchor + (theTicksPerRing * (theCount + 1))) {
        ++theCount;
        atomic_store_explicit(&theDevice->timeStampCount, theCount, memory_order_relaxed);
    }

    *outSampleTime = (Float64)(theCount * (UInt64)kClapboard_RingFrames);
    *outHostTime   = theAnchor + (theTicksPerRing * theCount);
    *outSeed       = atomic_load_explicit(&theDevice->timeLineSeed, memory_order_relaxed);
    return kAudioHardwareNoError;
}

static OSStatus Clapboard_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            Boolean* outWillDo,
                                            Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (Clapboard_DeviceForID(inDeviceObjectID) == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    const Boolean theWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput) ||
                              (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDo        = theWillDo;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Clapboard_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID,
                                           UInt32 inOperationID,
                                           UInt32 inIOBufferFrameSize,
                                           const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return (Clapboard_DeviceForID(inDeviceObjectID) != NULL) ? kAudioHardwareNoError
                                                             : kAudioHardwareBadObjectError;
}

static OSStatus Clapboard_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return (Clapboard_DeviceForID(inDeviceObjectID) != NULL) ? kAudioHardwareNoError
                                                             : kAudioHardwareBadObjectError;
}

//  Sample time -> ring offset. Negative sample times can only turn up if the
//  host asks for data from before the anchor; treat them as the ring origin.
static inline UInt32 Clapboard_RingOffset(Float64 inSampleTime)
{
    if (!(inSampleTime > 0.0)) {
        return 0;
    }
    const UInt64 theSampleTime = (UInt64)inSampleTime;
    return (UInt32)(theSampleTime % (UInt64)kClapboard_RingFrames);
}

static OSStatus Clapboard_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        AudioObjectID inStreamObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                        void* ioMainBuffer,
                                        void* ioSecondaryBuffer)
{
    (void)inStreamObjectID;
    (void)inClientID;
    (void)ioSecondaryBuffer;

    if (inDriver != gClapboard_DriverRef) {
        return kAudioHardwareBadObjectError;
    }

    ClapboardDevice* theDevice = Clapboard_DeviceForID(inDeviceObjectID);
    if (theDevice == NULL || theDevice->ring == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL || inIOBufferFrameSize == 0) {
        return kAudioHardwareNoError;
    }

    UInt32 theFrames = inIOBufferFrameSize;
    if (theFrames > (UInt32)kClapboard_RingFrames) {
        theFrames = (UInt32)kClapboard_RingFrames;
    }

    Float32* const theRing = theDevice->ring;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        const bool theMuted = atomic_load_explicit(&theDevice->muted, memory_order_relaxed);
        const Float32 theGain =
            theMuted ? 0.0f : atomic_load_explicit(&theDevice->gain, memory_order_relaxed);
        if (theGain == 0.0f) {
            return kAudioHardwareNoError;
        }

        const Float32* theSource = (const Float32*)ioMainBuffer;
        UInt32 theOffset    = Clapboard_RingOffset(inIOCycleInfo->mOutputTime.mSampleTime);
        UInt32 theRemaining = theFrames;
        while (theRemaining > 0) {
            UInt32 theChunk = (UInt32)kClapboard_RingFrames - theOffset;
            if (theChunk > theRemaining) {
                theChunk = theRemaining;
            }
            Float32* theDestination = theRing + ((size_t)theOffset * kClapboard_ChannelCount);
            const UInt32 theSamples = theChunk * (UInt32)kClapboard_ChannelCount;
            for (UInt32 i = 0; i < theSamples; ++i) {
                theDestination[i] += theSource[i] * theGain;
            }
            theSource    += theSamples;
            theRemaining -= theChunk;
            theOffset     = 0;
        }
        return kAudioHardwareNoError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        Float32* theDestination = (Float32*)ioMainBuffer;
        UInt32 theOffset    = Clapboard_RingOffset(inIOCycleInfo->mInputTime.mSampleTime);
        UInt32 theRemaining = theFrames;
        while (theRemaining > 0) {
            UInt32 theChunk = (UInt32)kClapboard_RingFrames - theOffset;
            if (theChunk > theRemaining) {
                theChunk = theRemaining;
            }
            Float32* theSource = theRing + ((size_t)theOffset * kClapboard_ChannelCount);
            const size_t theBytes =
                (size_t)theChunk * kClapboard_ChannelCount * sizeof(Float32);
            memcpy(theDestination, theSource, theBytes);
            //  Hand each frame out once: what has been read is now silence.
            memset(theSource, 0, theBytes);
            theDestination += (size_t)theChunk * kClapboard_ChannelCount;
            theRemaining   -= theChunk;
            theOffset       = 0;
        }
        return kAudioHardwareNoError;
    }

    return kAudioHardwareNoError;
}

#pragma mark - Interface table and factory

static AudioServerPlugInDriverInterface gClapboard_Interface = {
    ._reserved                        = NULL,
    .QueryInterface                   = Clapboard_QueryInterface,
    .AddRef                           = Clapboard_AddRef,
    .Release                          = Clapboard_Release,
    .Initialize                       = Clapboard_Initialize,
    .CreateDevice                     = Clapboard_CreateDevice,
    .DestroyDevice                    = Clapboard_DestroyDevice,
    .AddDeviceClient                  = Clapboard_AddDeviceClient,
    .RemoveDeviceClient               = Clapboard_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = Clapboard_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange   = Clapboard_AbortDeviceConfigurationChange,
    .HasProperty                      = Clapboard_HasPropertyEntry,
    .IsPropertySettable               = Clapboard_IsPropertySettableEntry,
    .GetPropertyDataSize              = Clapboard_GetPropertyDataSizeEntry,
    .GetPropertyData                  = Clapboard_GetPropertyDataEntry,
    .SetPropertyData                  = Clapboard_SetPropertyDataEntry,
    .StartIO                          = Clapboard_StartIO,
    .StopIO                           = Clapboard_StopIO,
    .GetZeroTimeStamp                 = Clapboard_GetZeroTimeStamp,
    .WillDoIOOperation                = Clapboard_WillDoIOOperation,
    .BeginIOOperation                 = Clapboard_BeginIOOperation,
    .DoIOOperation                    = Clapboard_DoIOOperation,
    .EndIOOperation                   = Clapboard_EndIOOperation,
};

//  Referenced from Info.plist -> CFPlugInFactories.
void* ClapboardDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (inRequestedTypeUUID == NULL) {
        return NULL;
    }
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    if (Clapboard_StateRetain() == 0) {
        return NULL;
    }
    return gClapboard_DriverRef;
}
