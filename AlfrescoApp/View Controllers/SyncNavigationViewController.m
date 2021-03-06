/*******************************************************************************
 * Copyright (C) 2005-2014 Alfresco Software Limited.
 * 
 * This file is part of the Alfresco Mobile iOS App.
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *  
 *  http://www.apache.org/licenses/LICENSE-2.0
 * 
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 ******************************************************************************/
 
#import "SyncNavigationViewController.h"
#import "ProgressView.h"

static CGFloat const kProgressViewAnimationDuration = 0.2f;

@interface SyncNavigationViewController ()

@property (nonatomic, assign) NSInteger numberOfSyncOperations;
@property (nonatomic, assign) unsigned long long totalSyncSize;
@property (nonatomic, assign) unsigned long long syncedSize;
@property (nonatomic, strong) ProgressView *progressView;
@property (nonatomic, assign) BOOL isProgressViewShowing;

@end

@implementation SyncNavigationViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // setup navigation view frame
    CGRect navigationFrame = self.view.frame;
    navigationFrame.size.width = kRevealControllerMasterViewWidth;
    self.view.frame = navigationFrame;
    
    SyncManager *syncManager = [SyncManager sharedManager];
    syncManager.progressDelegate = self;
    
    self.progressView = [[ProgressView alloc] init];
    
    // setup progress view's frame to appear at the bottom of the navigation view
    CGRect progressViewFrame = self.progressView.frame;
    progressViewFrame.origin.y = navigationFrame.size.height;
    self.progressView.frame = progressViewFrame;
    [self.progressView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];
    
    [self.progressView.cancelButton addTarget:self action:@selector(cancelSyncOperations:) forControlEvents:UIControlEventTouchUpInside];
    
    [self.view addSubview:self.progressView];
}

#pragma mark - Sync Manager Progress Delegate Methods

- (void)numberOfSyncOperationsInProgress:(NSInteger)numberOfOperations
{
    self.numberOfSyncOperations = numberOfOperations;
    [self updateProgressDetails];
    
    if (numberOfOperations > 0)
    {
        [self showSyncProgressDetails];
    }
    else
    {
        [self hideSyncProgressDetails];
    }
}

- (void)totalSizeToSync:(unsigned long long)totalSize syncedSize:(unsigned long long)syncedSize
{
    self.totalSyncSize = totalSize;
    self.syncedSize = syncedSize;
    [self updateProgressDetails];
}

#pragma mark - private Methods

- (void)cancelSyncOperations:(id)sender
{
    SyncManager *syncManager = [SyncManager sharedManager];
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"sync.cancelAll.alert.title", @"Sync")
                                                    message:NSLocalizedString(@"sync.cancelAll.alert.message", @"Would you like to...")
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"sync.cancelAll.alert.button.continue", @"Continue")
                                          otherButtonTitles:NSLocalizedString(@"sync.cancelAll.alert.button.stop", @"Stop Sync"), nil];
    
    [alert showWithCompletionBlock:^(NSUInteger buttonIndex, BOOL isCancelButton) {
        
        if (!isCancelButton)
        {
            [syncManager cancelAllSyncOperations];
            self.syncedSize = 0;
            self.totalSyncSize = 0;
            self.progressView.progressBar.progress = 0.0f;
        }
    }];
}

- (void)showSyncProgressDetails
{
    if (!self.isProgressViewShowing)
    {
        CGRect navFrame = self.view.bounds;
        CGRect progressViewFrame = self.progressView.frame;
        progressViewFrame.origin.y = navFrame.size.height - progressViewFrame.size.height;
        
        [UIView animateWithDuration:kProgressViewAnimationDuration animations:^{
            self.progressView.frame = progressViewFrame;
        }];
        
        self.isProgressViewShowing = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:kSyncProgressViewVisiblityChangeNotification object:self];
    }
}

- (void)hideSyncProgressDetails
{
    self.totalSyncSize = 0;
    self.syncedSize = 0;
    self.progressView.progressBar.progress = 0.0f;
    
    if (self.isProgressViewShowing)
    {
        CGRect navFrame = self.view.bounds;
        CGRect progressViewFrame = self.progressView.frame;
        progressViewFrame.origin.y = navFrame.size.height;
        
        [UIView animateWithDuration:kProgressViewAnimationDuration animations:^{
            self.progressView.frame = progressViewFrame;
        }];
        
        self.isProgressViewShowing = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:kSyncProgressViewVisiblityChangeNotification object:self];
    }
}

- (void)updateProgressDetails
{
    NSString *leftToUpload = stringForLongFileSize(self.totalSyncSize - self.syncedSize);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.numberOfSyncOperations == 1)
        {
            self.progressView.progressInfoLabel.text = [NSString stringWithFormat:NSLocalizedString(@"sync.progress.label.singular", @"1 file, %@ left"), leftToUpload];
        }
        else
        {
            self.progressView.progressInfoLabel.text = [NSString stringWithFormat:NSLocalizedString(@"sync.progress.label.plural", @"%d file, %@ left"), self.numberOfSyncOperations, leftToUpload];
        }
        self.progressView.progressBar.progress = (float)self.syncedSize / (float)self.totalSyncSize;
    });
}

#pragma mark - Public Methods

- (BOOL)isProgressViewVisible
{
    return self.isProgressViewShowing;
}

- (CGFloat)progressViewHeight
{
    return self.progressView.frame.size.height;
}

@end
