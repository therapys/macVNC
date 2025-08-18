#import <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    CFArrayRef infoArray = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!infoArray) {
        fprintf(stderr, "Unable to query window list.\n");
        return 1;
    }

    CFIndex count = CFArrayGetCount(infoArray);
    for (CFIndex i = 0; i < count; ++i) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(infoArray, i);
        if (!info) continue;

        CFStringRef title = (CFStringRef)CFDictionaryGetValue(info, kCGWindowName);
        if (!title || CFStringGetLength(title) == 0) continue; /* only windows with titles */

        CFNumberRef numRef = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowNumber);
        int windowId = 0;
        if (!numRef || !CFNumberGetValue(numRef, kCFNumberIntType, &windowId)) continue;

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(info, kCGWindowOwnerName);
        char titleBuf[1024];
        char ownerBuf[256];
        titleBuf[0] = '\0';
        ownerBuf[0] = '\0';
        if (title) CFStringGetCString(title, titleBuf, sizeof(titleBuf), kCFStringEncodingUTF8);
        if (owner) CFStringGetCString(owner, ownerBuf, sizeof(ownerBuf), kCFStringEncodingUTF8);

        printf("%d\t%s - %s\n", windowId, ownerBuf, titleBuf);
    }

    CFRelease(infoArray);
    return 0;
}


