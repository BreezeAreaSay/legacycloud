// Ядро iOS6Revive в SpringBoard: публикует состояние функций для программ из песочницы
// и перезапускает SpringBoard по запросу из Настроек.

#import "IRShared.h"
#import "IRPrivate.h"

static int gStateToken;
static BOOL gStateTokenReady;

static void IRPublishState(void) {
    NSDictionary *prefs = IRPrefsRead() ?: @{};
    uint64_t state = IRStatePublished;
    if (IRBool(prefs, kIRSwipeBack, YES))
        state |= IRStateSwipeBack;
    if (IRBool(prefs, kIRLowPower, NO))
        state |= IRStateLowPower;
    if (IRBool(prefs, kIRBoldText, NO))
        state |= IRStateBoldText;

    // Токен не отменяем: пока он открыт, notifyd хранит состояние.
    if (!gStateTokenReady)
        gStateTokenReady = notify_register_check(IR_NOTIFY_STATE, &gStateToken) == NOTIFY_STATUS_OK;
    if (gStateTokenReady)
        notify_set_state(gStateToken, state);
    notify_post(IR_NOTIFY_STATE);
}

static void IRPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    IRPublishState();
}

static void IRRespring(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    IRPublishState();
    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
    if ([springBoard respondsToSelector:@selector(_relaunchSpringBoardNow)])
        [springBoard _relaunchSpringBoardNow];
    else
        exit(0); // launchd сразу поднимет SpringBoard заново
}

__attribute__((constructor)) static void IRCoreInit(void) {
    @autoreleasepool {
        IRPublishState();
        IRObserveDarwin(IR_NOTIFY_PREFS, IRPrefsChanged);
        IRObserveDarwin(IR_NOTIFY_RESPRING, IRRespring);
    }
}
