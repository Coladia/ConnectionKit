//
//  CKSFTPConnection.m
//  Sandvox
//
//  Created by Mike on 25/10/2011.
//  Copyright 2011 Karelia Software. All rights reserved.
//

#import "CKCurlFTPConnection.h"

#import "UKMainThreadProxy.h"
#import "NSInvocation+Connection.h"

#import <sys/dirent.h>


@interface CKCurlFTPConnection () <CURLHandleDelegate>
@end


#pragma mark -


@implementation CKCurlFTPConnection

+ (void)load
{
    [[CKConnectionRegistry sharedConnectionRegistry] registerClass:self forName:@"FTP" URLScheme:@"ftp"];
    [[CKConnectionRegistry sharedConnectionRegistry] registerClass:self forName:@"FTPS" URLScheme:@"ftps"];
}

+ (NSArray *)URLSchemes { return [NSArray arrayWithObjects:@"ftp", @"ftps", nil]; }

#pragma mark Lifecycle

- (id)initWithRequest:(NSURLRequest *)request;
{
    if (self = [self init])
    {
        _session = [[CURLFTPSession alloc] initWithRequest:request];
        if (!_session)
        {
            [self release]; return nil;
        }
        [_session setDelegate:self];
        
        _request = [request copy];
        
        _queue = [[NSOperationQueue alloc] init];
        [_queue setMaxConcurrentOperationCount:1];
    }
    return self;
}

- (void)dealloc;
{
    [_request release];
    [_credential release];
    [_session release];
    [_queue release];
    [_currentDirectory release];
    
    [super dealloc];
}

#pragma mark Delegate

@synthesize delegate = _delegate;

#pragma mark Queue

- (void)enqueueOperationWithBlock:(void (^)(void))block;
{
    // Assume that only _session targeted invocations are async
    [_queue addOperationWithBlock:block];
}

#pragma mark Connection

- (void)connect;
{
    // Try an empty request to see how far we get, and learn starting directory
    [_session findHomeDirectoryWithCompletionHandler:^(NSString *path, NSError *error) {
        
        if (path)
        {
            [self setCurrentDirectory:path];
                        
            if ([[self delegate] respondsToSelector:@selector(connection:didConnectToHost:error:)])
            {
                [[self delegate] connection:self didConnectToHost:[[_request URL] host] error:nil];
            }
        }
        else
        {
            [[self delegate] connection:self didReceiveError:error];
        }
    }];
}

- (void)disconnect;
{
    [self enqueueOperationWithBlock:^{
        [self forceDisconnect];
    }];
}

- (void)forceDisconnect
{
    // Cancel all in queue
    [_queue cancelAllOperations];
    
    [self enqueueOperationWithBlock:^{
        [self threaded_disconnect];
    }];
}

- (void)threaded_disconnect;
{
    if ([[self delegate] respondsToSelector:@selector(connection:didDisconnectFromHost:)])
    {
        id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
        [proxy connection:self didDisconnectFromHost:[[_request URL] host]];
        [proxy release];
    }
}

#pragma mark Requests

- (void)cancelAll { }

- (NSString *)canonicalPathForPath:(NSString *)path;
{
    // Heavily based on +ks_stringWithPath:relativeToDirectory: in KSFileUtilities
    
    if ([path isAbsolutePath]) return path;
    
    NSString *directory = [self currentDirectory];
    if (!directory) return path;
    
    NSString *result = [directory stringByAppendingPathComponent:path];
    return result;
}

- (CKTransferRecord *)uploadFileAtURL:(NSURL *)url toPath:(NSString *)path openingPosixPermissions:(unsigned long)permissions;
{
    return [self uploadData:[NSData dataWithContentsOfURL:url] toPath:path openingPosixPermissions:permissions];
}

- (CKTransferRecord *)uploadData:(NSData *)data toPath:(NSString *)path openingPosixPermissions:(unsigned long)permissions;
{
    NSParameterAssert(data);
    
    CKTransferRecord *result = [CKTransferRecord recordWithName:[path lastPathComponent] size:[data length]];
    //CFDictionarySetValue((CFMutableDictionaryRef)_transferRecordsByRequest, request, result);
    
    path = [self canonicalPathForPath:path];
    
    [self enqueueOperationWithBlock:^{
        
        [_queue setSuspended:YES];
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            [_session createFileAtPath:path contents:data withIntermediateDirectories:NO progressBlock:^(NSUInteger bytesWritten, NSError *error) {
                
                if (bytesWritten != 0) return;  // don't care about progress updates
                
                if ([[self delegate] respondsToSelector:@selector(connection:uploadDidFinish:error:)])
                {
                    id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
                    [proxy connection:self uploadDidFinish:path error:(result ? nil : error)];
                    [proxy release];
                }
                
                [_queue setSuspended:NO];
            }];
        }];
    }];
    
    return result;
}

- (void)createDirectoryAtPath:(NSString *)path posixPermissions:(NSNumber *)permissions;
{
    [self enqueueOperationWithBlock:^{
        
        [_queue setSuspended:YES];
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            [_session createDirectoryAtPath:path withIntermediateDirectories:NO completionHandler:^(NSError *error) {
                
                if (!error && permissions)
                {
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        
                        [_session setAttributes:[NSDictionary dictionaryWithObject:permissions forKey:NSFilePosixPermissions]
                                   ofItemAtPath:path
                              completionHandler:^(NSError *error) {
                                  
                                  id delegate = [self delegate];
                                  if ([delegate respondsToSelector:@selector(connection:didCreateDirectory:error:)])
                                  {
                                      id proxy = [[UKMainThreadProxy alloc] initWithTarget:delegate];
                                      [proxy connection:self didCreateDirectory:path error:error];
                                      [proxy release];
                                  }
                                  
                                  [_queue setSuspended:NO];
                              }];
                    }];
                    
                    return;
                }
                
                id delegate = [self delegate];
                if ([delegate respondsToSelector:@selector(connection:didCreateDirectory:error:)])
                {
                    id proxy = [[UKMainThreadProxy alloc] initWithTarget:delegate];
                    [proxy connection:self didCreateDirectory:path error:error];
                    [proxy release];
                }
                
                [_queue setSuspended:NO];
            }];
        }];
    }];
}

- (void)setPermissions:(unsigned long)permissions forFile:(NSString *)path;
{
    [self enqueueOperationWithBlock:^{
        
        [_queue setSuspended:YES];
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            NSDictionary *attributes = [NSDictionary dictionaryWithObject:@(permissions) forKey:NSFilePosixPermissions];
            
            [_session setAttributes:attributes ofItemAtPath:path completionHandler:^(NSError *error) {
                
                id delegate = [self delegate];
                if ([delegate respondsToSelector:@selector(connection:didSetPermissionsForFile:error:)])
                {
                    id proxy = [[UKMainThreadProxy alloc] initWithTarget:delegate];
                    [proxy connection:self didSetPermissionsForFile:path error:error];
                    [proxy release];
                }
                
                [_queue setSuspended:NO];
            }];
        }];
    }];
}

- (void)deleteFile:(NSString *)path
{
    path = [self canonicalPathForPath:path];
    
    [self enqueueOperationWithBlock:^{
        
        [_queue setSuspended:YES];
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            [_session removeFileAtPath:path completionHandler:^(NSError *error) {
                
                id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
                [proxy connection:self didDeleteFile:path error:error];
                [proxy release];
                
                [_queue setSuspended:NO];
            }];
        }];
    }];
}

- (void)directoryContents
{
    NSString *path = [self currentDirectory];
    
    [self enqueueOperationWithBlock:^{
        
        [_queue setSuspended:YES];
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            NSMutableArray *result = [[NSMutableArray alloc] init];
            
            [_session enumerateContentsOfDirectoryAtPath:path usingBlock:^(NSDictionary *parsedResourceListing, NSError *error) {
                
                if (parsedResourceListing)
                {
                    // Convert from CFFTP's format to ours
                    NSString *type = NSFileTypeUnknown;
                    switch ([[parsedResourceListing objectForKey:(NSString *)kCFFTPResourceType] integerValue])
                    {
                        case DT_CHR:
                            type = NSFileTypeCharacterSpecial;
                            break;
                        case DT_DIR:
                            type = NSFileTypeDirectory;
                            break;
                        case DT_BLK:
                            type = NSFileTypeBlockSpecial;
                            break;
                        case DT_REG:
                            type = NSFileTypeRegular;
                            break;
                        case DT_LNK:
                            type = NSFileTypeSymbolicLink;
                            break;
                        case DT_SOCK:
                            type = NSFileTypeSocket;
                            break;
                    }
                    
                    NSDictionary *attributes = [[NSDictionary alloc] initWithObjectsAndKeys:
                                                [parsedResourceListing objectForKey:(NSString *)kCFFTPResourceName], cxFilenameKey,
                                                type, NSFileType,
                                                nil];
                    [result addObject:attributes];
                    [attributes release];
                }
                else
                {
                    id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
                    
                    [proxy connection:self
                   didReceiveContents:(error ? nil : result)
                          ofDirectory:(path ? path : @"")   // so Open Panel has something to go on initially
                                error:error];
                    
                    [proxy release];
                    [result release];
                    
                    [_queue setSuspended:NO];
                }
            }];
        }];
    }];
}

#pragma mark Current Directory

@synthesize currentDirectory = _currentDirectory;

- (void)changeToDirectory:(NSString *)dirPath
{
    [self setCurrentDirectory:dirPath];
    
    [self enqueueOperationWithBlock:^{
        [self threaded_changedToDirectory:dirPath];
    }];
}

- (void)threaded_changedToDirectory:(NSString *)dirPath;
{
    if ([[self delegate] respondsToSelector:@selector(connection:didChangeToDirectory:error:)])
    {
        id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
        [proxy connection:self didChangeToDirectory:dirPath error:nil];
        [proxy release];
    }
}

- commandQueue { return nil; }
- (void)cleanupConnection { }

#pragma mark Delegate

- (void)FTPSession:(CURLFTPSession *)session didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    [[self delegate] connection:self didReceiveAuthenticationChallenge:challenge];
}

- (void)FTPSession:(CURLFTPSession *)session didReceiveDebugInfo:(NSString *)string ofType:(curl_infotype)type;
{
    if (![self delegate]) return;
    
    id proxy = [[UKMainThreadProxy alloc] initWithTarget:[self delegate]];
    [proxy connection:self appendString:string toTranscript:(type == CURLINFO_HEADER_IN ? CKTranscriptReceived : CKTranscriptSent)];
    [proxy release];
}

@end
