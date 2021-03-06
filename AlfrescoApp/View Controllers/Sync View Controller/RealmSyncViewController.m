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

#import "RealmSyncViewController.h"
#import "ConnectivityManager.h"
#import "SyncCollectionViewDataSource.h"
#import "RealmSyncManager.h"
#import "UniversalDevice.h"
#import "PreferenceManager.h"
#import "AccountManager.h"

#import "SyncObstaclesViewController.h"
#import "SyncNavigationViewController.h"
#import "FailedTransferDetailViewController.h"
#import "FileFolderCollectionViewCell.h"
#import "ALFSwipeToDeleteGestureRecognizer.h"


static CGFloat const kCellHeight = 64.0f;
static CGFloat const kSyncOnSiteRequestsCompletionTimeout = 5.0; // seconds

static NSString * const kVersionSeriesValueKeyPath = @"properties.cmis:versionSeriesId.value";

@interface RealmSyncViewController () < RepositoryCollectionViewDataSourceDelegate >

@property (nonatomic) AlfrescoNode *parentNode;
@property (nonatomic, strong) AlfrescoDocumentFolderService *documentFolderService;
@property (nonatomic, strong) UIPopoverController *retrySyncPopover;
@property (nonatomic, strong) AlfrescoNode *retrySyncNode;
@property (nonatomic, assign) BOOL didSyncAfterSessionRefresh;

@property (nonatomic, strong) UIBarButtonItem *switchLayoutBarButtonItem;
@property (nonatomic, strong) UITapGestureRecognizer *tapToDismissDeleteAction;
@property (nonatomic, strong) ALFSwipeToDeleteGestureRecognizer *swipeToDeleteGestureRecognizer;
@property (nonatomic, strong) NSIndexPath *initialCellForSwipeToDelete;
@property (nonatomic) BOOL shouldShowOrHideDelete;
@property (nonatomic) CGFloat cellActionViewWidth;

@property (nonatomic, strong) SyncCollectionViewDataSource *dataSource;

@end

@implementation RealmSyncViewController

- (id)initWithParentNode:(AlfrescoNode *)node andSession:(id<AlfrescoSession>)session
{
    self = [super initWithSession:session];
    if (self)
    {
        self.session = session;
        self.parentNode = node;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if (self.parentNode != nil || ![[ConnectivityManager sharedManager] hasInternetConnection])
    {
        [self disablePullToRefresh];
    }
    
    [self adjustCollectionViewForProgressView:nil];
    
    UINib *cellNib = [UINib nibWithNibName:NSStringFromClass([FileFolderCollectionViewCell class]) bundle:nil];
    [self.collectionView registerNib:cellNib forCellWithReuseIdentifier:[FileFolderCollectionViewCell cellIdentifier]];
    
    self.collectionView.delegate = self;
    
    self.listLayout = [[BaseCollectionViewFlowLayout alloc] initWithNumberOfColumns:1 itemHeight:kCellHeight shouldSwipeToDelete:YES hasHeader:NO];
    self.listLayout.collectionViewMultiSelectDelegate = self;
    self.gridLayout = [[BaseCollectionViewFlowLayout alloc] initWithNumberOfColumns:3 itemHeight:-1 shouldSwipeToDelete:NO hasHeader:NO];
    self.gridLayout.collectionViewMultiSelectDelegate = self;
    
    //Swipe to Delete Gestures
    
    self.swipeToDeleteGestureRecognizer = [[ALFSwipeToDeleteGestureRecognizer alloc] initWithTarget:self action:@selector(swipeToDeletePanGestureHandler:)];
    self.swipeToDeleteGestureRecognizer.delegate = self;
    [self.collectionView addGestureRecognizer:self.swipeToDeleteGestureRecognizer];
    
    self.tapToDismissDeleteAction = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapToDismissDeleteGestureHandler:)];
    self.tapToDismissDeleteAction.numberOfTapsRequired = 1;
    self.tapToDismissDeleteAction.delegate = self;
    [self.collectionView addGestureRecognizer:self.tapToDismissDeleteAction];
    
    [self changeCollectionViewStyle:self.style animated:YES];
    
    [self addNotificationListeners];
    
    [self setupBarButtonItems];
    
    if (!self.didSyncAfterSessionRefresh || self.parentNode != nil)
    {
        self.documentFolderService = [[AlfrescoDocumentFolderService alloc] initWithSession:self.session];
        [self loadSyncNodesForFolder:self.parentNode];
        [self reloadCollectionView];
        self.didSyncAfterSessionRefresh = YES;
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Private methods
- (void)reloadCollectionView
{
    [super reloadCollectionView];
    self.collectionView.contentOffset = CGPointMake(0., 0.);
}

- (void)addNotificationListeners
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(siteRequestsCompleted:)
                                                 name:kAlfrescoSiteRequestsCompletedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSyncObstacles:)
                                                 name:kSyncObstaclesNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didUpdatePreference:)
                                                 name:kSettingsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nodeAdded:)
                                                 name:kAlfrescoNodeAddedOnServerNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(adjustCollectionViewForProgressView:)
                                                 name:kSyncProgressViewVisiblityChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(editingDocumentCompleted:)
                                                 name:kAlfrescoDocumentEditedNotification object:nil];
}

- (void)loadSyncNodesForFolder:(AlfrescoNode *)folder
{
    self.dataSource = [[SyncCollectionViewDataSource alloc] initWithParentNode:self.parentNode session:self.session delegate:self];
    
    self.listLayout.dataSourceInfoDelegate = self.dataSource;
    self.gridLayout.dataSourceInfoDelegate = self.dataSource;
    self.collectionView.dataSource = self.dataSource;
    
    self.title = self.dataSource.screenTitle;
    
    [self reloadCollectionView];
    [self hidePullToRefreshView];
}

- (void)setupBarButtonItems
{
    NSMutableArray *rightBarButtonItems = [NSMutableArray array];
    
    // update the UI based on permissions
    self.switchLayoutBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"dots-A"] style:UIBarButtonItemStylePlain target:self action:@selector(showLayoutSwitchPopup:)];
    
    [rightBarButtonItems addObject:self.switchLayoutBarButtonItem];
    
    [self.navigationItem setRightBarButtonItems:rightBarButtonItems animated:NO];
}

- (void)showLayoutSwitchPopup:(UIBarButtonItem *)sender
{
    [self setupActionsAlertController];
    self.actionsAlertController.modalPresentationStyle = UIModalPresentationPopover;
    UIPopoverPresentationController *popPC = [self.actionsAlertController popoverPresentationController];
    popPC.barButtonItem = self.switchLayoutBarButtonItem;
    popPC.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popPC.delegate = self;
    
    [self presentViewController:self.actionsAlertController animated:YES completion:nil];
}

- (void)setupActionsAlertController
{
    self.actionsAlertController = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSString *changeLayoutTitle;
    if(self.style == CollectionViewStyleList)
    {
        changeLayoutTitle = NSLocalizedString(@"browser.actioncontroller.grid", @"Grid View");
    }
    else
    {
        changeLayoutTitle = NSLocalizedString(@"browser.actioncontroller.list", @"List View");
    }
    
    __weak typeof(self) weakSelf = self;
    UIAlertAction *changeLayoutAction = [UIAlertAction actionWithTitle:changeLayoutTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if(weakSelf.style == CollectionViewStyleList)
        {
            [weakSelf changeCollectionViewStyle:CollectionViewStyleGrid animated:YES];
        }
        else
        {
            [weakSelf changeCollectionViewStyle:CollectionViewStyleList animated:YES];
        }
    }];
    [self.actionsAlertController addAction:changeLayoutAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        [weakSelf.actionsAlertController dismissViewControllerAnimated:YES completion:nil];
    }];
    
    [self.actionsAlertController addAction:cancelAction];
}

- (void)showPopoverForFailedSyncNodeAtIndexPath:(NSIndexPath *)indexPath
{
    RealmSyncManager *syncManager = [RealmSyncManager sharedManager];
    AlfrescoNode *node = [self.dataSource alfrescoNodeAtIndex:indexPath.row];
    NSString *errorDescription = [syncManager syncErrorDescriptionForNode:node];
    
    if (IS_IPAD)
    {
        __weak typeof(self) weakSelf = self;
        FailedTransferDetailViewController *syncFailedDetailController = [[FailedTransferDetailViewController alloc] initWithTitle:NSLocalizedString(@"sync.state.failed-to-sync", @"Upload failed popover title")
                                                                                                                           message:errorDescription retryCompletionBlock:^() {
                                                                                                                               [weakSelf retrySyncAndCloseRetryPopover];
                                                                                                                           }];
        
        if (self.retrySyncPopover)
        {
            [self.retrySyncPopover dismissPopoverAnimated:YES];
        }
        self.retrySyncPopover = [[UIPopoverController alloc] initWithContentViewController:syncFailedDetailController];
        [self.retrySyncPopover setPopoverContentSize:syncFailedDetailController.view.frame.size];
        
        FileFolderCollectionViewCell *cell = (FileFolderCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:indexPath];
        
        if (cell.accessoryView.window != nil)
        {
            [self.retrySyncPopover presentPopoverFromRect:cell.accessoryView.frame inView:cell permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        }
    }
    else
    {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"sync.state.failed-to-sync", @"Upload Failed")
                                    message:errorDescription
                                   delegate:self
                          cancelButtonTitle:NSLocalizedString(@"Close", @"Close")
                          otherButtonTitles:NSLocalizedString(@"Retry", @"Retry"), nil] show];
    }
}

- (void)retrySyncAndCloseRetryPopover
{
    [[RealmSyncManager sharedManager] retrySyncForDocument:(AlfrescoDocument *)self.retrySyncNode completionBlock:nil];
    [self.retrySyncPopover dismissPopoverAnimated:YES];
    self.retrySyncNode = nil;
    self.retrySyncPopover = nil;
}

- (void)cancelSync
{
    [[RealmSyncManager sharedManager] cancelAllSyncOperations];
}

#pragma mark - UIAdaptivePresentationControllerDelegate methods
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
{
    return UIModalPresentationNone;
}

- (UIViewController *)presentationController:(UIPresentationController *)controller viewControllerForAdaptivePresentationStyle:(UIModalPresentationStyle)style
{
    return self.actionsAlertController;
}

#pragma mark - CollectionViewMultiSelectDelegate methods
- (BOOL)isItemSelected:(NSIndexPath *) indexPath
{
    if(self.isEditing)
    {
        AlfrescoNode *selectedNode = nil;
        if(indexPath.item < [self.dataSource numberOfNodesInCollection])
        {
            selectedNode = [self.dataSource alfrescoNodeAtIndex:indexPath.row];
        }
        
        if([self.multiSelectToolbar.selectedItems containsObject:selectedNode])
        {
            return YES;
        }
    }
    return NO;
}

#pragma mark - RepositoryCollectionViewDataSourceDelegate methods
- (BaseCollectionViewFlowLayout *)currentSelectedLayout
{
    return [self layoutForStyle:self.style];
}

- (id<CollectionViewCellAccessoryViewDelegate>)cellAccessoryViewDelegate
{
    return self;
}

- (void)dataSourceUpdated
{
    [self reloadCollectionView];
}

- (void)requestFailedWithError:(NSError *)error stringFormat:(NSString *)stringFormat
{
    displayErrorMessage([NSString stringWithFormat:stringFormat, [ErrorDescriptions descriptionForError:error]]);
    [Notifier notifyWithAlfrescoError:error];
}

- (void)didDeleteItems:(NSArray *)items atIndexPaths:(NSArray *)indexPathsOfDeletedItems
{
    [self.collectionView performBatchUpdates:^{
        [self.collectionView deleteItemsAtIndexPaths:indexPathsOfDeletedItems];
    } completion:^(BOOL finished) {
        for(AlfrescoNode *deletedNode in items)
        {
            if ([[UniversalDevice detailViewItemIdentifier] isEqualToString:deletedNode.identifier])
            {
                [UniversalDevice clearDetailViewController];
            }
        }
    }];
}

- (void)failedToDeleteItems:(NSError *)error
{
    displayErrorMessage([NSString stringWithFormat:NSLocalizedString(@"error.filefolder.unable.to.delete", @"Unable to delete file/folder"), [ErrorDescriptions descriptionForError:error]]);
}

- (void)didRetrievePermissionsForParentNode
{
#warning TODO
}

- (void)selectItemAtIndexPath:(NSIndexPath *)indexPath
{
#warning TODO
}

- (void)setNodeDataSource:(RepositoryCollectionViewDataSource *)dataSource
{
 #warning TODO
}

- (UISearchBar *)searchBarForSupplimentaryHeaderView
{
    #warning TODO
    return nil;
}

#pragma mark - CollectionViewCellAccessoryViewDelegate methods
- (void)didTapCollectionViewCellAccessorryView:(AlfrescoNode *)node
{
    RealmSyncManager *syncManager = [RealmSyncManager sharedManager];
    SyncNodeStatus *nodeStatus = [syncManager syncStatusForNodeWithId:node.identifier];
    
    NSIndexPath *selectedIndexPath = nil;
    
    NSUInteger item = [self.collectionViewData indexOfObject:node];
    selectedIndexPath = [NSIndexPath indexPathForItem:item inSection:0];
    
    if (node.isFolder)
    {
        [self.collectionView selectItemAtIndexPath:selectedIndexPath animated:YES scrollPosition:UICollectionViewScrollPositionNone];
        
        AlfrescoPermissions *syncNodePermissions = [syncManager permissionsForSyncNode:node];
        if (syncNodePermissions)
        {
            [UniversalDevice pushToDisplayFolderPreviewControllerForAlfrescoDocument:(AlfrescoFolder *)node
                                                                         permissions:syncNodePermissions
                                                                             session:self.session
                                                                navigationController:self.navigationController
                                                                            animated:YES];
        }
        else
        {
            __weak typeof(self) weakSelf = self;
            [self.documentFolderService retrievePermissionsOfNode:node completionBlock:^(AlfrescoPermissions *permissions, NSError *error) {
                if (permissions)
                {
                    [UniversalDevice pushToDisplayFolderPreviewControllerForAlfrescoDocument:(AlfrescoFolder *)node
                                                                                 permissions:permissions
                                                                                     session:weakSelf.session
                                                                        navigationController:weakSelf.navigationController
                                                                                    animated:YES];
                }
                else
                {
                    NSString *permissionRetrievalErrorMessage = [NSString stringWithFormat:NSLocalizedString(@"error.filefolder.permission.notfound", "Permission Retrieval Error"), node.name];
                    displayErrorMessage(permissionRetrievalErrorMessage);
                    [Notifier notifyWithAlfrescoError:error];
                }
            }];
        }
    }
    else
    {
        switch (nodeStatus.status)
        {
            case SyncStatusLoading:
            {
                [syncManager cancelSyncForDocumentWithIdentifier:node.identifier];
                break;
            }
            case SyncStatusFailed:
            {
                self.retrySyncNode = node;
                [self showPopoverForFailedSyncNodeAtIndexPath:selectedIndexPath];
                break;
            }
            default:
            {
                break;
            }
        }
    }
}

#pragma mark - UICollectionViewDelegate methods
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    RealmSyncManager *syncManager = [RealmSyncManager sharedManager];
    AlfrescoNode *selectedNode = [self.dataSource alfrescoNodeAtIndex:indexPath.row];
    SyncNodeStatus *nodeStatus = [[RealmSyncManager sharedManager] syncStatusForNodeWithId:selectedNode.identifier];
    
    if (selectedNode.isFolder)
    {
        RealmSyncViewController *controller = [[RealmSyncViewController alloc] initWithParentNode:selectedNode andSession:self.session];
        controller.style = self.style;
        [self.navigationController pushViewController:controller animated:YES];
    }
    else
    {
        if (nodeStatus.status == SyncStatusLoading)
        {
            [self.collectionView deselectItemAtIndexPath:indexPath animated:YES];
            return;
        }
        
        NSString *filePath = [syncManager contentPathForNode:(AlfrescoDocument *)selectedNode];
        AlfrescoPermissions *syncNodePermissions = [syncManager permissionsForSyncNode:selectedNode];
        if (filePath)
        {
            if ([[ConnectivityManager sharedManager] hasInternetConnection])
            {
                [UniversalDevice pushToDisplayDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                               permissions:syncNodePermissions
                                                                               contentFile:filePath
                                                                          documentLocation:InAppDocumentLocationSync
                                                                                   session:self.session
                                                                      navigationController:self.navigationController
                                                                                  animated:YES];
            }
            else
            {
                [UniversalDevice pushToDisplayDownloadDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                                       permissions:nil
                                                                                       contentFile:filePath
                                                                                  documentLocation:InAppDocumentLocationSync
                                                                                           session:self.session
                                                                              navigationController:self.navigationController
                                                                                          animated:YES];
            }
        }
        else if ([[ConnectivityManager sharedManager] hasInternetConnection])
        {
            [self showHUD];
            __weak typeof(self) weakSelf = self;
            [self.documentFolderService retrievePermissionsOfNode:selectedNode completionBlock:^(AlfrescoPermissions *permissions, NSError *error) {
                
                [weakSelf hideHUD];
                if (!error)
                {
                    [UniversalDevice pushToDisplayDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                                   permissions:permissions
                                                                                   contentFile:filePath
                                                                              documentLocation:InAppDocumentLocationFilesAndFolders
                                                                                       session:weakSelf.session
                                                                          navigationController:weakSelf.navigationController
                                                                                      animated:YES];
                }
                else
                {
                    // display an error
                    NSString *permissionRetrievalErrorMessage = [NSString stringWithFormat:NSLocalizedString(@"error.filefolder.permission.notfound", "Permission Retrieval Error"), selectedNode.name];
                    displayErrorMessage(permissionRetrievalErrorMessage);
                    [Notifier notifyWithAlfrescoError:error];
                }
            }];
        }
    }
}

#pragma mark - Notifications methods
- (void)sessionReceived:(NSNotification *)notification
{
    id<AlfrescoSession> session = notification.object;
    self.session = session;
    self.documentFolderService = [[AlfrescoDocumentFolderService alloc] initWithSession:self.session];
    self.didSyncAfterSessionRefresh = NO;
    self.dataSource.session = session;
    self.title = self.dataSource.screenTitle;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
    // Hold off making sync network requests until either the Sites requests have completed, or a timeout period has passed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSyncOnSiteRequestsCompletionTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        if (!self.didSyncAfterSessionRefresh)
        {
            [self loadSyncNodesForFolder:self.parentNode];
            self.didSyncAfterSessionRefresh = YES;
        }
    });
}

- (void)siteRequestsCompleted:(NSNotification *)notification
{
    [self loadSyncNodesForFolder:self.parentNode];
    self.didSyncAfterSessionRefresh = YES;
}

- (void)editingDocumentCompleted:(NSNotification *)notification
{
    AlfrescoDocument *editedDocument = notification.object;
    NSString *editedDocumentIdentifier = [Utility nodeRefWithoutVersionID:editedDocument.identifier];
    
    NSIndexPath *indexPath = [self indexPathForNodeWithIdentifier:editedDocumentIdentifier inNodeIdentifiers:[self.collectionViewData valueForKeyPath:kVersionSeriesValueKeyPath]];
    
    if (indexPath)
    {
        [self.collectionViewData replaceObjectAtIndex:indexPath.row withObject:editedDocument];
        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
    }
}

- (void)didUpdatePreference:(NSNotification *)notification
{
    NSString *preferenceKeyChanged = notification.object;
    BOOL isCurrentlyOnCellular = [[ConnectivityManager sharedManager] isOnCellular];
    
    if ([preferenceKeyChanged isEqualToString:kSettingsSyncOnCellularIdentifier] && isCurrentlyOnCellular)
    {
        BOOL shouldSyncOnCellular = [notification.userInfo[kSettingChangedToKey] boolValue];
        
        // if changed to no and is syncing, then cancel sync
        if ([[RealmSyncManager sharedManager] isCurrentlySyncing] && !shouldSyncOnCellular)
        {
            [self cancelSync];
        }
        else if (shouldSyncOnCellular)
        {
            [self loadSyncNodesForFolder:self.parentNode];
        }
    }
}

- (void)nodeAdded:(NSNotification *)notification
{
    NSDictionary *infoDictionary = notification.object;
    AlfrescoFolder *parentFolder = [infoDictionary objectForKey:kAlfrescoNodeAddedOnServerParentFolderKey];
    
    if ([parentFolder.identifier isEqualToString:self.parentNode.identifier])
    {
        AlfrescoNode *subnode = [infoDictionary objectForKey:kAlfrescoNodeAddedOnServerSubNodeKey];
        if(subnode)
        {
            [self addAlfrescoNodes:@[subnode] completion:nil];
        }
    }
}

#warning Change progressDelegate from SyncManagerProgressDelegate to RealmSyncManagerProgressDelegate and the new Realm backed system - part of IOS-564
- (void)adjustCollectionViewForProgressView:(NSNotification *)notification
{
    id navigationController = self.navigationController;
    
    if((notification) && (notification.object) && (navigationController != notification.object) && ([navigationController conformsToProtocol: @protocol(SyncManagerProgressDelegate)]))
    {
        /* The sender is not the navigation controller of this view controller, but the navigation controller of another instance of SyncViewController (namely the favorites view controller
         which was created when the account was first added). Will update the progress delegate on SyncManager to be able to show the progress view. The cause of this problem is a timing issue
         between begining the syncing process, menu reloading and delegate calls and notifications going around from component to component.
         */
        [SyncManager sharedManager].progressDelegate = navigationController;
    }
    
    if ([navigationController isKindOfClass:[SyncNavigationViewController class]])
    {
        SyncNavigationViewController *syncNavigationController = (SyncNavigationViewController *)navigationController;
        
        UIEdgeInsets edgeInset = UIEdgeInsetsMake(0.0, 0.0, 0.0, 0.0);
        if ([syncNavigationController isProgressViewVisible])
        {
            edgeInset = UIEdgeInsetsMake(0.0, 0.0, [syncNavigationController progressViewHeight], 0.0);
        }
        self.collectionView.contentInset = edgeInset;
    }
}

- (void)handleSyncObstacles:(NSNotification *)notification
{
    NSMutableDictionary *syncObstacles = [[notification.userInfo objectForKey:kSyncObstaclesKey] mutableCopy];
    
    if (syncObstacles)
    {
        SyncObstaclesViewController *syncObstaclesController = [[SyncObstaclesViewController alloc] initWithErrors:syncObstacles];
        syncObstaclesController.modalPresentationStyle = UIModalPresentationFormSheet;
        
        UINavigationController *syncObstaclesNavigationController = [[UINavigationController alloc] initWithRootViewController:syncObstaclesController];
        [UniversalDevice displayModalViewController:syncObstaclesNavigationController onController:self withCompletionBlock:nil];
    }
}

- (void)connectivityChanged:(NSNotification *)notification
{
    [super connectivityChanged:notification];
    [self loadSyncNodesForFolder:self.parentNode];
}

#pragma mark - Gesture Recognizers methods

- (void) tapToDismissDeleteGestureHandler:(UIGestureRecognizer *)gestureReconizer
{
    if(gestureReconizer.state == UIGestureRecognizerStateEnded)
    {
        CGPoint touchPoint = [gestureReconizer locationInView:self.collectionView];
        if([self.collectionView.collectionViewLayout isKindOfClass:[BaseCollectionViewFlowLayout class]])
        {
            BaseCollectionViewFlowLayout *properLayout = (BaseCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
            UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:properLayout.selectedIndexPathForSwipeToDelete];
            if([cell isKindOfClass:[FileFolderCollectionViewCell class]])
            {
                FileFolderCollectionViewCell *properCell = (FileFolderCollectionViewCell *)cell;
                CGPoint touchPointInButton = [gestureReconizer locationInView:properCell.deleteButton];
                
                if((CGRectContainsPoint(self.collectionView.bounds, touchPoint)) && (!CGRectContainsPoint(properCell.deleteButton.bounds, touchPointInButton)))
                {
                    properLayout.selectedIndexPathForSwipeToDelete = nil;
                }
                else if(CGRectContainsPoint(properCell.deleteButton.bounds, touchPointInButton))
                {
                    [self.dataSource collectionView:self.collectionView didSwipeToDeleteItemAtIndex:properLayout.selectedIndexPathForSwipeToDelete];
                }
            }
        }
    }
}

- (void) swipeToDeletePanGestureHandler:(ALFSwipeToDeleteGestureRecognizer *)gestureRecognizer
{
    if([self.collectionView.collectionViewLayout isKindOfClass:[BaseCollectionViewFlowLayout class]])
    {
        BaseCollectionViewFlowLayout *properLayout = (BaseCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
        if(properLayout.selectedIndexPathForSwipeToDelete)
        {
            if(gestureRecognizer.state == UIGestureRecognizerStateBegan)
            {
                [gestureRecognizer alf_endGestureHandling];
            }
            else if(gestureRecognizer.state == UIGestureRecognizerStateEnded)
            {
                properLayout.selectedIndexPathForSwipeToDelete = nil;
            }
        }
        else
        {
            if (gestureRecognizer.state == UIGestureRecognizerStateBegan)
            {
                CGPoint startingPoint = [gestureRecognizer locationInView:self.collectionView];
                if (CGRectContainsPoint(self.collectionView.bounds, startingPoint))
                {
                    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:startingPoint];
                    if(indexPath && indexPath.item < self.dataSource.numberOfNodesInCollection)
                    {
                        self.initialCellForSwipeToDelete = indexPath;
                    }
                }
            }
            else if (gestureRecognizer.state == UIGestureRecognizerStateChanged)
            {
                if(self.initialCellForSwipeToDelete)
                {
                    CGPoint translation = [gestureRecognizer translationInView:self.view];
                    if (translation.x < 0)
                    {
                        self.shouldShowOrHideDelete = (translation.x * -1) > self.cellActionViewWidth / 2;
                    }
                    else
                    {
                        self.shouldShowOrHideDelete = translation.x > self.cellActionViewWidth / 2;
                    }
                    
                    FileFolderCollectionViewCell *cell = (FileFolderCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:self.initialCellForSwipeToDelete];
                    [cell revealActionViewWithAmount:translation.x];
                }
            }
            else if (gestureRecognizer.state == UIGestureRecognizerStateEnded)
            {
                if(self.initialCellForSwipeToDelete)
                {
                    if(self.shouldShowOrHideDelete)
                    {
                        if(properLayout.selectedIndexPathForSwipeToDelete)
                        {
                            properLayout.selectedIndexPathForSwipeToDelete = nil;
                        }
                        else
                        {
                            properLayout.selectedIndexPathForSwipeToDelete = self.initialCellForSwipeToDelete;
                        }
                    }
                    else
                    {
                        FileFolderCollectionViewCell *cell = (FileFolderCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:self.initialCellForSwipeToDelete];
                        [cell resetView];
                        properLayout.selectedIndexPathForSwipeToDelete = nil;
                    }
                }
            }
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    if(gestureRecognizer == self.tapToDismissDeleteAction)
    {
        if([self.collectionView.collectionViewLayout isKindOfClass:[BaseCollectionViewFlowLayout class]])
        {
            BaseCollectionViewFlowLayout *properLayout = (BaseCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
            if((properLayout.selectedIndexPathForSwipeToDelete != nil) && (!self.editing))
            {
                return YES;
            }
        }
    }
    else if (gestureRecognizer == self.swipeToDeleteGestureRecognizer)
    {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    BOOL shouldBegin = NO;
    if(gestureRecognizer == self.swipeToDeleteGestureRecognizer)
    {
        if([self.collectionView.collectionViewLayout isKindOfClass:[BaseCollectionViewFlowLayout class]])
        {
            BaseCollectionViewFlowLayout *properLayout = (BaseCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
            CGPoint translation = [self.swipeToDeleteGestureRecognizer translationInView:self.collectionView];
            if((translation.x < 0 && !properLayout.selectedIndexPathForSwipeToDelete) || (properLayout.selectedIndexPathForSwipeToDelete))
            {
                shouldBegin = YES;
            }
        }
    }
    else if (gestureRecognizer == self.tapToDismissDeleteAction)
    {
        if([self.collectionView.collectionViewLayout isKindOfClass:[BaseCollectionViewFlowLayout class]])
        {
            BaseCollectionViewFlowLayout *properLayout = (BaseCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
            if((properLayout.selectedIndexPathForSwipeToDelete != nil) && (!self.editing))
            {
                shouldBegin = YES;
            }
        }
    }
    
    return shouldBegin;
}

@end
