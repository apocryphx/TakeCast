//
//  TakeCastFlowUITests.m
//  TakeCastUITests
//
//  Walks the V1 screens a first-time user meets: Onboarding, Setup, the Live
//  screen while stopped, and Recordings. Never presses REC. Keeps a screenshot
//  of each screen in the result bundle for review.
//

#import <XCTest/XCTest.h>

@interface TakeCastFlowUITests : XCTestCase
@end

@implementation TakeCastFlowUITests

- (void)setUp {
    self.continueAfterFailure = NO;
}

- (void)_snapshot:(XCUIApplication *)app named:(NSString *)name {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

- (void)testFirstLaunchThroughSetupToLiveAndRecordings {
    XCUIApplication *app = [[XCUIApplication alloc] init];
    // The argument domain wins over saved defaults, so every run starts as a first launch.
    app.launchArguments = @[@"-ESOnboardingCompleted", @"NO"];
    [app launch];

    XCTAssertTrue([app.navigationBars[@"Welcome to TakeCast"] waitForExistenceWithTimeout:10]);
    [self _snapshot:app named:@"1-onboarding"];

    XCUIElement *helper = app.buttons[@"Someone else is setting up YouTube for me"];
    XCTAssertTrue(helper.exists);
    [helper tap];
    XCTAssertTrue([app.navigationBars[@"For your helper"] waitForExistenceWithTimeout:5]);
    [self _snapshot:app named:@"2-helper"];
    [app.navigationBars.buttons.firstMatch tap];

    XCUIElement *continueButton = app.buttons[@"Continue to Setup"];
    for (int i = 0; i < 6 && !continueButton.isHittable; i++) [app swipeUp];
    [self _snapshot:app named:@"3-onboarding-end"];
    [continueButton tap];

    XCTAssertTrue([app.navigationBars[@"Setup"] waitForExistenceWithTimeout:5]);
    [self _snapshot:app named:@"4-setup"];
    XCUIElement *advanced = app.staticTexts[@"Advanced"];
    if (advanced.exists) [advanced tap];
    for (int i = 0; i < 3; i++) [app swipeUp];
    [self _snapshot:app named:@"5-setup-checks"];

    XCUIElement *go = app.buttons[@"Go to camera"];
    for (int i = 0; i < 4 && !go.isHittable; i++) [app swipeUp];
    [go tap];

    XCUIElement *recordings = app.buttons[@"Recordings"];
    XCTAssertTrue([recordings waitForExistenceWithTimeout:5]);
    XCTAssertTrue(app.buttons[@"Setup"].exists);
    XCTAssertTrue(app.buttons[@"REC"].exists);
    [self _snapshot:app named:@"6-live-idle"];

    [recordings tap];
    XCTAssertTrue([app.navigationBars[@"Recordings"] waitForExistenceWithTimeout:5]);
    [self _snapshot:app named:@"7-recordings"];
}

@end
