/*******************************************************************************
 * Copyright (C) 2005-2016 Alfresco Software Limited.
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

#import "MainMenuReorderViewController.h"
#import "AppConfigurationManager.h"
#import "AccountManager.h"
#import "MainMenuLocalConfigurationBuilder.h"

#import "RealmSyncManager.h"

static NSString * const kSyncViewIdentifier = @"view-sync-default";

typedef NS_ENUM(NSUInteger, MainMenuReorderSections)
{
    MainMenuReorderSectionsVisible,
    MainMenuReorderSectionsHidden,
    MainMenuReorderSectionsTotalCount
};

static NSString * const kCellIdentifier = @"ReorderCellIdentifier";

@interface MainMenuReorderViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *visibleItems;
@property (nonatomic, strong) NSArray *oldData;
@property (nonatomic, strong) NSMutableArray *hiddenItems;
@property (nonatomic, strong) MainMenuBuilder *mainMenuBuilder;
@property (nonatomic, strong) UserAccount *account;
@property (nonatomic) BOOL isSyncPresent;
@property (nonatomic) BOOL isSyncVisible;
@end

@implementation MainMenuReorderViewController

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        self.visibleItems = [NSMutableArray array];
        self.hiddenItems = [NSMutableArray array];
        
    }
    return self;
}

- (instancetype)initWithAccount:(UserAccount *)userAccount session:(id<AlfrescoSession>)session
{
    self = [self init];
    if (self)
    {
        self.account = userAccount;
        self.mainMenuBuilder = [[MainMenuLocalConfigurationBuilder alloc] initWithAccount:userAccount session:nil];
    }
    return self;
}

- (void)loadView
{
    UIView *view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    
    UITableView *tableView = [[UITableView alloc] initWithFrame:view.frame style:UITableViewStyleGrouped];
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [view addSubview:tableView];
    self.tableView = tableView;
    
    view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.view = view;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.title = NSLocalizedString(@"main.menu.reorder.title", @"Reorder Title");
    
    UIBarButtonItem *saveBarButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    self.navigationItem.rightBarButtonItem = saveBarButton;
    
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellIdentifier];
    [self.tableView setEditing:YES];
    UIEdgeInsets inset = UIEdgeInsetsMake(0, 5, 0, 0);
    self.tableView.separatorInset = inset;
    
    [self loadData];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    [[AnalyticsManager sharedManager] trackScreenWithName:kAnalyticsViewAccountEditEditMainMenu];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    // If the order or visibility has changed
    if (![self.oldData isEqualToArray:self.visibleItems])
    {
        [[AppConfigurationManager sharedManager] saveVisibleMenuItems:self.visibleItems hiddenMenuItems:self.hiddenItems forAccount:self.account];
        
        NSString *label = [AccountManager sharedManager].selectedAccount.accountType == UserAccountTypeOnPremise ? kAnalyticsEventLabelOnPremise : kAnalyticsEventLabelCloud;
        
        [[AnalyticsManager sharedManager] trackEventWithCategory:kAnalyticsEventCategoryAccount
                                                          action:kAnalyticsEventActionUpdateMenu
                                                           label:label
                                                           value:@1];

        // Only need to post a notification informing the app if the current account order has been modified
        if ([AccountManager sharedManager].selectedAccount == self.account)
        {
            [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoConfigShouldUpdateMainMenuNotification object:self.mainMenuBuilder];
        }
        else
        {
            [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoConfigFileDidUpdateNotification object:self.mainMenuBuilder];
        }
    }
}

#pragma mark - Private Methods

- (void)loadData
{
    MBProgressHUD *progress = [[MBProgressHUD alloc] initWithView:self.view];
    progress.mode = MBProgressHUDModeIndeterminate;
    progress.labelText = NSLocalizedString(@"main.menu.reorder.retrieving.profiles", @"");
    progress.removeFromSuperViewOnHide = YES;
    [self.view addSubview:progress];
    [progress show:YES];
    [self.mainMenuBuilder sectionsForContentGroupWithCompletionBlock:^(NSArray *sections) {
        AppConfigurationManager *configManager = [AppConfigurationManager sharedManager];
        
        NSMutableArray *sectionsForConfigGroup = sections.mutableCopy;
        MainMenuSection *firstSection = sectionsForConfigGroup.firstObject;
        
        // Let the app configuration manager determine which of these items should be displayed and update the visibility flag
        [[AppConfigurationManager sharedManager] setVisibilityForMenuItems:firstSection.allSectionItems forAccount:self.account];
        
        // Order the visible and hidden items
        NSArray *sortedVisibleItems = [configManager orderedArrayFromUnorderedMainMenuItems:firstSection.visibleSectionItems
                                                                    usingOrderedIdentifiers:[configManager visibleItemIdentifiersForAccount:self.account]
                                                                      appendNotFoundObjects:NO];
        
        NSArray *sortedHiddenItems = [configManager orderedArrayFromUnorderedMainMenuItems:firstSection.hiddenSectionItems
                                                                   usingOrderedIdentifiers:[configManager hiddenItemIdentifiersForAccount:self.account]
                                                                     appendNotFoundObjects:NO];
        
        self.visibleItems = sortedVisibleItems.mutableCopy;
        self.oldData = sortedVisibleItems;
        self.hiddenItems = sortedHiddenItems.mutableCopy;
        
        [self determineSyncMenuItemInitialStatus];
        
        [progress hide:YES];
        [self.tableView reloadData];
    }];
}

- (NSMutableArray *)arrayForSection:(MainMenuReorderSections)section
{
    NSMutableArray *returnArray = nil;
    
    switch (section)
    {
        case MainMenuReorderSectionsVisible:
        {
            returnArray = self.visibleItems;
        }
        break;
            
        case MainMenuReorderSectionsHidden:
        {
            returnArray = self.hiddenItems;
        }
        break;
            
        default:
            break;
    }
    
    return returnArray;
}

- (void)determineSyncMenuItemInitialStatus
{
    self.isSyncPresent = NO;
    self.isSyncVisible = NO;
    for(MainMenuItem *item in self.visibleItems)
    {
        if([item.itemIdentifier isEqualToString:kSyncViewIdentifier])
        {
            self.isSyncPresent = YES;
            self.isSyncVisible = YES;
        }
    }
    for(MainMenuItem *item in self.hiddenItems)
    {
        if([item.itemIdentifier isEqualToString:kSyncViewIdentifier])
        {
            self.isSyncPresent = YES;
        }
    }
}

- (void)moveSyncMenuItemToVisibleItems
{
    MainMenuItem *syncMenuItem = nil;
    for(int i = 0; i < self.hiddenItems.count; i++)
    {
        MainMenuItem *item = self.hiddenItems[i];
        if([item.itemIdentifier isEqualToString:kSyncViewIdentifier])
        {
            syncMenuItem = item;
        }
    }
    
    if(syncMenuItem)
    {
        [self.hiddenItems removeObject:syncMenuItem];
        [self.visibleItems addObject:syncMenuItem];
    }
    
    [self.tableView reloadData];
}

- (void)disableSync
{
    [[RealmSyncManager sharedManager] disableSyncForAccount:self.account fromViewController:self cancelBlock:^{
        [self moveSyncMenuItemToVisibleItems];
    } completionBlock:^{
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)save
{
    // If the order or visibility has changed
    if (![self.oldData isEqualToArray:self.visibleItems])
    {
        if(self.isSyncPresent)
        {
            if(self.isSyncVisible)
            {
                //check if the sync menu item is now in the hidden items
                BOOL syncWasMovedToHiddedItems = NO;
                for(MainMenuItem *item in self.hiddenItems)
                {
                    if([item.itemIdentifier isEqualToString:kSyncViewIdentifier])
                    {
                        syncWasMovedToHiddedItems = YES;
                    }
                }
                
                if(syncWasMovedToHiddedItems)
                {
                    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"action.disablesync.title", @"Disable sync?") message:NSLocalizedString(@"action.disablesync.message", @"This will disable sync") preferredStyle:UIAlertControllerStyleAlert];
                    [confirmAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                        [self moveSyncMenuItemToVisibleItems];
                    }]];
                    [confirmAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"action.disablesync.confirm", @"Confirm") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                        [self disableSync];
                    }]];
                    
                    [self presentViewController:confirmAlert animated:YES completion:nil];
                }
            }
            else
            {
                //check if the sync menu item is now in the visible items
                for(MainMenuItem *item in self.visibleItems)
                {
                    if([item.itemIdentifier isEqualToString:kSyncViewIdentifier])
                    {
                        [[RealmSyncManager sharedManager] realmForAccount:self.account.accountIdentifier];
                    }
                }
                [self.navigationController popViewControllerAnimated:YES];
            }
        }
    }
    else
    {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - UITableViewDataSourceDelegate Methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return MainMenuReorderSectionsTotalCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray *sectionArray = [self arrayForSection:section];
    return sectionArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    
    NSArray *dataArray = [self arrayForSection:indexPath.section];
    MainMenuItem *currentItem = dataArray[indexPath.row];

    cell.textLabel.text = NSLocalizedString(currentItem.itemIdentifier, @"Main Menu Item Title");
    cell.showsReorderControl = YES;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
    cell.imageView.image = currentItem.itemImage;
    
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSString *headerText = nil;
    
    switch (section)
    {
        case MainMenuReorderSectionsVisible:
        {
            headerText = NSLocalizedString(@"main.menu.reorder.header.visible.title", @"Visible title");
        }
        break;
            
        case MainMenuReorderSectionsHidden:
        {
            headerText = NSLocalizedString(@"main.menu.reorder.header.hidden.title", @"Hidden title");
        }
        break;
    }
    
    return headerText;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *footerText = nil;
    
    if (section == MainMenuReorderSectionsVisible)
    {
        footerText = NSLocalizedString(@"main.menu.reorder.footer.visible.description", @"Visible Section Description");
    }
    
    return footerText;
}

#pragma mark - UITableViewDelegate Methods

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath
{
    NSMutableArray *removalArray = [self arrayForSection:sourceIndexPath.section];
    NSMutableArray *insertArray = [self arrayForSection:destinationIndexPath.section];
    
    MainMenuItem *movingItem = removalArray[sourceIndexPath.row];
    
    if (movingItem)
    {
        [removalArray removeObjectAtIndex:sourceIndexPath.row];
        [insertArray insertObject:movingItem atIndex:destinationIndexPath.row];
        
        // set the flag on the object
        if (destinationIndexPath.section == MainMenuReorderSectionsHidden)
        {
            movingItem.hidden = YES;
        }
        else if (destinationIndexPath.section == MainMenuReorderSectionsVisible)
        {
            movingItem.hidden = NO;
        }
    }
    
    AlfrescoLogDebug(@"\n\nVisible Array: %@\n\n\n\nHidden Array: %@", self.visibleItems, self.hiddenItems);
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

@end
