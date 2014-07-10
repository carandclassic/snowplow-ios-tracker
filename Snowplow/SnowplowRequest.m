//
//  SnowplowRequest.m
//  Snowplow
//
//  Copyright (c) 2013-2014 Snowplow Analytics Ltd. All rights reserved.
//
//  This program is licensed to you under the Apache License Version 2.0,
//  and you may not use this file except in compliance with the Apache License
//  Version 2.0. You may obtain a copy of the Apache License Version 2.0 at
//  http://www.apache.org/licenses/LICENSE-2.0.
//
//  Unless required by applicable law or agreed to in writing,
//  software distributed under the Apache License Version 2.0 is distributed on
//  an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
//  express or implied. See the Apache License Version 2.0 for the specific
//  language governing permissions and limitations there under.
//
//  Authors: Jonathan Almeida
//  Copyright: Copyright (c) 2013-2014 Snowplow Analytics Ltd
//  License: Apache License Version 2.0
//

#import "SnowplowRequest.h"
#import "SnowplowEventStore.h"
#import "SnowplowUtils.h"
#import <AFNetworking/AFNetworking.h>

@implementation SnowplowRequest {
    NSURL *                     _urlEndpoint;
    NSString *                  _httpMethod;
    NSMutableArray *            _buffer;
    NSMutableArray *            _outQueue;
    enum SnowplowBufferOptions  _bufferOption;
    NSTimer *                   _timer;
    SnowplowEventStore *        _db;
}

static int       const kDefaultBufferTimeout = 60;
static NSString *const kPayloadDataSchema    = @"iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-0";

- (id) init {
    self = [super init];
    if (self) {
        _urlEndpoint = nil;
        _httpMethod = @"GET";
        _bufferOption = SnowplowBufferDefault;
        _buffer = [[NSMutableArray alloc] init];
        _outQueue = [[NSMutableArray alloc] init];
        _db = [[SnowplowEventStore alloc] initWithAppId:[SnowplowUtils getAppId]];
        [self setBufferTime:kDefaultBufferTimeout];
    }
    return self;
}

- (id) initWithURLRequest:(NSURL *)url httpMethod:(NSString* )method {
    self = [super init];
    if(self) {
        _httpMethod = method;
        _bufferOption = SnowplowBufferDefault;
        _buffer = [[NSMutableArray alloc] init];
        _outQueue = [[NSMutableArray alloc] init];
        _urlEndpoint = [url URLByAppendingPathComponent:@"/i"];
        _db = [[SnowplowEventStore alloc] initWithAppId:[SnowplowUtils getAppId]];
        [self setBufferTime:kDefaultBufferTimeout];
    }
    return self;
}

- (id) initWithURLRequest:(NSURL *)url httpMethod:(NSString *)method bufferOption:(enum SnowplowBufferOptions)option {
    self = [super init];
    if(self) {
        _urlEndpoint = url;
        _httpMethod = method;
        _bufferOption = option;
        _buffer = [[NSMutableArray alloc] init];
        _urlEndpoint = [url URLByAppendingPathComponent:@"/i"];
        _db = [[SnowplowEventStore alloc] initWithAppId:[SnowplowUtils getAppId]];
        [self setBufferTime:kDefaultBufferTimeout];
    }
    return self;
}

- (void) dealloc {
    // Save buffer to database Issue #9
    _urlEndpoint = nil;
    _buffer = nil;
}

- (void) addPayloadToBuffer:(SnowplowPayload *)spPayload {
    [_buffer addObject:spPayload.getPayloadAsDictionary];
    [_db insertEvent:spPayload];
    if([_buffer count] == _bufferOption) //TODO add isEmpty check for db
        [self flushBuffer];
}

- (void) addToOutQueue:(SnowplowPayload *)payload {
    [_db insertEvent:payload];
}

- (void) popFromOutQueue {
    [_db removeEventWithId:[_db getLastInsertedRowId]];
}

- (void) setBufferOption:(enum SnowplowBufferOptions) buffer {
    _bufferOption = buffer;
}

- (void) setBufferTime:(int) userTime {
    int time = kDefaultBufferTimeout;
    if(userTime <= 300) time = userTime; // 5 minute intervals
    
    _timer = [NSTimer scheduledTimerWithTimeInterval:time target:self selector:@selector(flushBuffer) userInfo:nil repeats:YES];
}

- (void) setUrlEndpoint:(NSURL *) url {
    _urlEndpoint = [url URLByAppendingPathComponent:@"/i"];
}

- (void) flushBuffer {
    NSLog(@"Flushing buffer..");
    // Avoid calling flush to send an empty buffer
    if ([_buffer count] == 0) {
        return;
    }
    
    NSMutableArray *bufferAndBackup = [[NSMutableArray alloc] init];
    for (NSDictionary * eventWithMetaData in [_db getAllEvents]) {
        [bufferAndBackup addObject:[eventWithMetaData objectForKey:@"data"]];
        [_outQueue addObject:[eventWithMetaData objectForKey:@"ID"]];
    }
    
    //Empties the buffer and sends the contents to the collector
    if([_httpMethod isEqual:@"POST"]) {
        NSMutableDictionary *payload = [[NSMutableDictionary alloc] init];
        [payload setValue:kPayloadDataSchema forKey:@"$schema"];
        [payload setValue:bufferAndBackup forKey:@"data"];
        
        [self sendPostData:payload];
    } else if ([_httpMethod isEqual:@"GET"]) {
        for (NSDictionary* event in bufferAndBackup) {
            [self sendGetData:event];
        }
    } else {
        NSLog(@"Invalid httpMethod provided. Use \"POST\" or \"GET\".");
    }
    [_buffer removeAllObjects];
}

- (void) sendPostData:(NSDictionary *)data {
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    
    [manager POST:[_urlEndpoint absoluteString] parameters:data success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"JSON: %@", responseObject);
        for (NSNumber *eventID in _outQueue) {
            [_db removeEventWithId:[eventID longLongValue]];
            [_outQueue removeObject:eventID];
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"Error: %@", error);
        //Add event to queue
    }];
}

- (void) sendGetData:(NSDictionary *)data {
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    manager.requestSerializer = [AFHTTPRequestSerializer serializer];
    
    [manager GET:[_urlEndpoint absoluteString] parameters:data success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"JSON: %@", responseObject);
        for (NSNumber *eventID in _outQueue) {
            [_db removeEventWithId:[eventID longLongValue]];
            [_outQueue removeObject:eventID];
        }
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"Error: %@", error);
        //Add event to queue
    }];
}

@end
