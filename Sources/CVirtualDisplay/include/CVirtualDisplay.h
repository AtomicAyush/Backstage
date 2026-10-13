// A small Objective-C wrapper around CoreGraphics' private CGVirtualDisplay family.
//
// macOS has shipped CGVirtualDisplay since 10.14 (it backs Sidecar and AirPlay to Mac), but the
// classes are not in the public SDK. We never link against them: every class is looked up by name
// at runtime, and a missing class or selector makes creation return nil rather than crash.
//
// The display lives exactly as long as the BSVirtualScreen that created it. When the owning
// process exits, macOS removes the display, so a crashed agent cannot leave a ghost screen behind.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSVirtualScreen : NSObject

/// Whether this macOS exposes the private classes and selectors we use.
@property (class, readonly) BOOL isSupported;

/// Creates and attaches a display. `width` and `height` are in points; with `hiDPI` the
/// framebuffer is twice that in pixels. `serial` makes the display's identity stable, so macOS
/// remembers where the user put it in System Settings › Displays.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                                hiDPI:(BOOL)hiDPI
                               serial:(unsigned int)serial;

@property (readonly) CGDirectDisplayID displayID;

/// Detaches the display now instead of waiting for deallocation.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
