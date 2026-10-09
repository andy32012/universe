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

// Godot's generated plugin file calls these (C++ linkage, as it declares them in Objective-C++). Nothing to do:
// the swap above happens when the class loads. Calling them also makes sure this object file is linked in.
void sharelog_init() {}
void sharelog_deinit() {}
