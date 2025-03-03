//
//  AmplitudeTests.m
//  Amplitude
//
//  Created by Daniel Jih on 8/7/15.
//  Copyright (c) 2015 Amplitude. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <OCMock/OCMock.h>
#import "Amplitude.h"
#import "AMPConstants.h"
#import "Amplitude+Test.h"
#import "BaseTestCase.h"
#import "AMPDeviceInfo.h"
#import "AMPUtils.h"
#import "AMPEventUtils.h"
#import "AMPTrackingOptions.h"
#import "AMPPlan.h"
#import "AMPIngestionMetadata.h"
#import "AMPServerZone.h"

@interface Amplitude (Tests)

@property (nonatomic, assign) bool initialized;

- (NSDictionary*)mergeEventsAndIdentifys:(NSMutableArray*)events identifys:(NSMutableArray*)identifys numEvents:(long) numEvents;
- (id)truncate:(id) obj;
- (long long)getNextSequenceNumber;

@end

@interface AmplitudeTests : BaseTestCase

@end

@implementation AmplitudeTests {
    id _sharedSessionMock;
    int _connectionCallCount;
}

- (void)setUp {
    [super setUp];
    _sharedSessionMock = [OCMockObject partialMockForObject:[NSURLSession sharedSession]];
    _connectionCallCount = 0;
    [self.amplitude initializeApiKey:apiKey];
}

- (void)tearDown {
    [_sharedSessionMock stopMocking];
}

- (void)setupAsyncResponse: (NSMutableDictionary*) serverResponse {
    [[[_sharedSessionMock stub] andDo:^(NSInvocation *invocation) {
        self->_connectionCallCount++;
        void (^handler)(NSURLResponse*, NSData*, NSError*);
        [invocation getArgument:&handler atIndex:3];
        handler(serverResponse[@"data"], serverResponse[@"response"], serverResponse[@"error"]);
    }] dataTaskWithRequest:OCMOCK_ANY completionHandler:OCMOCK_ANY];
}

- (void)testInstanceWithName {
    Amplitude *a = [Amplitude instance];
    Amplitude *b = [Amplitude instanceWithName:@""];
    Amplitude *c = [Amplitude instanceWithName:nil];
    Amplitude *e = [Amplitude instanceWithName:kAMPDefaultInstance];
    Amplitude *f = [Amplitude instanceWithName:@"app1"];
    Amplitude *g = [Amplitude instanceWithName:@"app2"];

    XCTAssertEqual(a, b);
    XCTAssertEqual(b, c);
    XCTAssertEqual(c, e);
    XCTAssertEqual(e, a);
    XCTAssertEqual(e, [Amplitude instance]);
    XCTAssertNotEqual(e,f);
    XCTAssertEqual(f, [Amplitude instanceWithName:@"app1"]);
    XCTAssertNotEqual(f,g);
    XCTAssertEqual(g, [Amplitude instanceWithName:@"app2"]);
}

- (void)testInitWithInstanceName {
    Amplitude *a = [Amplitude instanceWithName:@"APP1"];
    [a flushQueueWithQueue:a.initializerQueue];
    XCTAssertEqualObjects(a.instanceName, @"app1");
    XCTAssertTrue([a.propertyListPath rangeOfString:@"com.amplitude.plist_app1"].location != NSNotFound);

    Amplitude *b = [Amplitude instanceWithName:[kAMPDefaultInstance uppercaseString]];
    [b flushQueueWithQueue:b.initializerQueue];
    XCTAssertEqualObjects(b.instanceName, kAMPDefaultInstance);
    XCTAssertTrue([b.propertyListPath rangeOfString:@"com.amplitude.plist"].location != NSNotFound);
    XCTAssertTrue([ b.propertyListPath rangeOfString:@"com.amplitude.plist_"].location == NSNotFound);
}

- (void)testInitializeLoadNilUserIdFromEventData {
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nil);
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqual([event objectForKey:@"user_id"], nil);
    XCTAssertFalse([[event allKeys] containsObject:@"user_id"]);
}

- (void)testSeparateInstancesLogEventsSeparate {
    NSString *newInstance1 = @"newApp1";
    NSString *newApiKey1 = @"1234567890";
    NSString *newInstance2 = @"newApp2";
    NSString *newApiKey2 = @"0987654321";

    AMPDatabaseHelper *oldDbHelper = [AMPDatabaseHelper getDatabaseHelper];
    AMPDatabaseHelper *newDBHelper1 = [AMPDatabaseHelper getDatabaseHelper:newInstance1];
    AMPDatabaseHelper *newDBHelper2 = [AMPDatabaseHelper getDatabaseHelper:newInstance2];

    // reset databases
    [oldDbHelper resetDB:NO];
    [newDBHelper1 resetDB:NO];
    [newDBHelper2 resetDB:NO];

    // setup existing database file, init default instance
    [oldDbHelper insertOrReplaceKeyLongValue:@"sequence_number" value:[NSNumber numberWithLongLong:1000]];
    [oldDbHelper addEvent:@"{\"event_type\":\"oldEvent\"}"];
    [oldDbHelper addIdentify:@"{\"event_type\":\"$identify\"}"];
    [oldDbHelper addIdentify:@"{\"event_type\":\"$identify\"}"];

    [[Amplitude instance] setDeviceId:@"oldDeviceId"];
    [[Amplitude instance] flushQueue];
    XCTAssertEqualObjects([oldDbHelper getValue:@"device_id"], @"oldDeviceId");
    XCTAssertEqualObjects([[Amplitude instance] getDeviceId], @"oldDeviceId");
    XCTAssertEqual([[Amplitude instance] getNextSequenceNumber], 1001);

    XCTAssertNil([newDBHelper1 getValue:@"device_id"]);
    XCTAssertNil([newDBHelper2 getValue:@"device_id"]);
    XCTAssertEqualObjects([oldDbHelper getLongValue:@"sequence_number"], [NSNumber numberWithLongLong:1001]);
    XCTAssertNil([newDBHelper1 getLongValue:@"sequence_number"]);
    XCTAssertNil([newDBHelper2 getLongValue:@"sequence_number"]);

    // init first new app and verify separate database
    [[Amplitude instanceWithName:newInstance1] initializeApiKey:newApiKey1];
    [[Amplitude instanceWithName:newInstance1] flushQueue];
    XCTAssertNotEqualObjects([[Amplitude instanceWithName:newInstance1] getDeviceId], @"oldDeviceId");
    XCTAssertEqualObjects([[Amplitude instanceWithName:newInstance1] getDeviceId], [newDBHelper1 getValue:@"device_id"]);
    XCTAssertEqual([[Amplitude instanceWithName:newInstance1] getNextSequenceNumber], 1);
    XCTAssertEqual([newDBHelper1 getEventCount], 0);
    XCTAssertEqual([newDBHelper1 getIdentifyCount], 0);

    // init second new app and verify separate database
    [[Amplitude instanceWithName:newInstance2] initializeApiKey:newApiKey2];
    [[Amplitude instanceWithName:newInstance2] flushQueue];
    XCTAssertNotEqualObjects([[Amplitude instanceWithName:newInstance2] getDeviceId], @"oldDeviceId");
    XCTAssertEqualObjects([[Amplitude instanceWithName:newInstance2] getDeviceId], [newDBHelper2 getValue:@"device_id"]);
    XCTAssertEqual([[Amplitude instanceWithName:newInstance2] getNextSequenceNumber], 1);
    XCTAssertEqual([newDBHelper2 getEventCount], 0);
    XCTAssertEqual([newDBHelper2 getIdentifyCount], 0);

    // verify old database still intact
    XCTAssertEqualObjects([oldDbHelper getValue:@"device_id"], @"oldDeviceId");
    XCTAssertEqualObjects([oldDbHelper getLongValue:@"sequence_number"], [NSNumber numberWithLongLong:1001]);
    XCTAssertEqual([oldDbHelper getEventCount], 1);
    XCTAssertEqual([oldDbHelper getIdentifyCount], 2);

    // verify both apps can modify database independently and not affect old database
    [[Amplitude instanceWithName:newInstance1] setDeviceId:@"fakeDeviceId"];
    [[Amplitude instanceWithName:newInstance1] flushQueue];
    XCTAssertEqualObjects([newDBHelper1 getValue:@"device_id"], @"fakeDeviceId");
    XCTAssertNotEqualObjects([newDBHelper2 getValue:@"device_id"], @"fakeDeviceId");
    XCTAssertEqualObjects([oldDbHelper getValue:@"device_id"], @"oldDeviceId");
    [newDBHelper1 addIdentify:@"{\"event_type\":\"$identify\"}"];
    XCTAssertEqual([newDBHelper1 getIdentifyCount], 1);
    XCTAssertEqual([newDBHelper2 getIdentifyCount], 0);
    XCTAssertEqual([oldDbHelper getIdentifyCount], 2);

    [[Amplitude instanceWithName:newInstance2] setDeviceId:@"brandNewDeviceId"];
    [[Amplitude instanceWithName:newInstance2] flushQueue];
    XCTAssertEqualObjects([newDBHelper1 getValue:@"device_id"], @"fakeDeviceId");
    XCTAssertEqualObjects([newDBHelper2 getValue:@"device_id"], @"brandNewDeviceId");
    XCTAssertEqualObjects([oldDbHelper getValue:@"device_id"], @"oldDeviceId");
    [newDBHelper2 addEvent:@"{\"event_type\":\"testEvent2\"}"];
    [newDBHelper2 addEvent:@"{\"event_type\":\"testEvent3\"}"];
    XCTAssertEqual([newDBHelper1 getEventCount], 0);
    XCTAssertEqual([newDBHelper2 getEventCount], 2);
    XCTAssertEqual([oldDbHelper getEventCount], 1);

    [newDBHelper1 deleteDB];
    [newDBHelper2 deleteDB];
}

- (void)testInitializeLoadUserIdFromEventData {
    NSString *instanceName = @"testInitialize";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client flushQueue];
    XCTAssertEqual([client userId], nil);

    NSString *testUserId = @"testUserId";
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:instanceName];
    [dbHelper insertOrReplaceKeyValue:@"user_id" value:testUserId];
    [client initializeApiKey:apiKey];
    [client flushQueue];
    XCTAssertTrue([[client userId] isEqualToString:testUserId]);
}

- (void)testInitializeWithNilUserId {
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nil);

    NSString *nilUserId = nil;
    [self.amplitude initializeApiKey:apiKey userId:nilUserId];
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nilUserId);
    XCTAssertNil([[AMPDatabaseHelper getDatabaseHelper] getValue:@"user_id"]);
}

- (void)testInitializeWithUserId {
    NSString *instanceName = @"testInitializeWithUserId";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client flushQueue];
    XCTAssertEqual([client userId], nil);

    NSString *testUserId = @"testUserId";
    [client initializeApiKey:apiKey userId:testUserId];
    [client flushQueue];
    XCTAssertEqual([client userId], testUserId);
}

- (void)testSkipReinitialization {
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nil);

    NSString *testUserId = @"testUserId";
    [self.amplitude initializeApiKey:apiKey userId:testUserId];
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nil);
}

- (void)testClearUserId {
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nil);

    NSString *testUserId = @"testUserId";
    [self.amplitude setUserId:testUserId];
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], testUserId);
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    NSDictionary *event1 = [self.amplitude getLastEvent];
    XCTAssert([[event1 objectForKey:@"user_id"] isEqualToString:testUserId]);

    NSString *nilUserId = nil;
    [self.amplitude setUserId:nilUserId];
    [self.amplitude flushQueue];
    XCTAssertEqual([self.amplitude userId], nilUserId);
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    NSDictionary *event2 = [self.amplitude getLastEvent];
    XCTAssertEqual([event2 objectForKey:@"user_id"], nilUserId);
    XCTAssertFalse([[event2 allKeys] containsObject:@"user_id"]);
}

- (void)testRequestTooLargeBackoffLogic {
    [self.amplitude setEventUploadThreshold:2];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:413 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"response" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];

    // 413 error force backoff with 2 events --> new upload limit will be 1
    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    // after first 413, the backoffupload batch size should now be 1
    XCTAssertTrue(self.amplitude.backoffUpload);
    XCTAssertEqual(self.amplitude.backoffUploadBatchSize, 1);

    // 3 upload attempts: upload 2 events, upload first event fail -> remove first event, upload second event fail -> remove second event
    XCTAssertEqual(_connectionCallCount, 3);
}

- (void)testRequestTooLargeBackoffRemoveEvent {
    [self.amplitude setEventUploadThreshold:1];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:413 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"response" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];

    // 413 error force backoff with 1 events --> should drop the event
    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    // after first 413, the backoffupload batch size should now be 1
    XCTAssertTrue(self.amplitude.backoffUpload);
    XCTAssertEqual(self.amplitude.backoffUploadBatchSize, 1);
    XCTAssertEqual(_connectionCallCount, 1);
    XCTAssertEqual([self.databaseHelper getEventCount], 0);
}

- (void)testUUIDInEvent {
    [self.amplitude setEventUploadThreshold:5];
    [self.amplitude logEvent:@"event1"];
    [self.amplitude logEvent:@"event2"];
    [self.amplitude flushQueue];

    XCTAssertEqual([self.amplitude queuedEventCount], 2);
    NSArray *events = [[AMPDatabaseHelper getDatabaseHelper] getEvents:-1 limit:-1];
    XCTAssertEqual(2, [[events[1] objectForKey:@"event_id"] intValue]);
    XCTAssertNotNil([events[0] objectForKey:@"uuid"]);
    XCTAssertNotNil([events[1] objectForKey:@"uuid"]);
    XCTAssertNotEqual([events[0] objectForKey:@"uuid"], [events[1] objectForKey:@"uuid"]);
}

- (void)testLogEventSuccess {
    [self.amplitude setEventUploadThreshold:1];
    // configure response body to be random, as we only care about the status code
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"random-response-body" dataUsingEncoding:NSUTF8StringEncoding]
                                           }];

    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    XCTAssertEqual(_connectionCallCount, 1);
    XCTAssertEqual([self.databaseHelper getEventCount], 0);
    XCTAssertEqual([self.databaseHelper getIdentifyCount], 0);
    XCTAssertEqual([self.databaseHelper getTotalEventCount], 0);
}

- (void)testLogEventFailedWithInvalidApiKeyResponse {
    [self.amplitude setEventUploadThreshold:1];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:400 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"invalid_api_key" dataUsingEncoding:NSUTF8StringEncoding]
                                           }];

    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    XCTAssertEqual(_connectionCallCount, 1);
    XCTAssertEqual([self.databaseHelper getEventCount], 1);
    XCTAssertEqual([self.databaseHelper getIdentifyCount], 0);
    XCTAssertEqual([self.databaseHelper getTotalEventCount], 1);
}

- (void)testLogEventFailedWithBadChecksumResponse {
    [self.amplitude setEventUploadThreshold:1];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:400 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"bad_checksum" dataUsingEncoding:NSUTF8StringEncoding]
                                           }];

    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    XCTAssertEqual(_connectionCallCount, 1);
    XCTAssertEqual([self.databaseHelper getEventCount], 1);
    XCTAssertEqual([self.databaseHelper getIdentifyCount], 0);
    XCTAssertEqual([self.databaseHelper getTotalEventCount], 1);
}

- (void)testLogEventFailedWithRequestDbWriteFailedResponse {
    [self.amplitude setEventUploadThreshold:1];
    // Note that "request_db_write_failed" error response might not exist anymore, leave this test to make sure we can handle it.
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:500 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"request_db_write_failed" dataUsingEncoding:NSUTF8StringEncoding]
                                           }];

    [self setupAsyncResponse:serverResponse];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    XCTAssertEqual(_connectionCallCount, 1);
    XCTAssertEqual([self.databaseHelper getEventCount], 1);
    XCTAssertEqual([self.databaseHelper getIdentifyCount], 0);
    XCTAssertEqual([self.databaseHelper getTotalEventCount], 1);
}

- (void)testIdentify {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setEventUploadThreshold:2];

    AMPIdentify *identify = [[AMPIdentify identify] setOnce:@"key1" value:@"value1"];
    [self.amplitude identify:identify];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    NSDictionary *operations = [NSDictionary dictionaryWithObject:@"value1" forKey:@"key1"];
    NSDictionary *expected = [NSDictionary dictionaryWithObject:operations forKey:@"$setOnce"];
    NSDictionary *event = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], IDENTIFY_EVENT);
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], expected);
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], [NSDictionary dictionary]); // event properties should be empty
    XCTAssertEqual(1, [[event objectForKey:@"sequence_number"] intValue]);

    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];
    AMPIdentify *identify2 = [[[AMPIdentify alloc] init] setOnce:@"key2" value:@"value2"];
    [self.amplitude identify:identify2];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 0);
}

- (void)testGroupIdentify {
    NSString *groupType = @"test group type";
    NSString *groupName = @"test group name";
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setEventUploadThreshold:2];

    AMPIdentify *identify = [[AMPIdentify identify] set:@"key1" value:@"value1"];
    [self.amplitude groupIdentifyWithGroupType:groupType groupName:groupName groupIdentify:identify];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    NSDictionary *operations = [NSDictionary dictionaryWithObject:@"value1" forKey:@"key1"];
    NSDictionary *expected = [NSDictionary dictionaryWithObject:operations forKey:@"$set"];
    NSDictionary *expectedGroups = [NSDictionary dictionaryWithObject:@"test group name" forKey:@"test group type"];
    NSDictionary *event = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], GROUP_IDENTIFY_EVENT);
    XCTAssertEqualObjects([event objectForKey:@"groups"], expectedGroups);
    XCTAssertEqualObjects([event objectForKey:@"group_properties"], expected);
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], [NSDictionary dictionary]);
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], [NSDictionary dictionary]); // event properties should be empty
    XCTAssertEqual(1, [[event objectForKey:@"sequence_number"] intValue]);

    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];
    AMPIdentify *identify2 = [[[AMPIdentify alloc] init] set:@"key2" value:@"value2"];
    [self.amplitude groupIdentifyWithGroupType:groupType groupName:groupName groupIdentify:identify2];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 0);
}

- (void)testLogRevenueV2 {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];

    // ignore invalid revenue objects
    [self.amplitude logRevenueV2:nil];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], 0);

    [self.amplitude logRevenueV2:[AMPRevenue revenue]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], 0);

    // log valid revenue object
    NSNumber *price = [NSNumber numberWithDouble:15.99];
    NSInteger quantity = 15;
    NSString *productId = @"testProductId";
    NSString *revenueType = @"testRevenueType";
    NSDictionary *props = [NSDictionary dictionaryWithObject:@"San Francisco" forKey:@"city"];
    AMPRevenue *revenue = [[[[AMPRevenue revenue] setProductIdentifier:productId] setPrice:price] setQuantity:quantity];
    [[revenue setRevenueType:revenueType] setEventProperties:props];

    [self.amplitude logRevenueV2:revenue];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], 1);

    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], @"revenue_amount");

    NSDictionary *dict = [event objectForKey:@"event_properties"];
    XCTAssertEqualObjects([dict objectForKey:@"$productId"], productId);
    XCTAssertEqualObjects([dict objectForKey:@"$price"], price);
    XCTAssertEqualObjects([dict objectForKey:@"$quantity"], [NSNumber numberWithInteger:quantity]);
    XCTAssertEqualObjects([dict objectForKey:@"$revenueType"], revenueType);
    XCTAssertEqualObjects([dict objectForKey:@"city"], @"San Francisco");

    // user properties should be empty
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], [NSDictionary dictionary]);

    // api properties should not have any revenue info
    NSDictionary *api_props = [event objectForKey:@"api_properties"];
    XCTAssertTrue(api_props.count > 0);
    XCTAssertNil([api_props objectForKey:@"$productId"]);
    XCTAssertNil([api_props objectForKey:@"$price"]);
    XCTAssertNil([api_props objectForKey:@"quantity"]);
    XCTAssertNil([api_props objectForKey:@"revenueType"]);
}

- (void) test{
     NSMutableDictionary *event_properties = [NSMutableDictionary dictionary];
    [event_properties setObject:@"some event description" forKey:@"description"];
    [event_properties setObject:@"green" forKey:@"color"];
    [event_properties setObject:@"productIdentifier" forKey:@"$productId"];
    [event_properties setObject:[NSNumber numberWithDouble:10.99] forKey:@"$price"];
    [event_properties setObject:[NSNumber numberWithInt:2] forKey:@"$quantity"];
    [[Amplitude instance] logEvent:@"Completed Purchase" withEventProperties:event_properties];
}

- (void)testMergeEventsAndIdentifys {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setEventUploadThreshold:7];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    [self.amplitude logEvent:@"test_event1"];
    [self.amplitude identify:[[AMPIdentify identify] add:@"photoCount" value:[NSNumber numberWithInt:1]]];
    [self.amplitude logEvent:@"test_event2"];
    [self.amplitude logEvent:@"test_event3"];
    [self.amplitude logEvent:@"test_event4"];
    [self.amplitude identify:[[AMPIdentify identify] setOnce:@"gender" value:@"male"]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 4);
    XCTAssertEqual([dbHelper getIdentifyCount], 2);
    XCTAssertEqual([dbHelper getTotalEventCount], 6);

    // verify merging
    NSMutableArray *events = [dbHelper getEvents:-1 limit:-1];
    NSMutableArray *identifys = [dbHelper getIdentifys:-1 limit:-1];
    NSDictionary *merged = [self.amplitude mergeEventsAndIdentifys:events identifys:identifys numEvents:[dbHelper getTotalEventCount]];
    NSArray *mergedEvents = [merged objectForKey:@"events"];

    XCTAssertEqual(4, [[merged objectForKey:@"max_event_id"] intValue]);
    XCTAssertEqual(2, [[merged objectForKey:@"max_identify_id"] intValue]);
    XCTAssertEqual(6, [mergedEvents count]);

    XCTAssertEqualObjects([mergedEvents[0] objectForKey:@"event_type"], @"test_event1");
    XCTAssertEqual([[mergedEvents[0] objectForKey:@"event_id"] intValue], 1);
    XCTAssertEqual([[mergedEvents[0] objectForKey:@"sequence_number"] intValue], 1);

    XCTAssertEqualObjects([mergedEvents[1] objectForKey:@"event_type"], @"$identify");
    XCTAssertEqual([[mergedEvents[1] objectForKey:@"event_id"] intValue], 1);
    XCTAssertEqual([[mergedEvents[1] objectForKey:@"sequence_number"] intValue], 2);
    XCTAssertEqualObjects([mergedEvents[1] objectForKey:@"user_properties"], [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:1] forKey:@"photoCount"] forKey:@"$add"]);

    XCTAssertEqualObjects([mergedEvents[2] objectForKey:@"event_type"], @"test_event2");
    XCTAssertEqual([[mergedEvents[2] objectForKey:@"event_id"] intValue], 2);
    XCTAssertEqual([[mergedEvents[2] objectForKey:@"sequence_number"] intValue], 3);

    XCTAssertEqualObjects([mergedEvents[3] objectForKey:@"event_type"], @"test_event3");
    XCTAssertEqual([[mergedEvents[3] objectForKey:@"event_id"] intValue], 3);
    XCTAssertEqual([[mergedEvents[3] objectForKey:@"sequence_number"] intValue], 4);

    XCTAssertEqualObjects([mergedEvents[4] objectForKey:@"event_type"], @"test_event4");
    XCTAssertEqual([[mergedEvents[4] objectForKey:@"event_id"] intValue], 4);
    XCTAssertEqual([[mergedEvents[4] objectForKey:@"sequence_number"] intValue], 5);

    XCTAssertEqualObjects([mergedEvents[5] objectForKey:@"event_type"], @"$identify");
    XCTAssertEqual([[mergedEvents[5] objectForKey:@"event_id"] intValue], 2);
    XCTAssertEqual([[mergedEvents[5] objectForKey:@"sequence_number"] intValue], 6);
    XCTAssertEqualObjects([mergedEvents[5] objectForKey:@"user_properties"], [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"male" forKey:@"gender"] forKey:@"$setOnce"]);

    [self.amplitude identify:[[AMPIdentify identify] unset:@"karma"]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 0);
}

-(void)testMergeEventsBackwardsCompatible {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude identify:[[AMPIdentify identify] unset:@"key"]];
    [self.amplitude logEvent:@"test_event"];
    [self.amplitude flushQueue];

    // reinsert test event without sequence_number
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:[self.amplitude getLastEvent]];
    [event removeObjectForKey:@"sequence_number"];
    long eventId = [[event objectForKey:@"event_id"] longValue];
    [dbHelper removeEvent:eventId];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [dbHelper addEvent:jsonString];

    // the event without sequence number should be ordered before the identify
    NSMutableArray *events = [dbHelper getEvents:-1 limit:-1];
    NSMutableArray *identifys = [dbHelper getIdentifys:-1 limit:-1];
    NSDictionary *merged = [self.amplitude mergeEventsAndIdentifys:events identifys:identifys numEvents:[dbHelper getTotalEventCount]];
    NSArray *mergedEvents = [merged objectForKey:@"events"];
    XCTAssertEqualObjects([mergedEvents[0] objectForKey:@"event_type"], @"test_event");
    XCTAssertNil([mergedEvents[0] objectForKey:@"sequence_number"]);
    XCTAssertEqualObjects([mergedEvents[1] objectForKey:@"event_type"], @"$identify");
    XCTAssertEqual(1, [[mergedEvents[1] objectForKey:@"sequence_number"] intValue]);
}

-(void)testTruncateLongStrings {
    NSString *longString = [@"" stringByPaddingToLength:kAMPMaxStringLength*2 withString: @"c" startingAtIndex:0];
    XCTAssertEqual([longString length], kAMPMaxStringLength*2);
    NSString *truncatedString = [self.amplitude truncate:longString];
    XCTAssertEqual([truncatedString length], kAMPMaxStringLength);
    XCTAssertEqualObjects(truncatedString, [@"" stringByPaddingToLength:kAMPMaxStringLength withString: @"c" startingAtIndex:0]);

    NSString *shortString = [@"" stringByPaddingToLength:kAMPMaxStringLength-1 withString: @"c" startingAtIndex:0];
    XCTAssertEqual([shortString length], kAMPMaxStringLength-1);
    truncatedString = [self.amplitude truncate:shortString];
    XCTAssertEqual([truncatedString length], kAMPMaxStringLength-1);
    XCTAssertEqualObjects(truncatedString, shortString);
}

-(void)testTruncateNullObjects {
    XCTAssertNil([self.amplitude truncate:nil]);
}

-(void)testTruncateDictionary {
    NSString *longString = [@"" stringByPaddingToLength:kAMPMaxStringLength*2 withString: @"c" startingAtIndex:0];
    NSString *truncString = [@"" stringByPaddingToLength:kAMPMaxStringLength withString: @"c" startingAtIndex:0];
    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    [object setValue:[NSNumber numberWithInt:10] forKey:@"int value"];
    [object setValue:[NSNumber numberWithBool:NO] forKey:@"bool value"];
    [object setValue:longString forKey:@"long string"];
    [object setValue:[NSArray arrayWithObject:longString] forKey:@"array"];
    [object setValue:longString forKey:AMP_REVENUE_RECEIPT];

    object = [self.amplitude truncate:object];
    XCTAssertEqual([[object objectForKey:@"int value"] intValue], 10);
    XCTAssertFalse([[object objectForKey:@"bool value"] boolValue]);
    XCTAssertEqual([[object objectForKey:@"long string"] length], kAMPMaxStringLength);
    XCTAssertEqual([[object objectForKey:@"array"] count], 1);
    XCTAssertEqualObjects([object objectForKey:@"array"][0], truncString);
    XCTAssertEqual([[object objectForKey:@"array"][0] length], kAMPMaxStringLength);

    // receipt field should not be truncated
    XCTAssertEqualObjects([object objectForKey:AMP_REVENUE_RECEIPT], longString);
}

-(void)testTruncateEventAndIdentify {
    [self.amplitude setEventUploadThreshold:5];

    NSString *longString = [@"" stringByPaddingToLength:kAMPMaxStringLength*2 withString: @"c" startingAtIndex:0];
    NSString *truncString = [@"" stringByPaddingToLength:kAMPMaxStringLength withString: @"c" startingAtIndex:0];

    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:longString, @"long_string", longString, AMP_REVENUE_RECEIPT, nil];
    [self.amplitude logEvent:@"test" withEventProperties:props];
    [self.amplitude identify:[[AMPIdentify identify] setOnce:@"long_string" value:longString]];
    [self.amplitude identify:[[AMPIdentify identify] set:@"long_string" value:longString]];
    [self.amplitude flushQueue];

    NSDictionary *event = [self.amplitude getLastEvent];
    NSDictionary *expected = [NSDictionary dictionaryWithObjectsAndKeys:truncString, @"long_string", longString, AMP_REVENUE_RECEIPT, nil];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], @"test");
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], expected);

    NSDictionary *identify = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects([identify objectForKey:@"event_type"], @"$identify");
    XCTAssertEqualObjects([identify objectForKey:@"user_properties"], [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:truncString forKey:@"long_string"] forKey:@"$setOnce"]);

    NSDictionary *interceptedIdentify = [self.amplitude getLastInterceptedIdentify];
    XCTAssertEqualObjects([interceptedIdentify objectForKey:@"event_type"], @"$identify");
    XCTAssertEqualObjects([interceptedIdentify objectForKey:@"user_properties"], [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:truncString forKey:@"long_string"] forKey:@"$set"]);
}

-(void)testAutoIncrementSequenceNumber {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    int limit = 10;
    for (int i = 0; i < limit; i++) {
        XCTAssertEqual([dbHelper getNextSequenceNumber], i+1);
        XCTAssertEqual([[dbHelper getLongValue:@"sequence_number"] intValue], i+1);
    }
}

-(void)testSetOffline {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    [self.amplitude setOffline:YES];
    [self.amplitude logEvent:@"test"];
    [self.amplitude logEvent:@"test"];
    [self.amplitude identify:[[AMPIdentify identify] setOnce:@"key" value:@"value"]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 2);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 3);

    [self.amplitude setOffline:NO];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 0);
}

-(void)testSetOfflineTruncate {
    int eventMaxCount = 3;
    self.amplitude.eventMaxCount = eventMaxCount;

    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    [self.amplitude setOffline:YES];
    [self.amplitude logEvent:@"test1"];
    [self.amplitude logEvent:@"test2"];
    [self.amplitude logEvent:@"test3"];
    [self.amplitude identify:[[AMPIdentify identify] unset:@"key1"]];
    [self.amplitude identify:[[AMPIdentify identify] unset:@"key2"]];
    [self.amplitude identify:[[AMPIdentify identify] unset:@"key3"]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 3);
    XCTAssertEqual([dbHelper getIdentifyCount], 3);
    XCTAssertEqual([dbHelper getTotalEventCount], 6);

    [self.amplitude logEvent:@"test4"];
    [self.amplitude identify:[[AMPIdentify identify] unset:@"key4"]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 3);
    XCTAssertEqual([dbHelper getIdentifyCount], 3);
    XCTAssertEqual([dbHelper getTotalEventCount], 6);

    NSMutableArray *events = [dbHelper getEvents:-1 limit:-1];
    XCTAssertEqual([events count], 3);
    XCTAssertEqualObjects([events[0] objectForKey:@"event_type"], @"test2");
    XCTAssertEqualObjects([events[1] objectForKey:@"event_type"], @"test3");
    XCTAssertEqualObjects([events[2] objectForKey:@"event_type"], @"test4");

    NSMutableArray *identifys = [dbHelper getIdentifys:-1 limit:-1];
    XCTAssertEqual([identifys count], 3);
    XCTAssertEqualObjects([[[identifys[0] objectForKey:@"user_properties"] objectForKey:@"$unset"] objectForKey:@"key2"], @"-");
    XCTAssertEqualObjects([[[identifys[1] objectForKey:@"user_properties"] objectForKey:@"$unset"] objectForKey:@"key3"], @"-");
    XCTAssertEqualObjects([[[identifys[2] objectForKey:@"user_properties"] objectForKey:@"$unset"] objectForKey:@"key4"], @"-");


    [self.amplitude setOffline:NO];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 0);
}

-(void)testTruncateEventsQueues {
    int eventMaxCount = 50;
    XCTAssertGreaterThanOrEqual(eventMaxCount, kAMPEventRemoveBatchSize);
    self.amplitude.eventMaxCount = eventMaxCount;

    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setOffline:YES];
    for (int i = 0; i < eventMaxCount; i++) {
        [self.amplitude logEvent:@"test"];
    }
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], eventMaxCount);

    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], eventMaxCount - (eventMaxCount/10) + 1);
}

-(void)testTruncateEventsQueuesWithOneEvent {
    int eventMaxCount = 1;
    self.amplitude.eventMaxCount = eventMaxCount;

    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude logEvent:@"test1"];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], eventMaxCount);

    [self.amplitude logEvent:@"test2"];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getEventCount], eventMaxCount);

    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], @"test2");
}

-(void)testInvalidJSONEventProperties {
    NSURL *url = [NSURL URLWithString:@"https://amplitude.com/"];
    NSDictionary *properties = [NSDictionary dictionaryWithObjectsAndKeys:url, url, url, @"url", nil];
    [self.amplitude logEvent:@"test" withEventProperties:properties];
    [self.amplitude flushQueue];
    XCTAssertEqual([[AMPDatabaseHelper getDatabaseHelper] getEventCount], 1);
}

-(void)testClearUserProperties {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setEventUploadThreshold:2];

    [self.amplitude clearUserProperties];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    NSDictionary *expected = [NSDictionary dictionaryWithObject:@"-" forKey:@"$clearAll"];
    NSDictionary *event = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], IDENTIFY_EVENT);
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], expected);
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], [NSDictionary dictionary]); // event properties should be empty
    XCTAssertEqual(1, [[event objectForKey:@"sequence_number"] intValue]);
}

-(void)testSetGroup {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude setGroup:@"orgId" groupName:[NSNumber numberWithInt:15]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    NSDictionary *groups = [NSDictionary dictionaryWithObject:@"15" forKey:@"orgId"];
    NSDictionary *userProperties = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:15] forKey:@"orgId"] forKey:@"$set"];

    NSDictionary *event = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], IDENTIFY_EVENT);
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], userProperties);
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], [NSDictionary dictionary]); // event properties should be empty
    XCTAssertEqualObjects([event objectForKey:@"groups"], groups);
}

-(void)testLogEventWithGroups {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];

    [groups setObject:[NSNumber numberWithInt: 10] forKey:[NSNumber numberWithFloat: 1.23]]; // validateGroups should coerce non-string values into strings
    NSMutableArray *innerArray = [NSMutableArray arrayWithObjects:@"test", [NSNumber numberWithInt:23], nil]; // should ignore nested array
    [groups setObject:[NSArray arrayWithObjects:@"test2", [NSNumber numberWithBool:FALSE], innerArray, [NSNull null], nil] forKey:@"array"]; // should ignore null values
    [groups setObject:[NSDictionary dictionaryWithObject:@"test3" forKey:[NSNumber numberWithDouble:160.0]] forKey:@"dictionary"]; // should ignore dictionary values
    [groups setObject:[NSNull null] forKey:@"null"]; // should ignore null values

    [self.amplitude logEvent:@"test" withEventProperties:nil withGroups:groups outOfSession:NO];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 1);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    NSDictionary *expectedGroups = [NSDictionary dictionaryWithObjectsAndKeys:@"10", @"1.23", @[@"test2", @"0"], @"array", nil];

    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqualObjects([event objectForKey:@"event_type"], @"test");
    XCTAssertEqualObjects([event objectForKey:@"user_properties"], [NSDictionary dictionary]); // user properties should be empty
    XCTAssertEqualObjects([event objectForKey:@"event_properties"], [NSDictionary dictionary]); // event properties should be empty
    XCTAssertEqualObjects([event objectForKey:@"groups"], expectedGroups);
}

-(void)testUnarchiveEventsDict {
    NSString *archiveName = @"test_archive";
    NSDictionary *event = [NSDictionary dictionaryWithObject:@"test event" forKey:@"event_type"];
    XCTAssertTrue([self.amplitude archive:event toFile:archiveName]);

    NSDictionary *unarchived = [self.amplitude unarchive:archiveName];
#if !TARGET_OS_OSX
    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_8_4) {
        XCTAssertEqualObjects(unarchived, event);
    } else {
        XCTAssertNil(unarchived);
    }
#else
    XCTAssertEqualObjects(unarchived, event);
#endif
}

-(void)testBlockTooManyProperties {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];

    NSMutableDictionary *eventProperties = [NSMutableDictionary dictionary];
    NSMutableDictionary *userProperties = [NSMutableDictionary dictionary];
    AMPIdentify *identify = [AMPIdentify identify];
    for (int i = 0; i < kAMPMaxPropertyKeys + 1; i++) {
        [eventProperties setObject:[NSNumber numberWithInt:i] forKey:[NSNumber numberWithInt:i]];
        [userProperties setObject:[NSNumber numberWithInt:i*2] forKey:[NSNumber numberWithInt:i*2]];
        [identify setOnce:[NSString stringWithFormat:@"%d", i] value:[NSNumber numberWithInt:i]];
    }

    // verify that setUserProperties ignores dict completely
    [self.amplitude setUserProperties:userProperties];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getIdentifyCount], 0);

    // verify that event properties and user properties are scrubbed
    [self.amplitude logEvent:@"test event" withEventProperties:eventProperties];
    [self.amplitude identify:identify];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getEventCount], 1);
    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqualObjects(event[@"event_properties"], [NSDictionary dictionary]);
    XCTAssertEqualObjects(event[@"user_properties"], [NSDictionary dictionary]);

    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    NSDictionary *identifyEvent = [self.amplitude getLastIdentify];
    XCTAssertEqualObjects(identifyEvent[@"event_properties"], [NSDictionary dictionary]);
    XCTAssertEqualObjects(identifyEvent[@"user_properties"], [NSDictionary dictionaryWithObject:[NSDictionary dictionary] forKey:@"$setOnce"]);
}

-(void)testLogEventWithTimestamp {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1000];
    NSNumber *timestamp = [NSNumber numberWithLongLong:[date timeIntervalSince1970]];

    [self.amplitude logEvent:@"test" withEventProperties:nil withGroups:nil withTimestamp:timestamp outOfSession:NO];
    [self.amplitude flushQueue];
    NSDictionary *event = [self.amplitude getLastEvent];
    XCTAssertEqual(1000, [[event objectForKey:@"timestamp"] longLongValue]);

    [self.amplitude logEvent:@"test2" withEventProperties:nil withGroups:nil withLongLongTimestamp:2000 outOfSession:NO];
    [self.amplitude flushQueue];
    event = [self.amplitude getLastEvent];
    XCTAssertEqual(2000, [[event objectForKey:@"timestamp"] longLongValue]);
}

-(void)testRegenerateDeviceId {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude flushQueue];
    NSString *oldDeviceId = [self.amplitude getDeviceId];
    XCTAssertFalse([AMPUtils isEmptyString:oldDeviceId]);
    XCTAssertEqualObjects(oldDeviceId, [dbHelper getValue:@"device_id"]);

    [self.amplitude regenerateDeviceId];
    [self.amplitude flushQueue];
    NSString *newDeviceId = [self.amplitude getDeviceId];
    XCTAssertNotEqualObjects(oldDeviceId, newDeviceId);
    XCTAssertEqualObjects(newDeviceId, [dbHelper getValue:@"device_id"]);
    XCTAssertTrue([newDeviceId hasSuffix:@"R"]);
}

-(void)testTrackIdfa {
    NSString *value = @"12340000-0000-0000-0000-000000000000";

    self.amplitude.adSupportBlock = ^NSString * _Nonnull{
        return value;
    };

    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];

    self.amplitude.adSupportBlock = nil;

    NSDictionary *apiProps = [self.amplitude getLastEvent][@"api_properties"];
    XCTAssertTrue([[apiProps objectForKey:@"ios_idfa"] isEqualToString:value]);
}

#if TARGET_OS_IOS
-(void)testIdfaAsDeviceId {
    AMPTrackingOptions *opts = [AMPTrackingOptions options]; // has shouldTrackIDFA set.
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:@"idfa"];
    if (dbHelper != nil) {
        [dbHelper deleteDB];
    }

    NSString *value = @"12340000-0000-0000-0000-000000000000";

    Amplitude *client = [Amplitude instanceWithName:@"idfa"];
    client.adSupportBlock = ^NSString * _Nonnull{
        return value;
    };
    [client setTrackingOptions:opts];
    [client flushQueueWithQueue:client.initializerQueue];
    [client initializeApiKey:@"api key"];
    [client useAdvertisingIdForDeviceId];
    [client flushQueue];

    NSString *deviceId = [client getDeviceId];
    XCTAssertTrue([deviceId isEqual:value]);
}

-(void)testDisableIdfaAsDeviceId {
    AMPTrackingOptions *options = [[AMPTrackingOptions options] disableIDFA];
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:@"disable_idfa"];
    if (dbHelper != nil) {
        [dbHelper deleteDB];
    }

    NSString *value = @"12340000-0000-0000-0000-000000000000";

    Amplitude *client = [Amplitude instanceWithName:@"disable_idfa"];
    client.adSupportBlock = ^NSString * _Nonnull{
        return value;
    };

    [client flushQueueWithQueue:client.initializerQueue];
    [client setTrackingOptions:options];
    [client initializeApiKey:@"api key"];
    [client useAdvertisingIdForDeviceId];
    [client flushQueue];

    NSString *deviceId = [client getDeviceId];
    XCTAssertFalse([deviceId isEqual:value]);
}
#endif

-(void)testIdfvAsDeviceId {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:@"idfv"];
    if (dbHelper != nil) {
        [dbHelper deleteDB];
    }

    Amplitude *client = [Amplitude instanceWithName:@"idfv"];

    AMPDeviceInfo * deviceInfo = [[AMPDeviceInfo alloc] init];

    [client flushQueueWithQueue:client.initializerQueue];
    [client initializeApiKey:@"api key"];
    [client flushQueue];

    XCTAssertTrue([[client getDeviceId] isEqual:deviceInfo.vendorID]);
}

-(void)testDisableIdfvAsDeviceId {
    AMPTrackingOptions *options = [[AMPTrackingOptions options] disableIDFV];
    AMPDeviceInfo *deviceInfo = [[AMPDeviceInfo alloc] init];

    Amplitude *client = [Amplitude instanceWithName:@"disable_idfv"];
    [client flushQueueWithQueue:client.initializerQueue];
    [client setTrackingOptions:options];
    [client initializeApiKey:@"api key"];
    [client flushQueue];

    XCTAssertFalse([[client getDeviceId] isEqual:deviceInfo.vendorID]);
    XCTAssertEqual([[client getDeviceId] characterAtIndex:36], 'R');
}

-(void)testSetTrackingConfig {
    AMPTrackingOptions *options = [[[[[AMPTrackingOptions options] disableCity] disableIPAddress] disableLanguage] disableCountry];
    [self.amplitude setTrackingOptions:options];

    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    NSDictionary *event = [self.amplitude getLastEvent];

    // verify we have platform and carrier since those were not filtered out
    XCTAssertEqualObjects([event objectForKey:@"carrier"], @"Unknown");

    // verify we do not have any of the filtered out events
    XCTAssertNil([event objectForKey:@"city"]);
    XCTAssertNil([event objectForKey:@"country"]);
    XCTAssertNil([event objectForKey:@"language"]);

    // verify api properties contains tracking options for location filtering
    NSDictionary *apiProperties = [event objectForKey:@"api_properties"];
    XCTAssertNotNil([apiProperties objectForKey:@"ios_idfv"]);
    XCTAssertNotNil([apiProperties objectForKey:@"tracking_options"]);

    NSDictionary *trackingOptions = [apiProperties objectForKey:@"tracking_options"];
    XCTAssertEqual(3, trackingOptions.count);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"city"]);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"country"]);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"ip_address"]);
}

- (void)testEnableCoppaControl {
    NSDictionary *event = nil;
    NSDictionary *apiProperties = nil;

    [self.amplitude disableCoppaControl];

    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    event = [self.amplitude getLastEvent];

    apiProperties = [event objectForKey:@"api_properties"];
    XCTAssertNotNil([apiProperties objectForKey:@"ios_idfv"]);

    [self.amplitude enableCoppaControl];
    [self.amplitude logEvent:@"test"];
    [self.amplitude flushQueue];
    event = [self.amplitude getLastEvent];
    apiProperties = [event objectForKey:@"api_properties"];
    XCTAssertNil([apiProperties objectForKey:@"ios_idfv"]);

    // Minor guard covers 3 server configs. city, lat_lng, ip
    NSDictionary *trackingOptions = [apiProperties objectForKey:@"tracking_options"];
    XCTAssertEqual(3, trackingOptions.count);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"city"]);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"lat_lng"]);
    XCTAssertEqualObjects([NSNumber numberWithBool:NO], [trackingOptions objectForKey:@"ip_address"]);
}

- (void)testCustomizedLibrary {
    Amplitude *client = [Amplitude instanceWithName:@"custom_lib"];
    [client initializeApiKey:@"blah"];

    client.libraryName = @"amplitude-unity";
    client.libraryVersion = @"1.0.0";

    [client logEvent:@"test"];
    [client flushQueue];

    NSDictionary *event = [client getLastEventFromInstanceName:@"custom_lib"];
    NSDictionary *targetLibraryValue = @{ @"name" : @"amplitude-unity",
                                          @"version" : @"1.0.0"
    };

    NSDictionary *currentLibraryValue = event[@"library"];
    XCTAssertEqualObjects(currentLibraryValue, targetLibraryValue);
}

- (void)testCustomizedLibraryWithNilVersion {
    Amplitude *client = [Amplitude instanceWithName:@"custom_lib"];
    [client initializeApiKey:@"blah"];

    client.libraryName = @"amplitude-unity";
    client.libraryVersion = nil;

    [client logEvent:@"test"];
    [client flushQueue];

    NSDictionary *event = [client getLastEventFromInstanceName:@"custom_lib"];
    NSDictionary *targetLibraryValue = @{ @"name" : @"amplitude-unity",
                                          @"version" : kAMPUnknownVersion
    };

    NSDictionary *currentLibraryValue = event[@"library"];
    XCTAssertEqualObjects(currentLibraryValue, targetLibraryValue);
}

- (void)testCustomizedLibraryWithNilLibrary {
    Amplitude *client = [Amplitude instanceWithName:@"custom_lib"];
    [client initializeApiKey:@"blah"];

    client.libraryName = nil;
    client.libraryVersion = @"1.0.0";

    [client logEvent:@"test"];
    [client flushQueue];

    NSDictionary *event = [client getLastEventFromInstanceName:@"custom_lib"];
    NSDictionary *targetLibraryValue = @{ @"name" : kAMPUnknownLibrary,
                                          @"version" : @"1.0.0"
    };

    NSDictionary *currentLibraryValue = event[@"library"];
    XCTAssertEqualObjects(currentLibraryValue, targetLibraryValue);
}

- (void)testCustomizedLibraryWithNilLibraryAndVersion {
    Amplitude *client = [Amplitude instanceWithName:@"custom_lib"];
    [client initializeApiKey:@"blah"];

    client.libraryName = nil;
    client.libraryVersion = nil;

    [client logEvent:@"test"];
    [client flushQueue];

    NSDictionary *event = [client getLastEventFromInstanceName:@"custom_lib"];
    NSDictionary *targetLibraryValue = @{ @"name" : kAMPUnknownLibrary,
                                          @"version" : kAMPUnknownVersion
    };

    NSDictionary *currentLibraryValue = event[@"library"];
    XCTAssertEqualObjects(currentLibraryValue, targetLibraryValue);
}

- (void)testSetPlan {
    Amplitude *client = [Amplitude instanceWithName:@"observe_plan"];
    [client initializeApiKey:@"tracking_plan"];
    NSString *branch = @"main";
    NSString *source = @"mobile";
    NSString *version = @"1.0.0";
    NSString *versionId = @"9ec23ba0-275f-468f-80d1-66b88bff9529";

    AMPPlan *plan = [[[[[AMPPlan plan] setBranch:branch] setSource:source] setVersion:version] setVersionId:versionId];
    [client setPlan:plan];
    [client logEvent:@"test"];
    [client flushQueue];
    NSDictionary *event = [client getLastEventFromInstanceName:@"observe_plan"];

    NSDictionary *planValue = event[@"plan"];
    XCTAssertEqualObjects(branch, planValue[@"branch"]);
    XCTAssertEqualObjects(source, planValue[@"source"]);
    XCTAssertEqualObjects(version, planValue[@"version"]);
    XCTAssertEqualObjects(versionId, planValue[@"versionId"]);
}

- (void)testSetIngestionMetadata {
    Amplitude *client = [Amplitude instanceWithName:@"ingestion_metadata"];
    [client initializeApiKey:@"ingestion_metadata"];
    NSString *sourceName = @"ampli";
    NSString *sourceVersion = @"2.0.0";

    AMPIngestionMetadata *ingestionMetadata = [[[AMPIngestionMetadata ingestionMetadata] setSourceName:sourceName] setSourceVersion:sourceVersion];
    [client setIngestionMetadata:ingestionMetadata];
    [client logEvent:@"test"];
    [client flushQueue];
    NSDictionary *event = [client getLastEventFromInstanceName:@"ingestion_metadata"];

    NSDictionary *ingestionMetadataValue = event[@"ingestion_metadata"];
    XCTAssertEqualObjects(sourceName, ingestionMetadataValue[@"source_name"]);
    XCTAssertEqualObjects(sourceVersion, ingestionMetadataValue[@"source_version"]);
}

- (void)testSetServerZone {
    Amplitude *client = [Amplitude instanceWithName:@"eu_zone"];
    XCTAssertEqualObjects(kAMPEventLogUrl, [client valueForKey:@"serverUrl"]);
    [client initializeApiKey:@"eu_api_key"];
    [client setServerZone:EU];
    XCTAssertEqualObjects(kAMPEventLogEuUrl, [client valueForKey:@"serverUrl"]);
}

- (void)testSetServerZoneWithoutUpdateServerUrl {
    Amplitude *client = [Amplitude instanceWithName:@"eu_zone_2"];
    XCTAssertEqualObjects(kAMPEventLogUrl, [client valueForKey:@"serverUrl"]);
    [client initializeApiKey:@"eu_api_key"];
    [client setServerZone:EU updateServerUrl:NO];
    XCTAssertEqualObjects(kAMPEventLogUrl, [client valueForKey:@"serverUrl"]);
}

- (void)testMiddlewareSupport {
    NSString *eventType = @"middleware event";
    AMPBlockMiddleware *updateEventTypeMiddleware = [[AMPBlockMiddleware alloc] initWithBlock: ^(AMPMiddlewarePayload * _Nonnull payload, AMPMiddlewareNext _Nonnull next) {
        [payload.event setValue:eventType forKey:@"event_type"];
        [payload.event setValue:payload.extra[@"description"] forKey:@"description"];
        next(payload);
    }];
    Amplitude *client = [Amplitude instanceWithName:@"middleware_support"];
    [client addEventMiddleware:updateEventTypeMiddleware];
    [client initializeApiKey:@"middleware_api_key"];
    NSMutableDictionary *eventProperties = [NSMutableDictionary dictionary];
    [eventProperties setObject:@"green" forKey:@"color"];
    NSMutableDictionary *middlewareExtra = [NSMutableDictionary dictionary];
    [middlewareExtra setObject:@"some event description" forKey:@"description"];
    [client logEvent:@"test" withEventProperties:eventProperties withMiddlewareExtra:middlewareExtra];
    [client flushQueue];

    NSDictionary *event = [client getLastEventFromInstanceName:@"middleware_support"];
    XCTAssertEqualObjects(eventType, event[@"event_type"]);
    XCTAssertEqualObjects(middlewareExtra[@"description"], event[@"description"]);
}

- (void)testSwallowMiddleware {
    AMPBlockMiddleware *swallowMiddleware = [[AMPBlockMiddleware alloc] initWithBlock: ^(AMPMiddlewarePayload * _Nonnull payload, AMPMiddlewareNext _Nonnull next) {
    }];
    Amplitude *client = [Amplitude instanceWithName:@"middleware_swallow"];
    [client addEventMiddleware:swallowMiddleware];
    [client initializeApiKey:@"middleware_api_key"];
    [client logEvent:@"test"];
    [client flushQueue];

    XCTAssertNil([client getLastEventFromInstanceName:@"middleware_swallow"]);
}

-(void)testLogEventWithUserProperties {
    NSString *instanceName = @"eventWithUserProperties";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client initializeApiKey:@"api-key"];

    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:instanceName];
    [dbHelper resetDB:NO];

    NSMutableDictionary *userProperties = [NSMutableDictionary dictionary];
    [userProperties setValue:@"-" forKey:@"$clearAll"];
    NSMutableDictionary *setOpProperties = [NSMutableDictionary dictionary];
    [setOpProperties setValue:@"value" forKey:@"prop"];
    [userProperties setValue:setOpProperties forKey:@"$set"];

    [client logEvent:@"$identify" withEventProperties:nil withUserProperties:userProperties];
    [client flushQueue];
    NSMutableArray *identifys = [dbHelper getIdentifys:-1 limit:-1];
    XCTAssertEqual([identifys count], 1);

    XCTAssertEqualObjects([identifys[0] objectForKey:@"user_properties"], userProperties);
}

-(void)testNoDeferCheckInForeground {
    NSString *instanceName = @"noDeferCheckInForegroundInstance";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client initializeApiKey:@"api-key"];
    XCTAssertEqual(client.initialized, YES);
}

-(void)testDeferCheckInForeground {
    NSString *instanceName = @"DeferCheckInForegroundInstance";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client setDeferCheckInForeground:YES];
    [client initializeApiKey:@"api-key"];
    XCTAssertEqual(client.initialized, NO);

    [client checkInForeground];
    XCTAssertEqual(client.initialized, YES);
}

-(void)testSetIdentifyUploadSecondsOnInitializedClient {
    NSString *instanceName = @"SetIdentifyUploadSecondsOnInitializedClient";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client initializeApiKey:@"api-key"];

    // Check minimum
    XCTAssertFalse([client setIdentifyUploadPeriodSeconds:0]);
    XCTAssertFalse([client setIdentifyUploadPeriodSeconds:(kAMPIdentifyUploadPeriodSeconds - 1)]);

    // Check valid values
    XCTAssertTrue([client setIdentifyUploadPeriodSeconds:kAMPIdentifyUploadPeriodSeconds]);
    XCTAssertTrue([client setIdentifyUploadPeriodSeconds:(kAMPIdentifyUploadPeriodSeconds * 2)]);
}

-(void)testSetIdentifyUploadSecondsOnUninitializedClient {
    NSString *instanceName = @"SetIdentifyUploadSecondsOnUninitializedClient";
    Amplitude *uninitializedClient = [Amplitude instanceWithName:instanceName];

    // Don't initialized the client

    // Check minimum
    XCTAssertFalse([uninitializedClient setIdentifyUploadPeriodSeconds:0]);
    XCTAssertFalse([uninitializedClient setIdentifyUploadPeriodSeconds:(kAMPIdentifyUploadPeriodSeconds - 1)]);

    // Check valid values
    XCTAssertTrue([uninitializedClient setIdentifyUploadPeriodSeconds:kAMPIdentifyUploadPeriodSeconds]);
    XCTAssertTrue([uninitializedClient setIdentifyUploadPeriodSeconds:(kAMPIdentifyUploadPeriodSeconds * 2)]);
}

- (void)testInterceptIdentifys {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude flushQueue];
    // This is necessary for tvOs and macOS which have default eventUploadThreshold = 1
    [self.amplitude setEventUploadThreshold:30];

    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    // log intercept identify 1
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-1" value:@"set-value-1"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);

    // log active identify
    [self.amplitude identify:[[AMPIdentify identify] add:@"add-key-1" value:[NSNumber numberWithInt:1]]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);

    NSDictionary *lastIdentify = [self.amplitude getLastIdentify];
    NSMutableDictionary *lastIdentifyUserProperties = [AMPEventUtils getUserProperties:lastIdentify];
    NSArray *lastIdentifyUserPropertiesOperations = [lastIdentifyUserProperties allKeys];

    XCTAssertEqual(lastIdentifyUserPropertiesOperations.count, 2);
    XCTAssertTrue([lastIdentifyUserProperties[AMP_OP_SET][@"set-key-1"] isEqualToString:@"set-value-1"]);
    XCTAssertTrue([lastIdentifyUserProperties[AMP_OP_ADD][@"add-key-1"] isEqualToNumber:@1]);


    // log intercept identify 2
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-2" value:@"set-value-2"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);

    // log an event
    [self.amplitude logEvent:@"test_event1"];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getEventCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 2);

    NSDictionary *lastEvent = [self.amplitude getLastEvent];
    NSMutableDictionary *lastEventUserProperties = [AMPEventUtils getUserProperties:lastEvent];
    NSArray *lastEventUserPropertiesOperations = [lastEventUserProperties allKeys];

    XCTAssertEqual(lastEventUserPropertiesOperations.count, 1);
    XCTAssertTrue([lastEventUserProperties[@"set-key-2"] isEqualToString:@"set-value-2"]);

    // log intercept identify 3
    // this value should be cleared after "unset"
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-1" value:@"set-value-1"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);

    // log intercept identify 4 with "unset"
    [self.amplitude identify:[[AMPIdentify identify] clearAll]];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 2);
    XCTAssertEqual([dbHelper getTotalEventCount], 3);

    NSDictionary *unsetIdentify = [self.amplitude getLastIdentify];
    NSMutableDictionary *unsetIdentifyUserProperties = [AMPEventUtils getUserProperties:unsetIdentify];
    NSArray *unsetIdentifyUserPropertiesOperations = [unsetIdentifyUserProperties allKeys];

    XCTAssertEqual(unsetIdentifyUserPropertiesOperations.count, 1);
    XCTAssertTrue([unsetIdentifyUserProperties[AMP_OP_CLEAR_ALL] isEqualToString:@"-"]);
}


- (void)testInterceptedIdentifysAreSentOnUploadEvents {
    NSString *instanceName = @"testInterceptedIdentifysAreSentOnUploadEvents";
    Amplitude *client = [Amplitude instanceWithName:instanceName];
    [client initializeApiKey:@"api-key"];
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:instanceName];


    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    // log intercept identify 1
    [client identify:[[AMPIdentify identify] set:@"set-key-1" value:@"set-value-1"]];
    [client flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);

    // log intercept identify 2
    [client identify:[[AMPIdentify identify] set:@"set-key-2" value:@"set-value-2"]];
    [client flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 2);

    // log an event
    [client uploadEvents];
    [client flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getIdentifyCount], 0);
}

- (void)testInterceptedIdentifyIsAppliedToSetGroup {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude flushQueue];
    // This is necessary for tvOs and macOS which have default eventUploadThreshold = 1
    [self.amplitude setEventUploadThreshold:30];

    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    // log intercept identify 1
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-1" value:@"set-value-1"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);

    // log active identify
    [self.amplitude setGroup:@"group_type" groupName:@"group_value"];
    [self.amplitude flushQueue];

    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 0);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);

    NSDictionary *lastIdentify = [self.amplitude getLastIdentify];
    NSMutableDictionary *lastIdentifyUserProperties = [AMPEventUtils getUserProperties:lastIdentify];
    NSArray *lastIdentifyUserPropertiesOperations = [lastIdentifyUserProperties allKeys];

    XCTAssertEqual(lastIdentifyUserPropertiesOperations.count, 1);
    XCTAssertTrue([lastIdentifyUserProperties[AMP_OP_SET][@"set-key-1"] isEqualToString:@"set-value-1"]);
    XCTAssertTrue([lastIdentify[@"groups"][@"group_type"] isEqualToString:@"group_value"]);
}

- (void)testInterceptIdentifysAreSentOnUserIdChange {
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    [self.amplitude flushQueue];
    // This is necessary for tvOs and macOS which have default eventUploadThreshold = 1
    [self.amplitude setEventUploadThreshold:30];

    NSMutableDictionary *serverResponse = [NSMutableDictionary dictionaryWithDictionary:
                                           @{ @"response" : [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"/"] statusCode:200 HTTPVersion:nil headerFields:@{}],
                                              @"data" : [@"success" dataUsingEncoding:NSUTF8StringEncoding]
                                              }];
    [self setupAsyncResponse:serverResponse];

    // userId #1
    [self.amplitude setUserId:@"test-user-1"];
    // log intercepted identify's
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-1" value:@"set-value-1"]];
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-2" value:@"set-value-2"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 2);

    // userId #2
    [self.amplitude setUserId:@"test-user-2"];
    // log intercept identify with new user_id
    [self.amplitude identify:[[AMPIdentify identify] set:@"set-key-3" value:@"set-value-3"]];
    [self.amplitude flushQueue];
    XCTAssertEqual([dbHelper getInterceptedIdentifyCount], 1);
    XCTAssertEqual([dbHelper getIdentifyCount], 1);
    XCTAssertEqual([dbHelper getTotalEventCount], 1);

    // verify idenitfy was transfered
    NSDictionary *lastIdentify = [self.amplitude getLastIdentify];
    NSMutableDictionary *lastIdentifyUserProperties = [AMPEventUtils getUserProperties:lastIdentify];
    NSArray *lastIdentifyUserPropertiesOperations = [lastIdentifyUserProperties allKeys];

    XCTAssertEqualObjects([AMPEventUtils getUserId:lastIdentify], @"test-user-1");
    XCTAssertEqual(lastIdentifyUserPropertiesOperations.count, 1);
    XCTAssertEqualObjects(lastIdentifyUserProperties[AMP_OP_SET][@"set-key-1"], @"set-value-1");
    XCTAssertEqualObjects(lastIdentifyUserProperties[AMP_OP_SET][@"set-key-2"], @"set-value-2");

    // verify intercepted
    NSDictionary *interceptedIdentify = [self.amplitude getLastInterceptedIdentify];
    NSMutableDictionary *interceptedIdentifyUserProperties = [AMPEventUtils getUserProperties:interceptedIdentify];
    NSArray *interceptedIdentifyUserPropertiesOperations = [interceptedIdentifyUserProperties allKeys];
    XCTAssertEqualObjects([AMPEventUtils getUserId:interceptedIdentify], @"test-user-2");
    XCTAssertEqual(interceptedIdentifyUserPropertiesOperations.count, 1);
    XCTAssertEqualObjects(interceptedIdentifyUserProperties[AMP_OP_SET][@"set-key-3"], @"set-value-3");
}

@end
