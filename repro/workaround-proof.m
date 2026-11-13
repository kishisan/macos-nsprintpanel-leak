// clang -fno-objc-arc fix.m -framework AppKit -o fix ; ./fix N [--workaround]
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>

static NSMutableArray *tokens;
static int deallocs;
static IMP origAdd, origDealloc;

static double footprintMB(void) {
    task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS ? i.phys_footprint / 1048576.0 : -1;
}
static id my_add(id s, SEL _c, NSNotificationName n, id obj, NSOperationQueue *q, void (^b)(NSNotification*)) {
    id tok = ((id(*)(id,SEL,id,id,id,id))origAdd)(s, _c, n, obj, q, b);
    if ([n isEqualToString:@"PMNearbyPrinterAddedNotification"] || [n isEqualToString:@"PMNearbyPrinterRemovedNotification"]) [tokens addObject:tok];
    return tok;
}
static void my_dealloc(id s, SEL _c) { deallocs++; ((void(*)(id,SEL))origDealloc)(s, _c); }

int main(int argc, char **argv) { @autoreleasepool {
    int n = argc > 1 ? atoi(argv[1]) : 10;
    BOOL wa = argc > 2 && !strcmp(argv[2], "--workaround");
    tokens = [NSMutableArray new];
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PrintingPrivate.framework/Versions/A/Plugins/PrintingUI.bundle"] load];
    Method m = class_getInstanceMethod([NSNotificationCenter class], @selector(addObserverForName:object:queue:usingBlock:));
    origAdd = method_setImplementation(m, (IMP)my_add);
    Method d = class_getInstanceMethod(NSClassFromString(@"PMPrinterListController"), NSSelectorFromString(@"dealloc"));
    origDealloc = method_setImplementation(d, (IMP)my_dealloc);

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    printf("mode=%s  start %.1f MB\n", wa ? "workaround" : "plain", footprintMB());
    for (int i = 1; i <= n; i++) {
        @autoreleasepool {
            NSTimer *t = [NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *x) { [app abortModal]; }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
            [[NSPrintPanel printPanel] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
        }
        if (wa) { for (id tok in tokens) [[NSNotificationCenter defaultCenter] removeObserver:tok]; [tokens removeAllObjects]; }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        printf("%3d  %7.1f MB   PMPrinterListController deallocs=%d\n", i, footprintMB(), deallocs);
    }
}}
