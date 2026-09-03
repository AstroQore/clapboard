//
//  ClapboardState.c
//  Global driver state: device table, lifetime, timeline and volume maths.
//
//  Nothing in this file may be called from the IO thread except
//  Clapboard_HostTicksPerRing() (pure) and the inline atomic reads the IO
//  path does itself.
//

#include "ClapboardDriver.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

const Float64 kClapboard_SampleRates[] = { 44100.0, 48000.0, 96000.0 };
const UInt32  kClapboard_SampleRateCount =
    (UInt32)(sizeof(kClapboard_SampleRates) / sizeof(kClapboard_SampleRates[0]));

#define kClapboard_DefaultSampleRate 48000.0

pthread_mutex_t          gClapboard_StateMutex = PTHREAD_MUTEX_INITIALIZER;
AudioServerPlugInHostRef gClapboard_Host       = NULL;
ClapboardDevice          gClapboard_Devices[kClapboard_MaxDeviceCount];
UInt32                   gClapboard_DeviceCount = 0;

static UInt32            gClapboard_RefCount = 0;

static os_log_t Clapboard_Log(void)
{
    static os_log_t sLog;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        sLog = os_log_create("com.astroqore.ClapboardDriver", "driver");
    });
    return sLog;
}

#pragma mark - Device count

//  The compile-time default wins unless the bundle's Info.plist carries a
//  usable "ClapboardDeviceCount". When the binary is dlopen'ed directly (the
//  test harness) there is no bundle and the default is used.
static UInt32 Clapboard_ResolveDeviceCount(void)
{
    UInt32 theCount = (UInt32)kClapboard_DefaultDeviceCount;

    CFBundleRef theBundle = CFBundleGetBundleWithIdentifier(kClapboard_BundleID);
    if (theBundle != NULL) {
        CFTypeRef theValue = CFBundleGetValueForInfoDictionaryKey(theBundle,
                                                                  kClapboard_DeviceCountKey);
        if (theValue != NULL && CFGetTypeID(theValue) == CFNumberGetTypeID()) {
            int thePlistCount = 0;
            if (CFNumberGetValue((CFNumberRef)theValue, kCFNumberIntType, &thePlistCount)) {
                if (thePlistCount > 0) {
                    theCount = (UInt32)thePlistCount;
                }
            }
        }
    }

    if (theCount < 1) {
        theCount = 1;
    }
    if (theCount > (UInt32)kClapboard_MaxDeviceCount) {
        theCount = (UInt32)kClapboard_MaxDeviceCount;
    }
    return theCount;
}

#pragma mark - Timeline

UInt64 Clapboard_HostTicksPerRing(Float64 inSampleRate)
{
    static mach_timebase_info_data_t sTimebase;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        mach_timebase_info(&sTimebase);
    });

    if (inSampleRate <= 0.0 || sTimebase.numer == 0) {
        return 0;
    }

    //  ticks per second = 1e9 * denom / numer
    const Float64 theTicksPerSecond =
        1.0e9 * (Float64)sTimebase.denom / (Float64)sTimebase.numer;
    const Float64 theSecondsPerRing = (Float64)kClapboard_RingFrames / inSampleRate;
    return (UInt64)(theTicksPerSecond * theSecondsPerRing);
}

void Clapboard_ResetTimeline(ClapboardDevice* inDevice)
{
    if (inDevice == NULL) {
        return;
    }
    atomic_store_explicit(&inDevice->hostTicksPerRing,
                          Clapboard_HostTicksPerRing(inDevice->sampleRate),
                          memory_order_relaxed);
    atomic_store_explicit(&inDevice->timeStampCount, 0, memory_order_relaxed);
    atomic_store_explicit(&inDevice->anchorHostTime, mach_absolute_time(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&inDevice->timeLineSeed, 1, memory_order_relaxed);
}

#pragma mark - Volume curve

Float32 Clapboard_ScalarToDecibels(Float32 inScalar)
{
    Float32 theScalar = inScalar;
    if (theScalar < 0.0f) {
        theScalar = 0.0f;
    }
    if (theScalar > 1.0f) {
        theScalar = 1.0f;
    }
    const Float32 theCurved = theScalar * theScalar * theScalar;
    return kClapboard_VolumeMinDB +
           theCurved * (kClapboard_VolumeMaxDB - kClapboard_VolumeMinDB);
}

Float32 Clapboard_DecibelsToScalar(Float32 inDecibels)
{
    Float32 theDecibels = inDecibels;
    if (theDecibels < kClapboard_VolumeMinDB) {
        theDecibels = kClapboard_VolumeMinDB;
    }
    if (theDecibels > kClapboard_VolumeMaxDB) {
        theDecibels = kClapboard_VolumeMaxDB;
    }
    const Float32 theNormalized = (theDecibels - kClapboard_VolumeMinDB) /
                                  (kClapboard_VolumeMaxDB - kClapboard_VolumeMinDB);
    return cbrtf(theNormalized);
}

Float32 Clapboard_ScalarToGain(Float32 inScalar)
{
    if (inScalar <= 0.0f) {
        return 0.0f;
    }
    if (inScalar >= 1.0f) {
        return 1.0f;
    }
    return powf(10.0f, Clapboard_ScalarToDecibels(inScalar) / 20.0f);
}

bool Clapboard_IsSupportedSampleRate(Float64 inRate)
{
    for (UInt32 i = 0; i < kClapboard_SampleRateCount; ++i) {
        if (kClapboard_SampleRates[i] == inRate) {
            return true;
        }
    }
    return false;
}

#pragma mark - Object lookup

ClapboardObjectKind Clapboard_ClassifyObject(AudioObjectID inObjectID,
                                             ClapboardDevice** outDevice)
{
    if (outDevice != NULL) {
        *outDevice = NULL;
    }
    if (inObjectID == kAudioObjectPlugInObject) {
        return kClapboardObjectKind_PlugIn;
    }
    if (inObjectID < kClapboard_ObjectIDBase) {
        return kClapboardObjectKind_Unknown;
    }

    const UInt32 theIndex  = (UInt32)(inObjectID / kClapboard_ObjectIDStride) - 1u;
    const UInt32 theOffset = (UInt32)(inObjectID % kClapboard_ObjectIDStride);
    if (theIndex >= gClapboard_DeviceCount) {
        return kClapboardObjectKind_Unknown;
    }

    ClapboardDevice* theDevice = &gClapboard_Devices[theIndex];
    if (outDevice != NULL) {
        *outDevice = theDevice;
    }

    switch (theOffset) {
        case kClapboard_ObjectOffset_Device:       return kClapboardObjectKind_Device;
        case kClapboard_ObjectOffset_InputStream:  return kClapboardObjectKind_InputStream;
        case kClapboard_ObjectOffset_OutputStream: return kClapboardObjectKind_OutputStream;
        case kClapboard_ObjectOffset_Volume:       return kClapboardObjectKind_Volume;
        case kClapboard_ObjectOffset_Mute:         return kClapboardObjectKind_Mute;
        default: break;
    }

    if (outDevice != NULL) {
        *outDevice = NULL;
    }
    return kClapboardObjectKind_Unknown;
}

ClapboardDevice* Clapboard_DeviceForUID(CFStringRef inUID)
{
    if (inUID == NULL) {
        return NULL;
    }
    for (UInt32 i = 0; i < gClapboard_DeviceCount; ++i) {
        if (gClapboard_Devices[i].uid != NULL &&
            CFStringCompare(inUID, gClapboard_Devices[i].uid, 0) == kCFCompareEqualTo) {
            return &gClapboard_Devices[i];
        }
    }
    return NULL;
}

#pragma mark - Lifetime

static void Clapboard_TearDownLocked(void)
{
    for (UInt32 i = 0; i < gClapboard_DeviceCount; ++i) {
        ClapboardDevice* theDevice = &gClapboard_Devices[i];
        if (theDevice->name != NULL) {
            CFRelease(theDevice->name);
        }
        if (theDevice->uid != NULL) {
            CFRelease(theDevice->uid);
        }
        free(theDevice->ring);
    }
    memset(gClapboard_Devices, 0, sizeof(gClapboard_Devices));
    gClapboard_DeviceCount = 0;
    gClapboard_Host = NULL;
}

static bool Clapboard_SetUpLocked(void)
{
    const UInt32 theCount = Clapboard_ResolveDeviceCount();
    memset(gClapboard_Devices, 0, sizeof(gClapboard_Devices));

    for (UInt32 i = 0; i < theCount; ++i) {
        ClapboardDevice* theDevice = &gClapboard_Devices[i];
        const AudioObjectID theBase =
            (AudioObjectID)((i + 1u) * (UInt32)kClapboard_ObjectIDStride);

        theDevice->index          = i;
        theDevice->deviceID       = theBase + kClapboard_ObjectOffset_Device;
        theDevice->inputStreamID  = theBase + kClapboard_ObjectOffset_InputStream;
        theDevice->outputStreamID = theBase + kClapboard_ObjectOffset_OutputStream;
        theDevice->volumeID       = theBase + kClapboard_ObjectOffset_Volume;
        theDevice->muteID         = theBase + kClapboard_ObjectOffset_Mute;

        theDevice->name = CFStringCreateWithFormat(
            NULL, NULL, CFSTR("%s%u"), kClapboard_DeviceNamePrefix, (unsigned)(i + 1u));
        theDevice->uid = CFStringCreateWithFormat(
            NULL, NULL, CFSTR("%s%u"), kClapboard_DeviceUIDPrefix, (unsigned)(i + 1u));

        theDevice->sampleRate         = kClapboard_DefaultSampleRate;
        theDevice->pendingSampleRate  = 0.0;
        theDevice->inputStreamActive  = true;
        theDevice->outputStreamActive = true;
        theDevice->ioCount            = 0;
        theDevice->volumeScalar       = 1.0f;

        atomic_store_explicit(&theDevice->gain, 1.0f, memory_order_relaxed);
        atomic_store_explicit(&theDevice->muted, false, memory_order_relaxed);
        atomic_store_explicit(&theDevice->running, false, memory_order_relaxed);
        atomic_store_explicit(&theDevice->timeLineSeed, 1, memory_order_relaxed);
        atomic_store_explicit(&theDevice->hostTicksPerRing,
                              Clapboard_HostTicksPerRing(theDevice->sampleRate),
                              memory_order_relaxed);

        theDevice->ring = (Float32*)calloc((size_t)kClapboard_RingFrames *
                                               (size_t)kClapboard_ChannelCount,
                                           sizeof(Float32));

        if (theDevice->name == NULL || theDevice->uid == NULL || theDevice->ring == NULL) {
            gClapboard_DeviceCount = i + 1u;
            Clapboard_TearDownLocked();
            return false;
        }
    }

    gClapboard_DeviceCount = theCount;
    os_log_info(Clapboard_Log(), "Clapboard driver published %u bus(es)", (unsigned)theCount);
    return true;
}

UInt32 Clapboard_StateRetain(void)
{
    pthread_mutex_lock(&gClapboard_StateMutex);
    if (gClapboard_RefCount == 0) {
        if (!Clapboard_SetUpLocked()) {
            os_log_error(Clapboard_Log(), "Clapboard driver failed to allocate its device table");
            pthread_mutex_unlock(&gClapboard_StateMutex);
            return 0;
        }
    }
    ++gClapboard_RefCount;
    const UInt32 theCount = gClapboard_RefCount;
    pthread_mutex_unlock(&gClapboard_StateMutex);
    return theCount;
}

UInt32 Clapboard_StateRelease(void)
{
    pthread_mutex_lock(&gClapboard_StateMutex);
    if (gClapboard_RefCount == 0) {
        pthread_mutex_unlock(&gClapboard_StateMutex);
        return 0;
    }
    --gClapboard_RefCount;
    const UInt32 theCount = gClapboard_RefCount;
    if (theCount == 0) {
        Clapboard_TearDownLocked();
    }
    pthread_mutex_unlock(&gClapboard_StateMutex);
    return theCount;
}
