//
//  harness.c
//  Exercises ClapboardDriver.driver without coreaudiod.
//
//  It dlopen()s the built bundle binary, asks the factory for the driver
//  interface, hands it a fake AudioServerPlugInHostInterface and then drives
//  the same calls the HAL would: the whole property model, the timeline and
//  the loopback IO path. Every assertion prints PASS or FAIL; the process
//  exits non-zero if anything failed.
//
//  Usage: harness [path/to/ClapboardDriver]
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define kDefaultBinaryPath ".build/ClapboardDriver.driver/Contents/MacOS/ClapboardDriver"

#define kExpectedDeviceCount 4u
#define kRingFrames          (1u << 16)
#define kChannels            2u
#define kTestFrames          256u

typedef void* (*ClapboardCreateProc)(CFAllocatorRef, CFUUIDRef);

static AudioServerPlugInDriverRef gDriver;
static unsigned gChecks;
static unsigned gFailures;
static unsigned gPropertiesChangedCalls;
static unsigned gPerformConfigCalls;

#define CHECK(cond, ...)                        \
    do {                                        \
        ++gChecks;                              \
        if (cond) {                             \
            printf("PASS  ");                   \
        } else {                                \
            ++gFailures;                        \
            printf("FAIL  ");                   \
        }                                       \
        printf(__VA_ARGS__);                    \
        printf("\n");                           \
        fflush(stdout);                         \
    } while (0)

#pragma mark - Fake host

static OSStatus FakePropertiesChanged(AudioServerPlugInHostRef inHost,
                                      AudioObjectID inObjectID,
                                      UInt32 inNumberAddresses,
                                      const AudioObjectPropertyAddress* inAddresses)
{
    (void)inHost;
    (void)inObjectID;
    (void)inNumberAddresses;
    (void)inAddresses;
    ++gPropertiesChangedCalls;
    return kAudioHardwareNoError;
}

static OSStatus FakeCopyFromStorage(AudioServerPlugInHostRef inHost,
                                    CFStringRef inKey,
                                    CFPropertyListRef* outData)
{
    (void)inHost;
    (void)inKey;
    if (outData != NULL) {
        *outData = NULL;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus FakeWriteToStorage(AudioServerPlugInHostRef inHost,
                                   CFStringRef inKey,
                                   CFPropertyListRef inData)
{
    (void)inHost;
    (void)inKey;
    (void)inData;
    return kAudioHardwareNoError;
}

static OSStatus FakeDeleteFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey)
{
    (void)inHost;
    (void)inKey;
    return kAudioHardwareNoError;
}

//  The real host stops IO, then calls back. Here the callback is immediate,
//  which is also the tightest re-entrancy the driver has to survive.
static OSStatus FakeRequestDeviceConfigurationChange(AudioServerPlugInHostRef inHost,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void* inChangeInfo)
{
    (void)inHost;
    ++gPerformConfigCalls;
    return (*gDriver)->PerformDeviceConfigurationChange(gDriver, inDeviceObjectID,
                                                        inChangeAction, inChangeInfo);
}

static const AudioServerPlugInHostInterface gFakeHost = {
    .PropertiesChanged                = FakePropertiesChanged,
    .CopyFromStorage                  = FakeCopyFromStorage,
    .WriteToStorage                   = FakeWriteToStorage,
    .DeleteFromStorage                = FakeDeleteFromStorage,
    .RequestDeviceConfigurationChange = FakeRequestDeviceConfigurationChange,
};

#pragma mark - Property helpers

static AudioObjectPropertyAddress MakeAddress(AudioObjectPropertySelector inSelector,
                                              AudioObjectPropertyScope inScope)
{
    AudioObjectPropertyAddress theAddress;
    theAddress.mSelector = inSelector;
    theAddress.mScope    = inScope;
    theAddress.mElement  = kAudioObjectPropertyElementMain;
    return theAddress;
}

//  Reads a property and asserts that HasProperty, GetPropertyDataSize and the
//  outDataSize returned by GetPropertyData all agree.
static bool ReadProperty(AudioObjectID inObjectID,
                         AudioObjectPropertySelector inSelector,
                         AudioObjectPropertyScope inScope,
                         void* outData,
                         UInt32 inDataSize,
                         UInt32* outUsed,
                         const char* inLabel)
{
    const AudioObjectPropertyAddress theAddress = MakeAddress(inSelector, inScope);

    if (!(*gDriver)->HasProperty(gDriver, inObjectID, 0, &theAddress)) {
        CHECK(false, "%s: HasProperty", inLabel);
        return false;
    }

    UInt32 theExpected = 0;
    OSStatus theError = (*gDriver)->GetPropertyDataSize(gDriver, inObjectID, 0, &theAddress,
                                                        0, NULL, &theExpected);
    if (theError != kAudioHardwareNoError) {
        CHECK(false, "%s: GetPropertyDataSize -> %d", inLabel, (int)theError);
        return false;
    }

    UInt32 theUsed = 0;
    theError = (*gDriver)->GetPropertyData(gDriver, inObjectID, 0, &theAddress, 0, NULL,
                                           inDataSize, &theUsed, outData);
    if (theError != kAudioHardwareNoError) {
        CHECK(false, "%s: GetPropertyData -> %d", inLabel, (int)theError);
        return false;
    }
    if (theUsed != theExpected) {
        CHECK(false, "%s: size mismatch (size=%u, data=%u)", inLabel,
              (unsigned)theExpected, (unsigned)theUsed);
        return false;
    }
    if (outUsed != NULL) {
        *outUsed = theUsed;
    }
    return true;
}

static bool ReadUInt32(AudioObjectID inObjectID,
                       AudioObjectPropertySelector inSelector,
                       AudioObjectPropertyScope inScope,
                       UInt32* outValue,
                       const char* inLabel)
{
    UInt32 theUsed = 0;
    if (!ReadProperty(inObjectID, inSelector, inScope, outValue, (UInt32)sizeof(UInt32),
                      &theUsed, inLabel)) {
        return false;
    }
    return theUsed == sizeof(UInt32);
}

static bool ReadFloat64(AudioObjectID inObjectID,
                        AudioObjectPropertySelector inSelector,
                        AudioObjectPropertyScope inScope,
                        Float64* outValue,
                        const char* inLabel)
{
    UInt32 theUsed = 0;
    if (!ReadProperty(inObjectID, inSelector, inScope, outValue, (UInt32)sizeof(Float64),
                      &theUsed, inLabel)) {
        return false;
    }
    return theUsed == sizeof(Float64);
}

//  Returns a +1 CFStringRef, or NULL.
static CFStringRef CopyStringProperty(AudioObjectID inObjectID,
                                      AudioObjectPropertySelector inSelector,
                                      AudioObjectPropertyScope inScope,
                                      const char* inLabel)
{
    CFStringRef theString = NULL;
    UInt32 theUsed = 0;
    if (!ReadProperty(inObjectID, inSelector, inScope, &theString,
                      (UInt32)sizeof(CFStringRef), &theUsed, inLabel)) {
        return NULL;
    }
    return theString;
}

static bool StringEquals(CFStringRef inString, const char* inExpected)
{
    if (inString == NULL) {
        return false;
    }
    char theBuffer[256];
    if (!CFStringGetCString(inString, theBuffer, sizeof(theBuffer), kCFStringEncodingUTF8)) {
        return false;
    }
    return strcmp(theBuffer, inExpected) == 0;
}

#pragma mark - IO helpers

static AudioServerPlugInIOCycleInfo MakeCycleInfo(Float64 inSampleTime, UInt32 inFrames)
{
    AudioServerPlugInIOCycleInfo theInfo;
    memset(&theInfo, 0, sizeof(theInfo));
    theInfo.mIOCycleCounter           = 1;
    theInfo.mNominalIOBufferFrameSize = inFrames;
    theInfo.mCurrentTime.mSampleTime  = inSampleTime;
    theInfo.mCurrentTime.mFlags       = kAudioTimeStampSampleTimeValid;
    theInfo.mInputTime.mSampleTime    = inSampleTime;
    theInfo.mInputTime.mFlags         = kAudioTimeStampSampleTimeValid;
    theInfo.mOutputTime.mSampleTime   = inSampleTime;
    theInfo.mOutputTime.mFlags        = kAudioTimeStampSampleTimeValid;
    theInfo.mMainHostTicksPerFrame    = 1.0;
    theInfo.mDeviceHostTicksPerFrame  = 1.0;
    return theInfo;
}

static OSStatus RunIOOperation(AudioObjectID inDeviceID,
                               AudioObjectID inStreamID,
                               UInt32 inClientID,
                               UInt32 inOperationID,
                               Float64 inSampleTime,
                               UInt32 inFrames,
                               Float32* ioBuffer)
{
    const AudioServerPlugInIOCycleInfo theInfo = MakeCycleInfo(inSampleTime, inFrames);
    OSStatus theError = (*gDriver)->BeginIOOperation(gDriver, inDeviceID, inClientID,
                                                     inOperationID, inFrames, &theInfo);
    if (theError != kAudioHardwareNoError) {
        return theError;
    }
    theError = (*gDriver)->DoIOOperation(gDriver, inDeviceID, inStreamID, inClientID,
                                         inOperationID, inFrames, &theInfo, ioBuffer, NULL);
    if (theError != kAudioHardwareNoError) {
        return theError;
    }
    return (*gDriver)->EndIOOperation(gDriver, inDeviceID, inClientID, inOperationID,
                                      inFrames, &theInfo);
}

static void FillRamp(Float32* outBuffer, UInt32 inFrames, Float32 inScale)
{
    for (UInt32 i = 0; i < inFrames * kChannels; ++i) {
        outBuffer[i] = inScale * (Float32)i;
    }
}

static bool BuffersMatch(const Float32* inA, const Float32* inB, UInt32 inSamples)
{
    for (UInt32 i = 0; i < inSamples; ++i) {
        if (fabsf(inA[i] - inB[i]) > 1.0e-5f * (1.0f + fabsf(inA[i]))) {
            return false;
        }
    }
    return true;
}

static bool BufferIsSilent(const Float32* inBuffer, UInt32 inSamples)
{
    for (UInt32 i = 0; i < inSamples; ++i) {
        if (inBuffer[i] != 0.0f) {
            return false;
        }
    }
    return true;
}

static void SleepSeconds(double inSeconds)
{
    struct timespec theRequest;
    theRequest.tv_sec  = (time_t)inSeconds;
    theRequest.tv_nsec = (long)((inSeconds - (double)theRequest.tv_sec) * 1.0e9);
    nanosleep(&theRequest, NULL);
}

#pragma mark - Checks

static void CheckPlugInObject(AudioObjectID* outDeviceIDs, UInt32* outDeviceCount)
{
    printf("\n-- plug-in object --\n");

    UInt32 theClass = 0;
    if (ReadUInt32(kAudioObjectPlugInObject, kAudioObjectPropertyClass,
                   kAudioObjectPropertyScopeGlobal, &theClass, "plugin class")) {
        CHECK(theClass == kAudioPlugInClassID, "plug-in class is kAudioPlugInClassID");
    }

    UInt32 theBaseClass = 0;
    if (ReadUInt32(kAudioObjectPlugInObject, kAudioObjectPropertyBaseClass,
                   kAudioObjectPropertyScopeGlobal, &theBaseClass, "plugin base class")) {
        CHECK(theBaseClass == kAudioObjectClassID, "plug-in base class is kAudioObjectClassID");
    }

    CFStringRef theManufacturer = CopyStringProperty(kAudioObjectPlugInObject,
                                                     kAudioObjectPropertyManufacturer,
                                                     kAudioObjectPropertyScopeGlobal,
                                                     "plugin manufacturer");
    CHECK(StringEquals(theManufacturer, "AstroQore"), "plug-in manufacturer is AstroQore");
    if (theManufacturer != NULL) {
        CFRelease(theManufacturer);
    }

    CFStringRef theBundle = CopyStringProperty(kAudioObjectPlugInObject,
                                               kAudioPlugInPropertyResourceBundle,
                                               kAudioObjectPropertyScopeGlobal,
                                               "plugin resource bundle");
    CHECK(StringEquals(theBundle, ""), "plug-in resource bundle is the empty string");
    if (theBundle != NULL) {
        CFRelease(theBundle);
    }

    AudioObjectID theIDs[64];
    UInt32 theUsed = 0;
    if (ReadProperty(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList,
                     kAudioObjectPropertyScopeGlobal, theIDs, (UInt32)sizeof(theIDs),
                     &theUsed, "plugin device list")) {
        const UInt32 theCount = theUsed / (UInt32)sizeof(AudioObjectID);
        CHECK(theCount == kExpectedDeviceCount, "device list has %u devices (expected %u)",
              (unsigned)theCount, (unsigned)kExpectedDeviceCount);
        memcpy(outDeviceIDs, theIDs, theUsed);
        *outDeviceCount = theCount;
    }

    UInt32 theOwnedUsed = 0;
    AudioObjectID theOwned[64];
    if (ReadProperty(kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects,
                     kAudioObjectPropertyScopeGlobal, theOwned, (UInt32)sizeof(theOwned),
                     &theOwnedUsed, "plugin owned objects")) {
        CHECK(theOwnedUsed == theUsed, "plug-in owned objects match the device list");
    }
}

static void CheckStream(AudioObjectID inStreamID, AudioObjectID inDeviceID,
                        bool inIsInput, Float64 inExpectedRate)
{
    const char* theWhich = inIsInput ? "input" : "output";

    UInt32 theClass = 0;
    if (ReadUInt32(inStreamID, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal,
                   &theClass, "stream class")) {
        CHECK(theClass == kAudioStreamClassID, "%s stream class is kAudioStreamClassID",
              theWhich);
    }

    UInt32 theOwner = 0;
    if (ReadUInt32(inStreamID, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal,
                   &theOwner, "stream owner")) {
        CHECK(theOwner == inDeviceID, "%s stream is owned by device %u", theWhich,
              (unsigned)inDeviceID);
    }

    UInt32 theDirection = 0;
    if (ReadUInt32(inStreamID, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal,
                   &theDirection, "stream direction")) {
        CHECK(theDirection == (inIsInput ? 1u : 0u), "%s stream direction is %u", theWhich,
              (unsigned)theDirection);
    }

    UInt32 theTerminal = 0;
    if (ReadUInt32(inStreamID, kAudioStreamPropertyTerminalType,
                   kAudioObjectPropertyScopeGlobal, &theTerminal, "stream terminal type")) {
        CHECK(theTerminal == (inIsInput ? (UInt32)kAudioStreamTerminalTypeMicrophone
                                        : (UInt32)kAudioStreamTerminalTypeSpeaker),
              "%s stream terminal type is right", theWhich);
    }

    UInt32 theStart = 0;
    if (ReadUInt32(inStreamID, kAudioStreamPropertyStartingChannel,
                   kAudioObjectPropertyScopeGlobal, &theStart, "stream starting channel")) {
        CHECK(theStart == 1, "%s stream starts at channel 1", theWhich);
    }

    UInt32 theActive = 0;
    if (ReadUInt32(inStreamID, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                   &theActive, "stream is active")) {
        CHECK(theActive == 1, "%s stream is active", theWhich);
    }

    Boolean theSettable = false;
    const AudioObjectPropertyAddress theActiveAddress =
        MakeAddress(kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal);
    (*gDriver)->IsPropertySettable(gDriver, inStreamID, 0, &theActiveAddress, &theSettable);
    CHECK(theSettable, "%s stream IsActive is settable", theWhich);

    AudioStreamBasicDescription theFormat;
    UInt32 theUsed = 0;
    if (ReadProperty(inStreamID, kAudioStreamPropertyVirtualFormat,
                     kAudioObjectPropertyScopeGlobal, &theFormat, (UInt32)sizeof(theFormat),
                     &theUsed, "stream virtual format")) {
        const bool theOK = theFormat.mFormatID == kAudioFormatLinearPCM &&
                           (theFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                           (theFormat.mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
                           theFormat.mChannelsPerFrame == kChannels &&
                           theFormat.mBitsPerChannel == 32 &&
                           theFormat.mBytesPerFrame == kChannels * sizeof(Float32) &&
                           theFormat.mFramesPerPacket == 1 &&
                           theFormat.mSampleRate == inExpectedRate;
        CHECK(theOK, "%s stream format is Float32 %u ch @ %.0f Hz", theWhich,
              (unsigned)theFormat.mChannelsPerFrame, theFormat.mSampleRate);
    }

    AudioStreamBasicDescription thePhysical;
    if (ReadProperty(inStreamID, kAudioStreamPropertyPhysicalFormat,
                     kAudioObjectPropertyScopeGlobal, &thePhysical,
                     (UInt32)sizeof(thePhysical), &theUsed, "stream physical format")) {
        CHECK(memcmp(&thePhysical, &theFormat, sizeof(theFormat)) == 0,
              "%s stream physical format matches the virtual format", theWhich);
    }

    AudioStreamRangedDescription theFormats[8];
    if (ReadProperty(inStreamID, kAudioStreamPropertyAvailableVirtualFormats,
                     kAudioObjectPropertyScopeGlobal, theFormats, (UInt32)sizeof(theFormats),
                     &theUsed, "stream available formats")) {
        const UInt32 theCount = theUsed / (UInt32)sizeof(AudioStreamRangedDescription);
        const bool theOK = theCount == 3 &&
                           theFormats[0].mFormat.mSampleRate == 44100.0 &&
                           theFormats[1].mFormat.mSampleRate == 48000.0 &&
                           theFormats[2].mFormat.mSampleRate == 96000.0;
        CHECK(theOK, "%s stream advertises 44100/48000/96000 (%u formats)", theWhich,
              (unsigned)theCount);
    }
}

static void CheckDevice(AudioObjectID inDeviceID, UInt32 inIndex)
{
    char theExpectedName[64];
    char theExpectedUID[64];
    snprintf(theExpectedName, sizeof(theExpectedName), "Clapboard Bus %u", (unsigned)(inIndex + 1));
    snprintf(theExpectedUID, sizeof(theExpectedUID), "com.astroqore.Clapboard.bus.%u",
             (unsigned)(inIndex + 1));

    printf("\n-- device %u (object %u) --\n", (unsigned)(inIndex + 1), (unsigned)inDeviceID);

    CHECK(inDeviceID == (inIndex + 1) * 10, "device %u has object ID %u",
          (unsigned)(inIndex + 1), (unsigned)inDeviceID);

    UInt32 theClass = 0;
    if (ReadUInt32(inDeviceID, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal,
                   &theClass, "device class")) {
        CHECK(theClass == kAudioDeviceClassID, "device class is kAudioDeviceClassID");
    }

    UInt32 theOwner = 0;
    if (ReadUInt32(inDeviceID, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal,
                   &theOwner, "device owner")) {
        CHECK(theOwner == kAudioObjectPlugInObject, "device is owned by the plug-in object");
    }

    CFStringRef theName = CopyStringProperty(inDeviceID, kAudioObjectPropertyName,
                                             kAudioObjectPropertyScopeGlobal, "device name");
    CHECK(StringEquals(theName, theExpectedName), "device name is \"%s\"", theExpectedName);
    if (theName != NULL) {
        CFRelease(theName);
    }

    CFStringRef theUID = CopyStringProperty(inDeviceID, kAudioDevicePropertyDeviceUID,
                                            kAudioObjectPropertyScopeGlobal, "device UID");
    CHECK(StringEquals(theUID, theExpectedUID), "device UID is \"%s\"", theExpectedUID);
    if (theUID != NULL) {
        CFRelease(theUID);
    }

    CFStringRef theModelUID = CopyStringProperty(inDeviceID, kAudioDevicePropertyModelUID,
                                                 kAudioObjectPropertyScopeGlobal,
                                                 "device model UID");
    CHECK(StringEquals(theModelUID, "com.astroqore.Clapboard.bus"),
          "device model UID is com.astroqore.Clapboard.bus");
    if (theModelUID != NULL) {
        CFRelease(theModelUID);
    }

    CFStringRef theManufacturer = CopyStringProperty(inDeviceID, kAudioObjectPropertyManufacturer,
                                                     kAudioObjectPropertyScopeGlobal,
                                                     "device manufacturer");
    CHECK(StringEquals(theManufacturer, "AstroQore"), "device manufacturer is AstroQore");
    if (theManufacturer != NULL) {
        CFRelease(theManufacturer);
    }

    UInt32 theTransport = 0;
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyTransportType,
                   kAudioObjectPropertyScopeGlobal, &theTransport, "device transport type")) {
        CHECK(theTransport == kAudioDeviceTransportTypeVirtual,
              "device transport type is kAudioDeviceTransportTypeVirtual");
    }

    UInt32 theValue = 0;
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyDeviceIsAlive,
                   kAudioObjectPropertyScopeGlobal, &theValue, "device is alive")) {
        CHECK(theValue == 1, "device is alive");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                   kAudioObjectPropertyScopeOutput, &theValue, "device can be default")) {
        CHECK(theValue == 1, "device can be the default output device");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                   kAudioObjectPropertyScopeInput, &theValue, "device can be default in")) {
        CHECK(theValue == 1, "device can be the default input device");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                   kAudioObjectPropertyScopeOutput, &theValue, "device can be system default")) {
        CHECK(theValue == 1, "device can be the default system device");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal,
                   &theValue, "device is hidden")) {
        CHECK(theValue == 0, "device is not hidden");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput,
                   &theValue, "device latency")) {
        CHECK(theValue == 0, "device latency is 0");
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertySafetyOffset,
                   kAudioObjectPropertyScopeOutput, &theValue, "device safety offset")) {
        CHECK(theValue <= 16, "device safety offset is %u", (unsigned)theValue);
    }
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyZeroTimeStampPeriod,
                   kAudioObjectPropertyScopeGlobal, &theValue, "device timestamp period")) {
        CHECK(theValue == kRingFrames, "zero timestamp period is %u frames",
              (unsigned)theValue);
    }

    Float64 theRate = 0.0;
    if (ReadFloat64(inDeviceID, kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal, &theRate, "device sample rate")) {
        CHECK(theRate == 48000.0, "nominal sample rate is 48000");
    }

    AudioValueRange theRanges[8];
    UInt32 theUsed = 0;
    if (ReadProperty(inDeviceID, kAudioDevicePropertyAvailableNominalSampleRates,
                     kAudioObjectPropertyScopeGlobal, theRanges, (UInt32)sizeof(theRanges),
                     &theUsed, "device available rates")) {
        const UInt32 theCount = theUsed / (UInt32)sizeof(AudioValueRange);
        const bool theOK = theCount == 3 &&
                           theRanges[0].mMinimum == 44100.0 &&
                           theRanges[1].mMinimum == 48000.0 &&
                           theRanges[2].mMinimum == 96000.0;
        CHECK(theOK, "device advertises 44100/48000/96000 (%u ranges)", (unsigned)theCount);
    }

    UInt32 theStereo[2] = { 0, 0 };
    if (ReadProperty(inDeviceID, kAudioDevicePropertyPreferredChannelsForStereo,
                     kAudioObjectPropertyScopeOutput, theStereo, (UInt32)sizeof(theStereo),
                     &theUsed, "device stereo pair")) {
        CHECK(theStereo[0] == 1 && theStereo[1] == 2, "preferred stereo pair is (1, 2)");
    }

    unsigned char theLayout[512];
    if (ReadProperty(inDeviceID, kAudioDevicePropertyPreferredChannelLayout,
                     kAudioObjectPropertyScopeOutput, theLayout, (UInt32)sizeof(theLayout),
                     &theUsed, "device channel layout")) {
        const AudioChannelLayout* theChannelLayout = (const AudioChannelLayout*)theLayout;
        CHECK(theChannelLayout->mNumberChannelDescriptions == kChannels,
              "preferred channel layout describes %u channels",
              (unsigned)theChannelLayout->mNumberChannelDescriptions);
    }

    AudioObjectID theStreams[8];
    if (ReadProperty(inDeviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal,
                     theStreams, (UInt32)sizeof(theStreams), &theUsed, "device streams")) {
        CHECK(theUsed / sizeof(AudioObjectID) == 2, "device has 2 streams on the global scope");
    }
    AudioObjectID theInputStream = 0;
    if (ReadProperty(inDeviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                     theStreams, (UInt32)sizeof(theStreams), &theUsed, "device input streams")) {
        CHECK(theUsed / sizeof(AudioObjectID) == 1, "device has 1 input stream");
        theInputStream = theStreams[0];
    }
    AudioObjectID theOutputStream = 0;
    if (ReadProperty(inDeviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                     theStreams, (UInt32)sizeof(theStreams), &theUsed, "device output streams")) {
        CHECK(theUsed / sizeof(AudioObjectID) == 1, "device has 1 output stream");
        theOutputStream = theStreams[0];
    }
    CHECK(theInputStream == inDeviceID + 1 && theOutputStream == inDeviceID + 2,
          "stream object IDs are %u (in) and %u (out)", (unsigned)theInputStream,
          (unsigned)theOutputStream);

    AudioObjectID theControls[8];
    if (ReadProperty(inDeviceID, kAudioObjectPropertyControlList,
                     kAudioObjectPropertyScopeGlobal, theControls, (UInt32)sizeof(theControls),
                     &theUsed, "device control list")) {
        CHECK(theUsed / sizeof(AudioObjectID) == 2, "device has a volume and a mute control");
    }

    AudioObjectID theOwned[8];
    if (ReadProperty(inDeviceID, kAudioObjectPropertyOwnedObjects,
                     kAudioObjectPropertyScopeGlobal, theOwned, (UInt32)sizeof(theOwned),
                     &theUsed, "device owned objects")) {
        CHECK(theUsed / sizeof(AudioObjectID) == 4,
              "device owns 4 objects (2 streams + 2 controls)");
    }

    CheckStream(theInputStream, inDeviceID, true, 48000.0);
    CheckStream(theOutputStream, inDeviceID, false, 48000.0);
}

static void CheckControls(AudioObjectID inDeviceID)
{
    const AudioObjectID theVolumeID = inDeviceID + 3;
    const AudioObjectID theMuteID   = inDeviceID + 4;

    printf("\n-- controls on device %u --\n", (unsigned)inDeviceID);

    UInt32 theClass = 0;
    if (ReadUInt32(theVolumeID, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal,
                   &theClass, "volume class")) {
        CHECK(theClass == kAudioVolumeControlClassID, "volume control class is correct");
    }
    if (ReadUInt32(theMuteID, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal,
                   &theClass, "mute class")) {
        CHECK(theClass == kAudioMuteControlClassID, "mute control class is correct");
    }

    UInt32 theScope = 0;
    if (ReadUInt32(theVolumeID, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal,
                   &theScope, "volume control scope")) {
        CHECK(theScope == kAudioObjectPropertyScopeOutput, "volume control is on the output scope");
    }

    Float32 theScalar = 0.0f;
    UInt32 theUsed = 0;
    if (ReadProperty(theVolumeID, kAudioLevelControlPropertyScalarValue,
                     kAudioObjectPropertyScopeGlobal, &theScalar, (UInt32)sizeof(theScalar),
                     &theUsed, "volume scalar")) {
        CHECK(theScalar == 1.0f, "volume defaults to unity");
    }

    UInt32 theMuted = 1;
    if (ReadProperty(theMuteID, kAudioBooleanControlPropertyValue,
                     kAudioObjectPropertyScopeGlobal, &theMuted, (UInt32)sizeof(theMuted),
                     &theUsed, "mute value")) {
        CHECK(theMuted == 0, "mute defaults to off");
    }

    //  Round-trip the volume through SetPropertyData.
    const AudioObjectPropertyAddress theScalarAddress =
        MakeAddress(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    const Float32 theHalf = 0.5f;
    const unsigned theBefore = gPropertiesChangedCalls;
    OSStatus theError = (*gDriver)->SetPropertyData(gDriver, theVolumeID, 0, &theScalarAddress,
                                                    0, NULL, (UInt32)sizeof(theHalf), &theHalf);
    CHECK(theError == kAudioHardwareNoError, "setting the volume scalar succeeds");
    CHECK(gPropertiesChangedCalls > theBefore, "the volume change is announced to the host");

    Float32 theReadBack = 0.0f;
    if (ReadProperty(theVolumeID, kAudioLevelControlPropertyScalarValue,
                     kAudioObjectPropertyScopeGlobal, &theReadBack,
                     (UInt32)sizeof(theReadBack), &theUsed, "volume scalar read back")) {
        CHECK(theReadBack == theHalf, "volume scalar reads back as %.2f", (double)theReadBack);
    }

    //  Put it back so the loopback checks run at unity gain.
    const Float32 theUnity = 1.0f;
    theError = (*gDriver)->SetPropertyData(gDriver, theVolumeID, 0, &theScalarAddress, 0, NULL,
                                           (UInt32)sizeof(theUnity), &theUnity);
    CHECK(theError == kAudioHardwareNoError, "restoring unity volume succeeds");
}

static void CheckTranslateUID(const AudioObjectID* inDeviceIDs, UInt32 inDeviceCount)
{
    printf("\n-- UID translation --\n");

    const AudioObjectPropertyAddress theAddress =
        MakeAddress(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);

    for (UInt32 i = 0; i < inDeviceCount; ++i) {
        char theUIDText[64];
        snprintf(theUIDText, sizeof(theUIDText), "com.astroqore.Clapboard.bus.%u",
                 (unsigned)(i + 1));
        CFStringRef theUID = CFStringCreateWithCString(NULL, theUIDText, kCFStringEncodingUTF8);

        AudioObjectID theResult = kAudioObjectUnknown;
        UInt32 theUsed = 0;
        const OSStatus theError = (*gDriver)->GetPropertyData(
            gDriver, kAudioObjectPlugInObject, 0, &theAddress,
            (UInt32)sizeof(CFStringRef), &theUID,
            (UInt32)sizeof(theResult), &theUsed, &theResult);
        CHECK(theError == kAudioHardwareNoError && theResult == inDeviceIDs[i],
              "%s translates to object %u", theUIDText, (unsigned)theResult);
        CFRelease(theUID);
    }

    //  The HAL sometimes asks for the size before it has a UID to hand over.
    UInt32 theTranslateSize = 0;
    const OSStatus theSizeError = (*gDriver)->GetPropertyDataSize(
        gDriver, kAudioObjectPlugInObject, 0, &theAddress, 0, NULL, &theTranslateSize);
    CHECK(theSizeError == kAudioHardwareNoError &&
          theTranslateSize == sizeof(AudioObjectID),
          "TranslateUIDToDevice reports its size without a qualifier");

    CFStringRef theBogus = CFSTR("com.example.nope");
    AudioObjectID theResult = 12345;
    UInt32 theUsed = 0;
    const OSStatus theError = (*gDriver)->GetPropertyData(
        gDriver, kAudioObjectPlugInObject, 0, &theAddress,
        (UInt32)sizeof(CFStringRef), &theBogus,
        (UInt32)sizeof(theResult), &theUsed, &theResult);
    CHECK(theError == kAudioHardwareNoError && theResult == kAudioObjectUnknown,
          "an unknown UID translates to kAudioObjectUnknown");
}

static void CheckSampleRateChange(AudioObjectID inDeviceID, Float64 inNewRate)
{
    printf("\n-- sample rate change to %.0f --\n", inNewRate);

    const AudioObjectPropertyAddress theAddress =
        MakeAddress(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);

    Boolean theSettable = false;
    (*gDriver)->IsPropertySettable(gDriver, inDeviceID, 0, &theAddress, &theSettable);
    CHECK(theSettable, "the nominal sample rate is settable");

    const unsigned theBefore = gPerformConfigCalls;
    OSStatus theError = (*gDriver)->SetPropertyData(gDriver, inDeviceID, 0, &theAddress, 0, NULL,
                                                    (UInt32)sizeof(inNewRate), &inNewRate);
    CHECK(theError == kAudioHardwareNoError, "setting the nominal sample rate succeeds");
    CHECK(gPerformConfigCalls == theBefore + 1,
          "the change went through RequestDeviceConfigurationChange");

    Float64 theRate = 0.0;
    if (ReadFloat64(inDeviceID, kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal, &theRate, "sample rate read back")) {
        CHECK(theRate == inNewRate, "nominal sample rate reads back as %.0f", theRate);
    }

    AudioStreamBasicDescription theFormat;
    UInt32 theUsed = 0;
    if (ReadProperty(inDeviceID + 1, kAudioStreamPropertyVirtualFormat,
                     kAudioObjectPropertyScopeGlobal, &theFormat, (UInt32)sizeof(theFormat),
                     &theUsed, "input stream format after rate change")) {
        CHECK(theFormat.mSampleRate == inNewRate, "the input stream format follows the device");
    }

    //  A rate the device does not advertise must be refused.
    const Float64 theBadRate = 12345.0;
    theError = (*gDriver)->SetPropertyData(gDriver, inDeviceID, 0, &theAddress, 0, NULL,
                                           (UInt32)sizeof(theBadRate), &theBadRate);
    CHECK(theError != kAudioHardwareNoError, "an unsupported sample rate is refused");
}

static void CheckTimeline(AudioObjectID inDeviceID, Float64 inSampleRate)
{
    printf("\n-- timeline --\n");

    OSStatus theError = (*gDriver)->StartIO(gDriver, inDeviceID, 1);
    CHECK(theError == kAudioHardwareNoError, "StartIO succeeds");

    UInt32 theRunning = 0;
    if (ReadUInt32(inDeviceID, kAudioDevicePropertyDeviceIsRunning,
                   kAudioObjectPropertyScopeGlobal, &theRunning, "device is running")) {
        CHECK(theRunning == 1, "the device reports itself as running");
    }

    Float64 theSampleTime = -1.0;
    UInt64  theHostTime = 0;
    UInt64  theSeed = 0;
    theError = (*gDriver)->GetZeroTimeStamp(gDriver, inDeviceID, 1, &theSampleTime,
                                            &theHostTime, &theSeed);
    CHECK(theError == kAudioHardwareNoError && theSampleTime == 0.0,
          "the first zero timestamp is at sample time 0");

    Float64 thePrevious = theSampleTime;
    UInt64  thePreviousHost = theHostTime;
    bool    theMonotonic = true;
    for (int i = 0; i < 8; ++i) {
        Float64 theNextSample = 0.0;
        UInt64  theNextHost = 0;
        UInt64  theNextSeed = 0;
        (*gDriver)->GetZeroTimeStamp(gDriver, inDeviceID, 1, &theNextSample, &theNextHost,
                                     &theNextSeed);
        if (theNextSample < thePrevious || theNextHost < thePreviousHost ||
            theNextSeed != theSeed) {
            theMonotonic = false;
        }
        thePrevious = theNextSample;
        thePreviousHost = theNextHost;
    }
    CHECK(theMonotonic, "repeated zero timestamps are monotonic with a stable seed");

    //  One period is kRingFrames frames; wait slightly longer than that.
    const double thePeriod = (double)kRingFrames / inSampleRate;
    SleepSeconds(thePeriod + 0.10);

    Float64 theAdvancedSample = 0.0;
    UInt64  theAdvancedHost = 0;
    UInt64  theAdvancedSeed = 0;
    (*gDriver)->GetZeroTimeStamp(gDriver, inDeviceID, 1, &theAdvancedSample, &theAdvancedHost,
                                 &theAdvancedSeed);
    CHECK(theAdvancedSample == (Float64)kRingFrames,
          "after one period the zero timestamp is at sample time %.0f", theAdvancedSample);
    CHECK(theAdvancedHost > theHostTime, "the zero timestamp host time advanced too");
    CHECK(theAdvancedSeed == theSeed, "the timeline seed did not change while running");
}

static void CheckLoopback(AudioObjectID inDeviceID)
{
    printf("\n-- loopback IO --\n");

    const AudioObjectID theInputStream  = inDeviceID + 1;
    const AudioObjectID theOutputStream = inDeviceID + 2;
    const UInt32 theSamples = kTestFrames * kChannels;

    Boolean theWillDo = false;
    Boolean theInPlace = false;
    (*gDriver)->WillDoIOOperation(gDriver, inDeviceID, 1,
                                  kAudioServerPlugInIOOperationWriteMix,
                                  &theWillDo, &theInPlace);
    CHECK(theWillDo && theInPlace, "the device performs WriteMix in place");

    (*gDriver)->WillDoIOOperation(gDriver, inDeviceID, 1,
                                  kAudioServerPlugInIOOperationReadInput,
                                  &theWillDo, &theInPlace);
    CHECK(theWillDo && theInPlace, "the device performs ReadInput in place");

    (*gDriver)->WillDoIOOperation(gDriver, inDeviceID, 1,
                                  kAudioServerPlugInIOOperationProcessMix,
                                  &theWillDo, &theInPlace);
    CHECK(!theWillDo, "the device declines ProcessMix");

    Float32* theRamp    = (Float32*)malloc(theSamples * sizeof(Float32));
    Float32* theScratch = (Float32*)malloc(theSamples * sizeof(Float32));
    Float32* theExpect  = (Float32*)malloc(theSamples * sizeof(Float32));
    if (theRamp == NULL || theScratch == NULL || theExpect == NULL) {
        CHECK(false, "allocating the IO test buffers");
        free(theRamp);
        free(theScratch);
        free(theExpect);
        return;
    }

    //  1. Write a ramp at sample time 1024 and read it back from the same spot.
    const Float64 theTime = 1024.0;
    FillRamp(theRamp, kTestFrames, 1.0f / 4096.0f);
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    OSStatus theError = RunIOOperation(inDeviceID, theOutputStream, 1,
                                       kAudioServerPlugInIOOperationWriteMix,
                                       theTime, kTestFrames, theScratch);
    CHECK(theError == kAudioHardwareNoError, "WriteMix at sample time %.0f succeeds", theTime);

    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    theError = RunIOOperation(inDeviceID, theInputStream, 1,
                              kAudioServerPlugInIOOperationReadInput,
                              theTime, kTestFrames, theScratch);
    CHECK(theError == kAudioHardwareNoError, "ReadInput at sample time %.0f succeeds", theTime);
    CHECK(BuffersMatch(theScratch, theRamp, theSamples),
          "the ramp written to the output stream comes back on the input stream");

    //  2. Reading the same region again must yield silence.
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theTime, kTestFrames, theScratch);
    CHECK(BufferIsSilent(theScratch, theSamples), "a second read of the same region is silent");

    //  3. Two clients writing the same block sum.
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                   theTime, kTestFrames, theScratch);
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 2, kAudioServerPlugInIOOperationWriteMix,
                   theTime, kTestFrames, theScratch);
    for (UInt32 i = 0; i < theSamples; ++i) {
        theExpect[i] = theRamp[i] * 2.0f;
    }
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theTime, kTestFrames, theScratch);
    CHECK(BuffersMatch(theScratch, theExpect, theSamples),
          "two clients writing the same block are summed");

    //  4. A block that straddles the end of the ring.
    const Float64 theWrapTime = (Float64)(kRingFrames - (kTestFrames / 2));
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                   theWrapTime, kTestFrames, theScratch);
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theWrapTime, kTestFrames, theScratch);
    CHECK(BuffersMatch(theScratch, theRamp, theSamples),
          "a block that wraps the end of the ring survives the round trip");

    //  The wrapped block must also have been cleared on both sides of the seam.
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theWrapTime, kTestFrames, theScratch);
    CHECK(BufferIsSilent(theScratch, theSamples), "the wrapped region was zeroed after reading");

    //  5. The same offset one ring later addresses the same storage.
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                   theTime + (Float64)kRingFrames, kTestFrames, theScratch);
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theTime, kTestFrames, theScratch);
    CHECK(BuffersMatch(theScratch, theRamp, theSamples),
          "sample times one ring apart map to the same frames");

    //  6. Muting the device drops what clients write.
    const AudioObjectPropertyAddress theMuteAddress =
        MakeAddress(kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
    const UInt32 theOn = 1;
    const UInt32 theOff = 0;
    (*gDriver)->SetPropertyData(gDriver, inDeviceID + 4, 0, &theMuteAddress, 0, NULL,
                                (UInt32)sizeof(theOn), &theOn);
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                   theTime, kTestFrames, theScratch);
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theTime, kTestFrames, theScratch);
    CHECK(BufferIsSilent(theScratch, theSamples), "a muted device writes nothing into the ring");
    (*gDriver)->SetPropertyData(gDriver, inDeviceID + 4, 0, &theMuteAddress, 0, NULL,
                                (UInt32)sizeof(theOff), &theOff);

    //  7. Buses are independent.
    const AudioObjectID theOtherDevice = inDeviceID + 10;
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    (*gDriver)->StartIO(gDriver, theOtherDevice, 1);
    memcpy(theScratch, theRamp, theSamples * sizeof(Float32));
    RunIOOperation(inDeviceID, theOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                   theTime, kTestFrames, theScratch);
    memset(theScratch, 0xAB, theSamples * sizeof(Float32));
    RunIOOperation(theOtherDevice, theOtherDevice + 1, 1,
                   kAudioServerPlugInIOOperationReadInput, theTime, kTestFrames, theScratch);
    CHECK(BufferIsSilent(theScratch, theSamples), "writing to one bus does not leak into another");
    (*gDriver)->StopIO(gDriver, theOtherDevice, 1);

    //  Drain what we left behind on the bus under test.
    RunIOOperation(inDeviceID, theInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                   theTime, kTestFrames, theScratch);

    free(theRamp);
    free(theScratch);
    free(theExpect);
}

#pragma mark - main

int main(int argc, char** argv)
{
    const char* thePath = (argc > 1) ? argv[1] : kDefaultBinaryPath;

    printf("Clapboard driver harness\n");
    printf("binary: %s\n", thePath);

    void* theImage = dlopen(thePath, RTLD_NOW | RTLD_LOCAL);
    CHECK(theImage != NULL, "dlopen the driver binary");
    if (theImage == NULL) {
        printf("dlerror: %s\n", dlerror());
        return 1;
    }

    ClapboardCreateProc theCreate =
        (ClapboardCreateProc)dlsym(theImage, "ClapboardDriver_Create");
    CHECK(theCreate != NULL, "ClapboardDriver_Create is exported");
    if (theCreate == NULL) {
        return 1;
    }

    //  A factory request for some other plug-in type must be refused.
    CFUUIDRef theWrongType = CFUUIDCreateFromString(NULL,
        CFSTR("11111111-2222-3333-4444-555555555555"));
    CHECK(theCreate(NULL, theWrongType) == NULL, "the factory refuses a foreign type UUID");
    CFRelease(theWrongType);

    void* theInstance = theCreate(NULL, kAudioServerPlugInTypeUUID);
    CHECK(theInstance != NULL, "the factory returns an instance for kAudioServerPlugInTypeUUID");
    if (theInstance == NULL) {
        return 1;
    }

    AudioServerPlugInDriverRef theRef = (AudioServerPlugInDriverRef)theInstance;
    gDriver = theRef;

    void* theQueried = NULL;
    HRESULT theResult = (*theRef)->QueryInterface(
        theRef, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &theQueried);
    CHECK(theResult == S_OK && theQueried == theInstance,
          "QueryInterface returns the driver interface");

    void* theUnknown = NULL;
    theResult = (*theRef)->QueryInterface(theRef, CFUUIDGetUUIDBytes(IUnknownUUID), &theUnknown);
    CHECK(theResult == S_OK && theUnknown == theInstance, "QueryInterface supports IUnknown");

    CFUUIDRef theBogusUUID = CFUUIDCreateFromString(NULL,
        CFSTR("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"));
    void* theNothing = NULL;
    theResult = (*theRef)->QueryInterface(theRef, CFUUIDGetUUIDBytes(theBogusUUID), &theNothing);
    CHECK(theResult == E_NOINTERFACE, "QueryInterface rejects an unknown interface");
    CFRelease(theBogusUUID);

    //  Balance the two successful QueryInterface retains.
    (*theRef)->Release(theRef);
    (*theRef)->Release(theRef);

    OSStatus theError = (*theRef)->Initialize(theRef, &gFakeHost);
    CHECK(theError == kAudioHardwareNoError, "Initialize with the fake host succeeds");

    AudioObjectID theCreated = 0;
    CFDictionaryRef theEmptyDescription =
        CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    AudioServerPlugInClientInfo theHostClient;
    memset(&theHostClient, 0, sizeof(theHostClient));
    theHostClient.mClientID       = kAudioServerPlugInHostClientID;
    theHostClient.mIsNativeEndian = true;
    theError = (*theRef)->CreateDevice(theRef, theEmptyDescription, &theHostClient, &theCreated);
    CFRelease(theEmptyDescription);
    CHECK(theError == kAudioHardwareUnsupportedOperationError,
          "CreateDevice reports kAudioHardwareUnsupportedOperationError");
    theError = (*theRef)->DestroyDevice(theRef, 10);
    CHECK(theError == kAudioHardwareUnsupportedOperationError,
          "DestroyDevice reports kAudioHardwareUnsupportedOperationError");

    AudioObjectID theDeviceIDs[64];
    UInt32 theDeviceCount = 0;
    CheckPlugInObject(theDeviceIDs, &theDeviceCount);

    for (UInt32 i = 0; i < theDeviceCount; ++i) {
        CheckDevice(theDeviceIDs[i], i);
    }
    if (theDeviceCount > 0) {
        CheckControls(theDeviceIDs[0]);
    }
    CheckTranslateUID(theDeviceIDs, theDeviceCount);

    if (theDeviceCount > 0) {
        AudioServerPlugInClientInfo theClient;
        memset(&theClient, 0, sizeof(theClient));
        theClient.mClientID      = 1;
        theClient.mProcessID     = 0;
        theClient.mIsNativeEndian = true;
        theClient.mBundleID      = CFSTR("com.astroqore.ClapboardHarness");
        theError = (*theRef)->AddDeviceClient(theRef, theDeviceIDs[0], &theClient);
        CHECK(theError == kAudioHardwareNoError, "AddDeviceClient succeeds");

        //  96 kHz halves the zero-timestamp period, so the timeline check waits
        //  0.68 s rather than 1.37 s.
        CheckSampleRateChange(theDeviceIDs[0], 96000.0);
        CheckTimeline(theDeviceIDs[0], 96000.0);
        CheckLoopback(theDeviceIDs[0]);

        theError = (*theRef)->StopIO(theRef, theDeviceIDs[0], 1);
        CHECK(theError == kAudioHardwareNoError, "StopIO succeeds");

        UInt32 theRunning = 1;
        if (ReadUInt32(theDeviceIDs[0], kAudioDevicePropertyDeviceIsRunning,
                       kAudioObjectPropertyScopeGlobal, &theRunning, "device stopped")) {
            CHECK(theRunning == 0, "the device reports itself as stopped");
        }

        CheckSampleRateChange(theDeviceIDs[0], 48000.0);

        theError = (*theRef)->RemoveDeviceClient(theRef, theDeviceIDs[0], &theClient);
        CHECK(theError == kAudioHardwareNoError, "RemoveDeviceClient succeeds");
    }

    printf("\n-- teardown --\n");
    const ULONG theRemaining = (*theRef)->Release(theRef);
    CHECK(theRemaining == 0, "the final Release drops the reference count to 0");

    //  After teardown the object model is empty but the entry points still
    //  answer instead of crashing.
    const AudioObjectPropertyAddress theAddress =
        MakeAddress(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    UInt32 theSize = 0xFFFFFFFFu;
    (*theRef)->GetPropertyDataSize(theRef, kAudioObjectPlugInObject, 0, &theAddress,
                                   0, NULL, &theSize);
    CHECK(theSize == 0, "the device list is empty after the last release");

    printf("\n=== %u checks, %u failures ===\n", gChecks, gFailures);
    printf("%s\n", (gFailures == 0) ? "RESULT: PASS" : "RESULT: FAIL");
    return (gFailures == 0) ? 0 : 1;
}
