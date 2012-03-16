//
//  XDefaultPathController.m
//  xDrive
//
//  Created by Chris Gibbs on 9/22/11.
//  Copyright (c) 2011 Abilene Christian University. All rights reserved.
//

#import "DefaultPathController.h"
#import "XDriveConfig.h"
#import "XDefaultPath.h"



@interface DefaultPathController() <XServiceRemoteDelegate>

@property (nonatomic, weak) SetupController *setupController;
	// View controller to receive status notifications

@property (nonatomic, strong) XServer *xServer;
	// Server object to fetch default paths from

@property (nonatomic, strong) NSMutableArray *pathDetails;
	// The array of default paths to fetch

@property (nonatomic, assign) int activeFetchCount;
	// Counter that gets decremented when fetches return

@property (nonatomic, strong) NSMutableDictionary *iconToPathMap;
	// Map of icon file names and the paths they go to

- (void)receiveDefaultPaths:(NSArray *)details;
	// Creates an XDefaultPath object for each path returned and attaches them to the server

- (void)receiveDefaultPathDetails:(NSDictionary *)details;
	// Creates the default path directory and associates it with the XDefaultPath object

- (void)receiveDefaultPathIcon:(NSString *)tmpFilePath;
	// Moves the icon file to a permanent home and sets the path on the XDefaultPath object

- (XDefaultPath *)defaultPathWithPath:(NSString *)path;
	// Searches the XDefaultPath objects for one that matches the given path

- (NSString *)contextURLString;
	// Generates a URL to the configured server's context

@end




@implementation DefaultPathController


@synthesize setupController;
@synthesize xServer;


@synthesize pathDetails;
@synthesize activeFetchCount;
@synthesize iconToPathMap;



- (id)initWithController:(SetupController *)controller
{
	self = [super init];
	if (self)
	{
		self.setupController = controller;
	}
	return self;
}

- (void)dealloc
{
	self.iconToPathMap = nil;
	self.pathDetails = nil;
	self.xServer = nil;
	self.setupController = nil;
}



#pragma mark - Fetching

- (void)fetchDefaultPathsForServer:(XServer *)server
{
	xServer	= server;
	
	// Get the list of default paths
	[setupController defaultPathsStatusUpdate:@"Downloading defaults..."];
	[[XService sharedXService].remoteService fetchDefaultPathsForServer:xServer withDelegate:self];
}

- (void)initializeDefaultPaths
{
	// Map to associate fetched icons with their default path
	iconToPathMap = [[NSMutableDictionary alloc] init];
	
	// Start fetching directory contents and icons for each default path
	for (NSDictionary *defaultPath in pathDetails)
	{
		NSString *path = [defaultPath objectForKey:@"path"];
		
		// Get the default path's directory contents
		XDrvDebug(@"Fetching directory details for default path: %@", path);
		[[XService sharedXService].remoteService fetchDirectoryContentsAtPath:path withDelegate:self];
		activeFetchCount++;
		
		NSString *iconPath = [defaultPath objectForKey:@"icon"];
		if (iconPath)
		{
			// Get the default path's icon
			iconPath = [[self contextURLString] stringByAppendingString:iconPath];
			XDrvDebug(@"Fetching icon: %@", iconPath);
			[[XService sharedXService].remoteService downloadFileAtAbsolutePath:iconPath ifModifiedSinceCachedDate:nil withDelegate:self];
			[iconToPathMap setObject:path forKey:[iconPath lastPathComponent]];
			activeFetchCount++;
			
			NSString *hiresIconPath = [defaultPath objectForKey:@"icon@2x"];
			if (hiresIconPath)
			{
				// Get the default path's @2x icon
				hiresIconPath = [[self contextURLString] stringByAppendingString:hiresIconPath];
				XDrvDebug(@"Fetching @2x icon: %@", hiresIconPath);
				[[XService sharedXService].remoteService downloadFileAtAbsolutePath:hiresIconPath ifModifiedSinceCachedDate:nil withDelegate:self];
				[iconToPathMap setObject:path forKey:[iconPath lastPathComponent]];
				activeFetchCount++;
			}
		}
	}
}



#pragma mark - Receiving

- (void)receiveDefaultPaths:(NSArray *)details
{
	XDrvDebug(@"Got default paths");
	pathDetails = [[NSMutableArray alloc] init];
	NSMutableArray *tabBarOrder = [NSMutableArray arrayWithCapacity:[details count]];
	
	for (NSDictionary *path in details)
	{
		NSMutableDictionary *defaultPathDetails = [[NSMutableDictionary alloc] initWithDictionary:path];
		
		// Save path order
		[tabBarOrder addObject:[defaultPathDetails objectForKey:@"name"]];
		
		// Replace user placeholder in paths
		[defaultPathDetails setValue:[[defaultPathDetails objectForKey:@"path"] stringByReplacingOccurrencesOfString:@"${user}" withString:setupController.validateUser] forKey:@"path"];
		[pathDetails addObject:defaultPathDetails];
		
		// Create default path object
		[[XService sharedXService].localService createDefaultPathAtPath:[defaultPathDetails objectForKey:@"path"]
															   withName:[defaultPathDetails objectForKey:@"name"]];
	}
	
	// Add standard tab bar items and save order
	[tabBarOrder addObject:@"Recent"];
	[tabBarOrder addObject:@"Settings"];
	[XDriveConfig saveTabItemOrder:tabBarOrder];
	
	// All done
	[setupController defaultPathsValidated];
}

- (void)receiveDefaultPathDetails:(NSDictionary *)details
{	
	// Create directory
	XDirectory *directory = [[XService sharedXService] updateDirectoryDetails:details];
	
	if ([directory.path isEqualToString:@"/"])
		return;
	
	// Associate directory with default path
	XDefaultPath *defaultPath = [self defaultPathWithPath:directory.path];
	defaultPath.directory = directory;
	
	// Save
	[[XService sharedXService].localService saveWithCompletionBlock:^(NSError *error) {}];
}

- (void)receiveDefaultPathIcon:(NSString *)tmpFilePath
{
	// Move file to permanent home
	NSString *fileName = [tmpFilePath lastPathComponent];
	NSString *newFilePath = [[[[XService sharedXService] documentsPath] stringByAppendingString:@"-meta/icons"] 
							 stringByAppendingPathComponent:fileName];
	[[XService sharedXService] moveFileAtPath:tmpFilePath toPath:newFilePath];
	
	// Set icon path
	XDefaultPath *defaultPath = [self defaultPathWithPath:[iconToPathMap objectForKey:fileName]];
	XDrvDebug(@"Attaching icon %@ to default path %@", newFilePath, defaultPath.path);
	defaultPath.icon = newFilePath;
	
	// Save
	[[XService sharedXService].localService saveWithCompletionBlock:^(NSError *error) {}];
}



#pragma mark - Utils

- (XDefaultPath *)defaultPathWithPath:(NSString *)path
{
	XDefaultPath *defaultPath = nil;
	NSSet *defaultPaths = [XService sharedXService].localService.server.defaultPaths;
	for (XDefaultPath *dPath in defaultPaths)
	{
		if ([dPath.path isEqualToString:path])
		{
			defaultPath = dPath;
		}
	}
	return defaultPath;
}

- (NSString *)contextURLString
{
	return [NSString stringWithFormat:@"%@://%@:%i%@",
			xServer.protocol,
			xServer.hostname,
			[xServer.port intValue],
			xServer.context];
}



#pragma mark - XServiceRemoteDelegate

- (void)connectionFinishedWithResult:(NSObject *)result
{
	if (!xServer)
	{
		// A connection failed and we're in a reset state; do nothing
		return;
	}
	
	
	if (activeFetchCount == 0 && [result isKindOfClass:[NSArray class]])
	{
		// List of default paths
		[self receiveDefaultPaths:(NSArray *)result];
		return;
	}
	
	activeFetchCount--;
	
	if ([result isKindOfClass:[NSDictionary class]])
	{
		// Handle directory results
		[self receiveDefaultPathDetails:(NSDictionary *)result];
	}
	else if ([result isKindOfClass:[NSString class]])
	{
		// Handle icon file
		[self receiveDefaultPathIcon:(NSString *)result];
	}
	else
	{
		// No idea what this is
		XDrvLog(@"Unrecognized result: %@", result);
	}
	
	if (!activeFetchCount)
	{
		// All done getting default paths; notify delegate
		[setupController defaultPathsFinished];
	}
}

- (void)connectionFailedWithError:(NSError *)error
{
	XDrvLog(@"Connection failed: %@", error);
	
	// Update view
	[setupController defaultPathsFailedWithError:error];
	
	// Reset
	activeFetchCount = 0;
	pathDetails = nil;
	setupController = nil;
	xServer = nil;
}


@end










