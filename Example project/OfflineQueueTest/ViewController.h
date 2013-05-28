/*
ViewController.h
Created by Marco Arment on 8/30/11.

Copyright (c) 2011, Marco Arment
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Marco Arment nor the names of any contributors may 
      be used to endorse or promote products derived from this software without 
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL MARCO ARMENT BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(You may know this as the New BSD License.)
*/

#import <UIKit/UIKit.h>
#import "IPOfflineQueue.h"

@interface ViewController : UIViewController <IPOfflineQueueDelegate> {
    int lastTaskID;
}

- (IBAction)queueRunningSwitchChanged:(UISwitch *)sender;
- (IBAction)enqueueMoreTasksButtonTapped:(id)sender;
- (IBAction)enqueueDelayedTasksButtonTapped:(id)sender;
- (IBAction)clearQueueButtonTapped:(id)sender;
- (IBAction)filterQueueButtonTapped:(id)sender;
- (IBAction)releaseQueueButtonTapped:(id)sender;
- (IBAction)newQueueButtonTapped:(id)sender;
- (IBAction)enableTimerButtonTapped:(UIButton *)sender;

@property (nonatomic, retain) IPOfflineQueue *queue;
@property (nonatomic, retain) IBOutlet UISwitch *succeedSwitch;

@end
