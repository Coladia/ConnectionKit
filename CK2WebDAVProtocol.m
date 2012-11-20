//
//  CK2WebDAVProtocol.h
//
//  Created by Sam Deane on 19/11/2012.
//

#import "CK2WebDAVProtocol.h"
#import "CKRemoteURL.h"

#define CK2WebDAVLog NSLog
//#define CK2WebDAVLog(...)

@implementation CK2WebDAVProtocol


+ (BOOL)canHandleURL:(NSURL *)url;
{
    return [url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"];
}

#pragma mark Lifecycle

- (id)initWithRequest:(NSURLRequest *)request client:(id <CK2ProtocolClient>)client completionHandler:(void (^)(id))handler;
{
    if (self = [self initWithRequest:request client:client])
    {
        _queue = [[NSOperationQueue alloc] init];
        _queue.name = @"CK2WebDAVProtocol";
        _queue.suspended = YES;
        _session = [[DAVSession alloc] initWithRootURL:request.URL delegate:self];
        _completionHandler = [handler copy];
    }

    return self;
}

- (id)initWithRequest:(NSURLRequest *)request client:(id <CK2ProtocolClient>)client dataHandler:(void (^)(NSData *))dataBlock completionHandler:(void (^)(id))handler
{
    if (self = [self initWithRequest:request client:client completionHandler:handler])
    {
        _dataBlock = [dataBlock copy];
    }
    return self;
}

- (id)initWithRequest:(NSURLRequest *)request client:(id <CK2ProtocolClient>)client progressBlock:(void (^)(NSUInteger))progressBlock completionHandler:(void (^)(id))handler
{
    if (self = [self initWithRequest:request client:client completionHandler:handler])
    {
        _progressBlock = [progressBlock copy];
    }
    return self;
}

- (void)dealloc;
{
    CK2WebDAVLog(@"dealloced");
    
    [_completionHandler release];
    [_dataBlock release];
    [_davRequest release];
    [_progressBlock release];
    [_queue release];
    [_session release];

    [super dealloc];
}

#pragma mark - Operations

- (id)initForEnumeratingDirectoryWithRequest:(NSURLRequest *)request includingPropertiesForKeys:(NSArray *)keys options:(NSDirectoryEnumerationOptions)mask client:(id<CK2ProtocolClient>)client;
{
    CK2WebDAVLog(@"enumerating directory");

    NSString *path = [CK2WebDAVProtocol pathOfURLRelativeToHomeDirectory:request.URL];
    if (!path) path = @"/";



    NSMutableData *totalData = [[NSMutableData alloc] init];

    self = [self initWithRequest:request client:client dataHandler:^(NSData *data) {

        [totalData appendData:data];

    } completionHandler:^(id result) {

        NSURL* root = [NSURL URLWithString:@"/" relativeToURL:request.URL];
        for (DAVResponseItem* item in result)
        {
            NSString *name = [[item href] lastPathComponent];
            if (!((mask & NSDirectoryEnumerationSkipsHiddenFiles) && [name hasPrefix:@"."]))
            {
                CKRemoteURL* url = [[CKRemoteURL alloc] initWithString:[[root URLByAppendingPathComponent:[item href]] absoluteString]];
                [url setTemporaryResourceValue:[item modificationDate] forKey:NSURLContentModificationDateKey];
                [url setTemporaryResourceValue:[item creationDate] forKey:NSURLCreationDateKey];
                [url setTemporaryResourceValue:[NSNumber numberWithUnsignedInteger:[item contentLength]] forKey:NSURLFileSizeKey];
                [item.fileAttributes enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                    [url setTemporaryResourceValue:obj forKey:key];
                }];
                [url setTemporaryResourceValue:[item contentType] forKey:NSURLFileResourceTypeKey]; // 10.7 properties go last because might be nil at runtime
                [client protocol:self didDiscoverItemAtURL:url];
                CK2WebDAVLog(@"%@", url);
                [url release];
            }
        }

        [client protocolDidFinish:self];

    }];

    if (self != nil)
    {
        DAVRequest* davRequest = [[DAVListingRequest alloc] initWithPath:path session:_session delegate:self];
        [_queue addOperation:davRequest];
    }

    return self;
}

- (id)initForCreatingDirectoryWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates client:(id<CK2ProtocolClient>)client;
{
    CK2WebDAVLog(@"creating directory");

    return self;
}

- (id)initForCreatingFileWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates client:(id<CK2ProtocolClient>)client progressBlock:(void (^)(NSUInteger))progressBlock;
{
    CK2WebDAVLog(@"creating file");

    return self;
}

- (id)initForRemovingFileWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    CK2WebDAVLog(@"removing file");

    return self;
}

- (id)initForSettingResourceValues:(NSDictionary *)keyedValues ofItemWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    CK2WebDAVLog(@"setting resource values");

    return self;
}

- (void)start;
{
    CK2WebDAVLog(@"started");
    _queue.suspended = NO;
}

- (void)stop
{
    CK2WebDAVLog(@"stopped");
}

#pragma mark Request Delegate

- (void)requestDidBegin:(DAVRequest *)aRequest;
{
    CK2WebDAVLog(@"webdav request began");

    if (_progressBlock)
    {
        _progressBlock(0);
    }
}

- (void)request:(DAVRequest *)aRequest didSucceedWithResult:(id)result;
{
    CK2WebDAVLog(@"webdav request succeeded");

    _completionHandler(result);
}

- (void)request:(DAVRequest *)aRequest didFailWithError:(NSError *)error;
{
    CK2WebDAVLog(@"webdav request failed");

    [self.client protocol:self didFailWithError:error];
}

- (void)webDAVRequest:(DAVRequest *)request didSendDataOfLength:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    CK2WebDAVLog(@"webdav sent data");

    if (_progressBlock)
    {
        _progressBlock(totalBytesWritten);
    }
}

#pragma mark WebDAV Authentication


- (void)webDAVSession:(DAVSession *)session didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    CK2WebDAVLog(@"webdav received challenge");

    [[self client] protocol:self didReceiveAuthenticationChallenge:challenge];
}

- (void)webDAVSession:(DAVSession *)session didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    CK2WebDAVLog(@"webdav cancelled challenge");
    
    [[self client] protocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                      code:NSURLErrorUserCancelledAuthentication
                                                                  userInfo:nil]];
}

- (void)webDAVSession:(DAVSession *)session appendStringToTranscript:(NSString *)string sent:(BOOL)sent;
{
    CK2WebDAVLog(sent ? @"< %@ " : @"> %@", string);

    [[self client] protocol:self appendString:string toTranscript:(sent ? CKTranscriptSent : CKTranscriptReceived)];
}


#pragma mark NSURLAuthenticationChallengeSender

- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    CK2WebDAVLog(@"use credential called");
}

- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    CK2WebDAVLog(@"continue without credential called");

    [self useCredential:nil forAuthenticationChallenge:challenge];  // libcurl will use annonymous login
}

- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    CK2WebDAVLog(@"cancel authentication called");
    
    [[self client] protocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                      code:NSURLErrorUserCancelledAuthentication
                                                                  userInfo:nil]];
}

@end

