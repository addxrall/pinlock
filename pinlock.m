#import <Cocoa/Cocoa.h>
#import <Collaboration/Collaboration.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

static const CGFloat kDimFloor = 0.02;

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

@class PinPanel;

#pragma mark - Controller

@interface LockController : NSObject
@property (nonatomic, readonly) BOOL locked;
+ (instancetype)shared;
- (void)lock;
- (void)unlock;
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

@interface Delegate : NSObject <NSApplicationDelegate>
@end

@implementation Delegate {
    NSStatusItem *_item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.button.image = [NSImage imageWithSystemSymbolName:@"lock.fill"
                                   accessibilityDescription:@"pinlock"];

    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"Lock Now" action:@selector(lockNow:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Change PIN…" action:@selector(changePIN:) keyEquivalent:@""].target = self;

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit pinlock" action:@selector(quit:) keyEquivalent:@"q"].target = self;
    _item.menu = menu;

    if (!currentPIN())
        promptForPIN(@"Set a PIN",
                     @"pinlock locks the screen with this PIN. At least 4 digits.");
}

- (void)lockNow:(id)sender { [LockController.shared lock]; }

- (void)changePIN:(id)sender {
    promptForPIN(@"Change PIN", @"At least 4 digits. You will need this to unlock the screen.");
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)n { [LockController.shared unlock]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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
