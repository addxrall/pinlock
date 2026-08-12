#import <Cocoa/Cocoa.h>
#import <Collaboration/Collaboration.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>

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

static const NSInteger kQuitPresses = 4;
static const NSTimeInterval kQuitWindow = 2.0;

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

static BOOL quitGestureComplete(NSTimeInterval now) {
    static NSInteger presses = 0;
    static NSTimeInterval last = 0;

    if (now - last > kQuitWindow) presses = 0;
    last = now;

    if (++presses >= kQuitPresses) {
        presses = 0;
        return YES;
    }
    return NO;
}

static void selfTest(void) {
    NSCAssert(kQuitPresses == 4, @"test assumes a 4-press gesture");

    NSCAssert(!quitGestureComplete(0.0), @"1st press must not quit");
    NSCAssert(!quitGestureComplete(0.5), @"2nd press must not quit");
    NSCAssert(!quitGestureComplete(1.0), @"3rd press must not quit");
    NSCAssert(quitGestureComplete(1.5), @"4th press must quit");

    NSCAssert(!quitGestureComplete(10.0), @"after reset, 1st press must not quit");
    NSCAssert(!quitGestureComplete(10.5), @"2nd press must not quit");
    NSCAssert(!quitGestureComplete(99.0), @"stale press must restart the count, not quit");
    NSCAssert(!quitGestureComplete(99.5), @"2nd of new run must not quit");
    NSCAssert(!quitGestureComplete(100.0), @"3rd of new run must not quit");
    NSCAssert(quitGestureComplete(100.5), @"4th of new run must quit");

    printf("selftest ok\n");
}

@class PinPanel;

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
@property (nonatomic, weak) NSTextField *field;
@end

@implementation ShieldView

- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self.field]; }
- (void)rightMouseDown:(NSEvent *)e {}
- (void)otherMouseDown:(NSEvent *)e {}
- (void)scrollWheel:(NSEvent *)e {}

@end

#pragma mark - PIN panel

@interface PinPanel : NSViewController
@property (nonatomic, readonly) NSSecureTextField *field;
- (void)shake;
@end

@implementation PinPanel {
    NSVisualEffectView *_blur;
    NSSecureTextField *_field;
}

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

    _field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    _field.bezelStyle = NSTextFieldRoundedBezel;
    _field.alignment = NSTextAlignmentCenter;
    _field.placeholderString = @"Enter PIN";
    _field.target = self;
    _field.action = @selector(submit:);
    _field.nextKeyView = _field;

    NSStackView *stack = [NSStackView stackViewWithViews:@[avatar, name, _field]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_blur addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [avatar.widthAnchor constraintEqualToConstant:96],
        [avatar.heightAnchor constraintEqualToConstant:96],
        [_field.widthAnchor constraintEqualToConstant:200],
        [stack.centerXAnchor constraintEqualToAnchor:_blur.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_blur.centerYAnchor],
        [_blur.widthAnchor constraintEqualToConstant:300],
        [_blur.heightAnchor constraintEqualToConstant:320],
    ]];
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
    [self shake];
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

@implementation LockController {
    NSMutableArray<NSWindow *> *_windows;
    PinPanel *_panel;
    IOPMAssertionID _assertion;
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
            shield.field = _panel.field;
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
}

- (void)nudge { [_panel shake]; }

- (void)unlock {
    if (!_locked) return;
    _locked = NO;

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

@interface Delegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation Delegate {
    NSStatusItem *_item;
    NSMenuItem *_login;
    NSMenu *_blurMenu, *_dimMenu, *_tintMenu;
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
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit pinlock" action:@selector(quit:) keyEquivalent:@"q"].target = self;
    _item.menu = menu;

    [self registerHotKey];

    __block NSInteger presses = 0;
    __block NSTimeInterval last = 0;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (!((e.modifierFlags & NSEventModifierFlagCommand) &&
              [e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"q"]))
            return e;

        if (kQuitPresses <= 0) return nil;
        if (e.isARepeat) return nil;

        if (e.timestamp - last > kQuitWindow) presses = 0;
        last = e.timestamp;

        if (++presses >= kQuitPresses) {
            presses = 0;
            [NSApp terminate:nil];
        } else {
            [LockController.shared nudge];
        }
        return nil;
    }];

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

        if (argc > 1) {
            double secs = atof(argv[1]);
            dispatch_async(dispatch_get_main_queue(), ^{ [LockController.shared lock]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [LockController.shared unlock]; });
        }

        [NSApp run];
    }
}
