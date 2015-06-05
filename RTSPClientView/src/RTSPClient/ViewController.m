//
//  ViewController.m
//  RTSPClient
//
//  Created by jhsys on 12-11-20.
//  Copyright (c) 2012年 com.jhsys. All rights reserved.
//

#include "AppDelegate.h"
#import "ViewController.h"
#import "RTSPClientView.h"
#include <sys/time.h>

RTSPClientView* view1 = NULL, *view2 = NULL;

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    
    NSString* url = @"rtsp://192.168.3.203:8203/v1.3gp";
    NSString* url1 = @"rtsp://192.168.188.100:8100/v1.3gp";
    [url1 copy];
    
    printf("========== %p, %p, %s, %s\n", url, url1, [url UTF8String], [url1 UTF8String]);
    
    RTSPClientView* view1 = [[RTSPClientView alloc] initWithFrame:CGRectMake(0, 0, 352, 288)];
    view1.backgroundColor = [UIColor grayColor];
    [view1 rtsp_open:url];
    [self.view addSubview: view1];
//    self.view.backgroundColor = [UIColor blackColor];
//    sleep(2);
    
//    CGRect rect = view1.frame;
//    rect.origin.x = view1.frame.size.width +10;
//    view2 = [[RTSPClientView alloc] init];
//    view2.backgroundColor = [UIColor grayColor];
//    [view2 rtsp_open:url1];
//    view2.frame = rect;
//    [self.view addSubview: view2];
//    sleep(2);
    
//    rect.origin.y = 0;
//    rect.origin.x = view1.frame.size.width +10;
//    RTSPClientView* view3 = [[RTSPClientView alloc] init];
//    view3.backgroundColor = [UIColor grayColor];
//    [view3 rtsp_open:url1];
//    view3.frame = rect;
//    [self.view addSubview: view3];
//    
//    rect.origin.y = view2.frame.origin.y;
//    rect.origin.x = view3.frame.origin.x;
//    RTSPClientView* view4 = [[RTSPClientView alloc] init];
//    view4.backgroundColor = [UIColor grayColor];
//    [view4 rtsp_open:url];
//    view4.frame = rect;
//    [self.view addSubview: view4];
    
//    [NSThread detachNewThreadSelector:@selector(camera_turn_test:) toTarget:self withObject:view2];
}

- (void)camera_turn_test:(RTSPClientView*)view1
{
    sleep(30);
    struct timeval tv = {0, 0};
    gettimeofday(&tv, NULL);
    printf("rtsp_close, %ld, %d\n", tv.tv_sec, tv.tv_usec);
    [view1 rtsp_close];
    gettimeofday(&tv, NULL);
    printf("has closed, %ld, %d\n", tv.tv_sec, tv.tv_usec);
    return;
    
    int last_v = 0, v = 0;
    srand(time(NULL));
    while(1)
    {
        while (v == last_v) {
            v = rand() % 6 + 1;
        }
        
        last_v = v;
        switch (v) {
            case 1:
                [view1 turn_up];
                break;
                
            case 2:
                [view1 turn_down];
                break;
                
            case 3:
                [view1 turn_left];
                break;
                
            case 4:
                [view1 turn_right];
                break;
                
            case 5:
                [view1 turn_stop];
                break;
                
            case 6:
                [view1 turn_loop];
                break;
                
            default:
                [view1 turn_loop];
                break;
        }
        
        printf("conn_status: %d, turn_code - %d\n", [view1 conn_status], v);
        
        if(v != 5)
            sleep(1);
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
