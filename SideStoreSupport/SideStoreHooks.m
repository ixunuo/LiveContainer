//
//  SideStoreHooks.m
//  LiveContainer
//
//  Created by s s on 2026/8/6.
//
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
#include "XPCServer.h"
#import <sys/sysctl.h>
@import UserNotifications;
@import UIKit;

@interface LCAuthorizedNotificationSettings : UNNotificationSettings
@end

@implementation LCAuthorizedNotificationSettings

- (UNAuthorizationStatus)authorizationStatus {
    return UNAuthorizationStatusAuthorized;
}

@end

static NSMutableDictionary<NSString *, UIWindow *> *SSVersionWindows;
static id SSSceneObserver;

@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    return nil;
}

@end

@implementation UNUserNotificationCenter(SideStoreHooks)

- (void)lc_addNotificationRequest:(UNNotificationRequest*)request
            withCompletionHandler:(void (^)(NSError* error))completionHandler {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server addNotificationRequest:request];
    if (completionHandler) {
        completionHandler(nil);
    }
}

- (void)lc_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server removePendingNotificationRequestsWithIdentifiers:identifiers];
}

- (void)lc_getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings* settings))completionHandler {
    if (!completionHandler) {
        return;
    }

    UNNotificationSettings* settings = class_createInstance(LCAuthorizedNotificationSettings.class, 0);
    completionHandler(settings);
}

@end

@implementation NSBundle(SideStoreHooks)

+ (NSString*)hook_appbundleIdentifier {
    return @"com.kdt.livecontainer";
}

+ (NSString*)hook_storeAppBundleIdentifier {
    return @"com.kdt.livecontainer";
}

- (NSString*)hook_altstoreAppGroup {
    return LCSharedUtils.appGroupID;
}

+ (NSString*)hook_baseAltStoreAppGroupID {
    return @"group.com.SideStore.SideStore";
}

+ (NSBundle*)hook_activeBundle {
    if (!NSUserDefaults.isLiveProcess) return NSUserDefaults.lcMainBundle;
    
    static NSBundle* lcAppBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lcAppBundle = [NSBundle bundleWithURL: NSUserDefaults.lcMainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    });
    return lcAppBundle;
}

@end

NSURL* SideStoreSource_hook_altStoreSourceURL(id self, SEL cmd) {
    static NSURL* sourceURL = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sourceURL = [NSURL URLWithString:@"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps_ss_lc.json"];
    });
    return sourceURL;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
void (*SideStoreMyAppsViewController_orig_viewDidload)(UICollectionViewController* self, SEL cmd) = nil;
void SideStoreMyAppsViewController_hook_viewDidload(UICollectionViewController* self, SEL cmd) {
    if(!SideStoreMyAppsViewController_orig_viewDidload) return;
    SideStoreMyAppsViewController_orig_viewDidload(self, cmd);
    
    UIImage *escapeImage = [UIImage systemImageNamed:@"escape"];
    UIBarButtonItem *escapeItem = [[UIBarButtonItem alloc] initWithImage:escapeImage
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(escapeButtonTapped:)];
        
    NSMutableArray* oldToolBarItems = [self.navigationItem.leftBarButtonItems mutableCopy];
    [oldToolBarItems addObject:escapeItem];
    self.navigationItem.leftBarButtonItems = oldToolBarItems;
}

void SideStoreMyAppsViewController_hook_escapeButtonTapped(UICollectionViewController* self, SEL cmd, id target) {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}





static void SSInstallVersionWindow(UIWindowScene *windowScene)
{
    NSString *identifier = windowScene.session.persistentIdentifier;
    if (identifier.length == 0 || SSVersionWindows[identifier] != nil) {
        return;
    }
    
    
    NSString* LCVersion = [NSString stringWithFormat:@"%@-%@",
                         NSUserDefaults.lcMainBundle.infoDictionary[@"CFBundleShortVersionString"],
                         NSUserDefaults.lcMainBundle.infoDictionary[@"LCVersionInfo"]];
    
    NSString* SSVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];
    size_t size = 32;
    char iosBuild[32];
    sysctlbyname("kern.osversion", iosBuild, &size, NULL, 0);
    bool isPhone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    NSString* allVersionString = [NSString stringWithFormat:isPhone ? @"LC %@, SS %@\niOS %@ (%s)" : @"LC %@, SS %@, iOS %@ (%s)", LCVersion, SSVersion, osVersion, iosBuild];

    UILabel* versionLabel = [UILabel new];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
    versionLabel.textColor = UIColor.labelColor;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.userInteractionEnabled = NO;
    versionLabel.text = allVersionString;
    versionLabel.numberOfLines = 0;
    versionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    
    UIViewController *rootController = [[UIViewController alloc] init];
    rootController.view.backgroundColor = UIColor.clearColor;
    [rootController.view addSubview:versionLabel];
    
    if(windowScene.keyWindow.safeAreaInsets.bottom == 0) {
        // old devices with no bottom safe area
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.topAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.topAnchor]
        ]];
    } else {
        // new devices
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.bottomAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.bottomAnchor
                                                      constant: isPhone ? 22 : 0]
        ]];
    }
    PassthroughWindow *window = [[PassthroughWindow alloc] initWithWindowScene:windowScene];

    window.rootViewController = rootController;
    window.backgroundColor = UIColor.clearColor;

    window.windowLevel = UIWindowLevelAlert;

    window.hidden = NO;

    SSVersionWindows[identifier] = window;
}


#pragma mark - LiveProcess extension: remote-only Anisette + refresh diagnostics

// The LiveProcess extension runs without a UI and cannot reliably complete local ADI (Unicorn) provisioning,
// so a silent refresh has to use the remote Anisette servers. The override below is process-local: the
// user-visible setting in the SideStore UI is left untouched.
static BOOL (*LCOrigBoolForKey)(id, SEL, NSString*) = NULL;
static id (*LCOrigObjectForKey)(id, SEL, NSString*) = NULL;
static NSString* LCStoredUseOnDeviceAnisette = nil;

static BOOL LCHookBoolForKey(NSUserDefaults* self, SEL cmd, NSString* key) {
    if([key isEqualToString:@"useOnDeviceAnisette"]) {
        return NO;
    }
    return LCOrigBoolForKey(self, cmd, key);
}

static id LCHookObjectForKey(NSUserDefaults* self, SEL cmd, NSString* key) {
    if([key isEqualToString:@"useOnDeviceAnisette"]) {
        return @NO;
    }
    return LCOrigObjectForKey(self, cmd, key);
}

static void installRemoteAnisetteOverride(void) {
    NSUserDefaults* ud = NSUserDefaults.standardUserDefaults;
    id storedValue = [ud objectForKey:@"useOnDeviceAnisette"];
    LCStoredUseOnDeviceAnisette = storedValue ? [NSString stringWithFormat:@"%@", storedValue] : @"(unset)";

    Method boolForKeyMethod = class_getInstanceMethod(NSUserDefaults.class, @selector(boolForKey:));
    LCOrigBoolForKey = (BOOL (*)(id, SEL, NSString*))method_getImplementation(boolForKeyMethod);
    method_setImplementation(boolForKeyMethod, (IMP)LCHookBoolForKey);

    Method objectForKeyMethod = class_getInstanceMethod(NSUserDefaults.class, @selector(objectForKey:));
    LCOrigObjectForKey = (id (*)(id, SEL, NSString*))method_getImplementation(objectForKeyMethod);
    method_setImplementation(objectForKeyMethod, (IMP)LCHookObjectForKey);

    NSLog(@"[SideStoreSupport] LiveProcess refresh: using remote Anisette (stored useOnDeviceAnisette=%@, HOME=%@)", LCStoredUseOnDeviceAnisette, NSHomeDirectory());
}

NSString* LCAnisetteDiagnostics(void) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* home = NSHomeDirectory();
    NSString* guestId = NSUserDefaults.lcGuestAppId;
    NSString* prefsPath = guestId ? [home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", guestId]] : nil;
    NSString* serversPath = [home stringByAppendingPathComponent:@"Documents/anisette-servers.json"];

    NSMutableString* info = [NSMutableString string];
    [info appendString:@"diagnostics:"];
    [info appendFormat:@" HOME=%@", home];
    [info appendFormat:@", LC_HOME=%s", getenv("LC_HOME_PATH") ?: "(unset)"];
    [info appendFormat:@", LP_HOME=%s", getenv("LP_HOME_PATH") ?: "(unset)"];
    [info appendFormat:@", guestId=%@", guestId ?: @"(nil)"];
    [info appendFormat:@", storedODA=%@", LCStoredUseOnDeviceAnisette ?: @"(unknown)"];
    [info appendFormat:@", prefs=%@", prefsPath ? ([fm fileExistsAtPath:prefsPath] ? @"present" : @"missing") : @"unknown"];
    [info appendFormat:@", homeReadable=%@", [fm isReadableFileAtPath:home] ? @"yes" : @"no"];
    [info appendFormat:@", serversJSON=%@", [fm fileExistsAtPath:serversPath] ? @"present" : @"missing"];
    [info appendFormat:@", docsWritable=%@", [fm isWritableFileAtPath:[home stringByAppendingPathComponent:@"Documents"]] ? @"yes" : @"no"];
    return info;
}

void installSideStoreHooks(void) {

    swizzleClassMethod(NSBundle.class, @selector(appbundleIdentifier), @selector(hook_appbundleIdentifier));
    swizzleClassMethod(NSBundle.class, @selector(storeAppBundleIdentifier), @selector(hook_storeAppBundleIdentifier));
    swizzle(NSBundle.class, @selector(altstoreAppGroup), @selector(hook_altstoreAppGroup));
    swizzleClassMethod(NSBundle.class, @selector(activeBundle), @selector(hook_activeBundle));
    swizzleClassMethod(NSBundle.class, @selector(baseAltStoreAppGroupID), @selector(hook_baseAltStoreAppGroupID));
    
    // replace altStoreSourceURL
    Method altStoreSourceURLMethod = class_getClassMethod(PrivClass(Source), @selector(altStoreSourceURL));
    method_setImplementation(altStoreSourceURLMethod, (IMP)SideStoreSource_hook_altStoreSourceURL);
    
    if (!NSUserDefaults.isLiveProcess) {
        // add escape button
        Method viewDidLoadMethod = class_getInstanceMethod(PrivClass(MyAppsViewController), @selector(viewDidLoad));
        SideStoreMyAppsViewController_orig_viewDidload = (void (*)(UICollectionViewController *, SEL))method_getImplementation(viewDidLoadMethod);
        method_setImplementation(viewDidLoadMethod, (IMP)SideStoreMyAppsViewController_hook_viewDidload);
        class_addMethod(PrivClass(MyAppsViewController), @selector(escapeButtonTapped:), (IMP)SideStoreMyAppsViewController_hook_escapeButtonTapped, "v@:@");
        
        // add version number
        SSVersionWindows = [NSMutableDictionary dictionary];

        SSSceneObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            UIScene *scene = notification.object;
            
            if ([scene isKindOfClass:UIWindowScene.class]) {
                SSInstallVersionWindow((UIWindowScene *)scene);
            }
        }];
        
        
        
    }
    
    if (NSUserDefaults.isLiveProcess) {
        installRemoteAnisetteOverride();
    }

}
#pragma clang diagnostic pop

void installSideStoreNotificationHooks(void) {
    swizzle(UNUserNotificationCenter.class,
            @selector(addNotificationRequest:withCompletionHandler:),
            @selector(lc_addNotificationRequest:withCompletionHandler:));
    swizzle(UNUserNotificationCenter.class,
            @selector(removePendingNotificationRequestsWithIdentifiers:),
            @selector(lc_removePendingNotificationRequestsWithIdentifiers:));
    swizzle(UNUserNotificationCenter.class,
            @selector(getNotificationSettingsWithCompletionHandler:),
            @selector(lc_getNotificationSettingsWithCompletionHandler:));
}
