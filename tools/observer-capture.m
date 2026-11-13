// Does the observer block capture the PMPrinterListController, or is it passed as object:?
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
static IMP origAdd, origInit;
static void *current;   // controller whose -initWithPrintInfo: is running
struct BlockLayout { void *isa; int flags; int reserved; void *invoke; void *desc; };
static id my_init(id s, SEL c, id pi) { void *prev = current; current = s; id r = ((id(*)(id,SEL,id))origInit)(s, c, pi); current = prev; return r; }
static id my_add(id s, SEL c, NSNotificationName n, id obj, NSOperationQueue *q, id b) {
    if (current && [n hasPrefix:@"PMNearby"]) {
        size_t sz = malloc_size((__bridge void *)b);  // heap block? 0 => stack/global block (copied by callee)
        struct BlockLayout *bl = (__bridge void *)b;
        size_t descSize = ((size_t *)bl->desc)[1];   // Block_descriptor_1: reserved, size
        BOOL captured = NO; int slot = -1;
        void **words = (void **)bl;
        for (size_t i = sizeof(struct BlockLayout)/sizeof(void*); i < descSize/sizeof(void*); i++) if (words[i] == current) { captured = YES; slot = (int)i; }
        printf("%s\n  object: arg = %s\n  observer block (size %zu, heap=%s) captures controller: %s (slot %d)\n  queue = %s\n",
               n.UTF8String, obj ? object_getClassName(obj) : "nil", descSize, sz ? "yes" : "no(stack)", captured ? "YES" : "no", slot,
               q ? (q == [NSOperationQueue mainQueue] ? "mainQueue" : "other") : "nil");
        // also report flags: BLOCK_HAS_COPY_DISPOSE (1<<25) means captured objects are retained on copy
        printf("  block flags has_copy_dispose=%s\n", (bl->flags & (1<<25)) ? "yes" : "no");
    }
    return ((id(*)(id,SEL,id,id,id,id))origAdd)(s, c, n, obj, q, b);
}
int main(void) { @autoreleasepool {
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PrintingPrivate.framework/Versions/A/Plugins/PrintingUI.bundle"] load];
    origAdd = method_setImplementation(class_getInstanceMethod([NSNotificationCenter class], @selector(addObserverForName:object:queue:usingBlock:)), (IMP)my_add);
    origInit = method_setImplementation(class_getInstanceMethod(NSClassFromString(@"PMPrinterListController"), NSSelectorFromString(@"initWithPrintInfo:")), (IMP)my_init);
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSTimer *t = [NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *x) { [app abortModal]; }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
    [[NSPrintPanel printPanel] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
}}
