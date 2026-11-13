// What do -stopListeningForPMPrinterListChanged and -dealloc remove? (run after breaking the cycle so dealloc can happen)
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static IMP origAdd, origRm1, origRm2, origDealloc, origStop;
static NSMutableArray *tokens; static NSMutableSet *nearbyTokens;
static const char *phase = NULL;
static IMP origInit2; static id my_init2(id s, SEL c, id pi) { id r = ((id(*)(id,SEL,id))origInit2)(s, c, pi); printf(" init %p\n", r); return r; }
static IMP origBWD; static id my_bwd(id cls, SEL c, id del) { id r = ((id(*)(id,SEL,id))origBWD)(cls, c, del); printf(" +[PKPrinterBrowser browserWithDelegate:%p (%s)] -> %p\n", del, object_getClassName(del), r); return r; }
static id my_add(id s, SEL c, NSNotificationName n, id obj, NSOperationQueue *q, id b) {
    id tok = ((id(*)(id,SEL,id,id,id,id))origAdd)(s, c, n, obj, q, b);
    if ([n hasPrefix:@"PMNearby"]) { [tokens addObject:tok]; [nearbyTokens addObject:[NSValue valueWithPointer:(__bridge void*)tok]]; }
    return tok;
}
static void my_rm1(id s, SEL c, id o) {
    if (phase) printf("  [%s] removeObserver: %s%s\n", phase, object_getClassName(o), [nearbyTokens containsObject:[NSValue valueWithPointer:(__bridge void*)o]] ? "  <= PMNearby token" : "");
    ((void(*)(id,SEL,id))origRm1)(s, c, o);
}
static void my_rm2(id s, SEL c, id o, id n, id obj) {
    if (phase) printf("  [%s] removeObserver:name:%s\n", phase, n ? [n UTF8String] : "nil");
    ((void(*)(id,SEL,id,id,id))origRm2)(s, c, o, n, obj);
}
static void my_dealloc(id s, SEL c) { const char *p = phase; phase = "dealloc"; printf(" dealloc begin %p\n", s); ((void(*)(id,SEL))origDealloc)(s, c); printf(" dealloc end\n"); phase = p; }
static void my_stop(id s, SEL c) { const char *p = phase; phase = "stopListening"; printf(" stopListening begin\n"); ((void(*)(id,SEL))origStop)(s, c); printf(" stopListening end\n"); phase = p; }
int main(void) { @autoreleasepool {
    tokens = [NSMutableArray new]; nearbyTokens = [NSMutableSet new];
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PrintingPrivate.framework/Versions/A/Plugins/PrintingUI.bundle"] load];
    Class NC = [NSNotificationCenter class], PLC = NSClassFromString(@"PMPrinterListController");
    origAdd = method_setImplementation(class_getInstanceMethod(NC, @selector(addObserverForName:object:queue:usingBlock:)), (IMP)my_add);
    origRm1 = method_setImplementation(class_getInstanceMethod(NC, @selector(removeObserver:)), (IMP)my_rm1);
    origRm2 = method_setImplementation(class_getInstanceMethod(NC, @selector(removeObserver:name:object:)), (IMP)my_rm2);
    origDealloc = method_setImplementation(class_getInstanceMethod(PLC, NSSelectorFromString(@"dealloc")), (IMP)my_dealloc);
    origInit2 = method_setImplementation(class_getInstanceMethod(PLC, NSSelectorFromString(@"initWithPrintInfo:")), (IMP)my_init2);
    origBWD = method_setImplementation(class_getClassMethod(NSClassFromString(@"PKPrinterBrowser"), NSSelectorFromString(@"browserWithDelegate:")), (IMP)my_bwd);
    origStop = method_setImplementation(class_getInstanceMethod(PLC, NSSelectorFromString(@"stopListeningForPMPrinterListChanged")), (IMP)my_stop);
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSTimer *t = [NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *x) { [app abortModal]; }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
    @autoreleasepool { [[NSPrintPanel printPanel] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]]; }
    printf("panel closed; PMNearby tokens registered: %lu\n", (unsigned long)tokens.count);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    printf("breaking cycle: removing PMNearby tokens ourselves (phase=workaround)\n");
    @autoreleasepool { phase = "workaround";
    for (id tok in tokens) [[NSNotificationCenter defaultCenter] removeObserver:tok];
    phase = NULL;
    [tokens removeAllObjects]; }
    printf("tokens released\n");
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    printf("opening 2nd panel (cycle broken for 1st)\n");
    phase = "panel2";
    NSTimer *t2 = [NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *x) { [app abortModal]; }];
    [[NSRunLoop mainRunLoop] addTimer:t2 forMode:NSModalPanelRunLoopMode];
    @autoreleasepool { [[NSPrintPanel printPanel] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]]; }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    phase = NULL;
    printf("removing panel2 tokens too\n");
    @autoreleasepool { for (id tok in tokens) [[NSNotificationCenter defaultCenter] removeObserver:tok]; [tokens removeAllObjects]; }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    printf("done\n");
}}
