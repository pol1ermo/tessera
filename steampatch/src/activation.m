// activation.m - lets a Windows game come to the front when it opens its window.
//
// Since macOS 14 an app becomes the active app only when the active app hands over ("cooperative activation").
// Wine asks for that hand-over with a distributed notification, WineAppWillActivateNotification, which other Wine
// programs answer. Steam, the app the player starts the game from, never answered, so games opened behind the
// Steam window. Tessera's library inside Steam's window process (tessera_steam.c) answers it for the Windows
// programs of Steam games (their Windows folder is inside a Steam library's compatdata folder).
#import <AppKit/AppKit.h>

@interface TesseraActivation : NSObject
@end

@implementation TesseraActivation
- (void)wineAppWillActivate:(NSNotification *)note
{
    if (@available(macOS 14.0, *)) {
        // macOS itself grants the hand-over only when Steam is the active app (or was in the recent past)
        id prefix = note.userInfo[@"ActivatingAppPrefix"];
        if (![prefix isKindOfClass:[NSString class]] || ![prefix containsString:@"/steamapps/compatdata/"]) return;
        id pidValue = note.userInfo[@"ActivatingAppPID"];
        if (![pidValue respondsToSelector:@selector(intValue)]) return;
        NSRunningApplication *game = [NSRunningApplication runningApplicationWithProcessIdentifier:[pidValue intValue]];
        if (!game) return;
        [NSApp yieldActivationToApplication:game];
        BOOL ok = [game activateFromApplication:[NSRunningApplication currentApplication] options:0];
        NSLog(@"Tessera: game window to the front (pid %d): %@", game.processIdentifier, ok ? @"done" : @"refused by macOS");
    }
}
@end

void tessera_activation_init(void)
{
    if (@available(macOS 14.0, *)) {
        static TesseraActivation *observer;
        observer = [[TesseraActivation alloc] init];
        [[NSDistributedNotificationCenter defaultCenter] addObserver:observer
                                                            selector:@selector(wineAppWillActivate:)
                                                                name:@"WineAppWillActivateNotification"
                                                              object:nil
                                                  suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    }
}
