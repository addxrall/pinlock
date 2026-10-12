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

#pragma mark - App

static const UInt32 kHotKeyCode = kVK_ANSI_L;
static const UInt32 kHotKeyMods = controlKey | optionKey | cmdKey;

static OSStatus onHotKey(EventHandlerCallRef next, EventRef ev, void *ctx) {
    [LockController.shared lock];
    return noErr;
}

@interface Delegate : NSObject <NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate>
@end

@implementation Delegate {
    NSStatusItem *_item;
    NSMenuItem *_login;
    NSMenu *_blurMenu, *_dimMenu, *_tintMenu, *_awayMenu, *_distanceMenu;
    CBCentralManager *_bt;
    NSMutableDictionary<NSUUID *, NSDictionary *> *_seen;  // id -> {name, rssi, at}
    NSTimer *_awayTimer;
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
    NSString *name = p.name ?: ad[CBAdvertisementDataLocalNameKey] ?: _seen[p.identifier][@"name"];
    _seen[p.identifier] = @{@"name": name ?: @"", @"rssi": rssi, @"at": @(now)};

    if ([p.identifier.UUIDString isEqualToString:
                                  [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"]])
        awaySeen(&_away, rssi.integerValue, awayRSSI(), now);
}

- (void)awayTick:(NSTimer *)t {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // Random BLE addresses keep minting new ids; forget anything stale.
    for (NSUUID *k in _seen.allKeys)
        if (now - [_seen[k][@"at"] doubleValue] > 30) [_seen removeObjectForKey:k];

    if (awayDue(&_away, now)) [LockController.shared lock];
}

- (void)buildAwayMenu {
    [_awayMenu removeAllItems];
    NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:@"awayID"];

    NSMenuItem *off = [_awayMenu addItemWithTitle:@"Off" action:@selector(pickAway:) keyEquivalent:@""];
    off.target = self;
    off.state = chosen ? NSControlStateValueOff : NSControlStateValueOn;
    [_awayMenu addItem:NSMenuItem.separatorItem];

    if (_bt.state != CBManagerStatePoweredOn) {
        [_awayMenu addItemWithTitle:_bt.state == CBManagerStateUnauthorized
                                        ? @"Bluetooth access denied (System Settings › Privacy)"
                                        : @"Waiting for Bluetooth…"
                             action:nil
                      keyEquivalent:@""];
    } else {
        [_awayMenu addItemWithTitle:@"Hold your iPhone next to the Mac and pick the strongest:"
                             action:nil
                      keyEquivalent:@""];
    }

    NSArray<NSUUID *> *ids = [_seen keysSortedByValueUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [b[@"rssi"] compare:a[@"rssi"]];
    }];
    if (ids.count > 8) ids = [ids subarrayWithRange:NSMakeRange(0, 8)];

    BOOL chosenListed = NO;
    for (NSUUID *k in ids) {
        NSString *name = [_seen[k][@"name"] length] ? _seen[k][@"name"]
                                                    : [@"Unnamed " stringByAppendingString:[k.UUIDString substringToIndex:4]];
        NSMenuItem *it = [_awayMenu addItemWithTitle:[NSString stringWithFormat:@"%@   %@ dBm", name, _seen[k][@"rssi"]]
                                              action:@selector(pickAway:)
                                       keyEquivalent:@""];
        it.target = self;
        it.representedObject = @[k.UUIDString, name];
        if ([k.UUIDString isEqualToString:chosen]) {
            it.state = NSControlStateValueOn;
            chosenListed = YES;
        }
    }
    if (chosen && !chosenListed) {
        NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:@"awayName"];
        NSMenuItem *it = [_awayMenu addItemWithTitle:[name stringByAppendingString:@"   (out of range)"]
                                              action:nil
                                       keyEquivalent:@""];
        it.state = NSControlStateValueOn;
    }

    [_awayMenu addItem:NSMenuItem.separatorItem];
    _distanceMenu = [self levelMenu:@[@"Close", @"Medium", @"Far"]
                               tags:@[@-60, @-70, @-80]
                             action:@selector(setAwayRSSI:)];
    [_awayMenu addItemWithTitle:@"Distance" action:nil keyEquivalent:@""].submenu = _distanceMenu;
}

- (void)pickAway:(NSMenuItem *)sender {
    NSArray<NSString *> *v = sender.representedObject;  // nil for "Off": nil removes both keys
    [NSUserDefaults.standardUserDefaults setObject:v[0] forKey:@"awayID"];
    [NSUserDefaults.standardUserDefaults setObject:v[1] forKey:@"awayName"];
    _away = (Away){0};
}

- (void)setAwayRSSI:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"awayRSSI"];
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

    _awayMenu = [NSMenu new];
    _awayMenu.delegate = self;
    [menu addItemWithTitle:@"Lock When Away" action:nil keyEquivalent:@""].submenu = _awayMenu;

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
    if (menu == _awayMenu) {
        [self startBluetooth];
        [self buildAwayMenu];
        return;
    }

    if (menu == _distanceMenu) {
        for (NSMenuItem *it in menu.itemArray)
            it.state = it.tag == awayRSSI() ? NSControlStateValueOn : NSControlStateValueOff;
        return;
    }

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
