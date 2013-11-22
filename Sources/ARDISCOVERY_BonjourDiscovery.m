//
//  ARDiscovery.m
//  ARSDK 3
//
//  Created by Nicolas BRULEZ on 08/03/13.
//  Copyright (c) 2013 Parrot SA. All rights reserved.
//
#include <arpa/inet.h>
#import <libARDiscovery/ARDISCOVERY_BonjourDiscovery.h>
#import <libARDiscovery/ARDISCOVERY_Discovery.h>
#import <netdb.h>

#define kServiceNetControllerType                   @"_arsdk-ff3._udp."
#define kServiceNetDomain                           @"local."

#define ARBLESERVICE_BLE_MANUFACTURER_DATA_LENGTH   8
#define ARBLESERVICE_PARROT_BT_VENDOR_ID            0X0043  // Parrot Company ID registered by Bluetooth SIG (Bluetooth Specification v4.0 Requirement)
#define ARBLESERVICE_PARROT_USB_VENDOR_ID           0x19cf  // Official Parrot USB Vendor ID

#define kServiceResolutionTimeout                   5.f    // Time in seconds
#define kServiceBLERefreshTime                      10.f    // Time in seconds

#define CHECK_VALID(DEFAULT_RETURN_VALUE)       \
    do                                          \
    {                                           \
        if (! self.valid)                       \
        {                                       \
            return DEFAULT_RETURN_VALUE;        \
        }                                       \
    } while (0)

#pragma mark - ARBLEService implementation

@implementation ARBLEService

@end

@implementation ARService

- (BOOL)isEqual:(id)object
{
    ARService *otherService = (ARService *)object;
    return ([self.name isEqualToString:[otherService name]] && (self.productID == otherService.productID));
}

@end

#pragma mark Private part
@interface ARDiscovery () <NSNetServiceBrowserDelegate, NSNetServiceDelegate, CBCentralManagerDelegate>

#pragma mark - Controller/Devices Services list
@property (strong, nonatomic) NSMutableDictionary *controllersServicesList;
@property (strong, nonatomic) NSMutableDictionary *devicesServicesList;

#pragma mark - Current published service
@property (strong, nonatomic) NSNetService *currentPublishedService;
@property (strong, nonatomic) NSNetService *tryPublishService;

#pragma mark - Services browser / resolution
@property (strong, nonatomic) ARService *currentResolutionService;
@property (strong, nonatomic) NSNetServiceBrowser *controllersServiceBrowser;
@property (strong, nonatomic) NSMutableArray *devicesServiceBrowsers;

#pragma mark - Services CoreBluetooth
@property (strong, nonatomic) CBCentralManager *centralManager;
@property (strong, nonatomic) NSMutableDictionary *devicesBLEServicesTimerList;

#pragma mark - Object properly created
@property (nonatomic) BOOL valid;

#pragma mark - Object properly created
@property (nonatomic) BOOL isNSNetDiscovering;
@property (nonatomic) BOOL isCBDiscovering;

@end

#pragma mark Implementation
@implementation ARDiscovery

@synthesize controllersServicesList;
@synthesize devicesServicesList;
@synthesize devicesBLEServicesTimerList;
@synthesize currentPublishedService;
@synthesize tryPublishService;
@synthesize currentResolutionService;
@synthesize controllersServiceBrowser;
@synthesize devicesServiceBrowsers;
@synthesize centralManager;
@synthesize valid;
@synthesize isNSNetDiscovering;
@synthesize isCBDiscovering;

#pragma mark - Init
+ (ARDiscovery *)sharedInstance
{
    static ARDiscovery *_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
            _sharedInstance = [[ARDiscovery alloc] init];

            /**
             * Services list init
             */
            _sharedInstance.controllersServicesList = [[NSMutableDictionary alloc] init];
            _sharedInstance.devicesServicesList = [[NSMutableDictionary alloc] init];
            _sharedInstance.devicesBLEServicesTimerList = [[NSMutableDictionary alloc] init];

            /**
             * Current published service init
             */
            _sharedInstance.currentPublishedService = nil;
            _sharedInstance.tryPublishService = nil;

            /**
             * Services browser / resolution init
             */
            _sharedInstance.controllersServiceBrowser = [[NSNetServiceBrowser alloc] init];
            [_sharedInstance.controllersServiceBrowser setDelegate:_sharedInstance];
            _sharedInstance.devicesServiceBrowsers = [[NSMutableArray alloc] init];
            for (int i = ARDISCOVERY_PRODUCT_NSNETSERVICE; i < ARDISCOVERY_PRODUCT_BLESERVICE; ++i)
            {
                NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
                [browser setDelegate:_sharedInstance];
                [_sharedInstance.devicesServiceBrowsers addObject:browser];
            }

            _sharedInstance.currentResolutionService = nil;

            /**
             * Creation was done as a shared instance
             */
            _sharedInstance.valid = YES;

            /**
             * Discover is not in progress
             */
            _sharedInstance.isNSNetDiscovering = NO;
            _sharedInstance.isCBDiscovering = NO;
        });

    return _sharedInstance;
}

#pragma mark - Getters
- (NSArray *)getCurrentListOfDevicesServices
{
    NSArray *array = nil;
    CHECK_VALID(array);
    @synchronized (self)
    {
        array = [[self.devicesServicesList allValues] copy];
    }
    return array;
}

- (NSArray *)getCurrentListOfControllersServices
{
    NSArray *array = nil;
    CHECK_VALID(array);
    @synchronized (self)
    {
        array = [[self.controllersServicesList allValues] copy];
    }
    return array;
}

- (NSString *)getCurrentPublishedServiceName
{
    NSString *name = nil;
    CHECK_VALID(name);
    @synchronized (self)
    {
        name = [[self.currentPublishedService name] copy];
    }
    return name;
}

#pragma mark - Discovery
- (BOOL)isNetServiceValid:(NSNetService *)aNetService
{
    for (int i = ARDISCOVERY_PRODUCT_NSNETSERVICE; i < ARDISCOVERY_PRODUCT_BLESERVICE; ++i)
    {
        NSString *deviceType = [NSString stringWithFormat:kServiceNetDeviceFormat, ARDISCOVERY_getProductID(i)];
        if ([aNetService.type isEqualToString:deviceType])
            return YES;
    }
    return NO;
}

- (void)resolveService:(ARService *)aService
{
    CHECK_VALID();
    @synchronized (self)
    {
        if(self.currentResolutionService != nil)
        {
            [[self.currentResolutionService service] stop];
        }
        
        self.currentResolutionService = aService;
        [[self.currentResolutionService service] setDelegate:self];
        [[self.currentResolutionService service] resolveWithTimeout:kServiceResolutionTimeout];
    }
}

- (void)start
{
    if (!isNSNetDiscovering)
    {
        /**
         * Start NSNetServiceBrowser
         */
        [controllersServiceBrowser searchForServicesOfType:kServiceNetControllerType inDomain:kServiceNetDomain];
        for (int i = 0; i < [devicesServiceBrowsers count]; ++i)
        {
            NSNetServiceBrowser *browser = [devicesServiceBrowsers objectAtIndex:i];
            [browser searchForServicesOfType:[NSString stringWithFormat:kServiceNetDeviceFormat, ARDISCOVERY_getProductID(i)] inDomain:kServiceNetDomain];
        }
        
        isNSNetDiscovering = YES;
    }
    
    if (!isCBDiscovering)
    {
        /**
         * Start CoreBluetooth discovery
         */
        centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
}

- (void)stop
{
    if (isNSNetDiscovering)
    {
        /**
         * Stop NSNetServiceBrowser
         */
        [controllersServiceBrowser stop];
        for (NSNetServiceBrowser *browser in devicesServiceBrowsers)
        {
            [browser stop];
        }
        isNSNetDiscovering = NO;
    }
    
    if (isCBDiscovering)
    {
        /**
         * Stop CBCentralManager
         */
        centralManager = nil;
        isCBDiscovering = NO;
    }
}

- (NSString *)convertNSNetServiceToIp:(ARService *)aService
{
    NSString *name = nil;
    NSData *address = nil;
    struct sockaddr_in *socketAddress = nil;
    NSString *ipString = nil;
    int port;
    
    name = [[aService service] name];
    address = [[[aService service] addresses] objectAtIndex: 0];
    socketAddress = (struct sockaddr_in *) [address bytes];
    ipString = [NSString stringWithFormat: @"%s",inet_ntoa(socketAddress->sin_addr)];
    port = socketAddress->sin_port;
    
    // This will print the IP and port for you to connect to.
    NSLog(@"%@", [NSString stringWithFormat:@"Resolved:%@-->%@:%u\n", [[aService service] hostName], ipString, port]);

    return ipString;
}

#pragma mark - Publication
- (NSString *)uniqueNameFromServiceName:(NSString *)sname isController:(BOOL)isController
{
    NSString *rname = [sname copy];

    int addCount = 1;

    NSArray *servicesCopy;
    if (isController)
    {
        servicesCopy = [self getCurrentListOfControllersServices];
    }
    else
    {
        servicesCopy = [self getCurrentListOfDevicesServices];
    }
    BOOL rnameIsUnique = YES;
    do {
        rnameIsUnique = YES;
        for (NSNetService *ns in servicesCopy) {
            if ([rname isEqualToString:[ns name]])
            {
                rnameIsUnique = NO;
                break;
            }
        }
        if (! rnameIsUnique)
        {
            rname = [sname stringByAppendingFormat:@"%d", addCount++];
        }
    } while (! rnameIsUnique);
    return rname;
}

- (void)publishControllerServiceWithName:(NSString *)serviceName
{
    CHECK_VALID();
    @synchronized (self)
    {
        NSString *uniqueName = [self uniqueNameFromServiceName:serviceName isController:YES];
        [self.tryPublishService stop];
        self.tryPublishService = [[NSNetService alloc] initWithDomain:kServiceNetDomain type:kServiceNetControllerType name:uniqueName port:9];
        [self.tryPublishService setDelegate:self];
        [self.tryPublishService publish];
    }
}

- (void)unpublishService
{
    CHECK_VALID();
    @synchronized (self)
    {
        [self.tryPublishService stop];
        self.tryPublishService = nil;
        self.currentPublishedService = nil;
        [self sendPublishNotification];
    }
}

#pragma mark - NSNetServiceBrowser Delegate
- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didFindService:(NSNetService *)aNetService moreComing:(BOOL)moreComing
{
    @synchronized (self)
    {
        ARService *aService = [[ARService alloc] init];
        aService.name = [aNetService name];
        aService.service = aNetService;
        
        aService.productID = ARDISCOVERY_PRODUCT_MAX;

        
        if ([aNetService.type isEqualToString:kServiceNetControllerType])
        {
            [self.controllersServicesList setObject:aService forKey:aService.name];
            if (!moreComing)
            {
                [self sendControllersListUpdateNotification];
            }
        }
        else
        {
            for (int i = ARDISCOVERY_PRODUCT_NSNETSERVICE; i < ARDISCOVERY_PRODUCT_BLESERVICE; ++i)
            {
                NSString *deviceType = [NSString stringWithFormat:kServiceNetDeviceFormat, ARDISCOVERY_getProductID(i)];
                if ([aNetService.type isEqualToString:deviceType])
                {
                    aService.productID = ARDISCOVERY_getProductID(i);
                    break;
                }
            }
            
            if (aService.productID != ARDISCOVERY_PRODUCT_MAX)
            {
                [self.devicesServicesList setObject:aService forKey:aService.name];
                if (!moreComing)
                {
                    [self sendDevicesListUpdateNotification];
                }
            }
            else
            {
#ifdef DEBUG
                NSLog (@"Found an unknown service : %@", aNetService);
#endif
            }
        }
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didRemoveService:(NSNetService *)aNetService moreComing:(BOOL)moreComing
{
    @synchronized (self)
    {
        if ([self isNetServiceValid:aNetService])
        {
            ARService *aService = (ARService *)[self.devicesServicesList objectForKey:aNetService.name];
            if (aService != nil)
            {
                NSLog(@"Removed service %@ : %@", aService.name, NSStringFromClass([[aService service] class]));
                [self.devicesServicesList removeObjectForKey:aService.name];
                if (!moreComing)
                {
                    [self sendDevicesListUpdateNotification];
                }
            }
        }
        else if ([[aNetService type] isEqual:kServiceNetControllerType])
        {
            ARService *aService = (ARService *)[self.controllersServicesList objectForKey:aNetService.name];
            if (aService != nil)
            {
                NSLog(@"Removed service %@ : %@", aService.name, NSStringFromClass([[aService service] class]));
                [self.controllersServicesList removeObjectForKey:aService.name];
                if (!moreComing)
                {
                    [self sendControllersListUpdateNotification];
                }
            }
        }
        else
        {
#ifdef DEBUG
            NSLog (@"Removed an unknown service : %@", aNetService);
#endif
        }
    }
}

#pragma mark - NSNetService Delegate
- (void)netService:(NSNetService *)service didNotPublish:(NSDictionary *)errorDict
{
    @synchronized (self)
    {
        self.currentPublishedService = nil;
        [self sendPublishNotification];
    }
}

- (void)netServiceDidPublish:(NSNetService *)service
{
    @synchronized (self)
    {
        self.currentPublishedService = service;
        [self sendPublishNotification];
    }
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict
{
    @synchronized (self)
    {
        self.currentResolutionService = nil;
        [self sendNotResolveNotification];
    }
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    @synchronized (self)
    {
        [self sendResolveNotification];
    }
}

#pragma mark - Refresh BLE services methods
- (void)deviceBLETimeout:(NSTimer *)timer
{
    ARService *aService = [timer userInfo];
    CBPeripheral *peripheral = ((ARBLEService *) aService.service).peripheral;
    [self.devicesBLEServicesTimerList removeObjectForKey:[peripheral.identifier UUIDString]];
    [self.devicesServicesList removeObjectForKey:[peripheral.identifier UUIDString]];
    [self sendDevicesListUpdateNotification];
}

#pragma mark - CBCentralManagerDelegate methods
- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    NSString *sNewState = @"New CBCentralManager state :";
    switch(central.state)
    {
        case CBCentralManagerStatePoweredOn:
            NSLog(@"%@ CBCentralManagerStatePoweredOn", sNewState);
            if (!isCBDiscovering)
            {
                // Start scanning peripherals
                [central scanForPeripheralsWithServices:nil options:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], CBCentralManagerScanOptionAllowDuplicatesKey, nil]];
                isCBDiscovering = YES;
            }
            break;
            
        case CBCentralManagerStateResetting:
            NSLog(@"%@ CBCentralManagerStateResetting", sNewState);
            isCBDiscovering = NO;
            break;
            
        case CBCentralManagerStateUnsupported:
            NSLog(@"%@ CBCentralManagerStateUnsupported", sNewState);
            isCBDiscovering = NO;
            break;
            
        case CBCentralManagerStateUnauthorized:
            NSLog(@"%@ CBCentralManagerStateUnauthorized", sNewState);
            isCBDiscovering = NO;
            break;
            
        case CBCentralManagerStatePoweredOff:
            NSLog(@"%@ CBCentralManagerStatePoweredOff", sNewState);
            isCBDiscovering = NO;
            break;
            
        default:
        case CBCentralManagerStateUnknown:
            NSLog(@"%@ CBCentralManagerStateUnknown", sNewState);
            isCBDiscovering = NO;
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI
{
    NSLog(@"Scanning %@", [peripheral name]);
    @synchronized (self)
    {
        if([peripheral name] != nil)
        {
            if ( [self isParrotBLEDevice:advertisementData] )
            {
                ARBLEService *service = [[ARBLEService alloc] init];
                service.centralManager = central;
                service.peripheral = peripheral;
                
                ARService *aService = [[ARService alloc] init];
                aService.name = [service.peripheral name];
                aService.service = service;
                
                NSData *manufacturerData = [advertisementData valueForKey:CBAdvertisementDataManufacturerDataKey];
                uint16_t *ids = (uint16_t *) manufacturerData.bytes;
                aService.productID = ids[2];

                NSTimer *timer = (NSTimer *)[self.devicesBLEServicesTimerList objectForKey:aService.name];
                if(timer != nil)
                {
                    [timer invalidate];
                    timer = nil;
                }

                [self.devicesServicesList setObject:aService forKey:[peripheral.identifier UUIDString]];
                timer = [NSTimer scheduledTimerWithTimeInterval:kServiceBLERefreshTime target:self selector:@selector(deviceBLETimeout:) userInfo:aService repeats:NO];
                [self.devicesBLEServicesTimerList setObject:timer forKey:[peripheral.identifier UUIDString]];
                [self sendDevicesListUpdateNotification];
            }
        }
    }
}

- (BOOL)isParrotBLEDevice:(NSDictionary *)advertisementData
{
    /* Read the advertisementData to check if it is a PARROT Delos device with the good version */

    BOOL res = NO;
    NSData *manufacturerData = [advertisementData valueForKey:CBAdvertisementDataManufacturerDataKey];

    if ((manufacturerData != nil) && (manufacturerData.length == ARBLESERVICE_BLE_MANUFACTURER_DATA_LENGTH))
    {
        uint16_t *ids = (uint16_t*) manufacturerData.bytes;
        
#ifdef DEBUG
        NSLog(@"manufacturer Data: BTVendorID:0x%.4x USBVendorID:0x%.4x USBProduitID=0x%.4x versionID=0x%.4x", ids[0], ids[1], ids[2], ids[3]);
#endif
        
        if ((ids[0] == ARBLESERVICE_PARROT_BT_VENDOR_ID) &&
            (ids[1] == ARBLESERVICE_PARROT_USB_VENDOR_ID) &&
            (ids[2] == ARDISCOVERY_getProductID(ARDISCOVERY_PRODUCT_ARDRONE_MINI)))
        {
            res = YES;
        }
    }

    return res;
}

#pragma mark - Notification sender
- (void)sendPublishNotification
{
    NSDictionary *userInfos = @{kARDiscoveryServiceName: [self getCurrentPublishedServiceName]};
    [[NSNotificationCenter defaultCenter] postNotificationName:kARDiscoveryNotificationServicePublished object:self userInfo:userInfos];
}

- (void)sendDevicesListUpdateNotification
{
    NSDictionary *userInfos = @{kARDiscoveryServicesList: [self getCurrentListOfDevicesServices]};
    [[NSNotificationCenter defaultCenter] postNotificationName:kARDiscoveryNotificationServicesDevicesListUpdated object:self userInfo:userInfos];
}

- (void)sendControllersListUpdateNotification
{
    NSDictionary *userInfos = @{kARDiscoveryServicesList: [self getCurrentListOfControllersServices]};
    [[NSNotificationCenter defaultCenter] postNotificationName:kARDiscoveryNotificationServicesControllersListUpdated object:self userInfo:userInfos];
}

- (void)sendResolveNotification
{
    NSDictionary *userInfos = @{kARDiscoveryServiceResolved: self.currentResolutionService};
    [[NSNotificationCenter defaultCenter] postNotificationName:kARDiscoveryNotificationServiceResolved object:self userInfo:userInfos];
}

- (void)sendNotResolveNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kARDiscoveryNotificationServiceNotResolved object:self userInfo:nil];
}

@end