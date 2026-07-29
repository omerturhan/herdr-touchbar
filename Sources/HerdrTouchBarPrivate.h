// Private Touch Bar / DFR API surface used to place an item in the Control Strip
// and to present a system-modal Touch Bar from a background (accessory) app.
//
// These symbols are not in the public SDK. They are stable across macOS 10.12.2
// through macOS 26 and are the same entry points MTMR and Pock rely on.

#import <Cocoa/Cocoa.h>

@interface NSTouchBarItem (HerdrPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

@interface NSTouchBar (HerdrPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

extern void DFRElementSetControlStripPresenceForIdentifier(NSTouchBarItemIdentifier identifier, BOOL present);
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL shows);
