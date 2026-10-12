#import <Cocoa/Cocoa.h>
#import <Collaboration/Collaboration.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <stdatomic.h>

static const CGFloat kBlurDefault = 0.6;

static CGFloat blurStrength(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"blur"];
    return v ? v.doubleValue : kBlurDefault;
}

static const CGFloat kDimDefault = 0.0;

static CGFloat dimStrength(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"dim"];
    return v ? v.doubleValue : kDimDefault;
}

static NSArray<NSString *> *tintNames(void) {
    return @[@"Black", @"Grey", @"Blue", @"Purple", @"Red"];
}

static NSColor *tintColor(NSString *name) {
    static NSDictionary<NSString *, NSColor *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"Black":  NSColor.blackColor,
                @"Grey":   [NSColor colorWithWhite:0.45 alpha:1],
                @"Blue":   [NSColor colorWithRed:0.04 green:0.09 blue:0.28 alpha:1],
                @"Purple": [NSColor colorWithRed:0.14 green:0.04 blue:0.26 alpha:1],
                @"Red":    [NSColor colorWithRed:0.28 green:0.03 blue:0.05 alpha:1]};
    });
    return map[name] ?: NSColor.blackColor;
}

static NSString *currentTint(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"tint"] ?: @"Black";
}

static const CGFloat kDimFloor = 0.02;

// If the main thread stops answering for this long while locked, the
// watchdog kills the process so a hung pinlock can never trap the user.
static const uint64_t kStallLimit = 10;

static const NSInteger kAwayRSSIDefault = -70;
static const NSTimeInterval kAwayDelay = 15;
static const NSInteger kDistances[] = {-60, -70, -80};  // Close, Medium, Far

static NSInteger awayRSSI(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"awayRSSI"];
    return v ? v.integerValue : kAwayRSSIDefault;
}

// Phone counts as near while any reading is at or above the threshold; lock
// once no near reading has arrived for kAwayDelay. Fires once per absence, so
// unlocking with the phone still gone doesn't relock in a loop.
typedef struct {
    NSTimeInterval nearAt;
    BOOL armed;
} Away;

static void awaySeen(Away *a, NSInteger rssi, NSInteger threshold, NSTimeInterval now) {
    if (rssi < 0 && rssi >= threshold) {  // CoreBluetooth reports 127 for "unknown"
        a->nearAt = now;
        a->armed = YES;
    }
}

static BOOL awayDue(Away *a, NSTimeInterval now) {
    if (!a->armed || now - a->nearAt < kAwayDelay) return NO;
    a->armed = NO;
    return YES;
}

static BOOL isApple(NSDictionary *ad) {
    NSData *m = ad[CBAdvertisementDataManufacturerDataKey];
    const uint8_t *b = m.bytes;
    return m.length >= 2 && b[0] == 0x4C && b[1] == 0x00;  // Bluetooth SIG company id 0x004C
}

static BOOL macPasswordOK(NSString *password) {
    CBIdentity *me = [CBIdentity identityWithName:NSUserName()
                                        authority:CBIdentityAuthority.defaultIdentityAuthority];
    return [me isKindOfClass:CBUserIdentity.class] &&
           [(CBUserIdentity *)me authenticateWithPassword:password];
}

static NSString *currentPIN(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"pin"];
}

static void setPIN(NSString *pin) {
    [NSUserDefaults.standardUserDefaults setObject:pin forKey:@"pin"];
}

static BOOL promptForPIN(NSString *title, NSString *info) {
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;

    while (YES) {
        NSSecureTextField *f =
            [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];

        NSAlert *a = [NSAlert new];
        a.messageText = title;
        a.informativeText = info;
        a.accessoryView = f;
        [a addButtonWithTitle:@"Save"];
        [a addButtonWithTitle:@"Cancel"];

        [NSApp activateIgnoringOtherApps:YES];
        a.window.initialFirstResponder = f;

        if ([a runModal] != NSAlertFirstButtonReturn) return currentPIN() != nil;

        NSString *pin = f.stringValue;
        if (pin.length >= 4 && [pin rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            setPIN(pin);
            return YES;
        }
        info = @"At least 4 digits, digits only.";
    }
}

static NSString *pinDigits(NSString *s, NSUInteger max) {
    NSString *d = [[s componentsSeparatedByCharactersInSet:
                          NSCharacterSet.decimalDigitCharacterSet.invertedSet]
                      componentsJoinedByString:@""];
    return d.length > max ? [d substringToIndex:max] : d;
}

static void selfTest(void) {
    NSCAssert(kAwayDelay == 15, @"test assumes a 15 s away delay");

    Away a = {0};
    NSCAssert(!awayDue(&a, 100), @"never-seen phone must not lock");
    awaySeen(&a, 127, -70, 0);
    NSCAssert(!awayDue(&a, 100), @"RSSI 127 (unknown) must not count as near");
    awaySeen(&a, -50, -70, 0);
    NSCAssert(!awayDue(&a, 10), @"must wait the full delay");
    awaySeen(&a, -85, -70, 12);
    NSCAssert(awayDue(&a, 16), @"weak-only readings past the delay must lock");
    NSCAssert(!awayDue(&a, 40), @"must lock only once per absence");
    awaySeen(&a, -60, -70, 50);
    NSCAssert(!awayDue(&a, 60), @"back in range must not lock");
    NSCAssert(awayDue(&a, 66), @"leaving again must lock again");

    NSString *key = CBAdvertisementDataManufacturerDataKey;
    NSCAssert(isApple(@{key: [NSData dataWithBytes:(uint8_t[]){0x4C, 0x00, 0x10} length:3]}), @"Apple id must match");
    NSCAssert(!isApple(@{key: [NSData dataWithBytes:(uint8_t[]){0x06, 0x00} length:2]}), @"other vendors must not");
    NSCAssert(!isApple(@{key: [NSData dataWithBytes:(uint8_t[]){0x4C} length:1]}), @"short data must not");
    NSCAssert(!isApple(@{}), @"no manufacturer data must not");

    NSCAssert(!macPasswordOK(@""), @"empty password must be rejected");

    NSCAssert([pinDigits(@"12a3", 6) isEqualToString:@"123"], @"non-digits must be dropped");
    NSCAssert([pinDigits(@"1234567", 4) isEqualToString:@"1234"], @"input must stop at PIN length");
    NSCAssert([pinDigits(@"", 4) isEqualToString:@""], @"empty stays empty");

    printf("selftest ok\n");
}

@interface PinPanel : NSViewController <NSTextFieldDelegate>
// Whichever field is taking input: the PIN field or the Mac password field.
@property (nonatomic, readonly) NSSecureTextField *field;
- (void)shake;
@end

#pragma mark - Controller

@interface LockController : NSObject
@property (nonatomic, readonly) BOOL locked;
+ (instancetype)shared;
- (void)lock;
- (void)unlock;
- (void)nudge;
@end

#pragma mark - Shield

@interface ShieldWindow : NSWindow
@end

@implementation ShieldWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface ShieldView : NSView
@property (nonatomic, weak) PinPanel *panel;
@end

@implementation ShieldView

- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self.panel.field]; }
- (void)rightMouseDown:(NSEvent *)e {}
- (void)otherMouseDown:(NSEvent *)e {}
- (void)scrollWheel:(NSEvent *)e {}

@end

#pragma mark - PIN panel

@interface PinBox : NSView
@property (nonatomic) BOOL filled, active;
@end

@implementation PinBox

- (NSSize)intrinsicContentSize { return NSMakeSize(36, 44); }

- (void)drawRect:(NSRect)r {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1)
                                                      xRadius:8
                                                      yRadius:8];
    [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
    [p fill];
    p.lineWidth = _active ? 2 : 1;
    [(_active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor) setStroke];
    [p stroke];

    if (_filled) {
        NSRect b = self.bounds;
        [NSColor.labelColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(b) - 5, NSMidY(b) - 5, 10, 10)] fill];
    }
}

@end

@implementation PinPanel {
    NSVisualEffectView *_blur;
    NSSecureTextField *_field, *_pass;
    NSArray<PinBox *> *_boxes;
    NSStackView *_row;
    NSButton *_mode;
}

- (NSSecureTextField *)field { return _pass.hidden ? _field : _pass; }

- (void)loadView {
    _blur = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 300, 320)];
    _blur.material = NSVisualEffectMaterialHUDWindow;
    _blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _blur.state = NSVisualEffectStateActive;
    _blur.wantsLayer = YES;
    _blur.layer.cornerRadius = 20;
    _blur.layer.masksToBounds = YES;
    self.view = _blur;

    NSImageView *avatar = [NSImageView imageViewWithImage:[self accountImage]];
    avatar.imageScaling = NSImageScaleProportionallyUpOrDown;
    avatar.wantsLayer = YES;
    avatar.layer.cornerRadius = 48;
    avatar.layer.masksToBounds = YES;

    NSTextField *name = [NSTextField labelWithString:NSFullUserName()];
    name.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    name.alignment = NSTextAlignmentCenter;

    // The secure field stays the real input (keeps Secure Event Input on);
    // it sits invisibly on top of the boxes, which only mirror its length.
    NSMutableArray<PinBox *> *boxes = [NSMutableArray array];
    for (NSUInteger i = 0; i < currentPIN().length; i++) [boxes addObject:[PinBox new]];
    _boxes = boxes;
    NSStackView *row = _row = [NSStackView stackViewWithViews:boxes];
    row.spacing = 8;

    _field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    _field.bezeled = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.alphaValue = 0;
    _field.delegate = self;
    _field.target = self;
    _field.action = @selector(submit:);
    _field.nextKeyView = _field;
    _field.translatesAutoresizingMaskIntoConstraints = NO;

    // Fallback for a forgotten PIN: the macOS account password, shown in
    // place of the boxes. The row only fades (not hidden) so the overlay
    // constraints above stay put.
    _pass = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    _pass.placeholderString = @"Mac password";
    _pass.bezelStyle = NSTextFieldRoundedBezel;
    _pass.hidden = YES;
    _pass.target = self;
    _pass.action = @selector(submitPassword:);
    _pass.nextKeyView = _pass;
    _pass.translatesAutoresizingMaskIntoConstraints = NO;

    _mode = [NSButton buttonWithTitle:@"Use Mac Password" target:self action:@selector(toggleMode:)];
    _mode.bordered = NO;
    _mode.contentTintColor = NSColor.secondaryLabelColor;
    _mode.refusesFirstResponder = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[avatar, name, row, _mode]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_blur addSubview:stack];
    [_blur addSubview:_field];
    [_blur addSubview:_pass];

    CGFloat rowWidth = boxes.count * 44.0 - 8;
    [NSLayoutConstraint activateConstraints:@[
        [avatar.widthAnchor constraintEqualToConstant:96],
        [avatar.heightAnchor constraintEqualToConstant:96],
        [_field.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [_field.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [_field.topAnchor constraintEqualToAnchor:row.topAnchor],
        [_field.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [_pass.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],
        [_pass.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [_pass.widthAnchor constraintEqualToConstant:220],
        [stack.centerXAnchor constraintEqualToAnchor:_blur.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_blur.centerYAnchor],
        [_blur.widthAnchor constraintEqualToConstant:MAX(300, rowWidth + 60)],
        [_blur.heightAnchor constraintEqualToConstant:320],
    ]];
    [self refresh];
}

- (void)refresh {
    NSUInteger len = _field.stringValue.length;
    [_boxes enumerateObjectsUsingBlock:^(PinBox *b, NSUInteger i, BOOL *stop) {
        b.filled = i < len;
        b.active = i == len;
        b.needsDisplay = YES;
    }];
}

- (void)controlTextDidChange:(NSNotification *)n {
    NSString *pin = pinDigits(_field.stringValue, _boxes.count);
    if (![pin isEqualToString:_field.stringValue]) _field.stringValue = pin;
    [self refresh];
    // Deferred so the last box paints before unlock/shake, and so unlock
    // doesn't free the panel while the field editor is still calling us.
    if (pin.length == _boxes.count)
        dispatch_async(dispatch_get_main_queue(), ^{ [self submit:nil]; });
}

- (NSImage *)accountImage {
    CBIdentity *me = [CBIdentity identityWithName:NSUserName()
                                        authority:CBIdentityAuthority.defaultIdentityAuthority];
    return me.image ?: [NSImage imageNamed:NSImageNameUserAccounts];
}

- (void)submit:(id)sender {
    if ([_field.stringValue isEqualToString:currentPIN()]) {
        [LockController.shared unlock];
        return;
    }
    _field.stringValue = @"";
    [self refresh];
    [self shake];
}

- (void)toggleMode:(id)sender {
    BOOL toPassword = _pass.hidden;
    _pass.hidden = !toPassword;
    _field.hidden = toPassword;
    _row.alphaValue = toPassword ? 0 : 1;
    _field.stringValue = _pass.stringValue = @"";
    [self refresh];
    _mode.title = toPassword ? @"Use PIN" : @"Use Mac Password";
    [self.view.window makeFirstResponder:self.field];
}

- (void)submitPassword:(id)sender {
    NSString *password = _pass.stringValue;
    _pass.stringValue = @"";
    _pass.enabled = NO;
    // Off the main thread: opendirectoryd can be slow (and throttles after
    // failures), and a stalled main thread would trip the watchdog.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = macPasswordOK(password);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_pass.enabled = YES;
            if (ok) {
                [LockController.shared unlock];
                return;
            }
            [self.view.window makeFirstResponder:self->_pass];
            [self shake];
        });
    });
}

- (void)shake {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    CGFloat x = _blur.layer.position.x;
    a.values = @[ @(x), @(x - 12), @(x + 12), @(x - 8), @(x + 8), @(x) ];
    a.duration = 0.35;
    [_blur.layer addAnimation:a forKey:@"shake"];
}

@end

#pragma mark - Controller impl

static _Atomic uint64_t gHeartbeat;

static uint64_t uptimeNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }  // stops during sleep

@implementation LockController {
    NSMutableArray<NSWindow *> *_windows;
    PinPanel *_panel;
    IOPMAssertionID _assertion;
    NSTimer *_heartbeat;
    dispatch_source_t _watchdog;
}

// The PIN, the password and the menu all live on the main thread, so if it
// hangs nothing can unlock. A background thread watches a main-thread
// heartbeat and exits the process; WindowServer then drops the shield and
// the presentation options with it.
- (void)startWatchdog {
    gHeartbeat = uptimeNs();
    _heartbeat = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        gHeartbeat = uptimeNs();
    }];
    [NSRunLoop.mainRunLoop addTimer:_heartbeat forMode:NSRunLoopCommonModes];

    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_watchdog, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_watchdog, ^{
        uint64_t beat = gHeartbeat;  // read before the clock, so now >= beat
        if (uptimeNs() - beat > kStallLimit * NSEC_PER_SEC) _exit(70);
    });
    dispatch_resume(_watchdog);
}

- (void)stopWatchdog {
    [_heartbeat invalidate];
    _heartbeat = nil;
    if (_watchdog) dispatch_source_cancel(_watchdog);
    _watchdog = nil;
}

+ (instancetype)shared {
    static LockController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [LockController new]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) _windows = [NSMutableArray array];
    return self;
}

- (void)lock {
    if (_locked) return;

    if (!currentPIN() &&
        !promptForPIN(@"Set a PIN", @"pinlock needs a PIN before it can lock the screen."))
        return;

    _locked = YES;

    IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep,
                                kIOPMAssertionLevelOn, CFSTR("pinlock"), &_assertion);

    _panel = [PinPanel new];
    NSWindow *keyWindow = nil;

    for (NSScreen *scr in NSScreen.screens) {
        NSWindow *w = [[ShieldWindow alloc] initWithContentRect:scr.frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO
                                                         screen:nil];
        w.level = CGShieldingWindowLevel();
        w.opaque = NO;
        w.hasShadow = NO;
        w.releasedWhenClosed = NO;
        w.backgroundColor = [NSColor colorWithWhite:0 alpha:kDimFloor];
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle;

        NSRect bounds = NSMakeRect(0, 0, scr.frame.size.width, scr.frame.size.height);
        ShieldView *shield = [[ShieldView alloc] initWithFrame:bounds];
        w.contentView = shield;

        CGFloat blur = blurStrength(), dim = dimStrength();
        if (blur > 0 && dim < 1.0) {
            NSVisualEffectView *frost = [[NSVisualEffectView alloc] initWithFrame:bounds];
            frost.material = NSVisualEffectMaterialFullScreenUI;
            frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            frost.state = NSVisualEffectStateActive;
            frost.alphaValue = blur;
            frost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [shield addSubview:frost];
        }

        if (dim > 0) {
            NSView *cover = [[NSView alloc] initWithFrame:bounds];
            cover.wantsLayer = YES;
            cover.layer.backgroundColor =
                [tintColor(currentTint()) colorWithAlphaComponent:dim].CGColor;
            cover.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [shield addSubview:cover];
        }

        if (scr == NSScreen.screens.firstObject) {
            NSView *p = _panel.view;
            p.translatesAutoresizingMaskIntoConstraints = NO;
            [shield addSubview:p];
            [NSLayoutConstraint activateConstraints:@[
                [p.centerXAnchor constraintEqualToAnchor:shield.centerXAnchor],
                [p.centerYAnchor constraintEqualToAnchor:shield.centerYAnchor],
            ]];
            shield.panel = _panel;
            keyWindow = w;
        }
        [w orderFrontRegardless];
        [_windows addObject:w];
    }

    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    [NSApp activateIgnoringOtherApps:YES];
    [keyWindow makeKeyAndOrderFront:nil];
    [keyWindow makeFirstResponder:_panel.field];
    NSApp.presentationOptions = NSApplicationPresentationHideDock |
                                NSApplicationPresentationHideMenuBar |
                                NSApplicationPresentationDisableProcessSwitching |
                                NSApplicationPresentationDisableForceQuit |
                                NSApplicationPresentationDisableSessionTermination |
                                NSApplicationPresentationDisableHideApplication;
    [self startWatchdog];
}

- (void)nudge { [_panel shake]; }

- (void)unlock {
    if (!_locked) return;
    _locked = NO;
    [self stopWatchdog];

    NSApp.presentationOptions = NSApplicationPresentationDefault;
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;

    for (NSWindow *w in _windows) [w close];
    [_windows removeAllObjects];
    _panel = nil;

    if (_assertion) {
        IOPMAssertionRelease(_assertion);
        _assertion = 0;
    }
}

@end

#pragma mark - Radar

static NSString *deviceSymbol(NSString *name) {
    for (NSArray<NSString *> *m in @[@[@"Watch", @"applewatch"], @[@"iPad", @"ipad"],
                                     @[@"AirPods", @"airpods"], @[@"Mac", @"laptopcomputer"],
                                     @[@"iPhone", @"iphone"]])
        if ([name containsString:m[0]]) return m[1];
    return @"questionmark.square.dashed";
}

@interface RadarTile : NSAccessibilityElement
@property (nonatomic, copy) void (^press)(void);
@end

@implementation RadarTile
- (BOOL)accessibilityPerformPress {
    self.press();
    return YES;
}
@end

// The Mac sits in the middle and each nearby Apple device sits as far out as
// its signal is weak. The dashed ring is the Distance setting: past it = away.
@interface RadarView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;  // {id, name, rssi}
@property (nonatomic, copy) NSString *chosen;
@property (nonatomic) NSInteger threshold;
@property (nonatomic, copy) void (^onPick)(NSString *uuid, NSString *name);
@end

@implementation RadarView {
    NSMutableDictionary<NSString *, NSNumber *> *_radius;  // smoothed: RSSI jumps a lot
    NSString *_hover;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _radius = [NSMutableDictionary dictionary];
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                               NSTrackingActiveAlways | NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
    return self;
}

- (CGFloat)radiusFor:(NSInteger)rssi {
    CGFloat inner = 48, outer = NSWidth(self.bounds) / 2 - 40;
    CGFloat t = MIN(MAX((-40.0 - rssi) / 55.0, 0), 1);  // -40 dBm at the Mac, -95 dBm at the edge
    return inner + (outer - inner) * t;
}

- (void)setDevices:(NSArray<NSDictionary *> *)devices {
    _devices = [devices copy];
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    for (NSDictionary *d in devices) {
        CGFloat target = [self radiusFor:[d[@"rssi"] integerValue]];
        NSNumber *old = _radius[d[@"id"]];
        next[d[@"id"]] = @(old ? old.doubleValue + (target - old.doubleValue) * 0.15 : target);
    }
    _radius = next;
    self.needsDisplay = YES;
}

- (NSRect)tileFor:(NSDictionary *)d {
    // ponytail: angle from the id hash, so tiles can overlap; spread them if that bites.
    CGFloat a = ([d[@"id"] hash] % 360) * M_PI / 180, r = _radius[d[@"id"]].doubleValue;
    NSPoint c = NSMakePoint(NSMidX(self.bounds) + cos(a) * r, NSMidY(self.bounds) + sin(a) * r);
    return NSMakeRect(c.x - 15, c.y - 20, 30, 40);
}

- (void)drawSymbol:(NSString *)name size:(CGFloat)size color:(NSColor *)color in:(NSRect)r {
    NSImage *img = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size
                                                                                    weight:NSFontWeightMedium]];
    NSImage *tinted = [NSImage imageWithSize:img.size flipped:NO drawingHandler:^BOOL(NSRect b) {
        [img drawInRect:b];
        [color set];
        NSRectFillUsingOperation(b, NSCompositingOperationSourceAtop);
        return YES;
    }];
    NSSize s = img.size;
    [tinted drawInRect:NSMakeRect(NSMidX(r) - s.width / 2, NSMidY(r) - s.height / 2, s.width, s.height)];
}

- (void)drawText:(NSString *)text color:(NSColor *)color below:(NSRect)r {
    if (text.length > 14) text = [[text substringToIndex:13] stringByAppendingString:@"…"];
    NSDictionary *attr = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
                           NSForegroundColorAttributeName: color};
    NSSize s = [text sizeWithAttributes:attr];
    [text drawAtPoint:NSMakePoint(NSMidX(r) - s.width / 2, NSMinY(r) - s.height - 3) withAttributes:attr];
}

- (void)drawRect:(NSRect)dirty {
    NSPoint c = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    NSBezierPath *(^ring)(CGFloat) = ^(CGFloat r) {
        return [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)];
    };

    NSBezierPath *edge = ring([self radiusFor:-95] + 24);
    [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
    [edge fill];
    [NSColor.separatorColor setStroke];
    [edge stroke];

    NSBezierPath *lockLine = ring([self radiusFor:_threshold]);
    CGFloat dash[] = {5, 4};
    [lockLine setLineDash:dash count:2 phase:0];
    lockLine.lineWidth = 1.5;
    [NSColor.controlAccentColor setStroke];
    [lockLine stroke];

    NSRect mac = NSMakeRect(c.x - 30, c.y - 22, 60, 44);
    NSBezierPath *macBox = [NSBezierPath bezierPathWithRoundedRect:mac xRadius:10 yRadius:10];
    [NSColor.controlBackgroundColor setFill];
    [macBox fill];
    [NSColor.separatorColor setStroke];
    [macBox stroke];
    [self drawSymbol:@"laptopcomputer" size:22 color:NSColor.labelColor in:mac];
    if (!_devices.count) [self drawText:@"Searching…" color:NSColor.secondaryLabelColor below:mac];

    NSColor *green = NSColor.systemGreenColor;
    for (NSDictionary *d in [self drawOrder]) {
        BOOL chosen = [d[@"id"] isEqual:_chosen], hover = [d[@"id"] isEqual:_hover];
        NSRect t = [self tileFor:d];
        NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:t xRadius:8 yRadius:8];
        [(chosen ? green : [green colorWithAlphaComponent:hover ? 0.4 : 0.2]) setFill];
        [box fill];
        box.lineWidth = hover ? 2 : 1;
        [green setStroke];
        [box stroke];
        [self drawSymbol:deviceSymbol(d[@"name"]) size:15 color:chosen ? NSColor.whiteColor : green in:t];
        [self drawText:d[@"name"] color:chosen ? NSColor.labelColor : NSColor.secondaryLabelColor below:t];
    }
}

// Chosen device last, so it is drawn on top and wins clicks.
- (NSArray<NSDictionary *> *)drawOrder {
    return [_devices sortedArrayUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"id"] isEqual:self.chosen]) compare:@([b[@"id"] isEqual:self.chosen])];
    }];
}

- (NSDictionary *)deviceAt:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    for (NSDictionary *d in [self drawOrder].reverseObjectEnumerator)
        if (NSPointInRect(p, NSInsetRect([self tileFor:d], -4, -4))) return d;
    return nil;
}

- (void)mouseMoved:(NSEvent *)e {
    NSDictionary *d = [self deviceAt:e];
    _hover = d[@"id"];
    [(d ? NSCursor.pointingHandCursor : NSCursor.arrowCursor) set];
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)e {
    _hover = nil;
    [NSCursor.arrowCursor set];
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)e {
    NSDictionary *d = [self deviceAt:e];
    if (d) self.onPick(d[@"id"], d[@"name"]);
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Nearby devices"; }

- (NSArray *)accessibilityChildren {
    NSMutableArray *kids = [NSMutableArray array];
    for (NSDictionary *d in _devices) {
        RadarTile *t = [RadarTile new];
        t.accessibilityRole = NSAccessibilityButtonRole;
        t.accessibilityLabel = [NSString stringWithFormat:@"%@, %@ dBm%@", d[@"name"], d[@"rssi"],
                                                          [d[@"id"] isEqual:_chosen] ? @", watched" : @""];
        t.accessibilityParent = self;
        t.accessibilityFrameInParentSpace = [self tileFor:d];
        __weak RadarView *weakSelf = self;
        t.press = ^{ weakSelf.onPick(d[@"id"], d[@"name"]); };
        [kids addObject:t];
    }
    return kids;
}

@end

#pragma mark - App

static const UInt32 kHotKeyCode = kVK_ANSI_L;
static const UInt32 kHotKeyMods = controlKey | optionKey | cmdKey;

static OSStatus onHotKey(EventHandlerCallRef next, EventRef ev, void *ctx) {
    [LockController.shared lock];
    return noErr;
}

@interface Delegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                                CBCentralManagerDelegate>
@end

@implementation Delegate {
    NSStatusItem *_item;
    NSMenuItem *_login, *_awayItem;
    NSMenu *_blurMenu, *_dimMenu, *_tintMenu;
    CBCentralManager *_bt;
    NSMutableDictionary<NSUUID *, NSDictionary *> *_seen;  // id -> {name, rssi, at}
    NSTimer *_awayTimer, *_radarTimer;
    NSWindow *_awayWindow;
    RadarView *_radar;
    NSTextField *_awayLabel;
    NSSegmentedControl *_distance;
    NSButton *_awayOff;
    id<NSObject> _noNap;
    Away _away;
}

#pragma mark Lock When Away

// Created lazily: the first CBCentralManager triggers the Bluetooth
// permission prompt, which nobody who skips this feature should see.
- (void)startBluetooth {
    if (_bt) return;
    _seen = [NSMutableDictionary dictionary];
    _bt = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    _awayTimer = [NSTimer scheduledTimerWithTimeInterval:2
                                                  target:self
                                                selector:@selector(awayTick:)
                                                userInfo:nil
                                                 repeats:YES];
    // App Nap would stretch the timer and delay the lock by minutes.
    _noNap = [NSProcessInfo.processInfo
        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                          reason:@"Lock When Away"];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
    if (c.state == CBManagerStatePoweredOn)
        [c scanForPeripheralsWithServices:nil
                                  options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
}

- (void)centralManager:(CBCentralManager *)c
    didDiscoverPeripheral:(CBPeripheral *)p
        advertisementData:(NSDictionary<NSString *, id> *)ad
                     RSSI:(NSNumber *)rssi {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL chosen = [p.identifier.UUIDString isEqualToString:
                                           [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"]];
    if (chosen) awaySeen(&_away, rssi.integerValue, awayRSSI(), now);
    if (!chosen && !isApple(ad)) return;  // headphones, TVs, the neighbours' kettle

    NSString *name = p.name ?: ad[CBAdvertisementDataLocalNameKey] ?: _seen[p.identifier][@"name"];
    _seen[p.identifier] = @{@"name": name ?: @"", @"rssi": rssi, @"at": @(now)};
}

- (void)awayTick:(NSTimer *)t {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // Random BLE addresses keep minting new ids; forget anything stale.
    for (NSUUID *k in _seen.allKeys)
        if (now - [_seen[k][@"at"] doubleValue] > 30) [_seen removeObjectForKey:k];

    if (awayDue(&_away, now)) [LockController.shared lock];
}

- (NSString *)awayStatus {
    NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"];
    NSDictionary *s = _seen[[[NSUUID alloc] initWithUUIDString:chosen]];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL fresh = s && now - [s[@"at"] doubleValue] < 5;
    NSInteger rssi = [s[@"rssi"] integerValue];

    if (fresh && rssi >= awayRSSI()) return [NSString stringWithFormat:@"Near · %ld dBm", rssi];
    if (_away.armed)
        return [NSString stringWithFormat:@"Moving away · locks in %.0f s",
                                          MAX(0, kAwayDelay - (now - _away.nearAt))];
    return fresh ? [NSString stringWithFormat:@"Too far to arm · %ld dBm", rssi] : @"Not in range";
}

- (void)showAwayWindow:(id)sender {
    [self startBluetooth];
    if (!_awayWindow) {
        _radar = [[RadarView alloc] initWithFrame:NSZeroRect];
        __weak Delegate *weakSelf = self;
        _radar.onPick = ^(NSString *uuid, NSString *name) { [weakSelf chooseAway:uuid name:name]; };

        _awayLabel = [NSTextField wrappingLabelWithString:@""];
        _awayLabel.alignment = NSTextAlignmentCenter;
        _awayLabel.preferredMaxLayoutWidth = 340;

        _distance = [NSSegmentedControl segmentedControlWithLabels:@[@"Close", @"Medium", @"Far"]
                                                      trackingMode:NSSegmentSwitchTrackingSelectOne
                                                            target:self
                                                            action:@selector(setDistance:)];
        NSStackView *distanceRow =
            [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Lock beyond"], _distance]];

        _awayOff = [NSButton buttonWithTitle:@"Turn Off" target:self action:@selector(turnAwayOff:)];

        NSStackView *stack = [NSStackView stackViewWithViews:@[_radar, _awayLabel, distanceRow, _awayOff]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.spacing = 14;
        stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
        [NSLayoutConstraint activateConstraints:@[
            [_radar.widthAnchor constraintEqualToConstant:340],
            [_radar.heightAnchor constraintEqualToConstant:340],
        ]];

        _awayWindow = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
        _awayWindow.title = @"Lock When Away";
        _awayWindow.releasedWhenClosed = NO;
        _awayWindow.delegate = self;
        _awayWindow.contentView = stack;
        [_awayWindow setContentSize:stack.fittingSize];
        [_awayWindow center];
    }

    [self refreshAway:nil];
    if (!_radarTimer) {
        _radarTimer = [NSTimer timerWithTimeInterval:0.1
                                              target:self
                                            selector:@selector(refreshAway:)
                                            userInfo:nil
                                             repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_radarTimer forMode:NSRunLoopCommonModes];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [_awayWindow makeKeyAndOrderFront:nil];
}

- (void)windowWillClose:(NSNotification *)n {
    [_radarTimer invalidate];
    _radarTimer = nil;
}

- (void)refreshAway:(NSTimer *)t {
    NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"];

    NSMutableArray<NSUUID *> *ids = [[_seen keysSortedByValueUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [b[@"rssi"] compare:a[@"rssi"]];
    }] mutableCopy];
    NSUUID *chosenID = chosen ? [[NSUUID alloc] initWithUUIDString:chosen] : nil;
    if (ids.count > 10) {
        [ids removeObjectsInRange:NSMakeRange(10, ids.count - 10)];
        if (_seen[chosenID] && ![ids containsObject:chosenID]) [ids addObject:chosenID];
    }

    NSMutableArray *devices = [NSMutableArray array];
    for (NSUUID *k in ids) {
        NSString *name = _seen[k][@"name"];
        if (!name.length) name = [@"Apple device " stringByAppendingString:[k.UUIDString substringToIndex:4]];
        [devices addObject:@{@"id": k.UUIDString, @"name": name, @"rssi": _seen[k][@"rssi"]}];
    }
    _radar.chosen = chosen;
    _radar.threshold = awayRSSI();
    _radar.devices = devices;

    _awayLabel.stringValue =
        _bt.state == CBManagerStateUnauthorized
            ? @"Bluetooth access is off for pinlock. Allow it in System Settings › Privacy & Security › Bluetooth."
        : _bt.state != CBManagerStatePoweredOn ? @"Waiting for Bluetooth…"
        : !chosen ? @"Hold your iPhone next to the Mac and click it on the radar."
                  : [NSString stringWithFormat:@"%@ — %@",
                                               [NSUserDefaults.standardUserDefaults stringForKey:@"awayName"],
                                               [self awayStatus]];

    _distance.selectedSegment = -1;
    for (NSInteger i = 0; i < 3; i++)
        if (kDistances[i] == awayRSSI()) _distance.selectedSegment = i;
    _awayOff.enabled = chosen != nil;
}

- (void)chooseAway:(NSString *)uuid name:(NSString *)name {
    // nil (Turn Off) removes both keys.
    [NSUserDefaults.standardUserDefaults setObject:uuid forKey:@"awayID"];
    [NSUserDefaults.standardUserDefaults setObject:name forKey:@"awayName"];
    _away = (Away){0};
    [self refreshAway:nil];
}

- (void)turnAwayOff:(id)sender { [self chooseAway:nil name:nil]; }

- (void)setDistance:(NSSegmentedControl *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:kDistances[sender.selectedSegment] forKey:@"awayRSSI"];
}

- (NSMenu *)levelMenu:(NSArray<NSString *> *)titles
                 tags:(NSArray<NSNumber *> *)tags
               action:(SEL)action {
    NSMenu *m = [NSMenu new];
    m.delegate = self;
    [titles enumerateObjectsUsingBlock:^(NSString *t, NSUInteger i, BOOL *stop) {
        NSMenuItem *it = [m addItemWithTitle:t action:action keyEquivalent:@""];
        it.target = self;
        it.tag = tags[i].integerValue;
    }];
    return m;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.button.image = [NSImage imageWithSystemSymbolName:@"lock.fill"
                                   accessibilityDescription:@"pinlock"];

    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    NSMenuItem *lockItem = [menu addItemWithTitle:@"Lock Now"
                                           action:@selector(lockNow:)
                                    keyEquivalent:@"l"];
    lockItem.target = self;
    lockItem.keyEquivalentModifierMask =
        NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [menu addItemWithTitle:@"Change PIN…" action:@selector(changePIN:) keyEquivalent:@""].target = self;

    _blurMenu = [self levelMenu:@[@"Off", @"Light", @"Medium", @"Full"]
                           tags:@[@0, @30, @60, @100]
                         action:@selector(setBlur:)];
    [menu addItemWithTitle:@"Blur" action:nil keyEquivalent:@""].submenu = _blurMenu;

    _dimMenu = [self levelMenu:@[@"Off", @"Light", @"Heavy", @"Solid (hide desktop)"]
                          tags:@[@0, @30, @60, @100]
                        action:@selector(setDim:)];
    [menu addItemWithTitle:@"Cover" action:nil keyEquivalent:@""].submenu = _dimMenu;

    _tintMenu = [NSMenu new];
    _tintMenu.delegate = self;
    for (NSString *name in tintNames())
        [_tintMenu addItemWithTitle:name
                             action:@selector(setTint:)
                      keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Cover Colour" action:nil keyEquivalent:@""].submenu = _tintMenu;

    _login = [menu addItemWithTitle:@"Open at Login"
                             action:@selector(toggleLogin:)
                      keyEquivalent:@""];
    _login.target = self;

    _awayItem = [menu addItemWithTitle:@"Lock When Away…"
                                action:@selector(showAwayWindow:)
                         keyEquivalent:@""];
    _awayItem.target = self;

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit pinlock" action:@selector(quit:) keyEquivalent:@"q"].target = self;
    _item.menu = menu;

    [self registerHotKey];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (LockController.shared.locked &&
            (e.modifierFlags & NSEventModifierFlagCommand) &&
            [e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"q"]) {
            [LockController.shared nudge];
            return nil;
        }
        return e;
    }];

    if ([NSUserDefaults.standardUserDefaults stringForKey:@"awayID"]) [self startBluetooth];

    if (!currentPIN())
        promptForPIN(@"Set a PIN",
                     @"pinlock locks the screen with this PIN. At least 4 digits.");
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == _blurMenu || menu == _dimMenu) {
        NSInteger cur = lround((menu == _blurMenu ? blurStrength() : dimStrength()) * 100);
        for (NSMenuItem *it in menu.itemArray)
            it.state = it.tag == cur ? NSControlStateValueOn : NSControlStateValueOff;
        return;
    }

    if (menu == _tintMenu) {
        for (NSMenuItem *it in menu.itemArray)
            it.state = [it.title isEqualToString:currentTint()] ? NSControlStateValueOn
                                                                : NSControlStateValueOff;
        return;
    }

    _awayItem.state = [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"]
                          ? NSControlStateValueOn
                          : NSControlStateValueOff;

    if (@available(macOS 13.0, *))
        _login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
                           ? NSControlStateValueOn
                           : NSControlStateValueOff;
    else
        _login.hidden = YES;
}

- (void)registerHotKey {
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&onHotKey, 1, &spec, NULL, NULL);

    EventHotKeyID hkid = {'plck', 1};
    EventHotKeyRef ref = NULL;
    OSStatus err = RegisterEventHotKey(kHotKeyCode, kHotKeyMods, hkid,
                                       GetApplicationEventTarget(), 0, &ref);
    if (err != noErr)
        NSLog(@"pinlock: hotkey registration failed (%d)", err);
}

- (void)lockNow:(id)sender { [LockController.shared lock]; }

- (void)toggleLogin:(id)sender {
    if (@available(macOS 13.0, *)) {
        BOOL on = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
        NSError *err = nil;
        if (on) [SMAppService.mainAppService unregisterAndReturnError:&err];
        else [SMAppService.mainAppService registerAndReturnError:&err];
        if (err) [self alertWithText:@"Could not change the login item"
                                info:err.localizedDescription];
    }
}

- (void)setBlur:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setDouble:sender.tag / 100.0 forKey:@"blur"];
}

- (void)setDim:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setDouble:sender.tag / 100.0 forKey:@"dim"];
}

- (void)setTint:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.title forKey:@"tint"];
}

- (void)changePIN:(id)sender {
    promptForPIN(@"Change PIN", @"At least 4 digits. You will need this to unlock the screen.");
}

- (void)alertWithText:(NSString *)text info:(NSString *)info {
    NSAlert *a = [NSAlert new];
    a.messageText = text;
    a.informativeText = info;
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)n { [LockController.shared unlock]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            selfTest();
            return 0;
        }

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
        static Delegate *del;
        del = [Delegate new];
        NSApp.delegate = del;

        if (argc > 1 && strcmp(argv[1], "--hangtest") == 0) {
            // Lock, then freeze the main thread: the watchdog must exit the
            // process within kStallLimit. If it doesn't, unlock after 30 s.
            dispatch_async(dispatch_get_main_queue(), ^{ [LockController.shared lock]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                sleep(30);
                [LockController.shared unlock];
            });
        } else if (argc > 1) {
            double secs = atof(argv[1]);
            dispatch_async(dispatch_get_main_queue(), ^{ [LockController.shared lock]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [LockController.shared unlock]; });
        }

        [NSApp run];
    }
}
