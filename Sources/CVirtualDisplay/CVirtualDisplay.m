#import "CVirtualDisplay.h"

// Only the members we call are declared. The classes themselves are never referenced by symbol,
// only through NSClassFromString, so the binary still loads if Apple renames or removes them.

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// Distinct from any real panel vendor, so our displays are easy to recognise in display lists.
static const unsigned int kBackstageVendorID = 0xBAC5;

@implementation BSVirtualScreen {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    Class display = NSClassFromString(@"CGVirtualDisplay");
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    return display && descriptor && mode && settings
        && [display instancesRespondToSelector:@selector(initWithDescriptor:)]
        && [display instancesRespondToSelector:@selector(applySettings:)]
        && [display instancesRespondToSelector:@selector(displayID)]
        && [mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]
        && [settings instancesRespondToSelector:@selector(setHiDPI:)]
        && [settings instancesRespondToSelector:@selector(setModes:)];
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                                hiDPI:(BOOL)hiDPI
                               serial:(unsigned int)serial {
    if (!(self = [super init])) return nil;
    if (!BSVirtualScreen.isSupported || width == 0 || height == 0) return nil;

    unsigned int scale = hiDPI ? 2 : 1;

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = name;
    descriptor.vendorID = kBackstageVendorID;
    descriptor.productID = 0x0001;
    descriptor.serialNum = serial;
    descriptor.maxPixelsWide = width * scale;
    descriptor.maxPixelsHigh = height * scale;
    // Roughly a 110 ppi panel. macOS uses the physical size for its default scaling choices.
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0);
    // sRGB primaries, so captures of this display are colour-correct.
    descriptor.redPrimary = CGPointMake(0.640, 0.330);
    descriptor.greenPrimary = CGPointMake(0.300, 0.600);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    descriptor.terminationHandler = ^(id a, id b) {};

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;

    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width * scale height:height * scale refreshRate:60];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[mode];
    if (![_display applySettings:settings] || _display.displayID == kCGNullDirectDisplay) {
        _display = nil;
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : kCGNullDirectDisplay;
}

- (void)invalidate {
    _display = nil;
}

@end
