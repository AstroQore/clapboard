//
//  ClapboardProperties.c
//  The property half of the AudioServerPlugIn interface.
//
//  Every object the driver publishes — the plug-in, each device, each stream
//  and the two output controls per device — answers here. The five entry
//  points share one description routine so that HasProperty(),
//  IsPropertySettable() and GetPropertyDataSize() can never disagree with
//  each other.
//
//  None of this runs on the IO thread, so taking gClapboard_StateMutex is
//  fine. The one rule is that the host must never be called back while the
//  mutex is held: RequestDeviceConfigurationChange() may re-enter the driver
//  synchronously.
//

#include "ClapboardDriver.h"

#include <stddef.h>
#include <string.h>

#define kClapboard_MaxOwnedObjects (kClapboard_ObjectOffset_Count)

#pragma mark - Small writers

static OSStatus Clapboard_WriteUInt32(UInt32 inValue, UInt32 inDataSize,
                                      UInt32* outDataSize, void* outData)
{
    if (inDataSize < sizeof(UInt32)) {
        return kAudioHardwareBadPropertySizeError;
    }
    *((UInt32*)outData) = inValue;
    *outDataSize = (UInt32)sizeof(UInt32);
    return kAudioHardwareNoError;
}

static OSStatus Clapboard_WriteFloat32(Float32 inValue, UInt32 inDataSize,
                                       UInt32* outDataSize, void* outData)
{
    if (inDataSize < sizeof(Float32)) {
        return kAudioHardwareBadPropertySizeError;
    }
    *((Float32*)outData) = inValue;
    *outDataSize = (UInt32)sizeof(Float32);
    return kAudioHardwareNoError;
}

static OSStatus Clapboard_WriteFloat64(Float64 inValue, UInt32 inDataSize,
                                       UInt32* outDataSize, void* outData)
{
    if (inDataSize < sizeof(Float64)) {
        return kAudioHardwareBadPropertySizeError;
    }
    *((Float64*)outData) = inValue;
    *outDataSize = (UInt32)sizeof(Float64);
    return kAudioHardwareNoError;
}

//  CFString properties hand ownership to the caller.
static OSStatus Clapboard_WriteCFString(CFStringRef inValue, UInt32 inDataSize,
                                        UInt32* outDataSize, void* outData)
{
    if (inDataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    *((CFStringRef*)outData) = (inValue != NULL) ? (CFStringRef)CFRetain(inValue) : NULL;
    *outDataSize = (UInt32)sizeof(CFStringRef);
    return kAudioHardwareNoError;
}

static OSStatus Clapboard_WriteObjectIDs(const AudioObjectID* inIDs, UInt32 inCount,
                                         UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    UInt32 theFits = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (theFits > inCount) {
        theFits = inCount;
    }
    if (theFits > 0) {
        memcpy(outData, inIDs, (size_t)theFits * sizeof(AudioObjectID));
    }
    *outDataSize = theFits * (UInt32)sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

#pragma mark - Stream formats

static void Clapboard_FillFormat(AudioStreamBasicDescription* outFormat, Float64 inSampleRate)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate       = inSampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat |
                                   kAudioFormatFlagsNativeEndian |
                                   kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kClapboard_BytesPerFrame;
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kClapboard_BytesPerFrame;
    outFormat->mChannelsPerFrame = kClapboard_ChannelCount;
    outFormat->mBitsPerChannel   = 32;
}

//  True when the format differs from ours only in its sample rate, which is
//  the only thing a client is allowed to change.
static bool Clapboard_FormatIsAcceptable(const AudioStreamBasicDescription* inFormat)
{
    AudioStreamBasicDescription theReference;
    Clapboard_FillFormat(&theReference, inFormat->mSampleRate);
    return inFormat->mFormatID         == theReference.mFormatID &&
           inFormat->mFormatFlags      == theReference.mFormatFlags &&
           inFormat->mBytesPerPacket   == theReference.mBytesPerPacket &&
           inFormat->mFramesPerPacket  == theReference.mFramesPerPacket &&
           inFormat->mBytesPerFrame    == theReference.mBytesPerFrame &&
           inFormat->mChannelsPerFrame == theReference.mChannelsPerFrame &&
           inFormat->mBitsPerChannel   == theReference.mBitsPerChannel &&
           Clapboard_IsSupportedSampleRate(inFormat->mSampleRate);
}

#pragma mark - Owned object lists

//  Fills outIDs with the objects `inSelector` asks for in `inScope`, and
//  returns how many there are. outIDs may be NULL when only the count is
//  wanted; it must have room for kClapboard_MaxOwnedObjects otherwise.
static UInt32 Clapboard_CollectObjectIDs(ClapboardObjectKind inKind,
                                         const ClapboardDevice* inDevice,
                                         AudioObjectPropertySelector inSelector,
                                         AudioObjectPropertyScope inScope,
                                         AudioObjectID* outIDs)
{
    AudioObjectID theIDs[kClapboard_MaxDeviceCount];
    UInt32 theCount = 0;

    if (inKind == kClapboardObjectKind_PlugIn) {
        for (UInt32 i = 0; i < gClapboard_DeviceCount; ++i) {
            theIDs[theCount++] = gClapboard_Devices[i].deviceID;
        }
        if (outIDs != NULL && theCount > 0) {
            memcpy(outIDs, theIDs, (size_t)theCount * sizeof(AudioObjectID));
        }
        return theCount;
    }

    if (inKind != kClapboardObjectKind_Device || inDevice == NULL) {
        return 0;
    }

    const bool theWantsInput  = (inScope == kAudioObjectPropertyScopeGlobal) ||
                                (inScope == kAudioObjectPropertyScopeInput);
    const bool theWantsOutput = (inScope == kAudioObjectPropertyScopeGlobal) ||
                                (inScope == kAudioObjectPropertyScopeOutput);

    switch (inSelector) {
        case kAudioObjectPropertyOwnedObjects:
            if (theWantsInput) {
                theIDs[theCount++] = inDevice->inputStreamID;
            }
            if (theWantsOutput) {
                theIDs[theCount++] = inDevice->outputStreamID;
                theIDs[theCount++] = inDevice->volumeID;
                theIDs[theCount++] = inDevice->muteID;
            }
            break;

        case kAudioDevicePropertyStreams:
            if (theWantsInput) {
                theIDs[theCount++] = inDevice->inputStreamID;
            }
            if (theWantsOutput) {
                theIDs[theCount++] = inDevice->outputStreamID;
            }
            break;

        case kAudioObjectPropertyControlList:
            //  Scope-independent: the HAL always asks on the global scope.
            theIDs[theCount++] = inDevice->volumeID;
            theIDs[theCount++] = inDevice->muteID;
            break;

        default:
            break;
    }

    if (outIDs != NULL && theCount > 0) {
        memcpy(outIDs, theIDs, (size_t)theCount * sizeof(AudioObjectID));
    }
    return theCount;
}

#pragma mark - Property description

//  The single source of truth for "does this object have this property, how
//  big is it, and can it be set". Callers must hold gClapboard_StateMutex.
static OSStatus Clapboard_DescribePropertyLocked(ClapboardObjectKind inKind,
                                                 const ClapboardDevice* inDevice,
                                                 const AudioObjectPropertyAddress* inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void* inQualifierData,
                                                 UInt32* outSize,
                                                 Boolean* outSettable)
{
    UInt32  theSize     = 0;
    Boolean theSettable = false;

    switch (inKind) {
        case kClapboardObjectKind_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    theSize = (UInt32)sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    theSize = (UInt32)sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    theSize = Clapboard_CollectObjectIDs(inKind, NULL, inAddress->mSelector,
                                                         inAddress->mScope, NULL) *
                              (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    //  The answer is always one object ID, whether or not the
                    //  caller bothered to bring the UID along. Only
                    //  GetPropertyData insists on the qualifier.
                    (void)inQualifierDataSize;
                    (void)inQualifierData;
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    theSize = 0;
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kClapboardObjectKind_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    theSize = (UInt32)sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    theSize = (UInt32)sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                    theSize = Clapboard_CollectObjectIDs(inKind, inDevice, inAddress->mSelector,
                                                         inAddress->mScope, NULL) *
                              (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIsHidden:
                    theSize = (UInt32)sizeof(UInt32);
                    break;
                case kAudioDevicePropertyRelatedDevices:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    theSize     = (UInt32)sizeof(Float64);
                    theSettable = true;
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    theSize = kClapboard_SampleRateCount * (UInt32)sizeof(AudioValueRange);
                    break;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    theSize = 2 * (UInt32)sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelLayout:
                    theSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) +
                                       (kClapboard_ChannelCount * sizeof(AudioChannelDescription)));
                    break;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    theSize = 0;
                    break;
                default:
                    //  kAudioDevicePropertyIcon and everything else are not ours.
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kClapboardObjectKind_InputStream:
        case kClapboardObjectKind_OutputStream:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    theSize = (UInt32)sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                    theSize = (UInt32)sizeof(CFStringRef);
                    break;
                case kAudioStreamPropertyIsActive:
                    theSize     = (UInt32)sizeof(UInt32);
                    theSettable = true;
                    break;
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    theSize = (UInt32)sizeof(UInt32);
                    break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    theSize     = (UInt32)sizeof(AudioStreamBasicDescription);
                    theSettable = true;
                    break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    theSize = kClapboard_SampleRateCount *
                              (UInt32)sizeof(AudioStreamRangedDescription);
                    break;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    theSize = 0;
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kClapboardObjectKind_Volume:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    theSize = (UInt32)sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioControlPropertyScope:
                    theSize = (UInt32)sizeof(AudioObjectPropertyScope);
                    break;
                case kAudioControlPropertyElement:
                    theSize = (UInt32)sizeof(AudioObjectPropertyElement);
                    break;
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                    theSize     = (UInt32)sizeof(Float32);
                    theSettable = true;
                    break;
                case kAudioLevelControlPropertyDecibelRange:
                    theSize = (UInt32)sizeof(AudioValueRange);
                    break;
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    theSize = (UInt32)sizeof(Float32);
                    break;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    theSize = 0;
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kClapboardObjectKind_Mute:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    theSize = (UInt32)sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    theSize = (UInt32)sizeof(AudioObjectID);
                    break;
                case kAudioControlPropertyScope:
                    theSize = (UInt32)sizeof(AudioObjectPropertyScope);
                    break;
                case kAudioControlPropertyElement:
                    theSize = (UInt32)sizeof(AudioObjectPropertyElement);
                    break;
                case kAudioBooleanControlPropertyValue:
                    theSize     = (UInt32)sizeof(UInt32);
                    theSettable = true;
                    break;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    theSize = 0;
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }

    if (outSize != NULL) {
        *outSize = theSize;
    }
    if (outSettable != NULL) {
        *outSettable = theSettable;
    }
    return kAudioHardwareNoError;
}

#pragma mark - Entry points: describe

Boolean Clapboard_HasProperty(AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inAddress == NULL) {
        return false;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = NULL;
    const ClapboardObjectKind theKind = Clapboard_ClassifyObject(inObjectID, &theDevice);
    const OSStatus theError = Clapboard_DescribePropertyLocked(
        theKind, theDevice, inAddress, 0, NULL, NULL, NULL);
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return theError == kAudioHardwareNoError;
}

OSStatus Clapboard_IsPropertySettable(AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      Boolean* outIsSettable)
{
    (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = NULL;
    const ClapboardObjectKind theKind = Clapboard_ClassifyObject(inObjectID, &theDevice);
    const OSStatus theError = Clapboard_DescribePropertyLocked(
        theKind, theDevice, inAddress, 0, NULL, NULL, outIsSettable);
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return theError;
}

OSStatus Clapboard_GetPropertyDataSize(AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32* outDataSize)
{
    (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);
    ClapboardDevice* theDevice = NULL;
    const ClapboardObjectKind theKind = Clapboard_ClassifyObject(inObjectID, &theDevice);
    const OSStatus theError = Clapboard_DescribePropertyLocked(
        theKind, theDevice, inAddress, inQualifierDataSize, inQualifierData,
        outDataSize, NULL);
    pthread_mutex_unlock(&gClapboard_StateMutex);

    return theError;
}

#pragma mark - Entry point: get

static OSStatus Clapboard_GetPlugInPropertyLocked(const AudioObjectPropertyAddress* inAddress,
                                                  UInt32 inQualifierDataSize,
                                                  const void* inQualifierData,
                                                  UInt32 inDataSize,
                                                  UInt32* outDataSize,
                                                  void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return Clapboard_WriteUInt32(kAudioObjectClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyClass:
            return Clapboard_WriteUInt32(kAudioPlugInClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyOwner:
            return Clapboard_WriteUInt32(kAudioObjectUnknown, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyManufacturer:
            return Clapboard_WriteCFString(kClapboard_Manufacturer, inDataSize,
                                           outDataSize, outData);

        case kAudioPlugInPropertyResourceBundle:
            return Clapboard_WriteCFString(CFSTR(""), inDataSize, outDataSize, outData);

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID theIDs[kClapboard_MaxDeviceCount];
            const UInt32 theCount = Clapboard_CollectObjectIDs(
                kClapboardObjectKind_PlugIn, NULL, inAddress->mSelector,
                inAddress->mScope, theIDs);
            return Clapboard_WriteObjectIDs(theIDs, theCount, inDataSize, outDataSize, outData);
        }

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            const ClapboardDevice* theDevice =
                Clapboard_DeviceForUID(*((const CFStringRef*)inQualifierData));
            return Clapboard_WriteUInt32(theDevice != NULL ? theDevice->deviceID
                                                           : (UInt32)kAudioObjectUnknown,
                                         inDataSize, outDataSize, outData);
        }

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Clapboard_GetDevicePropertyLocked(const ClapboardDevice* inDevice,
                                                  const AudioObjectPropertyAddress* inAddress,
                                                  UInt32 inDataSize,
                                                  UInt32* outDataSize,
                                                  void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return Clapboard_WriteUInt32(kAudioObjectClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyClass:
            return Clapboard_WriteUInt32(kAudioDeviceClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyOwner:
            return Clapboard_WriteUInt32(kAudioObjectPlugInObject, inDataSize,
                                         outDataSize, outData);

        case kAudioObjectPropertyName:
            return Clapboard_WriteCFString(inDevice->name, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyManufacturer:
            return Clapboard_WriteCFString(kClapboard_Manufacturer, inDataSize,
                                           outDataSize, outData);

        case kAudioDevicePropertyDeviceUID:
            return Clapboard_WriteCFString(inDevice->uid, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyModelUID:
            return Clapboard_WriteCFString(kClapboard_ModelUID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList: {
            AudioObjectID theIDs[kClapboard_MaxOwnedObjects];
            const UInt32 theCount = Clapboard_CollectObjectIDs(
                kClapboardObjectKind_Device, inDevice, inAddress->mSelector,
                inAddress->mScope, theIDs);
            return Clapboard_WriteObjectIDs(theIDs, theCount, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyTransportType:
            return Clapboard_WriteUInt32(kAudioDeviceTransportTypeVirtual, inDataSize,
                                         outDataSize, outData);

        case kAudioDevicePropertyRelatedDevices: {
            const AudioObjectID theSelf = inDevice->deviceID;
            return Clapboard_WriteObjectIDs(&theSelf, 1, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyClockDomain:
            return Clapboard_WriteUInt32(0, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyDeviceIsAlive:
            return Clapboard_WriteUInt32(1, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyDeviceIsRunning:
            return Clapboard_WriteUInt32(inDevice->ioCount > 0 ? 1u : 0u, inDataSize,
                                         outDataSize, outData);

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return Clapboard_WriteUInt32(1, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyLatency:
            return Clapboard_WriteUInt32(0, inDataSize, outDataSize, outData);

        case kAudioDevicePropertySafetyOffset:
            return Clapboard_WriteUInt32(kClapboard_SafetyOffset, inDataSize,
                                         outDataSize, outData);

        case kAudioDevicePropertyZeroTimeStampPeriod:
            return Clapboard_WriteUInt32(kClapboard_RingFrames, inDataSize,
                                         outDataSize, outData);

        case kAudioDevicePropertyIsHidden:
            return Clapboard_WriteUInt32(0, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyNominalSampleRate:
            return Clapboard_WriteFloat64(inDevice->sampleRate, inDataSize,
                                          outDataSize, outData);

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 theFits = inDataSize / (UInt32)sizeof(AudioValueRange);
            if (theFits > kClapboard_SampleRateCount) {
                theFits = kClapboard_SampleRateCount;
            }
            AudioValueRange* theRanges = (AudioValueRange*)outData;
            for (UInt32 i = 0; i < theFits; ++i) {
                theRanges[i].mMinimum = kClapboard_SampleRates[i];
                theRanges[i].mMaximum = kClapboard_SampleRates[i];
            }
            *outDataSize = theFits * (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * (UInt32)sizeof(UInt32);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelLayout: {
            const UInt32 theNeeded =
                (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) +
                         (kClapboard_ChannelCount * sizeof(AudioChannelDescription)));
            if (inDataSize < theNeeded) {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
            memset(theLayout, 0, theNeeded);
            theLayout->mChannelLayoutTag          = kAudioChannelLayoutTag_UseChannelDescriptions;
            theLayout->mChannelBitmap             = 0;
            theLayout->mNumberChannelDescriptions = kClapboard_ChannelCount;
            theLayout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            theLayout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = theNeeded;
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Clapboard_GetStreamPropertyLocked(const ClapboardDevice* inDevice,
                                                  bool inIsInput,
                                                  const AudioObjectPropertyAddress* inAddress,
                                                  UInt32 inDataSize,
                                                  UInt32* outDataSize,
                                                  void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return Clapboard_WriteUInt32(kAudioObjectClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyClass:
            return Clapboard_WriteUInt32(kAudioStreamClassID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyOwner:
            return Clapboard_WriteUInt32(inDevice->deviceID, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyName:
            return Clapboard_WriteCFString(inDevice->name, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyIsActive:
            return Clapboard_WriteUInt32((inIsInput ? inDevice->inputStreamActive
                                                    : inDevice->outputStreamActive) ? 1u : 0u,
                                         inDataSize, outDataSize, outData);

        case kAudioStreamPropertyDirection:
            //  1 means the stream carries input, 0 output.
            return Clapboard_WriteUInt32(inIsInput ? 1u : 0u, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyTerminalType:
            return Clapboard_WriteUInt32(inIsInput ? kAudioStreamTerminalTypeMicrophone
                                                   : kAudioStreamTerminalTypeSpeaker,
                                         inDataSize, outDataSize, outData);

        case kAudioStreamPropertyStartingChannel:
            return Clapboard_WriteUInt32(1, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyLatency:
            return Clapboard_WriteUInt32(0, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                return kAudioHardwareBadPropertySizeError;
            }
            Clapboard_FillFormat((AudioStreamBasicDescription*)outData, inDevice->sampleRate);
            *outDataSize = (UInt32)sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 theFits = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
            if (theFits > kClapboard_SampleRateCount) {
                theFits = kClapboard_SampleRateCount;
            }
            AudioStreamRangedDescription* theFormats = (AudioStreamRangedDescription*)outData;
            for (UInt32 i = 0; i < theFits; ++i) {
                Clapboard_FillFormat(&theFormats[i].mFormat, kClapboard_SampleRates[i]);
                theFormats[i].mSampleRateRange.mMinimum = kClapboard_SampleRates[i];
                theFormats[i].mSampleRateRange.mMaximum = kClapboard_SampleRates[i];
            }
            *outDataSize = theFits * (UInt32)sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Clapboard_GetVolumePropertyLocked(const ClapboardDevice* inDevice,
                                                  const AudioObjectPropertyAddress* inAddress,
                                                  UInt32 inDataSize,
                                                  UInt32* outDataSize,
                                                  void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return Clapboard_WriteUInt32(kAudioLevelControlClassID, inDataSize,
                                         outDataSize, outData);

        case kAudioObjectPropertyClass:
            return Clapboard_WriteUInt32(kAudioVolumeControlClassID, inDataSize,
                                         outDataSize, outData);

        case kAudioObjectPropertyOwner:
            return Clapboard_WriteUInt32(inDevice->deviceID, inDataSize, outDataSize, outData);

        case kAudioControlPropertyScope:
            return Clapboard_WriteUInt32(kAudioObjectPropertyScopeOutput, inDataSize,
                                         outDataSize, outData);

        case kAudioControlPropertyElement:
            return Clapboard_WriteUInt32(kAudioObjectPropertyElementMain, inDataSize,
                                         outDataSize, outData);

        case kAudioLevelControlPropertyScalarValue:
            return Clapboard_WriteFloat32(inDevice->volumeScalar, inDataSize,
                                          outDataSize, outData);

        case kAudioLevelControlPropertyDecibelValue:
            return Clapboard_WriteFloat32(Clapboard_ScalarToDecibels(inDevice->volumeScalar),
                                          inDataSize, outDataSize, outData);

        case kAudioLevelControlPropertyDecibelRange: {
            if (inDataSize < sizeof(AudioValueRange)) {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioValueRange* theRange = (AudioValueRange*)outData;
            theRange->mMinimum = kClapboard_VolumeMinDB;
            theRange->mMaximum = kClapboard_VolumeMaxDB;
            *outDataSize = (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }

        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *((Float32*)outData) = Clapboard_ScalarToDecibels(*((Float32*)outData));
            *outDataSize = (UInt32)sizeof(Float32);
            return kAudioHardwareNoError;
        }

        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *((Float32*)outData) = Clapboard_DecibelsToScalar(*((Float32*)outData));
            *outDataSize = (UInt32)sizeof(Float32);
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Clapboard_GetMutePropertyLocked(const ClapboardDevice* inDevice,
                                                const AudioObjectPropertyAddress* inAddress,
                                                UInt32 inDataSize,
                                                UInt32* outDataSize,
                                                void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return Clapboard_WriteUInt32(kAudioBooleanControlClassID, inDataSize,
                                         outDataSize, outData);

        case kAudioObjectPropertyClass:
            return Clapboard_WriteUInt32(kAudioMuteControlClassID, inDataSize,
                                         outDataSize, outData);

        case kAudioObjectPropertyOwner:
            return Clapboard_WriteUInt32(inDevice->deviceID, inDataSize, outDataSize, outData);

        case kAudioControlPropertyScope:
            return Clapboard_WriteUInt32(kAudioObjectPropertyScopeOutput, inDataSize,
                                         outDataSize, outData);

        case kAudioControlPropertyElement:
            return Clapboard_WriteUInt32(kAudioObjectPropertyElementMain, inDataSize,
                                         outDataSize, outData);

        case kAudioBooleanControlPropertyValue:
            return Clapboard_WriteUInt32(
                atomic_load_explicit(&inDevice->muted, memory_order_relaxed) ? 1u : 0u,
                inDataSize, outDataSize, outData);

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Clapboard_GetPropertyData(AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void* inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32* outDataSize,
                                   void* outData)
{
    (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || (outData == NULL && inDataSize > 0)) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gClapboard_StateMutex);

    ClapboardDevice* theDevice = NULL;
    const ClapboardObjectKind theKind = Clapboard_ClassifyObject(inObjectID, &theDevice);
    OSStatus theError = kAudioHardwareBadObjectError;

    switch (theKind) {
        case kClapboardObjectKind_PlugIn:
            theError = Clapboard_GetPlugInPropertyLocked(inAddress, inQualifierDataSize,
                                                         inQualifierData, inDataSize,
                                                         outDataSize, outData);
            break;
        case kClapboardObjectKind_Device:
            theError = Clapboard_GetDevicePropertyLocked(theDevice, inAddress, inDataSize,
                                                         outDataSize, outData);
            break;
        case kClapboardObjectKind_InputStream:
            theError = Clapboard_GetStreamPropertyLocked(theDevice, true, inAddress,
                                                         inDataSize, outDataSize, outData);
            break;
        case kClapboardObjectKind_OutputStream:
            theError = Clapboard_GetStreamPropertyLocked(theDevice, false, inAddress,
                                                         inDataSize, outDataSize, outData);
            break;
        case kClapboardObjectKind_Volume:
            theError = Clapboard_GetVolumePropertyLocked(theDevice, inAddress, inDataSize,
                                                         outDataSize, outData);
            break;
        case kClapboardObjectKind_Mute:
            theError = Clapboard_GetMutePropertyLocked(theDevice, inAddress, inDataSize,
                                                       outDataSize, outData);
            break;
        default:
            break;
    }

    pthread_mutex_unlock(&gClapboard_StateMutex);
    return theError;
}

#pragma mark - Entry point: set

//  A sample-rate change touches IO, so it has to go out through the host and
//  come back in PerformDeviceConfigurationChange(). Everything else can be
//  applied here and announced with PropertiesChanged().
OSStatus Clapboard_SetPropertyData(AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void* inQualifierData,
                                   UInt32 inDataSize,
                                   const void* inData)
{
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    AudioObjectPropertyAddress theChanged[3];
    UInt32        theChangedCount    = 0;
    AudioObjectID theChangedObject   = inObjectID;
    Float64       theRequestedRate   = 0.0;
    AudioObjectID theRateDeviceID    = kAudioObjectUnknown;
    OSStatus      theError           = kAudioHardwareUnknownPropertyError;

    pthread_mutex_lock(&gClapboard_StateMutex);

    ClapboardDevice* theDevice = NULL;
    const ClapboardObjectKind theKind = Clapboard_ClassifyObject(inObjectID, &theDevice);

    switch (theKind) {
        case kClapboardObjectKind_Device:
            if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
                if (inDataSize != sizeof(Float64)) {
                    theError = kAudioHardwareBadPropertySizeError;
                    break;
                }
                const Float64 theRate = *((const Float64*)inData);
                if (!Clapboard_IsSupportedSampleRate(theRate)) {
                    theError = kAudioHardwareIllegalOperationError;
                    break;
                }
                if (theRate != theDevice->sampleRate) {
                    theDevice->pendingSampleRate = theRate;
                    theRequestedRate = theRate;
                    theRateDeviceID  = theDevice->deviceID;
                }
                theError = kAudioHardwareNoError;
            } else {
                theError = Clapboard_DescribePropertyLocked(theKind, theDevice, inAddress,
                                                            0, NULL, NULL, NULL);
                if (theError == kAudioHardwareNoError) {
                    theError = kAudioHardwareUnsupportedOperationError;
                }
            }
            break;

        case kClapboardObjectKind_InputStream:
        case kClapboardObjectKind_OutputStream: {
            const bool theIsInput = (theKind == kClapboardObjectKind_InputStream);
            if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
                if (inDataSize != sizeof(UInt32)) {
                    theError = kAudioHardwareBadPropertySizeError;
                    break;
                }
                const bool theActive = (*((const UInt32*)inData) != 0);
                bool* theSlot = theIsInput ? &theDevice->inputStreamActive
                                           : &theDevice->outputStreamActive;
                if (*theSlot != theActive) {
                    *theSlot = theActive;
                    theChanged[theChangedCount].mSelector = kAudioStreamPropertyIsActive;
                    theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                }
                theError = kAudioHardwareNoError;
            } else if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
                       inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
                if (inDataSize != sizeof(AudioStreamBasicDescription)) {
                    theError = kAudioHardwareBadPropertySizeError;
                    break;
                }
                const AudioStreamBasicDescription* theFormat =
                    (const AudioStreamBasicDescription*)inData;
                if (!Clapboard_FormatIsAcceptable(theFormat)) {
                    theError = kAudioDeviceUnsupportedFormatError;
                    break;
                }
                if (theFormat->mSampleRate != theDevice->sampleRate) {
                    theDevice->pendingSampleRate = theFormat->mSampleRate;
                    theRequestedRate = theFormat->mSampleRate;
                    theRateDeviceID  = theDevice->deviceID;
                }
                theError = kAudioHardwareNoError;
            } else {
                theError = Clapboard_DescribePropertyLocked(theKind, theDevice, inAddress,
                                                            0, NULL, NULL, NULL);
                if (theError == kAudioHardwareNoError) {
                    theError = kAudioHardwareUnsupportedOperationError;
                }
            }
            break;
        }

        case kClapboardObjectKind_Volume: {
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
                inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                if (inDataSize != sizeof(Float32)) {
                    theError = kAudioHardwareBadPropertySizeError;
                    break;
                }
                Float32 theScalar = *((const Float32*)inData);
                if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                    theScalar = Clapboard_DecibelsToScalar(theScalar);
                }
                if (theScalar < 0.0f) {
                    theScalar = 0.0f;
                }
                if (theScalar > 1.0f) {
                    theScalar = 1.0f;
                }
                if (theScalar != theDevice->volumeScalar) {
                    theDevice->volumeScalar = theScalar;
                    atomic_store_explicit(&theDevice->gain,
                                          Clapboard_ScalarToGain(theScalar),
                                          memory_order_relaxed);
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyScalarValue;
                    theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyDecibelValue;
                    theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                }
                theError = kAudioHardwareNoError;
            } else {
                theError = Clapboard_DescribePropertyLocked(theKind, theDevice, inAddress,
                                                            0, NULL, NULL, NULL);
                if (theError == kAudioHardwareNoError) {
                    theError = kAudioHardwareUnsupportedOperationError;
                }
            }
            break;
        }

        case kClapboardObjectKind_Mute: {
            if (inAddress->mSelector == kAudioBooleanControlPropertyValue) {
                if (inDataSize != sizeof(UInt32)) {
                    theError = kAudioHardwareBadPropertySizeError;
                    break;
                }
                const bool theMuted = (*((const UInt32*)inData) != 0);
                if (theMuted != atomic_load_explicit(&theDevice->muted, memory_order_relaxed)) {
                    atomic_store_explicit(&theDevice->muted, theMuted, memory_order_relaxed);
                    theChanged[theChangedCount].mSelector = kAudioBooleanControlPropertyValue;
                    theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                }
                theError = kAudioHardwareNoError;
            } else {
                theError = Clapboard_DescribePropertyLocked(theKind, theDevice, inAddress,
                                                            0, NULL, NULL, NULL);
                if (theError == kAudioHardwareNoError) {
                    theError = kAudioHardwareUnsupportedOperationError;
                }
            }
            break;
        }

        case kClapboardObjectKind_PlugIn:
            theError = Clapboard_DescribePropertyLocked(theKind, theDevice, inAddress,
                                                        0, NULL, NULL, NULL);
            if (theError == kAudioHardwareNoError) {
                theError = kAudioHardwareUnsupportedOperationError;
            }
            break;

        default:
            theError = kAudioHardwareBadObjectError;
            break;
    }

    AudioServerPlugInHostRef theHost = gClapboard_Host;
    pthread_mutex_unlock(&gClapboard_StateMutex);

    //  Both callbacks may re-enter the driver, so they happen unlocked.
    if (theHost != NULL && theChangedCount > 0) {
        theHost->PropertiesChanged(theHost, theChangedObject, theChangedCount, theChanged);
    }
    if (theHost != NULL && theRequestedRate > 0.0) {
        theHost->RequestDeviceConfigurationChange(theHost, theRateDeviceID,
                                                  (UInt64)theRequestedRate, NULL);
    }

    return theError;
}
