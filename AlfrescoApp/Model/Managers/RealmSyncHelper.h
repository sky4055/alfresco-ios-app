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

#import <Foundation/Foundation.h>

@class RLMRealm;
@class SyncNodeStatus;

@interface RealmSyncHelper : NSObject

+ (RealmSyncHelper *)sharedHelper;

- (NSString *)syncNameForNode:(AlfrescoNode *)node inRealm:(RLMRealm *)realm;
- (NSDate *)lastDownloadedDateForNode:(AlfrescoNode *)node inRealm:(RLMRealm *)realm;
- (SyncNodeStatus *)syncNodeStatusObjectForNodeWithId:(NSString *)nodeId inSyncNodesStatus:(NSDictionary *)syncStatuses;
- (NSString *)syncContentDirectoryPathForAccountWithId:(NSString *)accountId;
- (void)resolvedObstacleForDocument:(AlfrescoDocument *)document inRealm:(RLMRealm *)realm;
- (NSString *)syncIdentifierForNode:(AlfrescoNode *)node;
- (NSMutableArray *)syncIdentifiersForNodes:(NSArray *)nodes;
- (void)deleteNodeFromSync:(AlfrescoNode *)node inRealm:(RLMRealm *)realm;

@end
