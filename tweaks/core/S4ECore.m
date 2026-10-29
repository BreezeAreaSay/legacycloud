// Ядро Skeuo4Ever в SpringBoard: публикует состояние функций для программ из песочницы
// и перезапускает SpringBoard по запросу из Настроек.

#import "S4EShared.h"
#import "S4EPrivate.h"

static int gStateToken;
static BOOL gStateTokenReady;

static void S4EPublishState(void) {
    NSDictionary *prefs = S4EPrefsRead() ?: @{};
    uint64_t state = S4EStatePublished;
    if (S4EBool(prefs, kS4ESwipeBack, YES))
        state |= S4EStateSwipeBack;
    if (S4EBool(prefs, kS4ELowPower, NO))
        state |= S4EStateLowPower;
    if (S4EBool(prefs, kS4EBoldText, NO))
        state |= S4EStateBoldText;

    // Токен не отменяем: пока он открыт, notifyd хранит состояние.
    if (!gStateTokenReady)
        gStateTokenReady = notify_register_check(S4E_NOTIFY_STATE, &gStateToken) == NOTIFY_STATUS_OK;
    if (gStateTokenReady)
        notify_set_state(gStateToken, state);
    notify_post(S4E_NOTIFY_STATE);
}

static void S4EPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EPublishState();
}

static void S4ERespring(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EPublishState();
    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
    if ([springBoard respondsToSelector:@selector(_relaunchSpringBoardNow)])
        [springBoard _relaunchSpringBoardNow];
    else
        exit(0); // launchd сразу поднимет SpringBoard заново
}

__attribute__((constructor)) static void S4ECoreInit(void) {
    @autoreleasepool {
        S4EPublishState();
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EPrefsChanged);
        S4EObserveDarwin(S4E_NOTIFY_RESPRING, S4ERespring);
    }
}
