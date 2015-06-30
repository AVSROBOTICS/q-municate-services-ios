//
//  QMChatService.m
//  Q-municate
//
//  Created by Andrey Ivanov on 02.07.14.
//  Copyright (c) 2014 Quickblox. All rights reserved.
//

#import "QMChatService.h"
#import "QBChatMessage+TextEncoding.h"
#import "NSString+GTMNSStringHTMLAdditions.h"
#import "QBChatMessage+QMCustomParameters.h"

const char *kChatCacheQueue = "com.q-municate.chatCacheQueue";

#define kChatServiceSaveToHistoryTrue @"1"

@interface QMChatService() <QBChatDelegate>

@property (strong, nonatomic) QBMulticastDelegate <QMChatServiceDelegate> *multicastDelegate;
@property (weak, nonatomic) id <QMChatServiceCacheDataSource> cacheDataSource;
@property (strong, nonatomic) QMDialogsMemoryStorage *dialogsMemoryStorage;
@property (strong, nonatomic) QMMessagesMemoryStorage *messagesMemoryStorage;
@property (strong, nonatomic, readonly) NSNumber *dateSendTimeInterval;

@property (copy, nonatomic) void(^chatSuccessBlock)(NSError *error);

@property (strong, nonatomic) NSTimer *presenceTimer;

@end

@implementation QMChatService

@dynamic dateSendTimeInterval;

- (void)dealloc {
	
	NSLog(@"%@ - %@",  NSStringFromSelector(_cmd), self);
	
	[self.presenceTimer invalidate];
	[QBChat.instance removeDelegate:self];
}

#pragma mark - Configure

- (instancetype)initWithServiceManager:(id<QMServiceManagerProtocol>)serviceManager cacheDataSource:(id<QMChatServiceCacheDataSource>)cacheDataSource {
	
	self = [super initWithServiceManager:serviceManager];
	
	if (self) {
		
		self.cacheDataSource = cacheDataSource;
		[self loadCachedDialogs];
		
		self.presenceTimerInterval = 45.0;
		self.automaticallySendPresences = YES;
	}
	
	return self;
}

- (void)serviceWillStart {
	
	self.multicastDelegate = (id<QMChatServiceDelegate>)[[QBMulticastDelegate alloc] init];
	self.dialogsMemoryStorage = [[QMDialogsMemoryStorage alloc] init];
	self.messagesMemoryStorage = [[QMMessagesMemoryStorage alloc] init];
	
	[QBChat.instance addDelegate:self];
}

#pragma mark - Getters

- (NSNumber *)dateSendTimeInterval {
	
	return @((NSInteger)CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970);
}

#pragma mark - Load cached data

- (void)loadCachedDialogs {
	
	__weak __typeof(self)weakSelf = self;
	
	if ([self.cacheDataSource respondsToSelector:@selector(cachedDialogs:)]) {
		
		[self.cacheDataSource cachedDialogs:^(NSArray *collection) {
			
			[weakSelf.dialogsMemoryStorage addChatDialogs:collection andJoin:NO];
			
			if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogsToMemoryStorage:)]) {
				[weakSelf.multicastDelegate chatService:weakSelf didAddChatDialogsToMemoryStorage:collection];
			}
		}];
	}
}

- (void)loadCahcedMessagesWithDialogID:(NSString *)dialogID {
	
	if ([self.cacheDataSource respondsToSelector:@selector(cachedMessagesWithDialogID:block:)]) {
		
		__weak __typeof(self)weakSelf = self;
		[self.cacheDataSource cachedMessagesWithDialogID:dialogID block:^(NSArray *collection) {
			
			if (collection.count > 0) {
				
				[weakSelf.messagesMemoryStorage replaceMessages:collection forDialogID:dialogID];
				
				if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddMessagesToMemoryStorage:forDialogID:)]) {
					[weakSelf.multicastDelegate chatService:weakSelf didAddMessagesToMemoryStorage:collection forDialogID:dialogID];
				}
			}
		}];
	}
}

#pragma mark - Add / Remove Multicast delegate

- (void)addDelegate:(id<QMChatServiceDelegate>)delegate {
	
	[self.multicastDelegate addDelegate:delegate];
}

- (void)removeDelegate:(id<QMChatServiceDelegate>)delegate{
	
	[self.multicastDelegate removeDelegate:delegate];
}

#pragma mark - QBChatDelegate

- (void)chatDidLogin {
	
	if (self.automaticallySendPresences){
		[self startSendPresence];
	}
	
	if (self.chatSuccessBlock) {
		self.chatSuccessBlock(nil);
		self.chatSuccessBlock = nil;
	}
}

- (void)chatDidFailWithStreamError:(NSError *)error {
	
	if (self.chatSuccessBlock){
		self.chatSuccessBlock(error);
		self.chatSuccessBlock = nil;
	}
	
	[self stopSendPresence];
}

#pragma mark Handle messages (QBChatDelegate)

- (void)chatRoomDidReceiveMessage:(QBChatMessage *)message fromRoomJID:(NSString *)roomJID {
    
	[self handleChatMessage:message];
    
}

- (void)chatDidReceiveMessage:(QBChatMessage *)message  {
	
	[self handleChatMessage:message];
}

- (void)chatDidReceiveSystemMessage:(QBChatMessage *)message
{
    [self handleSystemMessage:message];
}

- (void)chatDidReadMessageWithID:(NSString *)messageID
{
    NSLog(@"chatDidReadMessageWithID: %@", messageID);
}

#pragma mark - Chat Login/Logout

- (void)logIn:(void(^)(NSError *error))completion {
	
	BOOL isAutorized = self.serviceManager.isAutorized;
	NSAssert(isAutorized, @"User must be autorized");
	
	self.chatSuccessBlock = completion;
	QBUUser *user = self.serviceManager.currentUser;
    NSAssert(user != nil, @"User must be already allocated!");
	
	if (QBChat.instance.isLoggedIn) {
		if( self.chatSuccessBlock != nil ){
			self.chatSuccessBlock(nil);
		}
	}
	else {
		
		QBChat.instance.autoReconnectEnabled = YES;
		QBChat.instance.streamManagementEnabled = YES;
		[QBChat.instance loginWithUser:user];
		
	}
}

- (void)logoutChat {
	
	[self stopSendPresence];
	
	if (QBChat.instance.isLoggedIn) {
		[QBChat.instance logout];
	}
}

#pragma mark - Presence

- (void)startSendPresence {
	
	[self sendPresence:nil];
	
	self.presenceTimer =
	[NSTimer scheduledTimerWithTimeInterval:self.presenceTimerInterval
									 target:self
								   selector:@selector(sendPresence:)
								   userInfo:nil
									repeats:YES];
}

- (void)sendPresence:(NSTimer *)timer {
	
	[QBChat.instance sendPresence];
}

- (void)stopSendPresence {
	
	[self.presenceTimer invalidate];
	self.presenceTimer = nil;
}

#pragma mark - Handle Chat messages

- (void)handleSystemMessage:(QBChatMessage *)message {
    
    if (message.messageType == QMMessageTypeCreateGroupDialog) {
        if (message.senderID != [QBSession currentSession].currentUser.ID) {
            __weak __typeof(self)weakSelf = self;
            
            [self.dialogsMemoryStorage addChatDialog:message.dialog andJoin:YES onJoin:^{
                
                if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogToMemoryStorage:)]) {
                    [weakSelf.multicastDelegate chatService:weakSelf didAddChatDialogToMemoryStorage:message.dialog];
                }
            }];
        }
    }
}

- (void)handleChatMessage:(QBChatMessage *)message {
	
	NSAssert(message.dialogID, @"Need update this case");
	
	if (message.messageType == QMMessageTypeText) {
		
		if (message.recipientID == message.senderID) {
			return;
		}
        
        BOOL shouldSaveDialog = NO;
        
		//Update chat dialog in memory storage
		QBChatDialog *chatDialogToUpdate = [self.dialogsMemoryStorage chatDialogWithID:message.dialogID];
        
        if (!chatDialogToUpdate)
        {
            chatDialogToUpdate = [[QBChatDialog alloc] initWithDialogID:message.dialogID];
            chatDialogToUpdate.occupantIDs = @[@([self.serviceManager currentUser].ID), @(message.senderID)];
            chatDialogToUpdate.type = QBChatDialogTypePrivate;
            
            shouldSaveDialog = YES;
        }
        
		chatDialogToUpdate.lastMessageText = message.encodedText;
		chatDialogToUpdate.lastMessageDate = [NSDate dateWithTimeIntervalSince1970:message.customDateSent.doubleValue];
		chatDialogToUpdate.unreadMessagesCount++;
        
        if (shouldSaveDialog) {
            [self.dialogsMemoryStorage addChatDialog:chatDialogToUpdate andJoin:NO onJoin:nil];
            
            if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogToMemoryStorage:)]) {
                [self.multicastDelegate chatService:self didAddChatDialogToMemoryStorage:chatDialogToUpdate];
            }
        }
        
		//Add message in memory storage
		[self.messagesMemoryStorage addMessage:message forDialogID:message.dialogID];
		
		if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddMessageToMemoryStorage:forDialogID:)]) {
			[self.multicastDelegate chatService:self didAddMessageToMemoryStorage:message forDialogID:message.dialogID];
		}
        
        if (message.markable) {
            [[QBChat instance] readMessage:message];
        }
		
		return;
	}
	else if (message.messageType == QMMessageTypeUpdateGroupDialog) {
        
		QBChatDialog *chatDialogToUpdate = [self.dialogsMemoryStorage chatDialogWithID:message.dialogID];
		
        if (chatDialogToUpdate) {
//        if (!chatDialogToUpdate.updatedAt || [chatDialogToUpdate.updatedAt compare:message.dialog.updatedAt] == NSOrderedAscending) {
			chatDialogToUpdate.lastMessageText = message.encodedText;
            chatDialogToUpdate.name = message.dialog.name;
            chatDialogToUpdate.photo = message.dialog.photo;
            chatDialogToUpdate.occupantIDs = message.dialog.occupantIDs;
            chatDialogToUpdate.lastMessageDate = message.dialog.lastMessageDate;
            
            if ([self.multicastDelegate respondsToSelector:@selector(chatService:didUpdateChatDialogInMemoryStorage:)]) {
                [self.multicastDelegate chatService:self didUpdateChatDialogInMemoryStorage:chatDialogToUpdate];
            }
//        }
        }
	}
	else if (message.messageType == QMMessageTypeContactRequest) {
		
		
        if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogToMemoryStorage:)]) {
			[self.multicastDelegate chatService:self didAddChatDialogToMemoryStorage:message.dialog];
		}
	}
	
	QBChatDialog *dialog = message.dialog;
	
	if ([message.saveToHistory isEqualToString:kChatServiceSaveToHistoryTrue]) {
		
		[self.messagesMemoryStorage addMessage:message forDialogID:dialog.ID];
		
		if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddMessageToMemoryStorage:forDialogID:)]) {
			[self.multicastDelegate chatService:self didAddMessageToMemoryStorage:message forDialogID:message.dialogID];
		}
	}
	
	if ([self.multicastDelegate respondsToSelector:@selector(chatService:didReceiveNotificationMessage:createDialog:)]) {
		[self.multicastDelegate chatService:self didReceiveNotificationMessage:message createDialog:message.dialog];
	}
}

- (void)joinToGroupDialog:(QBChatDialog *)dialog
               failed:(void (^)(NSError *))failed {
    
    NSParameterAssert(dialog.type != QBChatDialogTypePrivate);
    
    if (dialog.isJoined) {
        return;
    }
    
    NSString *dialogID = dialog.ID;
    
    [dialog setOnJoinFailed:^(NSError *error) {
        
        if (error.code == 201 || error.code == 404 || error.code == 407) {
            
            [self.dialogsMemoryStorage deleteChatDialogWithID:dialogID];
            
            if ([self.multicastDelegate respondsToSelector:@selector(chatService:didDeleteChatDialogWithIDFromMemoryStorage:)]) {
                [self.multicastDelegate chatService:self didDeleteChatDialogWithIDFromMemoryStorage:dialogID];
            }
        }
        
        if (failed) {
            failed(error);
        }
        
    }];
    
    [dialog join];
}


#pragma mark - Dialog history

- (void)allDialogsWithPageLimit:(NSUInteger)limit
				extendedRequest:(NSDictionary *)extendedRequest
				iterationBlock:(void(^)(QBResponse *response, NSArray *dialogObjects, NSSet *dialogsUsersIDs, BOOL *stop))interationBlock
					 completion:(void(^)(QBResponse *response))completion {
	
	__weak __typeof(self)weakSelf = self;
	
	__block QBResponsePage *responsePage = [QBResponsePage responsePageWithLimit:limit];
	__block BOOL cancel = NO;
	
	__block dispatch_block_t t_request;
	
	dispatch_block_t request = [^{
		
		[QBRequest dialogsForPage:responsePage extendedRequest:extendedRequest successBlock:^(QBResponse *response, NSArray *dialogObjects, NSSet *dialogsUsersIDs, QBResponsePage *page) {
            
			[weakSelf.dialogsMemoryStorage addChatDialogs:dialogObjects andJoin:NO];
			
			if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogsToMemoryStorage:)]) {
				[weakSelf.multicastDelegate chatService:weakSelf didAddChatDialogsToMemoryStorage:dialogObjects];
			}
			
			responsePage.skip += dialogObjects.count;
			
			if (page.totalEntries <= responsePage.skip) {
				cancel = YES;
			}
			
			interationBlock(response, dialogObjects, dialogsUsersIDs, &cancel);
			
			if (!cancel) {
				
				t_request();
			}
			else {
				
				if (completion) {
					completion(response);
				}
			}
			
		} errorBlock:^(QBResponse *response) {
			
			[weakSelf.serviceManager handleErrorResponse:response];
			
			if (completion) {
				completion(response);
			}
		}];
		
	} copy];
	
	t_request = request;
	request();
}

#pragma mark - Create Private/Group dialog

- (void)createPrivateChatDialogWithOpponentID:(NSUInteger)opponentID
                                 completion:(void(^)(QBResponse *response, QBChatDialog *createdDialo))completion {
    
    QBChatDialog *dialog = [self.dialogsMemoryStorage privateChatDialogWithOpponentID:opponentID];
    
    if (!dialog) {
        
        QBChatDialog *chatDialog = [[QBChatDialog alloc] init];
        chatDialog.type = QBChatDialogTypePrivate;
        chatDialog.occupantIDs = @[@(opponentID)];
        
        __weak __typeof(self)weakSelf = self;
        
        [QBRequest createDialog:chatDialog successBlock:^(QBResponse *response, QBChatDialog *createdDialog) {
            
            [weakSelf.dialogsMemoryStorage addChatDialog:createdDialog andJoin:NO onJoin:nil];
            
            //Notify about create new dialog
            
            if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogToMemoryStorage:)]) {
                [weakSelf.multicastDelegate chatService:weakSelf didAddChatDialogToMemoryStorage:createdDialog];
            }
            
            if (completion) {
                completion(response, createdDialog);
            }
            
            
        } errorBlock:^(QBResponse *response) {
            
            [weakSelf.serviceManager handleErrorResponse:response];
            
            if (completion) {
                completion(response, nil);
            }
        }];
    }
    else {
        
        if (completion) {
            completion(nil, dialog);
        }
    }
}

- (void)createPrivateChatDialogWithOpponent:(QBUUser *)opponent
								 completion:(void(^)(QBResponse *response, QBChatDialog *createdDialo))completion {
	
    [self createPrivateChatDialogWithOpponentID:opponent.ID completion:completion];
}

- (void)createGroupChatDialogWithName:(NSString *)name photo:(NSString *)photo occupants:(NSArray *)occupants
						   completion:(void(^)(QBResponse *response, QBChatDialog *createdDialog))completion {
	
	NSMutableSet *occupantIDs = [NSMutableSet set];
	
	for (QBUUser *user in occupants) {
		NSAssert([user isKindOfClass:[QBUUser class]], @"occupants must be an array of QBUUser instances");
		[occupantIDs addObject:@(user.ID)];
	}
	
	QBChatDialog *chatDialog = [[QBChatDialog alloc] init];
	chatDialog.name = name;
	chatDialog.photo = photo;
	chatDialog.occupantIDs = occupantIDs.allObjects;
	chatDialog.type = QBChatDialogTypeGroup;
	
	__weak __typeof(self)weakSelf = self;
	[QBRequest createDialog:chatDialog successBlock:^(QBResponse *response, QBChatDialog *createdDialog) {
        
		[weakSelf.dialogsMemoryStorage addChatDialog:createdDialog andJoin:YES onJoin:^{
			
			if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddChatDialogToMemoryStorage:)]) {
				[weakSelf.multicastDelegate chatService:weakSelf didAddChatDialogToMemoryStorage:createdDialog];
			}
			
			if (completion) {
				completion(response, createdDialog);
			}
		}];
		
	} errorBlock:^(QBResponse *response) {
		
		[weakSelf.serviceManager handleErrorResponse:response];
		
		if (completion) {
			completion(response, nil);
		}
	}];
}

#pragma mark - Edit dialog methods

- (void)changeDialogName:(NSString *)dialogName forChatDialog:(QBChatDialog *)chatDialog
			  completion:(void(^)(QBResponse *response, QBChatDialog *updatedDialog))completion {
	
	chatDialog.name = dialogName;
	
	__weak __typeof(self)weakSelf = self;
	[QBRequest updateDialog:chatDialog successBlock:^(QBResponse *response, QBChatDialog *updatedDialog) {
        
		[weakSelf.dialogsMemoryStorage addChatDialog:updatedDialog andJoin:NO onJoin:nil];
		
		if (completion) {
			completion(response, updatedDialog);
		}
		
	} errorBlock:^(QBResponse *response) {
		
		[weakSelf.serviceManager handleErrorResponse:response];
		
		if (completion) {
			completion(response, nil);
		}
	}];
}

- (void)joinOccupantsWithIDs:(NSArray *)ids toChatDialog:(QBChatDialog *)chatDialog
				  completion:(void(^)(QBResponse *response, QBChatDialog *updatedDialog))completion {
	
	__weak __typeof(self)weakSelf = self;
    
    chatDialog.pushOccupantsIDs = ids;
	
	[QBRequest updateDialog:chatDialog successBlock:^(QBResponse *response, QBChatDialog *updatedDialog) {

		[weakSelf.dialogsMemoryStorage addChatDialog:updatedDialog andJoin:NO onJoin:nil];
		
		if (completion) {
			completion(response, updatedDialog);
		}
		
	} errorBlock:^(QBResponse *response) {
		
		[weakSelf.serviceManager handleErrorResponse:response];
		
		if (completion) {
			completion(response, nil);
		}
	}];
}

- (void)deleteDialogWithID:(NSString *)dialogId completion:(void (^)(QBResponse *))completion {
	
    NSParameterAssert(dialogId);
    
    __weak __typeof(self)weakSelf = self;
    
	[QBRequest deleteDialogWithID:dialogId successBlock:^(QBResponse *response) {
        
		[weakSelf.dialogsMemoryStorage deleteChatDialogWithID:dialogId];
		[weakSelf.messagesMemoryStorage deleteMessagesWithDialogID:dialogId];
		
		if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didDeleteChatDialogWithIDFromMemoryStorage:)]) {
			[weakSelf.multicastDelegate chatService:weakSelf didDeleteChatDialogWithIDFromMemoryStorage:dialogId];
		}
		
		if (completion) {
			completion(response);
		}
		
	} errorBlock:^(QBResponse *response) {
		
		if (response.status == QBResponseStatusCodeNotFound) {
			[weakSelf.dialogsMemoryStorage deleteChatDialogWithID:dialogId];
			
			if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didDeleteChatDialogWithIDFromMemoryStorage:)]) {
				[weakSelf.multicastDelegate chatService:weakSelf didDeleteChatDialogWithIDFromMemoryStorage:dialogId];
			}
		}
		else {
			[weakSelf.serviceManager handleErrorResponse:response];
		}
		
		if (completion) {
			completion(response);
		}
	}];
}

#pragma mark - Messages histroy

- (void)messagesWithChatDialogID:(NSString *)chatDialogID completion:(void(^)(QBResponse *response, NSArray *messages))completion {
	
	[self loadCahcedMessagesWithDialogID:chatDialogID];
	
	__weak __typeof(self) weakSelf = self;
    [QBRequest messagesWithDialogID:chatDialogID
                    extendedRequest:@{@"sort_desc" : @"date_sent",}
                            forPage:nil
                       successBlock:^(QBResponse *response, NSArray *messages, QBResponsePage *page) {
                           NSArray* sortedMessages = [[messages reverseObjectEnumerator] allObjects];
                           [weakSelf.messagesMemoryStorage replaceMessages:sortedMessages forDialogID:chatDialogID];
                           
                           if ([weakSelf.multicastDelegate respondsToSelector:@selector(chatService:didAddMessagesToMemoryStorage:forDialogID:)]) {
                               [weakSelf.multicastDelegate chatService:weakSelf didAddMessagesToMemoryStorage:sortedMessages forDialogID:chatDialogID];
                           }
                           
                           if (completion) {
                               completion(response, sortedMessages);
                           }
                       } errorBlock:^(QBResponse *response) {
                           // case where we may have deleted dialog from another device
                           if( response.status != QBResponseStatusCodeNotFound ) {
                               [weakSelf.serviceManager handleErrorResponse:response];
                           }
                           
                           if (completion) {
                               completion(response, nil);
                           }
                       }];
}

- (void)earlierMessagesWithChatDialogID:(NSString *)chatDialogID completion:(void(^)(QBResponse *response, NSArray *messages))completion {
    
    if ([self.messagesMemoryStorage isEmptyForDialogID:chatDialogID]) {
        
        [self messagesWithChatDialogID:chatDialogID completion:completion];
        
        return;
    }
    
    QBChatMessage *oldestMessage = [self.messagesMemoryStorage oldestMessageForDialogID:chatDialogID];
    NSString *oldestMessageDate = [NSString stringWithFormat:@"%ld", (long)[oldestMessage.dateSent timeIntervalSince1970]];
    __weak __typeof(self) weakSelf = self;
    
    [QBRequest messagesWithDialogID:chatDialogID extendedRequest:@{@"date_sent[lt]": oldestMessageDate} forPage:nil successBlock:^(QBResponse *response, NSArray *messages, QBResponsePage *page) {
        
        [weakSelf.messagesMemoryStorage addMessages:messages forDialogID:chatDialogID];
        
        if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddMessagesToMemoryStorage:forDialogID:)]) {
            [self.multicastDelegate chatService:weakSelf didAddMessagesToMemoryStorage:messages forDialogID:chatDialogID];
        }
        
        if (completion) {
            completion(response, messages);
        }
        
    } errorBlock:^(QBResponse *response) {
        
        // case where we may have deleted dialog from another device
        if( response.status != QBResponseStatusCodeNotFound ) {
            [weakSelf.serviceManager handleErrorResponse:response];
        }
        
        
        if (completion) {
            completion(response, nil);
        }
        
    }];
}

#pragma mark - Send messages

- (BOOL)sendMessage:(QBChatMessage *)message type:(QMMessageType)type toDialog:(QBChatDialog *)dialog save:(BOOL)save completion:(void(^)(NSError *error))completion {
	
	message.customDateSent = self.dateSendTimeInterval;
	
	message.text = [message.text gtm_stringByEscapingForHTML];
	
	//Save to history
	if (save) {
		message.saveToHistory = kChatServiceSaveToHistoryTrue;
	}
	//Set message type
	if (type != QMMessageTypeText) {
		message.messageType = type;
	}
	
	QBUUser *currentUser = self.serviceManager.currentUser;
	
	if (dialog.type == QBChatDialogTypePrivate) {
		
		message.senderID = currentUser.ID;
		message.recipientID = dialog.recipientID;
		message.markable = YES;
	}
	
	return [dialog sendMessage:message sentBlock:^(NSError *error) {
		
		if (!error) {
			
			message.senderID = currentUser.ID;
			
			dialog.lastMessageText = message.encodedText;
			dialog.lastMessageDate = message.dateSent;
			
			[self.messagesMemoryStorage addMessage:message forDialogID:dialog.ID];
			
			if ([self.multicastDelegate respondsToSelector:@selector(chatService:didAddMessageToMemoryStorage:forDialogID:)]) {
				[self.multicastDelegate chatService:self didAddMessageToMemoryStorage:message forDialogID:dialog.ID];
			}
		}
		
		if (completion) {
			completion(error);
		}
	}];
}

- (BOOL)sendMessage:(QBChatMessage *)message toDialog:(QBChatDialog *)dialog save:(BOOL)save completion:(void(^)(NSError *error))completion {
	
	return [self sendMessage:message type:QMMessageTypeText toDialog:dialog save:save completion:completion];
}

- (BOOL)sendMessage:(QBChatMessage *)message toDialogId:(NSString *)dialogID save:(BOOL)save completion:(void (^)(NSError *))completion
{
    NSCParameterAssert(dialogID);
    QBChatDialog *dialog = [self.dialogsMemoryStorage chatDialogWithID:dialogID];
    NSAssert(dialog != nil, @"Dialog have to be in memory cache!");
    
    return [self sendMessage:message toDialog:dialog save:YES completion:completion];
}

#pragma mark - QMMemoryStorageProtocol

- (void)free {
	
	[self.messagesMemoryStorage free];
	[self.dialogsMemoryStorage free];
}

#pragma mark - System messages

- (void)notifyUsersWithIDs:(NSArray *)usersIDs aboutAddingToDialog:(QBChatDialog *)dialog {
    
    for (NSNumber *occupantID in usersIDs) {
        
        if (self.serviceManager.currentUser.ID == [occupantID integerValue]) {
            continue;
        }
        
        QBChatMessage *privateMessage = [self systemMessageWithRecipientID:[occupantID integerValue] parameters:nil];
        privateMessage.messageType = QMMessageTypeCreateGroupDialog;
        [privateMessage updateCustomParametersWithDialog:dialog];
        
        [[QBChat instance] sendSystemMessage:privateMessage];
    }
}

- (void)notifyAboutUpdateDialog:(QBChatDialog *)updatedDialog
      occupantsCustomParameters:(NSDictionary *)occupantsCustomParameters
               notificationText:(NSString *)notificationText
                     completion:(void (^)(NSError *))completion {
    
    NSParameterAssert(updatedDialog);
    
    QBChatMessage *message = [QBChatMessage message];
    message.messageType = QMMessageTypeUpdateGroupDialog;
    message.text = notificationText;
    message.saveToHistory = kChatServiceSaveToHistoryTrue;
    
    [message updateCustomParametersWithDialog:updatedDialog];
    
    if (occupantsCustomParameters)
    {
        [message.customParameters addEntriesFromDictionary:occupantsCustomParameters];
    }
    
    BOOL sendMessage = [updatedDialog sendMessage:message sentBlock:completion];
    
    if (!sendMessage) {
        if (completion) {
            completion(nil);
        }
        
    }
}

- (void)notifyOponentAboutAcceptingContactRequest:(BOOL)accept opponentID:(NSUInteger)opponentID completion:(void(^)(NSError *error))completion {
    
    QBChatMessage *message = [self privateMessageWithRecipientID:opponentID text:accept ? @"Accept contact request" : @"Reject contact request" save:YES];
    
    message.messageType = accept ? QMMessageTypeAcceptContactRequest : QMMessageTypeRejectContactRequest;
    
    QBChatDialog *p2pDialog = [self.dialogsMemoryStorage privateChatDialogWithOpponentID:opponentID];
    NSParameterAssert(p2pDialog);
    
    [message updateCustomParametersWithDialog:p2pDialog];
    [p2pDialog sendMessage:message sentBlock:completion];
}

#pragma mark System messages Utilites

- (QBChatMessage *)privateMessageWithRecipientID:(NSUInteger)recipientID text:(NSString *)text save:(BOOL)save {
	
	QBChatMessage *message = [QBChatMessage message];
	message.recipientID = recipientID;
	message.senderID = self.serviceManager.currentUser.ID;
	message.customDateSent = self.dateSendTimeInterval;
	
	if (save) {
		message.saveToHistory = kChatServiceSaveToHistoryTrue;
	}
	
	return message;
}

- (QBChatMessage *)systemMessageWithRecipientID:(NSUInteger)recipientID parameters:(NSDictionary *)paramters {
    
    QBChatMessage *message = [QBChatMessage message];
    message.recipientID = recipientID;
    message.senderID = self.serviceManager.currentUser.ID;
    
    if (paramters) {
        [message.customParameters addEntriesFromDictionary:paramters];
    }
    
    return message;
}

@end
