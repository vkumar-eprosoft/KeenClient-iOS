//
//  KeenClient.m
//  KeenClient
//
//  Created by Daniel Kador on 2/8/12.
//  Copyright (c) 2012 Keen Labs. All rights reserved.
//

#import "KeenClient.h"
#import "KeenConstants.h"
#import "CJSONSerializer.h"
#import "CJSONDeserializer.h"


static NSDictionary *clients;
static KeenClient *lastClient;

@interface KeenClient () {}

// The project ID for this particular client.
@property (nonatomic, retain) NSString *projectId;

// The authorization token for this particular project.
@property (nonatomic, retain) NSString *token;

// The timestamp for the previous event.
@property (nonatomic, retain) NSDate *prevTimestamp;

// How many times the previous timestamp has been used.
@property (nonatomic) NSInteger numTimesTimestampUsed;

/**
 Initializes a KeenClient with the given authToken.
 @param authToken The auth token corresponding to the keen.io project.
 @returns an instance of KeenClient, or nil if authToken is nil or otherwise invalid.
 */
- (id) initWithProject: (NSString *) projectId AuthToken: (NSString *) authToken;

/**
 Returns the path to the app's library/cache directory.
 @returns An NSString* that is a path to the app's documents directory.
 */
- (NSString *) getCacheDirectory;

/**
 Returns the root keen directory where collection sub-directories exist.
 @returns An NSString* that is a path to the keen root directory.
 */
- (NSString *) getKeenDirectory;

/**
 Returns the direct child sub-directories of the root keen directory.
 @returns An NSArray* of NSStrings* that are names of sub-directories.
 */
- (NSArray *) getKeenSubDirectories;

/**
 Returns all the files and directories that are children of the argument path.
 @param path An NSString* that's a fully qualified path to a directory on the file system.
 @returns An NSArray* of NSStrings* that are names of sub-files or directories.
 */
- (NSArray *) getContentsAtPath: (NSString *) path;

/**
 Returns the directory for a particular collection where events exist.
 @param collection The collection.
 @returns An NSString* that is a path to the collection directory.
 */
- (NSString *) getEventDirectoryForCollection: (NSString *) collection;

/**
 Returns the full path to write an event to.
 @param collection The collection name.
 @param timestamp  The timestamp of the event.
 @returns An NSString* that is a path to the event to be written.
 */
- (NSString *) getPathForEventInCollection: (NSString *) collection WithTimestamp: (NSDate *) timestamp;

/**
 Creates a directory if it doesn't exist.
 @param dirPath The fully qualfieid path to a directory.
 @returns YES if the directory exists at the end of this operation, NO otherwise.
 */
- (Boolean) createDirectoryIfItDoesNotExist: (NSString *) dirPath;

/**
 Writes a particular blob to the given file.
 @param data The data blob to write.
 @param file The fully qualified path to a file.
 @returns YES if the file was successfully written, NO otherwise.
 */
- (Boolean) writeNSData: (NSData *) data toFile: (NSString *) file;

/**
 Sends an event to the server. Internal impl.
 */
- (NSData *) sendEvents: (NSData *) data returningResponse: (NSURLResponse **) response error: (NSError **) error;

    
@end

@implementation KeenClient

@synthesize projectId=_projectId;
@synthesize token=_token;
@synthesize prevTimestamp=_prevTimestamp;
@synthesize numTimesTimestampUsed=_numTimesTimestampUsed;
@synthesize isRunningTests=_isRunningTests;

# pragma mark - Class lifecycle

+ (void) initialize {
    // initialize the dictionary used to cache clients exactly once.
    if (!clients) {
        clients = [[NSMutableDictionary dictionary] retain];
    }
}

- (id) initWithProject: (NSString *) projectId AuthToken: (NSString *) authToken {
    self = [super init];
    if (self) {
        NSLog(@"Called init on KeenClient for token: %@", authToken);
        self.projectId = projectId;
        self.token = authToken;
        self.prevTimestamp = nil;
    }
    
    return self;
}

- (void) dealloc {
    self.projectId = nil;
    self.token = nil;
    self.prevTimestamp = nil;
    [super dealloc];
}

# pragma mark - Get a client

+ (KeenClient *) clientForProject: (NSString *) projectId WithAuthToken: (NSString *) authToken {
    // validate that project id and auth token are acceptable
    if (!projectId || !authToken) {
        return nil;
    }
    
    @synchronized(self) {
        // grab whatever's in the cache.
        KeenClient *client = [clients objectForKey:authToken];
        // if it's null, then create a new instance.
        if (!client) {
            // create a new instance
            client = [[KeenClient alloc] initWithProject:projectId AuthToken:authToken];
            // cache it
            [clients setValue:client forKey:authToken];
            // release it
            [client release];
        }
        KeenClient *temp = lastClient;
        lastClient = [client retain];
        [temp release];
        return client;
    }
}

+ (KeenClient *) client {
    return lastClient;
}

# pragma mark - Add events and upload them

- (Boolean) addEvent: (NSDictionary *) event ToCollection: (NSString *) collection {
    // don't do anything if event or collection are nil.
    if (!event || !collection) {
        return NO;
    }
    
    NSDictionary *eventToWrite = nil;
    // if there's no timestamp in the event, stamp it automatically.
    NSDate *timestamp = [event objectForKey:@"timestamp"];
    if (!timestamp) {
        eventToWrite = [NSMutableDictionary dictionaryWithDictionary:event];
        timestamp = [NSDate date];
        [eventToWrite setValue:timestamp forKey:@"timestamp"];
    } else {
        eventToWrite = event;
    }
    
    // serialize event to JSON
    NSError *error = nil;
    NSData *jsonData = [[CJSONSerializer serializer] serializeDictionary:eventToWrite error:&error];
    if (error) {
        NSLog(@"An error occurred when serializing event to JSON: %@", [error localizedDescription]);
        return NO;
    }
    
    // make sure the directory we want to write the file to exists
    NSString *dirPath = [self getEventDirectoryForCollection:collection];
    // if the directory doesn't exist, create it.
    Boolean success = [self createDirectoryIfItDoesNotExist:dirPath];
    if (!success) {
        return NO;
    }
    
    // now figure out the correct filename.
    NSString *fileName = [self getPathForEventInCollection:collection WithTimestamp:timestamp];
    
    // write JSON to file system
    return [self writeNSData:jsonData toFile:fileName];
}

- (void) uploadHelper {
    // get a file manager
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // list all the directories under Keen
    NSArray *directories = [self getKeenSubDirectories];
    NSString *rootPath = [self getKeenDirectory];
    
    // set up the request dictionary we'll send out.
    NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
    
    // declare an error object
    NSError *error = nil;
    
    // create a structure that will hold corresponding paths to all the files
    NSMutableDictionary *fileDict = [NSMutableDictionary dictionary];
    
    // iterate through each directory
    for (NSString *dirName in directories) {
        NSLog(@"Found directory: %@", dirName);
        // list contents of each directory
        NSString *dirPath = [rootPath stringByAppendingPathComponent:dirName];
        NSArray *files = [self getContentsAtPath:dirPath];
        
        // set up the array of events that will be used in the request
        NSMutableArray *requestArray = [NSMutableArray array];
        // set up the array of file paths
        NSMutableArray *fileArray = [NSMutableArray array];
        
        for (NSString *fileName in files) {
            NSLog(@"Found file: %@/%@", dirName, fileName);
            NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
            // for each file, grab the JSON blob
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            // deserialize it
            error = nil;
            NSDictionary *eventDict = [[CJSONDeserializer deserializer] deserializeAsDictionary:data error:&error];
            if (error) {
                NSLog(@"An error occurred when deserializing a saved event: %@", [error localizedDescription]);
                continue;
            }
            // and then add it to the array of events
            [requestArray addObject:eventDict];
            // and also to the array of paths
            [fileArray addObject:filePath];
        }
        // and then add the array back to the overall request
        [requestDict setObject:requestArray forKey:dirName];
        // and also to the dictionary of paths
        [fileDict setObject:fileArray forKey:dirName];
    }
    
    // now take the request dict and use it to make an HTTP request to the server
    
    // first serialize the request dict back to a json string
    error = nil;
    NSData *data = [[CJSONSerializer serializer] serializeDictionary:requestDict error:&error];
    if (error) {
        NSLog(@"An error occurred when serializing the final request data back to JSON: %@", 
              [error localizedDescription]);
        // can't do much here.
        return;
    }
    
    // and then make an http request to the keen server.
    NSURLResponse *response = nil;
    error = nil;
    NSData *responseData = [self sendEvents:data returningResponse:&response error:&error];
    
    /*
     if (error) {
     // if the request failed because the server was down, keep the events on the local file system for later upload.
     NSLog(@"An error occurred when sending HTTP request to %@: %@", KeenServerAddress, [error localizedDescription]);
     return;
     }
     */
    
    if (!responseData) {
        NSLog(@"responseData was nil for some reason.  That's not great.");
        return;
    }
    
    NSInteger responseCode = [((NSHTTPURLResponse *)response) statusCode];
    // if the request succeeded, dig into the response to figure out which events succeeded and which failed
    if (responseCode == 200) {
        // deserialize the response
        error = nil;
        NSDictionary *responseDict = [[CJSONDeserializer deserializer] 
                                      deserializeAsDictionary:responseData error:&error];
        if (error) {
            NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            NSLog(@"An error occurred when deserializing HTTP response JSON into dictionary.\nError: %@\nResponse: %@", [error localizedDescription], responseString);
            [responseString release];
            return;
        }
        // now iterate through the keys of the response, which represent collection names
        NSArray *collectionNames = [responseDict allKeys];
        for (NSString *collectionName in collectionNames) {
            // grab the results for this collection
            NSArray *results = [responseDict objectForKey:collectionName];
            // go through and delete any successes and failures because of user error
            // (making sure to keep any failures due to server error)
            NSUInteger count = 0;
            for (NSDictionary *result in results) {
                Boolean deleteFile = YES;
                Boolean success = [[result objectForKey:@"success"] boolValue];
                if (!success) {
                    // grab error code and description
                    NSDictionary *errorDict = [result objectForKey:@"error"];
                    NSString *errorCode = [errorDict objectForKey:@"name"];
                    NSString *errorDescription = [errorDict objectForKey:@"description"];
                    if ([errorCode isEqualToString:@"InvalidCollectionNameError"] ||
                        [errorCode isEqualToString:@"InvalidPropertyNameError"] ||
                        [errorCode isEqualToString:@"InvalidPropertyValueError"]) {
                        NSLog(@"An invalid event was found.  Deleting it.  Error: %@", errorDescription);
                        deleteFile = YES;
                    } else {
                        NSLog(@"The event could not be inserted for some reason.  Error name and description: %@, %@", 
                              errorCode, errorDescription);
                        deleteFile = NO;
                    }
                }
                // delete the file if we need to
                if (deleteFile) {
                    NSString *path = [[fileDict objectForKey:collectionName] objectAtIndex:count];
                    error = nil;
                    [fileManager removeItemAtPath:path error:&error];
                    if (error) {
                        NSLog(@"CRITICAL ERROR: Could not remove event at %@ because: %@", path, 
                              [error localizedDescription]);
                    } else {
                        NSLog(@"Successfully deleted file: %@", path);
                    }
                }
                count++;
            }
        }
    } else {
        // response code was NOT 200, which means something else happened. log this.
        NSLog(@"Response code was NOT 200. It was: %d", responseCode);
        NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        NSLog(@"Response body was: %@", responseString);
        [responseString release];
    }        
}

- (void) upload {
    if (self.isRunningTests) {
        // run upload in same thread if we're in tests
        [self uploadHelper];
    } else {
        // otherwise do it in the background to not interfere with UI operations
        [self performSelectorInBackground:@selector(uploadHelper) withObject:nil];
    }
}

# pragma mark - Directory/path management

- (NSString *) getCacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return documentsDirectory;
}

- (NSString *) getKeenDirectory {
    NSString *keenDirPath = [[self getCacheDirectory] stringByAppendingPathComponent:@"keen"];
    return [keenDirPath stringByAppendingPathComponent:self.projectId];
}

- (NSArray *) getKeenSubDirectories {
    return [self getContentsAtPath:[self getKeenDirectory]];
}

- (NSArray *) getContentsAtPath: (NSString *) path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        NSLog(@"An error occurred when listing directory (%@) contents: %@", path, [error localizedDescription]);
        return nil;
    }
    return files;
}

- (NSString *) getEventDirectoryForCollection: (NSString *) collection {
    return [[self getKeenDirectory] stringByAppendingPathComponent:collection];
}

- (NSString *) getPathForEventInCollection: (NSString *) collection WithTimestamp: (NSDate *) timestamp {
    // get a file manager.
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // determine the root of the filename.
    NSString *name = [NSString stringWithFormat:@"%d", (long) [timestamp timeIntervalSince1970]];
    // get the path to the directory where the file will be written
    NSString *directory = [self getEventDirectoryForCollection:collection];
    // start a counter that we'll use to make sure that even if multiple events are written with the same timestamp,
    // we'll be able to handle it.
    uint count = 0;
    
    // declare a tiny helper block to get the next path based on the counter.
    NSString * (^getNextPath)(uint count) = ^(uint count) {
        return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%i", name, count]];
    };
    
    // starting with our root filename.0, see if a file exists.  if it doesn't, great.  but if it does, then go
    // on to filename.1, filename.2, etc.
    NSString *path = getNextPath(count);
    while ([fileManager fileExistsAtPath:path]) {
        count++;
        path = getNextPath(count);
    }    
    
    return path;
}

- (Boolean) createDirectoryIfItDoesNotExist: (NSString *) dirPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // if the directory doesn't exist, create it.
    if (![fileManager fileExistsAtPath:dirPath]) {
        NSError *error = nil;
        Boolean success = [fileManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"An error occurred when creating directory (%@). Message: %@", dirPath, [error localizedDescription]);
            return NO;
        } else if (!success) {
            NSLog(@"Failed to create directory (%@) but no error was returned.", dirPath);
            return NO;
        }        
    }
    return YES;
}

- (Boolean) writeNSData: (NSData *) data toFile: (NSString *) file {
    // write file atomically so we don't ever have a partial event to worry about.    
    Boolean success = [data writeToFile:file atomically:YES];
    if (!success) {
        NSLog(@"Error when writing event to file: %@", file);
        return NO;
    } else {
        NSLog(@"Successfully wrote event to file: %@", file);
    }
    return YES;
}

# pragma mark - HTTP request/response management

- (NSData *) sendEvents: (NSData *) data returningResponse: (NSURLResponse **) response error: (NSError **) error {
    NSString *urlString = [NSString stringWithFormat:@"%@/%@/projects/%@/_events", 
                           KeenServerAddress, KeenApiVersion, self.projectId];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.token forHTTPHeaderField:@"Authorization"];
    // TODO check if setHTTPBody also sets content-length
    [request setValue:[NSString stringWithFormat:@"%d", [data length]] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:data];
    NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:response error:error];
    return responseData;
}

@end
