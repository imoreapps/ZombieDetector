//
//  ViewController.m
//  ZombieDetector
//
//  Created by apple on 2017/11/28.
//  Copyright © 2017年 apple. All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 
    UIView *testView = [[UIView alloc] initWithFrame:CGRectMake(50, 50, 100, 100)];
    NSLog(@"VIEW: %p", (__bridge void *)testView);
    [testView release];
    for (int i = 0; i < 10; ++i) {
        UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(50, 50, 100, 100)] autorelease];
        [self.view addSubview:v];
        NSLog(@"v: %p", (__bridge void *)v);
    }
    NSLog(@"///VIEW: %p", (__bridge void *)testView);
    [testView setNeedsLayout];
}

@end
