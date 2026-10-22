#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/IOReturn.h>
#include <stdio.h>
#include <unistd.h>

typedef CFTypeRef IOPSPowerSourceID;
extern IOReturn IOPSCreatePowerSource(IOPSPowerSourceID *outPS);
extern IOReturn IOPSSetPowerSourceDetails(IOPSPowerSourceID whichPS, CFDictionaryRef details);
extern IOReturn IOPSReleasePowerSource(IOPSPowerSourceID whichPS);

int main(void) {
    IOPSPowerSourceID ps = NULL;
    IOReturn r = IOPSCreatePowerSource(&ps);
    printf("IOPSCreatePowerSource -> 0x%08x (uid=%d)\n", r, getuid());
    if (r != kIOReturnSuccess) return 1;

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int cur = 100, max = 100, runtime = 1800;
    CFNumberRef nCur = CFNumberCreate(NULL, kCFNumberIntType, &cur);
    CFNumberRef nMax = CFNumberCreate(NULL, kCFNumberIntType, &max);
    CFNumberRef nRt  = CFNumberCreate(NULL, kCFNumberIntType, &runtime);
    CFDictionarySetValue(d, CFSTR(kIOPSNameKey), CFSTR("Squirrel Probe UPS"));
    CFDictionarySetValue(d, CFSTR(kIOPSTypeKey), CFSTR(kIOPSUPSType));
    CFDictionarySetValue(d, CFSTR(kIOPSTransportTypeKey), CFSTR(kIOPSNetworkTransportType));
    /* Deliberately healthy + on line power: nothing for powerd to act on. */
    CFDictionarySetValue(d, CFSTR(kIOPSPowerSourceStateKey), CFSTR(kIOPSACPowerValue));
    CFDictionarySetValue(d, CFSTR(kIOPSIsPresentKey), kCFBooleanTrue);
    CFDictionarySetValue(d, CFSTR(kIOPSIsChargingKey), kCFBooleanFalse);
    CFDictionarySetValue(d, CFSTR(kIOPSCurrentCapacityKey), nCur);
    CFDictionarySetValue(d, CFSTR(kIOPSMaxCapacityKey), nMax);
    CFDictionarySetValue(d, CFSTR(kIOPSTimeToEmptyKey), nRt);
    r = IOPSSetPowerSourceDetails(ps, d);
    printf("IOPSSetPowerSourceDetails -> 0x%08x\n", r);
    fflush(stdout);

    sleep(6);
    printf("IOPSReleasePowerSource -> 0x%08x\n", IOPSReleasePowerSource(ps));
    return 0;
}
