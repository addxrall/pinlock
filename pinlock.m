#import <Cocoa/Cocoa.h>
#import <Collaboration/Collaboration.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreMotion/CoreMotion.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
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

static const uint64_t kStallLimit = 10;

static const NSTimeInterval kAwayDelay = 15;
static const double kDistances[] = {1, 2, 3, 5, 8};

static const double kDeskMeters = 0.5, kPathLoss = 25;

static NSInteger awayRef(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"awayRef"];
    return v ? v.integerValue : -55;
}

static double awayMeters(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"awayMeters"];
    return v ? v.doubleValue : 3;
}

// Log-distance path loss (n = 2.5), anchored at the calibrated desk reading.
static double metersFor(NSInteger rssi, NSInteger ref) {
    return kDeskMeters * pow(10, (ref - rssi) / kPathLoss);
}

static NSInteger rssiFor(double meters, NSInteger ref) {
    return lround(ref - kPathLoss * log10(meters / kDeskMeters));
}

// Watched devices, uuid -> name. Any one nearby means you are here.
static NSDictionary<NSString *, NSString *> *awayDevices(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDictionary *v = [d dictionaryForKey:@"awayDevices"];
    if (v) return v;
    NSString *old = [d stringForKey:@"awayID"];
    return old ? @{old: [d stringForKey:@"awayName"] ?: @"Device"} : @{};
}

static NSInteger awayRSSI(void) { return rssiFor(awayMeters(), awayRef()); }

typedef struct {
    NSTimeInterval nearAt;
    BOOL armed;
} Away;

// Lock once no reading has reached the threshold for kAwayDelay; once per absence.
static void awaySeen(Away *a, NSInteger rssi, NSInteger threshold, NSTimeInterval now) {
    if (rssi < 0 && rssi >= threshold) {
        a->nearAt = now;
        a->armed = YES;
    }
}

static BOOL awayDue(Away *a, NSTimeInterval now) {
    if (!a->armed || now - a->nearAt < kAwayDelay) return NO;
    a->armed = NO;
    return YES;
}

static const NSTimeInterval kTurnDelay = 0.3;
static const NSTimeInterval kRecentreTime = 30;

static NSInteger lookAwayAngle(void) {
    return [NSUserDefaults.standardUserDefaults integerForKey:@"lookAway"];
}

typedef struct {
    double yaw0, yaw;
    NSTimeInterval turnedAt, last;
    BOOL started, turning, blurred;
    int side;
} Head;

// Blur after the head stays turned past the limit for kTurnDelay; the baseline slowly follows drift.
static BOOL headSample(Head *h, double yaw, double limit, NSTimeInterval now) {
    if (!h->started) {
        h->yaw0 = yaw;
        h->last = now;
        h->started = YES;
    }
    h->yaw = yaw;
    double d = remainder(yaw - h->yaw0, 2 * M_PI);
    if (fabs(d) > limit) {
        if (!h->turning) {
            h->turning = YES;
            h->turnedAt = now;
        }
        if (now - h->turnedAt >= kTurnDelay) h->blurred = YES;
        h->side = d > 0 ? 1 : -1;
    } else {
        h->turning = NO;
        if (fabs(d) < limit * 0.7) h->blurred = NO;
        if (!h->blurred && fabs(d) < limit * 0.5)
            h->yaw0 += d * MIN((now - h->last) / kRecentreTime, 1);
    }
    h->last = now;
    return h->blurred;
}

static void headRecentre(Head *h) {
    h->yaw0 = h->yaw;
    h->turning = h->blurred = NO;
}

static const NSTimeInterval kPeekIn = 0.7, kPeekOut = 0.5;
static const double kPeekDim = 0.3;
enum { kBlurLevels = 4 };
static const double kBlurSigma[kBlurLevels] = {3, 8, 16, 32};

// iPhone Duo blur strength (0..1) at progress e and distance d from the sharp side: d³, then filling in.
static double duoBlur(double e, double d) {
    double grow = MIN(1, 2 * e), fill = MAX(0, 2 * e - 1), d3 = d * d * d;
    return MIN(1, grow * d3 + fill * (1 - d3));
}

// Opacity of baked blur level k so the stacked levels add up to the given strength.
static double blurLevelAlpha(double strength, int k) {
    double lo = k ? kBlurSigma[k - 1] : 0, hi = kBlurSigma[k], s = strength * kBlurSigma[kBlurLevels - 1];
    return MIN(MAX((s - lo) / (hi - lo), 0), 1);
}

static CGImageRef maskStrip(const uint8_t *alpha, int n) {
    CGContextRef c = CGBitmapContextCreate(NULL, n, 1, 8, n, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    memcpy(CGBitmapContextGetData(c), alpha, n);
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return img;
}

// Push overlapping radar tiles apart along their rings; radii (distances) stay.
static void spreadAngles(double *angle, const double *radius, int n, double minGap) {
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++) {
            double dist = hypot(radius[i] * cos(angle[i]) - radius[j] * cos(angle[j]),
                                radius[i] * sin(angle[i]) - radius[j] * sin(angle[j]));
            if (dist >= minGap) continue;
            double push = (minGap - dist) / MAX(radius[i] + radius[j], 1);
            double way = remainder(angle[i] - angle[j], 2 * M_PI) >= 0 ? 1 : -1;
            angle[i] += way * push;
            angle[j] -= way * push;
        }
}

static BOOL isApple(NSDictionary *ad) {
    NSData *m = ad[CBAdvertisementDataManufacturerDataKey];
    const uint8_t *b = m.bytes;
    return m.length >= 2 && b[0] == 0x4C && b[1] == 0x00;
}

// SF Symbol for an Apple Continuity advert: AirPods/Beats model, or a Find My accessory.
static NSString *appleKind(NSData *m, NSString **label) {
    const uint8_t *b = m.bytes;
    for (NSUInteger i = 2; i + 2 <= m.length; i += 2 + b[i + 1]) {
        uint8_t type = b[i], len = b[i + 1];
        const uint8_t *v = b + i + 2;
        if (i + 2 + len > m.length) break;

        if (type == 0x07 && len >= 3) {
            uint16_t model = v[1] << 8 | v[2];
            switch (model) {
                case 0x0A20: case 0x1F20:
                    *label = @"AirPods Max";
                    return @"airpodsmax";
                case 0x0E20: case 0x1420: case 0x2420:
                    *label = @"AirPods Pro";
                    return @"airpodspro";
                case 0x0220: case 0x0F20: case 0x1320: case 0x1920: case 0x1B20:
                    *label = @"AirPods";
                    return @"airpods";
                default:
                    *label = @"Beats";
                    return @"headphones";
            }
        }
        if (type == 0x12) {
            *label = @"Find My accessory";
            return @"airtag";
        }
    }
    return nil;
}

// SF Symbol for a Device Information model number such as "iPhone15,2".
static NSString *modelKind(NSString *model, NSString **label) {
    for (NSArray<NSString *> *m in @[
             @[@"iPhone", @"iphone", @"iPhone"], @[@"iPad", @"ipad", @"iPad"],
             @[@"Watch", @"applewatch", @"Apple Watch"], @[@"AudioAccessory", @"homepod", @"HomePod"],
             @[@"AppleTV", @"appletv", @"Apple TV"], @[@"iMac", @"desktopcomputer", @"iMac"],
             @[@"Mac", @"laptopcomputer", @"Mac"],
         ])
        if ([model hasPrefix:m[0]]) {
            *label = m[2];
            return m[1];
        }
    return nil;
}

static NSString *nameKind(NSString *name) {
    NSString *n = name.lowercaseString;
    for (NSArray<NSString *> *m in @[
             @[@"airpods max", @"airpodsmax"], @[@"airpods pro", @"airpodspro"], @[@"airpods", @"airpods"],
             @[@"iphone", @"iphone"], @[@"ipad", @"ipad"], @[@"macbook", @"laptopcomputer"],
             @[@"imac", @"desktopcomputer"], @[@"homepod", @"homepod"], @[@"watch", @"applewatch"],
             @[@"keyboard", @"keyboard"], @[@"mouse", @"computermouse"],
             @[@"speaker", @"hifispeaker"], @[@"jbl", @"hifispeaker"], @[@"soundlink", @"hifispeaker"],
             @[@"sonos", @"hifispeaker"], @[@"marshall", @"hifispeaker"], @[@"boom", @"hifispeaker"],
             @[@"buds", @"earbuds"], @[@"wf-", @"earbuds"], @[@"headphone", @"headphones"],
             @[@"wh-", @"headphones"], @[@"beats", @"headphones"], @[@"bose", @"headphones"],
             @[@"jabra", @"headphones"], @[@"band", @"applewatch"], @[@"garmin", @"applewatch"],
             @[@"fitbit", @"applewatch"], @[@"galaxy", @"iphone"], @[@"pixel", @"iphone"],
             @[@"phone", @"iphone"], @[@"tv", @"tv"],
         ])
        if ([n containsString:m[0]]) return m[1];
    return nil;
}

static NSString *serviceKind(NSArray<CBUUID *> *services) {
    NSDictionary *map = @{@"1812": @"keyboard", @"180D": @"heart", @"FE2C": @"headphones"};
    for (CBUUID *u in services)
        if (map[u.UUIDString]) return map[u.UUIDString];
    return nil;
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

    double deg = M_PI / 180, limit = 45 * deg;
    Head h = {0};
    NSCAssert(!headSample(&h, 0, limit, 1), @"start counts as facing the screen");
    NSCAssert(!headSample(&h, 60 * deg, limit, 1.1), @"a turn must wait kTurnDelay");
    NSCAssert(headSample(&h, 60 * deg, limit, 1.5), @"a held turn must blur");
    NSCAssert(h.side == 1, @"positive yaw is a turn to the right");
    NSCAssert(headSample(&h, 40 * deg, limit, 1.6), @"just inside the limit stays blurred");
    NSCAssert(!headSample(&h, 10 * deg, limit, 1.7), @"facing the screen again must clear");
    NSCAssert(!headSample(&h, 60 * deg, limit, 2.0), @"glance starts");
    NSCAssert(!headSample(&h, 0, limit, 2.2), @"a quick glance must not blur");

    NSCAssert(duoBlur(0, 1) == 0 && duoBlur(0, 0) == 0, @"starts sharp");
    NSCAssert(duoBlur(0.5, 1) == 1 && duoBlur(0.5, 0) == 0, @"halfway: Duo profile, sharp at the hinge");
    NSCAssert(duoBlur(0.5, 0.5) < 0.2, @"the profile is steep (d³), not linear");
    NSCAssert(duoBlur(1, 0) == 1 && duoBlur(1, 0.3) == 1, @"ends fully blurred everywhere");
    NSCAssert(blurLevelAlpha(1, kBlurLevels - 1) == 1 && blurLevelAlpha(0, 0) == 0, @"level ends");
    NSCAssert(blurLevelAlpha(8.0 / 32, 1) == 1 && blurLevelAlpha(8.0 / 32, 2) == 0, @"levels hand over");

    Head wrap = {0};
    headSample(&wrap, 170 * deg, limit, 1);
    NSCAssert(!headSample(&wrap, -170 * deg, limit, 2), @"yaw must wrap at ±180°");

    Head drift = {0};
    for (int i = 0; i <= 1800; i++)
        headSample(&drift, MIN(i / 600.0, 1) * 20 * deg, limit, i * 0.1);
    headSample(&drift, 60 * deg, limit, 181);
    NSCAssert(!headSample(&drift, 60 * deg, limit, 182), @"baseline must follow slow drift");

    Head slow = {0};
    for (int i = 0; i <= 180; i++)
        headSample(&slow, i * 0.5 * deg, limit, i * 0.1);
    NSCAssert(headSample(&slow, 90 * deg, limit, 19), @"a slow turn must still blur");
    headRecentre(&slow);
    NSCAssert(!headSample(&slow, 90 * deg, limit, 20), @"recentred direction counts as facing");

    NSCAssert(rssiFor(kDeskMeters, -60) == -60, @"the calibrated spot is the reference");
    NSCAssert(rssiFor(5, -60) < rssiFor(1, -60), @"farther means weaker");
    NSCAssert(fabs(metersFor(rssiFor(3, -72), -72) - 3) < 0.2, @"metres and RSSI must round-trip");

    double ang[3] = {0, 0, 0.05}, rad[3] = {100, 100, 100};
    for (int i = 0; i < 30; i++) spreadAngles(ang, rad, 3, 50);
    for (int i = 0; i < 3; i++)
        for (int j = i + 1; j < 3; j++)
            NSCAssert(hypot(100 * (cos(ang[i]) - cos(ang[j])), 100 * (sin(ang[i]) - sin(ang[j]))) > 48,
                      @"stacked tiles must spread apart");
    double far[2] = {0, M_PI};
    spreadAngles(far, rad, 2, 50);
    NSCAssert(far[0] == 0 && far[1] == M_PI, @"tiles already apart must not move");

    NSString *label = nil;
    uint8_t max[] = {0x4C, 0x00, 0x07, 0x04, 0x01, 0x0A, 0x20, 0x55};
    NSCAssert([appleKind([NSData dataWithBytes:max length:8], &label) isEqual:@"airpodsmax"] &&
                  [label isEqual:@"AirPods Max"], @"AirPods Max model id");
    uint8_t beats[] = {0x4C, 0x00, 0x07, 0x03, 0x01, 0x12, 0x20};
    NSCAssert([appleKind([NSData dataWithBytes:beats length:7], &label) isEqual:@"headphones"], @"other pairing = headphones");
    uint8_t nearby[] = {0x4C, 0x00, 0x10, 0x05, 0x01, 0x18, 0x44, 0x00, 0x00, 0x12, 0x02, 0x00, 0x00};
    NSCAssert([appleKind([NSData dataWithBytes:nearby length:13], &label) isEqual:@"airtag"], @"must walk past the first message");
    uint8_t bad[] = {0x4C, 0x00, 0x07, 0x40, 0x01};
    NSCAssert(!appleKind([NSData dataWithBytes:bad length:5], &label), @"overlong length must not read past the end");
    NSCAssert(!appleKind([NSData data], &label), @"empty data");
    NSCAssert([modelKind(@"iPhone15,2", &label) isEqual:@"iphone"], @"iPhone model");
    NSCAssert([modelKind(@"AudioAccessory5,1", &label) isEqual:@"homepod"], @"HomePod model");
    NSCAssert([modelKind(@"iMac21,1", &label) isEqual:@"desktopcomputer"], @"iMac is not a laptop");
    NSCAssert(!modelKind(nil, &label), @"no model");
    NSCAssert([nameKind(@"JBL Flip 6") isEqual:@"hifispeaker"], @"speaker by brand");
    NSCAssert([nameKind(@"WH-1000XM5") isEqual:@"headphones"], @"Sony headphones");
    NSCAssert([nameKind(@"AirPods Max Edwina") isEqual:@"airpodsmax"], @"AirPods Max by name");
    NSCAssert(!nameKind(@"XYZ-123"), @"unknown name");

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

static uint64_t uptimeNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

@implementation LockController {
    NSMutableArray<NSWindow *> *_windows;
    PinPanel *_panel;
    IOPMAssertionID _assertion;
    NSTimer *_heartbeat;
    dispatch_source_t _watchdog;
}

// Exit if the main thread stalls while locked, so a hung pinlock can't trap the user.
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
        uint64_t beat = gHeartbeat;
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

@interface RadarTile : NSAccessibilityElement
@property (nonatomic, copy) void (^press)(void);
@end

@implementation RadarTile
- (BOOL)accessibilityPerformPress {
    self.press();
    return YES;
}
@end

@interface RadarView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSSet<NSString *> *watched;
@property (nonatomic) double limit;
@property (nonatomic, copy) void (^onPick)(NSString *uuid, NSString *name);
@end

@implementation RadarView {
    NSMutableDictionary<NSString *, NSNumber *> *_radius;
    NSMutableDictionary<NSString *, NSNumber *> *_angle;
    NSString *_hover;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _radius = [NSMutableDictionary dictionary];
        _angle = [NSMutableDictionary dictionary];
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                               NSTrackingActiveAlways | NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
    return self;
}

- (CGFloat)radiusFor:(double)meters {
    CGFloat inner = 52, outer = NSWidth(self.bounds) / 2 - 40;
    double t = log(MAX(meters, 0.3) / 0.3) / log(10 / 0.3);
    return inner + (outer - inner) * MIN(t, 1);
}

- (void)setDevices:(NSArray<NSDictionary *> *)devices {
    _devices = [devices copy];
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    for (NSDictionary *d in devices) {
        CGFloat target = [self radiusFor:[d[@"meters"] doubleValue]];
        NSNumber *old = _radius[d[@"id"]];
        next[d[@"id"]] = @(old ? old.doubleValue + (target - old.doubleValue) * 0.15 : target);
    }
    _radius = next;

    int n = (int)devices.count;
    double angle[n], radius[n];
    for (int i = 0; i < n; i++) {
        NSString *uuid = devices[i][@"id"];
        angle[i] = _angle[uuid] ? _angle[uuid].doubleValue : (uuid.hash % 360) * M_PI / 180;
        radius[i] = _radius[uuid].doubleValue;
    }
    spreadAngles(angle, radius, n, 64);
    NSMutableDictionary *angles = [NSMutableDictionary dictionary];
    for (int i = 0; i < n; i++) angles[devices[i][@"id"]] = @(angle[i]);
    _angle = angles;
    self.needsDisplay = YES;
}

- (NSRect)tileFor:(NSDictionary *)d {
    CGFloat a = _angle[d[@"id"]].doubleValue, r = _radius[d[@"id"]].doubleValue;
    NSPoint c = NSMakePoint(NSMidX(self.bounds) + cos(a) * r, NSMidY(self.bounds) + sin(a) * r);
    return NSMakeRect(c.x - 15, c.y - 20, 30, 40);
}

- (void)drawSymbol:(NSString *)name size:(CGFloat)size color:(NSColor *)color in:(NSRect)r {
    NSImage *img = [([NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                         ?: [NSImage imageWithSystemSymbolName:@"questionmark.square.dashed"
                                     accessibilityDescription:nil])
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

    NSBezierPath *edge = ring([self radiusFor:10] + 24);
    [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
    [edge fill];
    [NSColor.separatorColor setStroke];
    [edge stroke];

    NSDictionary *scale = @{NSFontAttributeName: [NSFont systemFontOfSize:9],
                            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor};
    for (int i = 0; i < 5; i++) {
        double m = kDistances[i];
        CGFloat r = [self radiusFor:m];
        [[NSColor.labelColor colorWithAlphaComponent:0.08] setStroke];
        [ring(r) stroke];
        [[NSString stringWithFormat:@"%g m", m] drawAtPoint:NSMakePoint(c.x + 3, c.y + r + 1) withAttributes:scale];
    }

    NSBezierPath *lockLine = ring([self radiusFor:_limit]);
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
        BOOL chosen = [_watched containsObject:d[@"id"]], hover = [d[@"id"] isEqual:_hover];
        NSRect t = [self tileFor:d];
        NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:t xRadius:8 yRadius:8];
        [(chosen ? green : [green colorWithAlphaComponent:hover ? 0.4 : 0.2]) setFill];
        [box fill];
        box.lineWidth = hover ? 2 : 1;
        [green setStroke];
        [box stroke];
        [self drawSymbol:d[@"symbol"] size:15 color:chosen ? NSColor.whiteColor : green in:t];
        [self drawText:d[@"name"] color:chosen ? NSColor.labelColor : NSColor.secondaryLabelColor below:t];
    }
}

- (NSArray<NSDictionary *> *)drawOrder {
    return [_devices sortedArrayUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [@([self.watched containsObject:a[@"id"]]) compare:@([self.watched containsObject:b[@"id"]])];
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
        t.accessibilityLabel = [NSString stringWithFormat:@"%@, about %.1f metres%@", d[@"name"],
                                                          [d[@"meters"] doubleValue],
                                                          [_watched containsObject:d[@"id"]] ? @", watched" : @""];
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
                                CBCentralManagerDelegate, CBPeripheralDelegate,
                                CMHeadphoneMotionManagerDelegate>
- (void)setPeek:(BOOL)on;
@end

@implementation Delegate {
    NSStatusItem *_item;
    NSMenuItem *_login, *_awayItem;
    NSMenu *_blurMenu, *_dimMenu, *_tintMenu, *_lookMenu;
    CBCentralManager *_bt;
    NSMutableDictionary<NSUUID *, NSDictionary *> *_seen;
    NSMutableDictionary<NSUUID *, CBPeripheral *> *_peripherals;
    NSMutableDictionary<NSUUID *, NSString *> *_models;
    CBPeripheral *_probing;
    NSTimer *_awayTimer, *_radarTimer;
    NSWindow *_awayWindow;
    RadarView *_radar;
    NSTextField *_awayLabel;
    NSSegmentedControl *_distance;
    NSButton *_awayOff, *_calibrate;
    NSMutableArray<NSNumber *> *_calibration;
    NSTimeInterval _calibrateUntil;
    id<NSObject> _noNap;
    id _head;
    BOOL _headConnected;
    Head _headState;
    NSArray<NSWindow *> *_peekWindows;
    id _peekMonitor;
    BOOL _peekOn;
    NSUInteger _peekGen;
    int _peekSide;
    NSArray<NSArray<CALayer *> *> *_peekMasks;
    NSTimer *_peekTimer;
    double _peekProgress;
    NSTimeInterval _peekLast;
    NSMenuItem *_lookStatus;
    Away _away;
}

#pragma mark Lock When Away

- (void)startBluetooth {
    if (_bt) return;
    _seen = [NSMutableDictionary dictionary];
    _peripherals = [NSMutableDictionary dictionary];
    _models = [NSMutableDictionary dictionary];
    _bt = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    _awayTimer = [NSTimer scheduledTimerWithTimeInterval:2
                                                  target:self
                                                selector:@selector(awayTick:)
                                                userInfo:nil
                                                 repeats:YES];
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
    if (rssi.integerValue >= 0) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSUUID *k = p.identifier;
    BOOL chosen = awayDevices()[k.UUIDString] != nil, apple = isApple(ad);
    if (chosen) awaySeen(&_away, rssi.integerValue, awayRSSI(), now);
    if (chosen && _calibration && rssi.integerValue < 0) [_calibration addObject:rssi];

    NSDictionary *old = _seen[k];
    NSString *name = p.name ?: ad[CBAdvertisementDataLocalNameKey];
    if (!chosen && !apple && !name && !old) return;

    NSString *label = nil;
    NSString *symbol = (apple ? appleKind(ad[CBAdvertisementDataManufacturerDataKey], &label) : nil)
                           ?: modelKind(_models[k], &label)
                           ?: nameKind(name ?: old[@"name"])
                           ?: serviceKind(ad[CBAdvertisementDataServiceUUIDsKey])
                           ?: old[@"symbol"];
    if (apple && !symbol && !_models[k]) _peripherals[k] = p;

    _seen[k] = @{@"name": name ?: old[@"name"] ?: label ?: @"",
                 @"rssi": rssi,
                 @"at": @(now),
                 @"symbol": symbol ?: @"questionmark.square.dashed"};
}

#pragma mark Device identification

// Read the model number of one unidentified nearby Apple device; only while the radar is open.
- (void)identifyNext {
    if (_probing || !_radarTimer || _bt.state != CBManagerStatePoweredOn) return;
    for (NSUUID *k in _peripherals) {
        if (_models[k] || [_seen[k][@"rssi"] integerValue] < -80) continue;
        CBPeripheral *p = _probing = _peripherals[k];
        _models[k] = @"";
        p.delegate = self;
        [_bt connectPeripheral:p options:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self->_probing == p) [self finishProbe];
        });
        return;
    }
}

- (void)finishProbe {
    [_peripherals removeObjectForKey:_probing.identifier];
    [_bt cancelPeripheralConnection:_probing];
    _probing = nil;
}

- (void)centralManager:(CBCentralManager *)c didConnectPeripheral:(CBPeripheral *)p {
    [p discoverServices:@[[CBUUID UUIDWithString:@"180A"]]];
}

- (void)centralManager:(CBCentralManager *)c didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    if (p == _probing) [self finishProbe];
}

- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)e {
    CBService *info = p.services.firstObject;
    if (info) [p discoverCharacteristics:@[[CBUUID UUIDWithString:@"2A24"]] forService:info];
    else if (p == _probing) [self finishProbe];
}

- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(NSError *)e {
    CBCharacteristic *model = s.characteristics.firstObject;
    if (model) [p readValueForCharacteristic:model];
    else if (p == _probing) [self finishProbe];
}

- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)e {
    NSString *model = ch.value ? [[NSString alloc] initWithData:ch.value encoding:NSUTF8StringEncoding] : nil;
    if (model.length) _models[p.identifier] = model;
    if (p == _probing) [self finishProbe];
}

- (void)awayTick:(NSTimer *)t {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSUUID *k in _seen.allKeys)
        if (now - [_seen[k][@"at"] doubleValue] > 30) {
            [_seen removeObjectForKey:k];
            [_models removeObjectForKey:k];
            if (_peripherals[k] != _probing) [_peripherals removeObjectForKey:k];
        }

    if (awayDue(&_away, now)) [LockController.shared lock];
}

- (NSString *)awayStatus {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSInteger rssi = NSIntegerMin;
    for (NSString *uuid in awayDevices()) {
        NSDictionary *s = _seen[[[NSUUID alloc] initWithUUIDString:uuid]];
        NSInteger r = [s[@"rssi"] integerValue];
        if (s && now - [s[@"at"] doubleValue] < 5 && r < 0) rssi = MAX(rssi, r);
    }
    BOOL fresh = rssi != NSIntegerMin;

    if (_calibrateUntil) return [NSString stringWithFormat:@"Calibrating — stay where you normally sit… %.0f s",
                                                          MAX(0, _calibrateUntil - now)];
    double m = metersFor(rssi, awayRef());
    if (fresh && rssi >= awayRSSI()) return [NSString stringWithFormat:@"Near · ~%.1f m", m];
    if (_away.armed)
        return [NSString stringWithFormat:@"Moving away · locks in %.0f s",
                                          MAX(0, kAwayDelay - (now - _away.nearAt))];
    return fresh ? [NSString stringWithFormat:@"Too far to arm · ~%.1f m", m] : @"Not in range";
}

- (void)showAwayWindow:(id)sender {
    [self startBluetooth];
    if (!_awayWindow) {
        _radar = [[RadarView alloc] initWithFrame:NSZeroRect];
        __weak Delegate *weakSelf = self;
        _radar.onPick = ^(NSString *uuid, NSString *name) { [weakSelf toggleAway:uuid name:name]; };

        _awayLabel = [NSTextField wrappingLabelWithString:@""];
        _awayLabel.alignment = NSTextAlignmentCenter;
        _awayLabel.preferredMaxLayoutWidth = 400;

        _distance = [NSSegmentedControl segmentedControlWithLabels:@[@"1 m", @"2 m", @"3 m", @"5 m", @"8 m"]
                                                      trackingMode:NSSegmentSwitchTrackingSelectOne
                                                            target:self
                                                            action:@selector(setDistance:)];
        NSStackView *distanceRow =
            [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Lock beyond"], _distance]];

        _awayOff = [NSButton buttonWithTitle:@"Turn Off" target:self action:@selector(turnAwayOff:)];
        _calibrate = [NSButton buttonWithTitle:@"Calibrate" target:self action:@selector(calibrate:)];
        _calibrate.toolTip = @"Sit as you normally do, with your devices where you usually keep them "
                             @"(pocket included), then click. Distances are measured from there.";
        NSStackView *buttons = [NSStackView stackViewWithViews:@[_calibrate, _awayOff]];

        NSStackView *stack = [NSStackView stackViewWithViews:@[_radar, _awayLabel, distanceRow, buttons]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.spacing = 14;
        stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
        [NSLayoutConstraint activateConstraints:@[
            [_radar.widthAnchor constraintEqualToConstant:400],
            [_radar.heightAnchor constraintEqualToConstant:400],
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
    NSDictionary<NSString *, NSString *> *watched = awayDevices();

    NSMutableArray<NSUUID *> *ids = [[_seen keysSortedByValueUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [b[@"rssi"] compare:a[@"rssi"]];
    }] mutableCopy];
    if (ids.count > 10) [ids removeObjectsInRange:NSMakeRange(10, ids.count - 10)];
    for (NSString *uuid in watched) {
        NSUUID *k = [[NSUUID alloc] initWithUUIDString:uuid];
        if (_seen[k] && ![ids containsObject:k]) [ids addObject:k];
    }

    NSMutableArray *devices = [NSMutableArray array];
    for (NSUUID *k in ids) {
        NSString *name = _seen[k][@"name"];
        if (!name.length) name = [@"Device " stringByAppendingString:[k.UUIDString substringToIndex:4]];
        [devices addObject:@{@"id": k.UUIDString, @"name": name,
                             @"meters": @(metersFor([_seen[k][@"rssi"] integerValue], awayRef())),
                             @"symbol": _seen[k][@"symbol"]}];
    }
    [self identifyNext];
    _radar.watched = [NSSet setWithArray:watched.allKeys];
    _radar.limit = awayMeters();
    _radar.devices = devices;

    _awayLabel.stringValue =
        _bt.state == CBManagerStateUnauthorized
            ? @"Bluetooth access is off for pinlock. Allow it in System Settings › Privacy & Security › Bluetooth."
        : _bt.state != CBManagerStatePoweredOn ? @"Waiting for Bluetooth…"
        : !watched.count
            ? @"Click the devices you carry on the radar. Any one of them nearby counts as you being here."
            : [NSString stringWithFormat:@"%@ — %@",
                                         [[watched.allValues sortedArrayUsingSelector:@selector(compare:)]
                                             componentsJoinedByString:@", "],
                                         [self awayStatus]];

    _distance.selectedSegment = -1;
    for (NSInteger i = 0; i < 5; i++)
        if (kDistances[i] == awayMeters()) _distance.selectedSegment = i;
    _awayOff.enabled = _calibrate.enabled = watched.count > 0 && !_calibrateUntil;
    if (_calibrateUntil && NSProcessInfo.processInfo.systemUptime >= _calibrateUntil) [self finishCalibration];
}

- (void)saveAwayDevices:(NSDictionary *)devices {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:devices forKey:@"awayDevices"];
    [d removeObjectForKey:@"awayID"];
    [d removeObjectForKey:@"awayName"];
    _away = (Away){0};
    [self refreshAway:nil];
}

- (void)toggleAway:(NSString *)uuid name:(NSString *)name {
    NSMutableDictionary *devices = [awayDevices() mutableCopy];
    devices[uuid] = devices[uuid] ? nil : name;
    [self saveAwayDevices:devices];
}

- (void)turnAwayOff:(id)sender { [self saveAwayDevices:@{}]; }

- (void)setDistance:(NSSegmentedControl *)sender {
    [NSUserDefaults.standardUserDefaults setDouble:kDistances[sender.selectedSegment] forKey:@"awayMeters"];
}

// Median signal over 5 s from where you sit becomes the 0.5 m reference.
- (void)calibrate:(id)sender {
    _calibration = [NSMutableArray array];
    _calibrateUntil = NSProcessInfo.processInfo.systemUptime + 5;
}

- (void)finishCalibration {
    _calibrateUntil = 0;
    NSArray<NSNumber *> *r = [_calibration sortedArrayUsingSelector:@selector(compare:)];
    _calibration = nil;
    if (r.count < 5) {
        _awayLabel.stringValue = @"Calibration failed: no signal from your devices. Try again.";
        return;
    }
    [NSUserDefaults.standardUserDefaults setInteger:r[r.count / 2].integerValue forKey:@"awayRef"];
    _away = (Away){0};
}

#pragma mark Blur When Looking Away

- (NSString *)headStatus {
    if (@available(macOS 14.0, *)) {
        CMAuthorizationStatus a = CMHeadphoneMotionManager.authorizationStatus;
        if (a == CMAuthorizationStatusDenied || a == CMAuthorizationStatusRestricted)
            return @"Motion access is off: allow pinlock in System Settings › Privacy & Security";
        if (!lookAwayAngle()) return @"Needs AirPods or Beats with head tracking";
        if (!_headConnected) return @"Waiting for head-tracking headphones…";
        if (!CGPreflightScreenCaptureAccess())
            return @"Allow Screen Recording in System Settings for the full blur";
        return @"Headphones connected";
    }
    return @"Needs macOS 14 or later";
}

- (void)setLookAway:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"lookAway"];
    if (sender.tag && !CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    [self updateHeadTracking];
}

- (void)updateHeadTracking {
    if (@available(macOS 14.0, *)) {
        if (lookAwayAngle() && !_head) {
            CMHeadphoneMotionManager *m = _head = [CMHeadphoneMotionManager new];
            m.delegate = self;
            __weak Delegate *weakSelf = self;
            [m startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue
                                   withHandler:^(CMDeviceMotion *motion, NSError *err) {
                if (motion) [weakSelf headMoved:motion.attitude.yaw];
            }];
        } else if (!lookAwayAngle() && _head) {
            [(CMHeadphoneMotionManager *)_head stopDeviceMotionUpdates];
            _head = nil;
            [self headGone];
        }
    }
}

- (void)headMoved:(double)yaw {
    _headConnected = YES;
    [self setPeek:headSample(&_headState, yaw, lookAwayAngle() * M_PI / 180,
                             NSProcessInfo.processInfo.systemUptime)];
}

- (void)headphoneMotionManagerDidConnect:(CMHeadphoneMotionManager *)m {
    _headConnected = YES;
}

- (void)headphoneMotionManagerDidDisconnect:(CMHeadphoneMotionManager *)m {
    [self headGone];
}

- (void)headGone {
    _headConnected = NO;
    _headState = (Head){0};
    [self setPeek:NO];
}

// Privacy blur, not a lock: input passes through, looking back clears it.
- (void)setPeek:(BOOL)on {
    if (on == _peekOn) return;
    _peekOn = on;
    NSUInteger gen = ++_peekGen;

    if (on) {
        _peekMonitor = [NSEvent
            addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                                  NSEventMaskRightMouseDown |
                                                  NSEventMaskScrollWheel
                                          handler:^(NSEvent *e) {
            headRecentre(&self->_headState);
            [self setPeek:NO];
        }];
        if (_peekWindows) {
            [self startPeekTimer];
            return;
        }
        _peekSide = _headState.side ?: 1;
        void (^show)(NSDictionary *) = ^(NSDictionary *shots) {
            if (gen != self->_peekGen) return;
            [self buildPeek:shots];
            [self startPeekTimer];
        };
        if (@available(macOS 14.0, *)) {
            if (CGPreflightScreenCaptureAccess()) {
                [self snapshotScreens:show];
                return;
            }
        }
        NSLog(@"pinlock: no Screen Recording access, darkening instead of blurring");
        show(@{});
    } else {
        [NSEvent removeMonitor:_peekMonitor];
        _peekMonitor = nil;
        if (_peekWindows) [self startPeekTimer];
    }
}

// displayID -> baked blur levels of a half-size screen snapshot.
- (void)snapshotScreens:(void (^)(NSDictionary *))done API_AVAILABLE(macos(14.0)) {
    NSMutableDictionary<NSNumber *, NSNumber *> *scales = [NSMutableDictionary dictionary];
    for (NSScreen *scr in NSScreen.screens)
        scales[scr.deviceDescription[@"NSScreenNumber"]] = @(scr.backingScaleFactor);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
        if (err) NSLog(@"pinlock: can't list displays to snapshot: %@", err);
        NSMutableDictionary *shots = [NSMutableDictionary dictionary];
        CIContext *ci = [CIContext context];
        dispatch_group_t group = dispatch_group_create();
        for (SCDisplay *d in content.displays) {
            CGFloat scale = scales[@(d.displayID)].doubleValue ?: 2;
            SCStreamConfiguration *cfg = [SCStreamConfiguration new];
            cfg.width = d.width * scale / 2;
            cfg.height = d.height * scale / 2;
            cfg.showsCursor = NO;
            dispatch_group_enter(group);
            [SCScreenshotManager
                captureImageWithFilter:[[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]]
                         configuration:cfg
                     completionHandler:^(CGImageRef img, NSError *e) {
                if (e) NSLog(@"pinlock: snapshot of display %u failed: %@", d.displayID, e);
                if (img) {
                    NSMutableArray *levels = [NSMutableArray array];
                    CIImage *half = [CIImage imageWithCGImage:img];
                    for (int k = 0; k < kBlurLevels; k++) {
                        CIImage *soft = [[half.imageByClampingToExtent
                            imageByApplyingGaussianBlurWithSigma:kBlurSigma[k] * scale / 2]
                            imageByCroppingToRect:half.extent];
                        [levels addObject:CFBridgingRelease([ci createCGImage:soft fromRect:half.extent])];
                    }
                    @synchronized (shots) { shots[@(d.displayID)] = levels; }
                }
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSLog(@"pinlock: snapshot %lu of %lu displays", shots.count, content.displays.count);
            done(shots);
        });
    }];
}

- (void)buildPeek:(NSDictionary *)shots {
    NSMutableArray<NSWindow *> *ws = [NSMutableArray array];
    NSMutableArray<NSArray<CALayer *> *> *masks = [NSMutableArray array];
    for (NSScreen *scr in NSScreen.screens) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:scr.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.level = CGShieldingWindowLevel() - 1;
        w.opaque = NO;
        w.hasShadow = NO;
        w.releasedWhenClosed = NO;
        w.ignoresMouseEvents = YES;
        w.backgroundColor = NSColor.clearColor;
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle;
        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, scr.frame.size.width, scr.frame.size.height)];
        root.wantsLayer = YES;
        w.contentView = root;

        NSArray *levels = shots[scr.deviceDescription[@"NSScreenNumber"]];
        NSMutableArray<CALayer *> *screenMasks = [NSMutableArray array];
        for (NSUInteger k = 0; k <= levels.count; k++) {
            CALayer *l = [CALayer layer];
            l.frame = root.bounds;
            if (k < levels.count) l.contents = levels[k];
            else l.backgroundColor = NSColor.blackColor.CGColor;
            CALayer *mask = [CALayer layer];
            mask.frame = l.bounds;
            mask.contentsGravity = kCAGravityResize;
            mask.contents = CFBridgingRelease(maskStrip((uint8_t[1]){0}, 1));
            l.mask = mask;
            [screenMasks addObject:mask];
            [root.layer addSublayer:l];
        }
        [masks addObject:screenMasks];
        [w orderFrontRegardless];
        [ws addObject:w];
    }
    _peekWindows = ws;
    _peekMasks = masks;
    _peekProgress = 0;
    [self renderPeek];
}

- (void)startPeekTimer {
    if (_peekTimer) return;
    _peekLast = NSProcessInfo.processInfo.systemUptime;
    _peekTimer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(peekStep:)
                                       userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_peekTimer forMode:NSRunLoopCommonModes];
}

- (void)peekStep:(NSTimer *)t {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime, dt = now - _peekLast;
    _peekLast = now;
    _peekProgress = _peekOn ? MIN(1, _peekProgress + dt / kPeekIn) : MAX(0, _peekProgress - dt / kPeekOut);
    [self renderPeek];

    if (_peekProgress == (_peekOn ? 1 : 0)) {
        [_peekTimer invalidate];
        _peekTimer = nil;
        if (!_peekOn) {
            for (NSWindow *w in _peekWindows) [w close];
            _peekWindows = nil;
            _peekMasks = nil;
        }
    }
}

- (void)renderPeek {
    double e = _peekProgress * _peekProgress * (3 - 2 * _peekProgress);
    enum { n = 128 };
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSArray<CALayer *> *screenMasks in _peekMasks) {
        NSUInteger count = screenMasks.count;
        BOOL dimOnly = count == 1;
        for (NSUInteger k = 0; k < count; k++) {
            BOOL dim = k == count - 1;
            uint8_t alpha[n];
            for (int i = 0; i < n; i++) {
                double x = (i + 0.5) / n, d = _peekSide > 0 ? x : 1 - x;
                double b = duoBlur(e, d);
                alpha[i] = (uint8_t)lround(255 * (dim ? (dimOnly ? 0.85 : kPeekDim) * b : blurLevelAlpha(b, (int)k)));
            }
            screenMasks[k].contents = CFBridgingRelease(maskStrip(alpha, n));
        }
    }
    [CATransaction commit];
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

    _lookMenu = [self levelMenu:@[@"Off", @"Small turn (30°)", @"Medium turn (45°)", @"Large turn (60°)"]
                           tags:@[@0, @30, @45, @60]
                         action:@selector(setLookAway:)];
    _lookStatus = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [_lookMenu insertItem:_lookStatus atIndex:0];
    [_lookMenu insertItem:NSMenuItem.separatorItem atIndex:1];
    [menu addItemWithTitle:@"Blur When Looking Away" action:nil keyEquivalent:@""].submenu = _lookMenu;

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

    if (awayDevices().count) [self startBluetooth];
    [self updateHeadTracking];

    if (!currentPIN())
        promptForPIN(@"Set a PIN",
                     @"pinlock locks the screen with this PIN. At least 4 digits.");
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == _lookMenu) {
        _lookStatus.title = [self headStatus];
        for (NSMenuItem *it in menu.itemArray)
            if (it.action) it.state = it.tag == lookAwayAngle() ? NSControlStateValueOn : NSControlStateValueOff;
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

    _awayItem.state = awayDevices().count ? NSControlStateValueOn : NSControlStateValueOff;

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

        if (argc > 1 && strcmp(argv[1], "--peektest") == 0) {
            if (!CGPreflightScreenCaptureAccess()) {
                CGRequestScreenCaptureAccess();
                NSAlert *a = [NSAlert new];
                a.messageText = @"pinlock can't see the screen";
                a.informativeText = @"Without Screen Recording access the blur can't run and you only get the "
                                    @"darkening fallback. Every rebuild counts as a new app to macOS, so "
                                    @"remove pinlock from the list, add this copy again, and relaunch.";
                [a addButtonWithTitle:@"Open Settings"];
                [a addButtonWithTitle:@"Show Fallback"];
                [NSApp activateIgnoringOtherApps:YES];
                if ([a runModal] == NSAlertFirstButtonReturn) {
                    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
                    return 0;
                }
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                           dispatch_get_main_queue(), ^{ [del setPeek:YES]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ [del setPeek:NO]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        } else if (argc > 1 && strcmp(argv[1], "--hangtest") == 0) {
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
