//
//  ClapboardDriver.h
//  Clapboard virtual audio devices — shared declarations.
//
//  The driver is a Core Audio AudioServerPlugIn loaded by coreaudiod out of
//  /Library/Audio/Plug-Ins/HAL. It publishes N loopback devices named
//  "Clapboard Bus 1" … "Clapboard Bus N". Every device has one output stream
//  and one input stream; whatever a client writes to the output stream is
//  what other clients read back from the input stream.
//
//  Written from the AudioServerPlugIn headers and Apple's published sample
//  structure. No GPL code was copied.
//

#ifndef ClapboardDriver_h
#define ClapboardDriver_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

#if defined(__cplusplus)
extern "C" {
#endif

#pragma mark - Compile-time configuration

//  How many buses the driver publishes. The Info.plist key
//  "ClapboardDeviceCount" overrides this at load time, clamped to
//  [1, kClapboard_MaxDeviceCount].
#ifndef CLAPBOARD_DEVICE_COUNT
#define CLAPBOARD_DEVICE_COUNT 4
#endif

enum {
    kClapboard_DefaultDeviceCount = CLAPBOARD_DEVICE_COUNT,
    kClapboard_MaxDeviceCount     = 16,

    //  Ring size in frames. Also the device's zero-timestamp period, so the
    //  timeline advances by exactly one ring per period and the modulo
    //  arithmetic in the IO path never disagrees with the HAL's.
    kClapboard_RingFrames         = 1 << 16,

    kClapboard_ChannelCount       = 2,
    kClapboard_BytesPerFrame      = kClapboard_ChannelCount * (UInt32)sizeof(Float32),

    //  Safety offset reported to the HAL, in frames, for both scopes.
    kClapboard_SafetyOffset       = 0,
};

#define kClapboard_BundleID          CFSTR("com.astroqore.ClapboardDriver")
#define kClapboard_DeviceCountKey    CFSTR("ClapboardDeviceCount")
#define kClapboard_Manufacturer      CFSTR("AstroQore")
#define kClapboard_ModelUID          CFSTR("com.astroqore.Clapboard.bus")
#define kClapboard_DeviceUIDPrefix   "com.astroqore.Clapboard.bus."
#define kClapboard_DeviceNamePrefix  "Clapboard Bus "

//  Volume control range. Scalar 0…1 maps to dB by
//  dB = min + scalar^3 * (max - min), matching how the HAL's own sample
//  drivers curve a master volume.
#define kClapboard_VolumeMinDB (-96.0f)
#define kClapboard_VolumeMaxDB (0.0f)

extern const Float64 kClapboard_SampleRates[];
extern const UInt32  kClapboard_SampleRateCount;

#pragma mark - Object IDs

//  The plug-in object is always kAudioObjectPlugInObject (1). Everything else
//  is allocated deterministically so an object ID can be decoded without a
//  lookup table: device i (0-based) owns IDs 10*(i+1) + 0…4.
enum {
    kClapboard_ObjectIDStride = 10,
    kClapboard_ObjectIDBase   = kClapboard_ObjectIDStride,
};

enum {
    kClapboard_ObjectOffset_Device       = 0,
    kClapboard_ObjectOffset_InputStream  = 1,
    kClapboard_ObjectOffset_OutputStream = 2,
    kClapboard_ObjectOffset_Volume       = 3,
    kClapboard_ObjectOffset_Mute         = 4,
    kClapboard_ObjectOffset_Count        = 5,
};

typedef enum {
    kClapboardObjectKind_Unknown = 0,
    kClapboardObjectKind_PlugIn,
    kClapboardObjectKind_Device,
    kClapboardObjectKind_InputStream,
    kClapboardObjectKind_OutputStream,
    kClapboardObjectKind_Volume,
    kClapboardObjectKind_Mute,
} ClapboardObjectKind;

#pragma mark - Device state

typedef struct {
    UInt32          index;              //  0-based
    AudioObjectID   deviceID;
    AudioObjectID   inputStreamID;
    AudioObjectID   outputStreamID;
    AudioObjectID   volumeID;
    AudioObjectID   muteID;

    CFStringRef     name;               //  "Clapboard Bus 1"
    CFStringRef     uid;                //  "com.astroqore.Clapboard.bus.1"

    //  Guarded by gClapboard_StateMutex.
    Float64         sampleRate;
    Float64         pendingSampleRate;  //  set between Request… and Perform…
    bool            inputStreamActive;
    bool            outputStreamActive;
    UInt32          ioCount;            //  clients that have called StartIO
    Float32         volumeScalar;       //  0…1, the value the UI shows

    //  Read on the IO thread without locking.
    _Atomic Float32 gain;               //  linear amplitude derived from volumeScalar
    _Atomic bool    muted;
    _Atomic bool    running;

    //  Timeline. Only StartIO (before any IO thread exists for this device)
    //  and the IO thread itself touch these.
    _Atomic UInt64  anchorHostTime;
    _Atomic UInt64  timeStampCount;
    _Atomic UInt64  hostTicksPerRing;
    _Atomic UInt64  timeLineSeed;

    Float32*        ring;               //  kClapboard_RingFrames * kClapboard_ChannelCount
} ClapboardDevice;

#pragma mark - Global state

extern pthread_mutex_t          gClapboard_StateMutex;
extern AudioServerPlugInHostRef gClapboard_Host;
extern ClapboardDevice          gClapboard_Devices[kClapboard_MaxDeviceCount];
extern UInt32                   gClapboard_DeviceCount;

//  Reference counting / lifetime. Both return the new reference count.
UInt32 Clapboard_StateRetain(void);
UInt32 Clapboard_StateRelease(void);

ClapboardObjectKind Clapboard_ClassifyObject(AudioObjectID inObjectID, ClapboardDevice** outDevice);
ClapboardDevice*    Clapboard_DeviceForUID(CFStringRef inUID);

//  Timeline helpers.
UInt64 Clapboard_HostTicksPerRing(Float64 inSampleRate);
void   Clapboard_ResetTimeline(ClapboardDevice* inDevice);

//  Volume curve.
Float32 Clapboard_ScalarToDecibels(Float32 inScalar);
Float32 Clapboard_DecibelsToScalar(Float32 inDecibels);
Float32 Clapboard_ScalarToGain(Float32 inScalar);

bool Clapboard_IsSupportedSampleRate(Float64 inRate);

#pragma mark - Property implementation (ClapboardProperties.c)

Boolean  Clapboard_HasProperty(AudioObjectID inObjectID,
                               pid_t inClientProcessID,
                               const AudioObjectPropertyAddress* inAddress);

OSStatus Clapboard_IsPropertySettable(AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      Boolean* outIsSettable);

OSStatus Clapboard_GetPropertyDataSize(AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32* outDataSize);

OSStatus Clapboard_GetPropertyData(AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void* inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32* outDataSize,
                                   void* outData);

OSStatus Clapboard_SetPropertyData(AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void* inQualifierData,
                                   UInt32 inDataSize,
                                   const void* inData);

#pragma mark - Factory

//  Named in the bundle's CFPlugInFactories dictionary.
void* ClapboardDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#if defined(__cplusplus)
}
#endif

#endif /* ClapboardDriver_h */
