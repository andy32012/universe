// The iPad's share sheet for a file, for the settings panel's 分享記錄檔 button.
//
// Godot has no share API, and a plugin that talks to the engine must be built against its source. This one
// needs neither: the game calls OS.shell_open("universe-share://file?path=<percent-encoded absolute path>"),
// which Godot passes to UIApplication's canOpenURL: and openURL:options:completionHandler:. Those two are
// swapped here, at load, for versions that recognise this address and present a UIActivityViewController
// with the file (AirDrop, Messages, Mail, Save to Files...); every other address goes through unchanged.
//
// Built into sharelog.a by .github/workflows/godot-ios.yml; sharelog.gdip lists it for Godot's iOS export.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kUniverseShareScheme = @"universe-share";

static UIViewController *universe_top_controller(void) {
	UIWindow *window = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) { window = w; break; }
			if (!window) window = w;
		}
	}
	UIViewController *vc = window.rootViewController;
	while (vc.presentedViewController) vc = vc.presentedViewController;
	return vc;
}

static void universe_share(NSURL *address) {
	NSURLComponents *parts = [NSURLComponents componentsWithURL:address resolvingAgainstBaseURL:NO];
	NSString *path = nil;
	for (NSURLQueryItem *item in parts.queryItems) {
		if ([item.name isEqualToString:@"path"]) path = item.value;
	}
	if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) return;
	NSURL *file = [NSURL fileURLWithPath:path];
	dispatch_async(dispatch_get_main_queue(), ^{
		UIViewController *top = universe_top_controller();
		if (!top) return;
		UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ file ] applicationActivities:nil];
		// on iPad the sheet is a popover and needs an anchor: the middle of the screen, no arrow
		UIPopoverPresentationController *pop = sheet.popoverPresentationController;
		if (pop) {
			pop.sourceView = top.view;
			pop.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
			pop.permittedArrowDirections = 0;
		}
		[top presentViewController:sheet animated:YES completion:nil];
	});
}

@implementation UIApplication (UniverseShare)

- (BOOL)universe_canOpenURL:(NSURL *)url {
	if ([url.scheme isEqualToString:kUniverseShareScheme]) return YES;
	return [self universe_canOpenURL:url];   // the original, after the swap
}

- (void)universe_openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options completionHandler:(void (^)(BOOL))completion {
	if ([url.scheme isEqualToString:kUniverseShareScheme]) {
		universe_share(url);
		if (completion) completion(YES);
		return;
	}
	[self universe_openURL:url options:options completionHandler:completion];
}

+ (void)load {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		SEL pairs[2][2] = {
			{ @selector(canOpenURL:), @selector(universe_canOpenURL:) },
			{ @selector(openURL:options:completionHandler:), @selector(universe_openURL:options:completionHandler:) } };
		for (int i = 0; i < 2; i++) {
			Method original = class_getInstanceMethod(self, pairs[i][0]);
			Method replacement = class_getInstanceMethod(self, pairs[i][1]);
			if (original && replacement) method_exchangeImplementations(original, replacement);
		}
	});
}

@end

// ---------- what only native code can see, for the game's log (diagnostics.gd) ----------
// Every 2 seconds Documents/native-status.json gets the thermal state, low power mode, the app's memory
// footprint (what iOS counts against it), how much more iOS would give it, and the use of every CPU core since
// the last sample; Documents/native-events.log gets a line whenever one of those states changes or iOS warns about
// memory. Godot's user:// is the Documents folder, so the game reads both.

#import <mach/mach.h>
#import <os/proc.h>

static NSString *universe_docs(void) {
	return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static void universe_event(NSString *text) {
	NSDateFormatter *f = [NSDateFormatter new];
	f.dateFormat = @"HH:mm:ss";
	NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:NSDate.date], text];
	NSString *path = [universe_docs() stringByAppendingPathComponent:@"native-events.log"];
	NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!h) {
		[line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		return;
	}
	[h seekToEndOfFile];
	[h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	[h closeFile];
}

static processor_info_array_t universe_prev_cpu = NULL;
static mach_msg_type_number_t universe_prev_cpu_count = 0;

// per-core use (percent) since the last call
static NSArray<NSNumber *> *universe_cores(void) {
	natural_t n = 0;
	processor_info_array_t info = NULL;
	mach_msg_type_number_t count = 0;
	if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) != KERN_SUCCESS) return @[];
	NSMutableArray *out = [NSMutableArray array];
	for (natural_t i = 0; i < n; i++) {
		integer_t *now = &info[i*CPU_STATE_MAX];
		double user = now[CPU_STATE_USER], sys = now[CPU_STATE_SYSTEM], nice = now[CPU_STATE_NICE], idle = now[CPU_STATE_IDLE];
		if (universe_prev_cpu && universe_prev_cpu_count == count) {
			integer_t *was = &universe_prev_cpu[i*CPU_STATE_MAX];
			user -= was[CPU_STATE_USER]; sys -= was[CPU_STATE_SYSTEM]; nice -= was[CPU_STATE_NICE]; idle -= was[CPU_STATE_IDLE];
		}
		double total = user + sys + nice + idle;
		[out addObject:@(total > 0 ? 100.0*(user + sys + nice)/total : 0.0)];
	}
	if (universe_prev_cpu) vm_deallocate(mach_task_self(), (vm_address_t)universe_prev_cpu, universe_prev_cpu_count*sizeof(integer_t));
	universe_prev_cpu = info;
	universe_prev_cpu_count = count;
	return out;
}

// the app's memory as iOS counts it against the app (what it closes apps for), MB
static double universe_footprint(void) {
	task_vm_info_data_t vm;
	mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
	return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &c) == KERN_SUCCESS ? vm.phys_footprint/1048576.0 : 0;
}

static void universe_status(void) {
	NSProcessInfo *pi = NSProcessInfo.processInfo;
	double footprint = universe_footprint();
	double available = os_proc_available_memory()/1048576.0;
	NSArray<NSNumber *> *cores = universe_cores();
	double busiest = 0;
	for (NSNumber *v in cores) busiest = MAX(busiest, v.doubleValue);
	NSDictionary *d = @{@"thermal": @((int)pi.thermalState), @"lowPower": @(pi.lowPowerModeEnabled),
		@"footprintMB": @(footprint), @"availableMB": @(available), @"cores": cores, @"busiest": @(busiest)};
	NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
	[json writeToFile:[universe_docs() stringByAppendingPathComponent:@"native-status.json"] atomically:YES];
}

static NSString *universe_heat(NSProcessInfoThermalState s) {
	switch (s) {
		case NSProcessInfoThermalStateNominal: return @"正常";
		case NSProcessInfoThermalStateFair: return @"偏熱";
		case NSProcessInfoThermalStateSerious: return @"很熱";
		default: return @"危急";
	}
}

// Godot's generated plugin file calls these at start-up and exit (C++ linkage, as it declares them in Objective-C++).
void sharelog_init() {
	dispatch_async(dispatch_get_main_queue(), ^{
		// a fresh events file for this run
		[@"" writeToFile:[universe_docs() stringByAppendingPathComponent:@"native-events.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
		NSProcessInfo *pi = NSProcessInfo.processInfo;
		universe_event([NSString stringWithFormat:@"原生監控啟動：溫度%@，低耗電模式%@，系統還能給 %.0f MB", universe_heat(pi.thermalState),
			pi.lowPowerModeEnabled ? @"開" : @"關", os_proc_available_memory()/1048576.0]);
		NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
		[nc addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			universe_event([NSString stringWithFormat:@"溫度變成%@", universe_heat(NSProcessInfo.processInfo.thermalState)]);
		}];
		[nc addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			universe_event(NSProcessInfo.processInfo.lowPowerModeEnabled ? @"低耗電模式打開" : @"低耗電模式關閉");
		}];
		[nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			universe_event([NSString stringWithFormat:@"記憶體警告（App 用 %.0f MB，系統還能給 %.0f MB）", universe_footprint(), os_proc_available_memory()/1048576.0]);
			universe_status();
		}];
		universe_status();
		[NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { universe_status(); }];
	});
}

void sharelog_deinit() {}
